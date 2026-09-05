# Karpenter Blueprint: GPU inference with fast image pull (SOCI) and S3-to-NVMe model loading

## Purpose

Large language model inference on instances such as `p5.48xlarge` has two cold-start bottlenecks that have nothing to do with the GPUs themselves:

1. **Pulling the container image.** Inference images (vLLM, TensorRT-LLM, Triton...) are routinely 10 GB or larger. containerd's default sequential layer download and unpack is slow on such images.
2. **Loading the model weights.** A 70B parameter model is 140 GB or more. Downloading it through the EBS root volume means every byte is written and read back through EBS, whose throughput is capped at 1,000 MiB/s for `gp3`, while a `p5.48xlarge` has eight local NVMe SSDs (8 x 3.84 TB) and a network link that is an order of magnitude faster.

This blueprint shows how to configure a Karpenter `EC2NodeClass` and `NodePool` on Amazon Linux 2023 so that, by default, GPU nodes:

* use the **SOCI snapshotter in parallel pull/unpack mode** to download and unpack image layers concurrently,
* assemble the **local NVMe instance store into a RAID-0 array** that backs containerd, the SOCI snapshotter, kubelet (`emptyDir`) and pod logs, so the EBS root volume only hosts the OS,
* **download model weights from Amazon S3 straight onto that NVMe array** with a `model-preloader` DaemonSet, in parallel with the image pull, and expose them to the inference pod through a `hostPath` volume.

The pattern follows the AWS Containers blog post [Fast model loading for AI inference on Amazon EKS](https://aws.amazon.com/blogs/containers/fast-model-loading-for-ai-inference-on-amazon-eks/). It builds on the [SOCI snapshotter](/blueprints/soci-snapshotter/) and [NVIDIA GPU workload](/blueprints/nvidia-gpu-workload/) blueprints, which explain each building block in more depth.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* The [NVIDIA device plugin for Kubernetes](https://github.com/NVIDIA/k8s-device-plugin) installed, as described in the [NVIDIA GPU workload](/blueprints/nvidia-gpu-workload/) blueprint.
* Amazon Linux 2023 EKS AMI [v20250821](https://github.com/awslabs/amazon-eks-ami/releases/tag/v20250821) or later (SOCI parallel mode). The `al2023@latest` alias used here always satisfies this.
* An S3 bucket holding the model weights (see [Upload a model to S3](#upload-a-model-to-s3)), and read access to it from the Karpenter node IAM role (see [Allow nodes to read the model bucket](#allow-nodes-to-read-the-model-bucket)).
* Capacity for the instance family you target. `p5` capacity is usually obtained through On-Demand Capacity Reservations or EC2 Capacity Blocks for ML. See [Consuming reserved capacity](#consuming-reserved-capacity).
* Strongly recommended: an [S3 gateway VPC endpoint](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html) in the cluster VPC, so that model downloads do not go through a NAT gateway (which adds per-GB cost and a bandwidth ceiling).
* A container registry that supports HTTP range requests, such as Amazon ECR, for the SOCI parallel pull to be effective.

## How it works

```
                 Karpenter launches p5.48xlarge (EC2NodeClass gpu-fast-model-loading)
                                         |
                    nodeadm (AL2023) --- RAID-0 over 8 local NVMe SSDs -> /mnt/k8s-disks/0
                                         |     bind mounts: /var/lib/containerd
                                         |                  /var/lib/soci-snapshotter-grpc
                                         |                  /var/lib/kubelet, /var/log/pods
                                         |
              +--------------------------+--------------------------+
              |                                                     |
  kubelet pulls vllm image                            model-preloader DaemonSet
  through SOCI (parallel pull/unpack)                 s5cmd s3://bucket/model/* -> /mnt/k8s-disks/0/models
  layers unpacked on NVMe                             writes .ready when done
              |                                                     |
              +--------------------------+--------------------------+
                                         |
                       vllm pod: init container waits for .ready
                       main container loads /models/<model> from NVMe into GPU memory
```

* **Image pull.** The `FastImagePull` feature gate in the `NodeConfig` makes `nodeadm` switch containerd to the SOCI snapshotter and write `/etc/soci-snapshotter-grpc/config.toml` with parallel mode enabled (20 concurrent downloads per image, 16 MB chunks, 12 concurrent unpacks, discard of unpacked layers). Because `/var/lib/soci-snapshotter-grpc` and `/var/lib/containerd` are bind-mounted onto the NVMe array, the download buffers and the unpacked layers never touch EBS.
* **Model download.** The DaemonSet starts as soon as the node joins the cluster, so the S3 download overlaps with the image pull. It uses [s5cmd](https://github.com/peak/s5cmd), a parallel S3 client that can drive very high throughput on large instances, and writes into `/mnt/k8s-disks/0/models` via a `hostPath` volume. The init container refuses to run if that path is not backed by an `md` RAID device, so you cannot silently fall back to EBS. A `.ready` marker makes the download idempotent: a node that already holds the weights (for example after a pod restart) is not re-downloaded.
* **Why not EC2 user data?** On AL2023, `nodeadm` assembles the RAID array *after* cloud-init has run the shell scripts from `userData`, so `/mnt/k8s-disks/0` does not exist yet when user data runs ([karpenter-provider-aws#5981](https://github.com/aws/karpenter-provider-aws/issues/5981)). A DaemonSet is the simplest reliable hook that runs once the array is mounted.
* **Inference pod.** The `vllm` Deployment mounts the same `hostPath` read-only, waits for the `.ready` marker in an init container, then serves the model with tensor parallelism across the 8 GPUs of a `p5.48xlarge`.

## Deploy

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role(not the ARN).

### Upload a model to S3

Pick the bucket and key prefix that will hold the weights. The example below downloads [Qwen/Qwen2.5-72B-Instruct](https://huggingface.co/Qwen/Qwen2.5-72B-Instruct) (about 145 GB, open weights, works with `--tensor-parallel-size 8`) with the Hugging Face CLI and syncs it to S3. Any model directory that vLLM can load from a local path works the same way.

```sh
export MODEL_BUCKET=<your-bucket-name>
export MODEL_PATH=models/Qwen2.5-72B-Instruct

pip install -U "huggingface_hub[cli]"
hf download Qwen/Qwen2.5-72B-Instruct --local-dir ./Qwen2.5-72B-Instruct
aws s3 sync ./Qwen2.5-72B-Instruct "s3://$MODEL_BUCKET/$MODEL_PATH/"
```

> ***NOTE***: The model bucket should live in the same region as the cluster. Cross-region downloads are slower and incur data transfer charges.

### Allow nodes to read the model bucket

The `model-preloader` DaemonSet uses the node's instance profile. Grant the Karpenter node role read access to the bucket:

```sh
aws iam put-role-policy \
  --role-name "$KARPENTER_NODE_IAM_ROLE_NAME" \
  --policy-name gpu-fast-model-loading-s3-read \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      { \"Effect\": \"Allow\", \"Action\": [\"s3:ListBucket\"], \"Resource\": \"arn:aws:s3:::$MODEL_BUCKET\" },
      { \"Effect\": \"Allow\", \"Action\": [\"s3:GetObject\"], \"Resource\": \"arn:aws:s3:::$MODEL_BUCKET/*\" }
    ]
  }"
```

> ***NOTE***: In production you may prefer to scope the permission to the DaemonSet's service account with [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) instead of the node role. `s5cmd` uses the standard AWS SDK credential chain, so no change to the manifest is needed.

### Apply the blueprint

Make sure you're in this blueprint folder, then replace the placeholders and apply all the manifests:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" nodeclass.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" nodeclass.yaml
sed -i '' "s|<<MODEL_BUCKET>>|$MODEL_BUCKET|g" model-preloader.yaml
sed -i '' "s|<<MODEL_PATH>>|$MODEL_PATH|g" model-preloader.yaml workload.yaml
kubectl apply -f .
```

> ***NOTE***: On Linux use `sed -i` instead of `sed -i ''`.

Those commands create the following:

1. `EC2NodeClass` named `gpu-fast-model-loading` with `instanceStorePolicy: RAID0` and the `FastImagePull` feature gate enabled (`nodeclass.yaml`).
2. `NodePool` named `gpu-fast-model-loading` that only launches `p5`, `p5e` or `p5en` instances with local NVMe, tainted with `nvidia.com/gpu` (`nodepool.yaml`).
3. `DaemonSet` named `model-preloader` that copies `s3://$MODEL_BUCKET/$MODEL_PATH/` onto the NVMe array of every node in that NodePool (`model-preloader.yaml`).
4. `Deployment` and `Service` named `vllm` running the Amazon Deep Learning Container for vLLM and serving the model from the NVMe array (`workload.yaml`).

> ***NOTE***: It can take several minutes for a `p5.48xlarge` to launch, pull the ~10 GB image and download the weights. While waiting, you can follow the progress with `kubectl logs -l app=model-preloader -c s5cmd -f`.

## Configuration

### EC2NodeClass

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu-fast-model-loading
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  instanceStorePolicy: RAID0
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        throughput: 600
        iops: 6000
  userData: |
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    ---
    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      featureGates:
        FastImagePull: true

    --BOUNDARY--
```

* `amiSelectorTerms` with the `al2023@latest` alias resolves to the EKS-optimized *accelerated* AL2023 AMI (NVIDIA driver and container toolkit included) as soon as the NodePool picks a GPU instance type. No custom AMI is needed.
* `instanceStorePolicy: RAID0` makes `nodeadm` run `setup-local-disks raid0`, which creates `/dev/md/0` from all instance-store disks, formats it as XFS, mounts it at `/mnt/k8s-disks/0` and bind-mounts `/var/lib/kubelet`, `/var/lib/containerd`, `/var/lib/soci-snapshotter-grpc` and `/var/log/pods` onto it. The node's allocatable `ephemeral-storage` becomes the size of the array (about 30 TB on a `p5.48xlarge`).
* `blockDeviceMappings` keeps a small `gp3` root volume. Because images and pod storage live on NVMe, you do not need the 1,000 MiB/s root volume the standalone SOCI blueprint uses. If you target an instance family *without* local NVMe, remove `instanceStorePolicy`, raise the root volume to at least 600 MiB/s throughput and 16k IOPS, and change the `hostPath` in the manifests.
* `FastImagePull: true` is the only user data required. `nodeadm` writes `/etc/soci-snapshotter-grpc/config.toml` from its built-in template with the ECR-recommended values (`max_concurrent_downloads_per_image = 20`, `concurrent_download_chunk_size = "16mb"`, `max_concurrent_unpacks_per_image = 12`, `discard_unpacked_layers = true`). The gate is ignored on instances with fewer than 4 vCPUs or 8 GiB of memory.

#### Tuning the SOCI parallel mode

`nodeadm` rewrites `/etc/soci-snapshotter-grpc/config.toml` every boot, so editing it from a user data shell script (which cloud-init runs *before* `nodeadm`) has no effect. To override the values, install a systemd drop-in that patches the file every time the snapshotter starts. Add this part to the `userData` MIME document, before the `NodeConfig` part:

```yaml
    --BOUNDARY
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash
    mkdir -p /etc/systemd/system/soci-snapshotter.service.d
    cat > /etc/systemd/system/soci-snapshotter.service.d/10-parallel-mode.conf <<'UNIT'
    [Service]
    ExecStartPre=/usr/bin/sed -i \
      -e 's/^max_concurrent_downloads_per_image = .*/max_concurrent_downloads_per_image = 32/' \
      -e 's/^max_concurrent_unpacks_per_image = .*/max_concurrent_unpacks_per_image = 16/' \
      /etc/soci-snapshotter-grpc/config.toml
    UNIT
    systemctl daemon-reload
```

See the [SOCI parallel mode documentation](https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md#configuration) for the meaning of each key. Higher parallelism needs more CPU, memory and disk bandwidth during the pull, which a `p5.48xlarge` has in abundance.

### NodePool

```yaml
requirements:
  - key: karpenter.k8s.aws/instance-family
    operator: In
    values: ["p5", "p5e", "p5en"]
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
```

* The `instance-local-nvme` requirement guarantees Karpenter never picks an instance type without instance store, even if you widen the family list. All `p5*`, `p4d*`, `g6e`, `g6` and `g5` instances qualify.
* Consolidation is `WhenEmpty` with a 10 minute delay: a GPU node costs several minutes of image pull and model download to warm up, so it should not be churned by `WhenEmptyOrUnderutilized`.
* `limits.nvidia.com/gpu: 16` caps the pool at two `p5.48xlarge`. Adjust to your capacity.

#### Consuming reserved capacity

If you hold an On-Demand Capacity Reservation or a Capacity Block for ML for your `p5` instances, add `reserved` to the capacity types and point the `EC2NodeClass` at the reservation. Karpenter then prefers reserved capacity and falls back to on-demand:

```yaml
# NodePool
- key: karpenter.sh/capacity-type
  operator: In
  values: ["reserved", "on-demand"]
# EC2NodeClass
capacityReservationSelectorTerms:
  - id: cr-0123456789abcdef0
```

See the [reserved-capacity](/blueprints/reserved-capacity/) blueprint for the details and Karpenter version requirements.

### model-preloader DaemonSet

The important knobs are environment variables on the `s5cmd` init container:

| Variable | Default | Description |
| --- | --- | --- |
| `MODEL_BUCKET` / `MODEL_PATH` | placeholders | Source of the weights: `s3://$MODEL_BUCKET/$MODEL_PATH/*` is copied to `/mnt/k8s-disks/0/models/$MODEL_PATH/`. |
| `REQUIRE_NVME` | `true` | Fail if `/models` is not on an `md` RAID device. Set to `false` only for experiments on EBS-only nodes. |
| `S5CMD_NUMWORKERS` | `256` | Global worker pool size of `s5cmd`. |
| `S5CMD_CONCURRENCY` | `16` | Parts downloaded in parallel per object. |
| `S5CMD_PART_SIZE_MB` | `64` | Size of each part in MB. |

`s5cmd` is a small Go binary distributed as `peakcom/s5cmd` on Docker Hub. For production, mirror the image to Amazon ECR to avoid Docker Hub rate limits and keep pulls inside your VPC. Any other S3 client works too (for example the AWS CLI with its [CRT transfer client](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-options.html#cli-configure-options-s3) or [Mountpoint for Amazon S3](https://github.com/awslabs/mountpoint-s3) with a local cache); the requirement is that it writes to the `hostPath` under `/mnt/k8s-disks/0`.

To serve several models from the same pool, either run one `model-preloader` DaemonSet per model or extend the script to loop over a list of prefixes; every model gets its own `.ready` marker.

### Inference workload

* The vLLM container mounts the same `hostPath` read-only and starts with `--model=/models/$MODEL_PATH`. Loading from the NVMe array into GPU memory runs at local disk speed rather than S3 or EBS speed.
* `--tensor-parallel-size=8` and `nvidia.com/gpu: 8` match a `p5.48xlarge`. For smaller instances lower both values together (for example `1` on a `g6e.xlarge`) and pick a model that fits in the GPU memory.
* `/dev/shm` is an in-memory `emptyDir` because NCCL uses shared memory for tensor-parallel communication.
* If you would rather not use `hostPath`, an `emptyDir` in the inference pod is also on the NVMe array (kubelet's pod directory is bind-mounted onto it) and can be filled by an init container with the same `s5cmd` command. You lose the overlap with the image pull and the reuse across pods on the same node, but avoid host-level access.

## Results

Wait for the node, the preloader and the inference pod:

```sh
> kubectl get nodeclaims
NAME                           TYPE          CAPACITY    ZONE         NODE                                        READY   AGE
gpu-fast-model-loading-7r2xk   p5.48xlarge   on-demand   us-east-1d   ip-10-0-14-201.us-east-1.compute.internal   True    6m

> kubectl get pods
NAME                    READY   STATUS    RESTARTS   AGE
model-preloader-9kq4z   1/1     Running   0          5m
vllm-6d9bfd996d-vhr4j   1/1     Running   0          5m
```

The preloader logs show the storage backing `/models` and the download rate. Note the `/dev/md0` device: the data is written to the NVMe array, not to the EBS root volume:

```sh
> kubectl logs -l app=model-preloader -c s5cmd
Local NVMe storage backing /models:
Filesystem      Size  Used Avail Use% Mounted on
/dev/md0         28T  9.8G   28T   1% /models
Downloading s3://my-models-bucket/models/Qwen2.5-72B-Instruct/ -> /models/models/Qwen2.5-72B-Instruct
...
Downloaded 136G in 71s
```

The image pull events show SOCI parallel mode at work on the ~10 GB vLLM image, in the same range as the [soci-snapshotter](/blueprints/soci-snapshotter/) blueprint measured (about 60 s on AL2023 versus about 112 s with the default snapshotter):

```sh
> kubectl describe pod -l app=vllm | grep Pulled
  Normal   Pulled   6m   kubelet   Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.9-gpu-py312-ec2" in 58.4s (58.4s including waiting). Image size: 10778400361 bytes.
```

Because the two run in parallel, the pod is ready shortly after the slower of the two finishes, instead of after their sum. Query the model to confirm it is served:

```sh
kubectl port-forward svc/vllm 8000:8000 &
curl -s localhost:8000/v1/models | jq .
curl -s localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"model","messages":[{"role":"user","content":"Why is local NVMe faster than EBS?"}],"max_tokens":64}' | jq .
```

You can double check on the node that containerd uses SOCI and that the array holds the container runtime state:

```sh
NODE=$(kubectl get nodeclaims -l karpenter.sh/nodepool=gpu-fast-model-loading -o jsonpath='{.items[0].status.nodeName}')
kubectl debug node/$NODE -it --image=public.ecr.aws/amazonlinux/amazonlinux:2023-minimal -- \
  sh -c 'grep -E "^snapshotter|proxy_plugins.soci" /host/etc/containerd/config.toml; cat /host/proc/mdstat; findmnt -n -o SOURCE,TARGET /host/var/lib/containerd /host/var/lib/soci-snapshotter-grpc /host/mnt/k8s-disks/0'
```

## Testing

`test.sh` validates the mechanics without a `p5.48xlarge`: it applies the blueprint `EC2NodeClass`, creates a test `NodePool` on smaller GPU families with local NVMe (`g6`, `g5` by default), uploads a synthetic 1 GiB model to `s3://$MODEL_BUCKET/karpenter-blueprints/gpu-fast-model-loading-test/` unless `MODEL_PATH` is set, and checks that the node uses the SOCI snapshotter, that `/models` is on an `md` RAID device, that the preloader downloaded the files, and that `nvidia-smi` works.

```sh
export MODEL_BUCKET=<your-bucket-name>
make test-gpu-fast-model-loading
```

## Cleanup

To remove all objects created, run the following commands from this folder:

```sh
kubectl delete -f .
aws iam delete-role-policy --role-name "$KARPENTER_NODE_IAM_ROLE_NAME" --policy-name gpu-fast-model-loading-s3-read
```

Instance store data is discarded with the instance, so nothing remains on the nodes once Karpenter terminates them. Delete the model from S3 if you no longer need it:

```sh
aws s3 rm "s3://$MODEL_BUCKET/$MODEL_PATH/" --recursive
```
