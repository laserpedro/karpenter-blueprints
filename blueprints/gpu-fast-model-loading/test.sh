#!/bin/bash
# Test script for the GPU fast model loading blueprint
# Validates that Karpenter provisions a GPU node with:
#   - the local NVMe instance store assembled as a RAID-0 array (instanceStorePolicy: RAID0)
#   - containerd configured with the SOCI snapshotter (FastImagePull feature gate)
#   - model weights downloaded from S3 straight onto the NVMe array by the model-preloader DaemonSet
#   - working NVIDIA drivers (nvidia-smi)
#
# The blueprint targets p5.48xlarge by default. To keep the test affordable it
# creates its own NodePool that reuses the blueprint EC2NodeClass but allows
# smaller GPU families with local NVMe (g6/g5 by default).
#
# Prerequisites:
# - kubectl and aws CLI configured with access to the EKS cluster / AWS account
# - Karpenter installed
# - NVIDIA device plugin installed (see the nvidia-gpu-workload blueprint)
# - The Karpenter node IAM role allowed to read the test bucket (see README)
# - Environment variables:
#     CLUSTER_NAME, KARPENTER_NODE_IAM_ROLE_NAME
#     MODEL_BUCKET          S3 bucket the test may write to and nodes can read from
#   Optional:
#     MODEL_PATH            Prefix that already holds model files. When unset the
#                           test uploads a synthetic 1 GiB "model" under
#                           karpenter-blueprints/gpu-fast-model-loading-test/
#     TEST_INSTANCE_FAMILIES  Comma separated list, default "g6,g5"
#
# Usage: ./test.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TIMEOUT_NODE_READY=600
TIMEOUT_POD_READY=900
TEST_NODEPOOL="gpu-fast-model-loading-test"
TEST_INSTANCE_FAMILIES="${TEST_INSTANCE_FAMILIES:-g6,g5}"
SYNTHETIC_MODEL_PATH="karpenter-blueprints/gpu-fast-model-loading-test"
TMP_DIR="$(mktemp -d)"

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${GREEN}[TEST]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."

    for tool in kubectl aws; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "$tool not found"
            exit 1
        fi
    done

    if ! kubectl get nodes &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    if [ -z "$CLUSTER_NAME" ]; then
        log_error "CLUSTER_NAME environment variable is not set"
        log_info "Set it with: export CLUSTER_NAME=\$(terraform -chdir='../../cluster/terraform' output -raw cluster_name)"
        exit 1
    fi

    if [ -z "$KARPENTER_NODE_IAM_ROLE_NAME" ]; then
        log_error "KARPENTER_NODE_IAM_ROLE_NAME environment variable is not set"
        log_info "Set it with: export KARPENTER_NODE_IAM_ROLE_NAME=\$(terraform -chdir='../../cluster/terraform' output -raw node_instance_role_name)"
        exit 1
    fi

    if [ -z "$MODEL_BUCKET" ]; then
        log_error "MODEL_BUCKET environment variable is not set"
        log_info "Set it to an S3 bucket the Karpenter node role can read: export MODEL_BUCKET=my-models-bucket"
        exit 1
    fi

    if ! kubectl get daemonset -A 2>/dev/null | grep -q "nvidia-device-plugin"; then
        log_error "NVIDIA device plugin is not installed"
        log_info "Install it with: helm upgrade -i nvdp nvdp/nvidia-device-plugin --namespace nvidia-device-plugin --create-namespace"
        exit 1
    fi

    log_info "Using cluster: $CLUSTER_NAME, IAM role: $KARPENTER_NODE_IAM_ROLE_NAME, bucket: $MODEL_BUCKET"
    log_info "Prerequisites check passed"
}

prepare_model() {
    if [ -n "$MODEL_PATH" ]; then
        log_info "Using existing model at s3://$MODEL_BUCKET/$MODEL_PATH"
        return 0
    fi
    MODEL_PATH="$SYNTHETIC_MODEL_PATH"
    if aws s3 ls "s3://$MODEL_BUCKET/$MODEL_PATH/" 2>/dev/null | grep -q "model-00001"; then
        log_info "Synthetic model already present at s3://$MODEL_BUCKET/$MODEL_PATH"
        return 0
    fi
    log_info "Uploading a synthetic 1 GiB model to s3://$MODEL_BUCKET/$MODEL_PATH ..."
    for i in 1 2; do
        dd if=/dev/urandom of="$TMP_DIR/model-0000$i-of-00002.safetensors" bs=1M count=512 status=none
    done
    echo '{"architectures": ["SyntheticTest"]}' > "$TMP_DIR/config.json"
    aws s3 cp "$TMP_DIR" "s3://$MODEL_BUCKET/$MODEL_PATH/" --recursive --only-show-errors
    log_info "Synthetic model uploaded"
}

wait_for_nodeclaim() {
    local label_selector=$1
    local expected_count=$2
    local timeout=$TIMEOUT_NODE_READY
    local elapsed=0

    log_info "Waiting for $expected_count nodeclaim(s) with selector '$label_selector' to be ready..."

    while [ $elapsed -lt $timeout ]; do
        ready_count=$(kubectl get nodeclaims -l "$label_selector" --no-headers 2>/dev/null | grep -c "True" || true)
        ready_count=${ready_count:-0}
        ready_count=$((ready_count + 0))
        if [ "$ready_count" -ge "$expected_count" ]; then
            log_info "$ready_count nodeclaim(s) ready"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for nodeclaims to be ready"
    kubectl get nodeclaims -l "$label_selector" 2>/dev/null || true
    return 1
}

wait_for_pod_phase() {
    local label_selector=$1
    local expected_phase=$2
    local timeout=$TIMEOUT_POD_READY
    local elapsed=0

    log_info "Waiting for pod(s) '$label_selector' to reach phase '$expected_phase'..."

    while [ $elapsed -lt $timeout ]; do
        phase=$(kubectl get pods -l "$label_selector" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        if [ "$phase" == "$expected_phase" ]; then
            log_info "Pod '$label_selector' is $expected_phase"
            return 0
        fi
        if [ "$phase" == "Failed" ]; then
            log_error "Pod '$label_selector' failed"
            kubectl describe pods -l "$label_selector" 2>/dev/null || true
            kubectl logs -l "$label_selector" --all-containers=true 2>/dev/null || true
            return 1
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        echo -n "."
    done
    echo ""
    log_error "Timeout waiting for pod '$label_selector' to reach '$expected_phase'"
    kubectl describe pods -l "$label_selector" 2>/dev/null || true
    return 1
}

cleanup() {
    log_info "Cleaning up gpu-fast-model-loading test resources..."
    kubectl delete pod gpu-fast-model-loading-verify --ignore-not-found=true 2>/dev/null || true
    kubectl delete daemonset model-preloader --ignore-not-found=true 2>/dev/null || true
    kubectl delete nodepool "$TEST_NODEPOOL" --ignore-not-found=true 2>/dev/null || true
    kubectl delete ec2nodeclass gpu-fast-model-loading --ignore-not-found=true 2>/dev/null || true
    rm -rf "$TMP_DIR"
    sleep 10
}

test_fast_model_loading() {
    cleanup
    TMP_DIR="$(mktemp -d)"
    prepare_model

    # --- Step 1: EC2NodeClass straight from the blueprint ---
    log_info "Creating EC2NodeClass from nodeclass.yaml..."
    sed "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g; s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" nodeclass.yaml | kubectl apply -f -

    # --- Step 2: Test NodePool (smaller GPU families with local NVMe) ---
    families_yaml=$(echo "$TEST_INSTANCE_FAMILIES" | tr ',' '\n' | sed 's/^/          - "/; s/$/"/')
    log_info "Creating NodePool $TEST_NODEPOOL for families: $TEST_INSTANCE_FAMILIES"
    cat <<NODEPOOL | kubectl apply -f -
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: $TEST_NODEPOOL
spec:
  limits:
    nvidia.com/gpu: 2
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 1m
  template:
    metadata:
      labels:
        intent: gpu-fast-model-loading
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: gpu-fast-model-loading
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values:
$families_yaml
        - key: karpenter.k8s.aws/instance-gpu-manufacturer
          operator: In
          values: ["nvidia"]
        - key: karpenter.k8s.aws/instance-local-nvme
          operator: Exists
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
      taints:
        - key: nvidia.com/gpu
          effect: NoSchedule
NODEPOOL

    # --- Step 3: model-preloader DaemonSet from the blueprint ---
    log_info "Creating model-preloader DaemonSet for s3://$MODEL_BUCKET/$MODEL_PATH ..."
    sed "s|<<MODEL_BUCKET>>|$MODEL_BUCKET|g; s|<<MODEL_PATH>>|$MODEL_PATH|g" model-preloader.yaml | kubectl apply -f -

    # --- Step 4: Verification pod (triggers the GPU node launch) ---
    log_info "Deploying verification pod..."
    cat <<POD | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-fast-model-loading-verify
  labels:
    app: gpu-fast-model-loading-verify
spec:
  restartPolicy: Never
  nodeSelector:
    intent: gpu-fast-model-loading
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  volumes:
    - name: models
      hostPath:
        path: /mnt/k8s-disks/0/models
        type: DirectoryOrCreate
    - name: host-containerd-config
      hostPath:
        path: /etc/containerd/config.toml
        type: File
    - name: host-mdstat
      hostPath:
        path: /proc/mdstat
        type: File
  initContainers:
    - name: wait-for-model
      image: public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
      command: ["/bin/sh", "-c"]
      args:
        - until [ -f "/models/$MODEL_PATH/.ready" ]; do echo "waiting for model"; sleep 5; done
      volumeMounts:
        - name: models
          mountPath: /models
          readOnly: true
  containers:
    - name: verify
      image: public.ecr.aws/amazonlinux/amazonlinux:2023-minimal
      command: ["/bin/sh", "-c"]
      args:
        - |
          echo "== containerd snapshotter =="; grep -E '^snapshotter|proxy_plugins.soci' /host/containerd-config.toml
          echo "== md arrays =="; cat /host/mdstat
          echo "== /models mount =="; grep ' /models ' /proc/mounts
          echo "== model files =="; ls -la "/models/$MODEL_PATH"
          echo "== nvidia-smi =="; nvidia-smi -L
      resources:
        limits:
          nvidia.com/gpu: 1
      volumeMounts:
        - name: models
          mountPath: /models
          readOnly: true
        - name: host-containerd-config
          mountPath: /host/containerd-config.toml
          readOnly: true
        - name: host-mdstat
          mountPath: /host/mdstat
          readOnly: true
POD

    # --- Step 5: Node provisioning ---
    if ! wait_for_nodeclaim "karpenter.sh/nodepool=$TEST_NODEPOOL" 1; then
        log_error "❌ FAILED: Karpenter did not provision a GPU node"
        return 1
    fi
    instance_type=$(kubectl get nodeclaims -l "karpenter.sh/nodepool=$TEST_NODEPOOL" -o jsonpath='{.items[0].spec.instanceType}' 2>/dev/null || echo "unknown")
    local_nvme=$(kubectl get nodeclaims -l "karpenter.sh/nodepool=$TEST_NODEPOOL" -o jsonpath='{.items[0].metadata.labels.karpenter\.k8s\.aws/instance-local-nvme}' 2>/dev/null || echo "0")
    log_info "Provisioned instance: $instance_type (local NVMe: ${local_nvme} GiB)"
    if [ "${local_nvme:-0}" -gt 0 ] 2>/dev/null; then
        log_test "✅ PASSED: Instance has local NVMe storage"
    else
        log_error "❌ FAILED: Instance has no local NVMe storage"
        return 1
    fi

    # --- Step 6: Model preloader ---
    if ! wait_for_pod_phase "app=model-preloader" "Running"; then
        log_error "❌ FAILED: model-preloader did not finish"
        return 1
    fi
    preloader_logs=$(kubectl logs -l app=model-preloader -c s5cmd 2>/dev/null || echo "")
    echo "$preloader_logs"
    if echo "$preloader_logs" | grep -qE "Downloaded .* in [0-9]+s|already present"; then
        log_test "✅ PASSED: model-preloader copied the model from S3 to the NVMe array"
    else
        log_error "❌ FAILED: model-preloader did not report a successful download"
        return 1
    fi

    # --- Step 7: Verification pod output ---
    if ! wait_for_pod_phase "app=gpu-fast-model-loading-verify" "Succeeded"; then
        log_error "❌ FAILED: verification pod did not complete"
        return 1
    fi
    verify_logs=$(kubectl logs gpu-fast-model-loading-verify 2>/dev/null || echo "")
    echo "$verify_logs"

    if echo "$verify_logs" | grep -q 'snapshotter = "soci"'; then
        log_test "✅ PASSED: containerd uses the SOCI snapshotter"
    else
        log_error "❌ FAILED: containerd is not configured with the SOCI snapshotter"
        return 1
    fi
    if echo "$verify_logs" | grep -qE '^/dev/md[0-9]+ /models '; then
        log_test "✅ PASSED: /models is served from the NVMe RAID-0 array"
    else
        log_error "❌ FAILED: /models is not on an md RAID device"
        return 1
    fi
    if echo "$verify_logs" | grep -q '\.ready'; then
        log_test "✅ PASSED: model files are present on the node"
    else
        log_error "❌ FAILED: model files are missing"
        return 1
    fi
    if echo "$verify_logs" | grep -q 'GPU 0'; then
        log_test "✅ PASSED: nvidia-smi sees the GPU"
    else
        log_error "❌ FAILED: nvidia-smi did not list a GPU"
        return 1
    fi

    return 0
}

main() {
    local exit_code=0

    check_prerequisites
    test_fast_model_loading || exit_code=1
    cleanup

    if [ $exit_code -eq 0 ]; then
        log_test "=== ALL TESTS PASSED ==="
    else
        log_error "=== SOME TESTS FAILED ==="
    fi

    exit $exit_code
}

main "$@"
