
# Karpenter Blueprint: Using SOCI snapshotter parallel pull/unpack mode

## Purpose

Container image pull performance has become a bottleneck as container images grow larger, compared to when typical images were just a few hundred megabytes.
The default pulling method uses sequential layer downloading and unpacking. SOCI parallel pull/unpack mode accelerates container image loading through concurrent downloads and unpacking operations, reducing image pull time by up to 50%. This makes it ideal for AI/ML and Batch workloads, where it is common for those applications to have a large container images.

This blueprint demonstrate how to setup SOCI snapshotter parallel pull/unpack mode on AL2023 and Bottlerocket through a custom `EC2NodeClass` and customizing the `userData` field.

> ***NOTE***: SOCI snapshotter parallel mode is supported on [Amazon Linux 2023 (AL2023) > v20250821](https://github.com/awslabs/amazon-eks-ami/releases/tag/v20250821) and [Bottlerocket > v1.44.0](https://github.com/bottlerocket-os/bottlerocket/releases/tag/v1.44.0)

If you would like to learn more about SOCI snapshotter's new parallel pull/unpack mode you can visit the following resources:
1. [SOCI snapshotter parallel mode feature docs](https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md) in the [SOCI project repository](https://github.com/awslabs/soci-snapshotter) on GitHub.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the `cluster` folder in the root of this repository.
* A Container Registry that supports HTTP range GET requests such as [Amazon Elastic Container Registry (ECR)](https://aws.amazon.com/ecr/)

## Deploy

You need to create a new `EC2NodeClass` with the `userData` field and customize the root volume EBS with `blockDeviceMappings`, along with a `NodePool` to use this new template.

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). Karpenter auto-generates the [instance profile](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles) in your `EC2NodeClass` given the role that you specify in [spec.role](https://karpenter.sh/preview/concepts/nodeclasses/) with the placeholder `KARPENTER_NODE_IAM_ROLE_NAME`, which is a way to pass a single IAM role to the EC2 instance launched by the Karpenter `NodePool`. Typically, the instance profile name is the same as the IAM role(not the ARN).

Now, make sure you're in this blueprint folder, then run the following command:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" soci-snapshotter.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" soci-snapshotter.yaml
kubectl apply -f .
```

> ***NOTE***: It can take a couple of minutes for resource to be created, while resources are being created you can continue reading.

Those commands creates the following:
1. `EC2NodeClass` and `NodePool` named `soci-snapshotter` for using SOCI snapshotter parallel pull/unpack mode with customized `blockDeviceMappings` for increased I/O and storage size on Amazon Linux 2023.
2. `EC2NodeClass` and `NodePool` named `soci-snapshotter-br` for using SOCI snapshotter parallel pull/unpack mode with customized `blockDeviceMappings` for increased I/O and storage size on Bottlerocket.
3. `EC2NodeClass` and `NodePool` named `soci-snapshotter-br-c6-32xl` for using SOCI snapshotter parallel pull/unpack mode on Bottlerocket, tuned for `c6.32xlarge` instances pulling massive container images.
4. `EC2NodeClass` and `NodePool` named `soci-snapshotter-br-p5` for using SOCI snapshotter parallel pull/unpack mode on Bottlerocket, tuned for `p5.48xlarge` instances (NVIDIA H100, 192 vCPUs, 30 TB NVMe RAID-0).
5. `EC2NodeClass` and `NodePool` named `soci-snapshotter-br-g6` for using SOCI snapshotter parallel pull/unpack mode on Bottlerocket, tuned for `g6.12xlarge`, `g6.24xlarge`, and `g6.48xlarge` instances (NVIDIA L4, NVMe RAID-0).
6. `EC2NodeClass` and `NodePool` named `non-soci-snapshotter` for using default containerd implementation with customized `blockDeviceMappings` for increased I/O and storage size.
7. Kubernetes `Deployment` named `vllm-soci` that uses the `soci-snapshotter` `NodePool`
8. Kubernetes `Deployment` named `vllm-soci-br` that uses the `soci-snapshotter-br` `NodePool`
9. Kubernetes `Deployment` named `vllm-soci-br-c6-32xl` that uses the `soci-snapshotter-br-c6-32xl` `NodePool`
10. Kubernetes `Deployment` named `vllm-soci-br-p5` that uses the `soci-snapshotter-br-p5` `NodePool`
11. Kubernetes `Deployment` named `vllm-soci-br-g6` that uses the `soci-snapshotter-br-g6` `NodePool`
12. Kubernetes `Deployment` named `vllm` that uses the `non-soci-snapshotter` `NodePool`

> ***NOTE***: For our example both deployments will request instances that have network and ebs bandwidth greater than 8000 Mbps by using `nodeAffinity` in order to eliminate network and storage I/O bottlenecks to demonstrate SOCI parallel mode capabilities.
```
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: karpenter.k8s.aws/instance-ebs-bandwidth
                operator: Gt
                values:
                - "8000"
              - key: karpenter.k8s.aws/instance-network-bandwidth
                operator: Gt
                values:
                - "8000"
```
## Configuration

The `EC2NodeClass` configuration for this blueprint has two parts: the **storage subsystem** (`blockDeviceMappings` and `instanceStorePolicy`) and the **SOCI parallel mode parameters** (`userData`). Both must be tuned together — fast downloads are useless if disk writes can't keep up, and fast storage is wasted if downloads are serialised.

### Storage subsystem

SOCI parallel mode buffers each layer chunk to disk as it arrives rather than holding it in memory. The storage subsystem must be able to absorb concurrent write bursts from all active downloads.

`instanceStorePolicy: RAID0` tells Karpenter to automatically stripe all available NVMe instance store disks into a single RAID-0 array on launch. Karpenter then moves `/var/lib/containerd`, `/var/lib/kubelet`, and `/var/log/pods` onto that array and symlinks them back. NVMe instance store achieves sequential write speeds of 3–10 GB/s depending on instance size, which is far above what EBS can provide and removes storage as the bottleneck for large images.

When no NVMe disks are present (e.g. `c6i`, `c6a` without the `d` suffix), `instanceStorePolicy: RAID0` is a no-op and EBS becomes the sole write path. The example configures the container volume as gp3 at the maximum of 16,000 IOPS and 1,000 MiB/s throughput. For cost-sensitive workloads where the full 50 Gbps network is not being used, 3,000 IOPS and 600 MiB/s is a practical starting point.

<details>
<summary>Amazon Linux 2023 — block device configuration</summary>

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter
spec:
  instanceStorePolicy: RAID0
  blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      volumeSize: 100Gi
      volumeType: gp3
      throughput: 1000
      iops: 16000
```
</details>

<details>
<summary>Bottlerocket — block device configuration</summary>

Bottlerocket uses two block devices: `/dev/xvda` is the read-only control volume (OS, settings) and `/dev/xvdb` is the container data volume (images, logs, SOCI data). Only `xvdb` needs the performance settings.

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter-br
spec:
  instanceStorePolicy: RAID0
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 4Gi
        volumeType: gp3
        encrypted: true
    - deviceName: /dev/xvdb
      ebs:
        volumeSize: 100Gi
        volumeType: gp3
        throughput: 1000
        iops: 16000
        encrypted: true
```

On Bottlerocket, SOCI stores its working data at `/var/lib/soci-snapshotter`. To redirect that path onto instance store (NVMe) when available, the bootstrap command binds it to ephemeral storage:

```toml
[settings.bootstrap-commands.k8s-ephemeral-storage]
commands = [
    ["apiclient", "ephemeral-storage", "init"],
    ["apiclient", "ephemeral-storage", "bind", "--dirs", "/var/lib/soci-snapshotter"]
]
essential = true
mode = "always"
```
</details>

<br>

### SOCI parallel mode parameters

The four parameters below sit in the `userData` field and control how SOCI downloads and unpacks image layers. Each parameter maps to a specific hardware resource. Understanding which resource is the bottleneck on a given instance type is the key to choosing the right values.

---

#### `concurrent_download_chunk_size`

**What it does:** SOCI splits each layer into fixed-size chunks and issues each chunk as a separate HTTP range request to the registry. This parameter sets the chunk size. A non-zero value enables *intra-layer parallelism* — multiple parts of the same layer are in-flight simultaneously, on top of the cross-layer parallelism provided by `max_concurrent_downloads_per_image`.

Setting this to `"unlimited"` (the Bottlerocket default) disables chunking entirely: the whole layer is fetched as a single request with no intra-layer parallelism.

**The trade-off between chunk size and HTTP overhead:**

Each range request carries fixed overhead regardless of payload size: a TCP connection (or reuse from the pool), a TLS record, HTTP headers, and ECR's per-request auth token evaluation on the server side. Smaller chunks create more requests and therefore more overhead per byte transferred. Larger chunks reduce overhead but reduce the number of concurrent in-flight requests per layer.

```
Layer A (200 MB) with "16mb" chunks  →  ~13 range requests per layer
Layer A (200 MB) with "32mb" chunks  →  ~7 range requests per layer
Same total data transferred; ~46% fewer connections with "32mb"
```

**How the instance network bandwidth shifts the optimum:**

On a **bandwidth-constrained instance** (≤ 25 Gbps), the network link is the bottleneck. Many small concurrent requests keep the pipe saturated and the per-request overhead is an acceptable price to pay for maximum parallelism.

On a **high-bandwidth instance** (≥ 50 Gbps), the link is no longer the constraint. The pipe can be saturated with fewer, larger requests. At that point the overhead of hundreds of simultaneous small HTTP connections becomes measurable: more kernel socket buffers, more ECR-side connection handling, more goroutine scheduling in the SOCI runtime. Larger chunks deliver the same throughput with lower overhead.

| Instance network bandwidth | Recommended value | Rationale |
|---|---|---|
| Up to 25 Gbps (e.g. `c5.9xlarge`, `m5.8xlarge`) | `"16mb"` | Maximise concurrent requests to saturate the link |
| 25 Gbps (e.g. `c5.18xlarge`, `m5.24xlarge`) | `"16mb"` | ECR-optimised sweet spot at this bandwidth tier |
| 50 Gbps (e.g. `c6i.32xlarge`, `g6.12xlarge`, `g6.24xlarge`) | `"32mb"` | Halves connection count; link still saturated with larger payloads |
| 100 Gbps (e.g. `g6.48xlarge`) | `"32mb"` | Same reasoning; connection overhead reduction matters more at very high bandwidth |
| EFA / 3,200 Gbps (e.g. `p5.48xlarge`) | `"32mb"` | EFA is for inter-node RDMA; ECR pulls use the standard VPC network path and behave like a high-bandwidth TCP link — same chunk size applies |

> **Defaults:** `"unlimited"` (Bottlerocket) — disables intra-layer parallelism entirely. `"16mb"` (AL2023). Always set an explicit value when your registry supports HTTP range requests; ECR does.

> **Upper bound:** Avoid values above `"64mb"`. Very large chunks increase per-chunk memory allocations and cause longer stalls when a single chunk request is slow due to ECR jitter, since the entire layer waits for that one request to complete.

---

#### `max_concurrent_downloads_per_image`

**What it does:** Sets the maximum number of layers that are downloaded simultaneously for a single image. This is the primary lever for cross-layer parallelism.

**The trade-off:** Higher concurrency keeps more of the available network bandwidth in use and reduces the time spent waiting for layers to arrive sequentially. However, each active download holds an open TCP connection to ECR, consumes kernel socket buffer memory, and requires a goroutine for scheduling. Beyond a certain point, adding more concurrent downloads does not increase throughput — it only increases connection overhead and risks triggering ECR rate-limiting.

**How the instance type affects this:**

Network bandwidth is the primary driver. More bandwidth means more bytes can be delivered per second, which means more concurrent layer downloads can run without each connection starving the others. vCPU count is a secondary factor: each download goroutine requires a small amount of CPU; on instances with fewer than 16 vCPUs a very high value can create scheduling contention.

| Instance vCPUs / Network | Recommended value | Notes |
|---|---|---|
| 4–32 vCPUs, ≤ 10 Gbps | `10–15` | Keep connection count low to avoid saturation |
| 32–64 vCPUs, 10–25 Gbps | `20` | ECR-optimised baseline |
| 64–96 vCPUs, 25–50 Gbps | `20–25` | Modest increase to use additional bandwidth headroom |
| 128 vCPUs, 50–100 Gbps (e.g. `c6i.32xlarge`, `g6.12/24xlarge`) | `25` | Further headroom without approaching ECR per-client limits |
| 192 vCPUs, 100 Gbps+ (e.g. `g6.48xlarge`, `p5.48xlarge`) | `25–30` | At 192 vCPUs goroutine overhead is negligible; `30` sits at the ECR ceiling |

> **Defaults:** `3` (Bottlerocket), `20` (AL2023). The Bottlerocket default of 3 serialises almost all download work — always increase this.

> **Ceiling:** ECR is designed for 20–30 concurrent connections per client. Values above `30` are unlikely to improve throughput and may cause throttled responses.

---

#### `max_concurrent_unpacks_per_image`

**What it does:** Sets the maximum number of layers being decompressed and written to disk simultaneously. Unpacking happens as soon as each layer's download is complete — a high value keeps the CPU pipeline busy with decompression while the next set of layers is still downloading.

**The trade-off:** Unpacking is CPU-bound (gzip or zstd decompression) and I/O-bound (writing decompressed data to the container volume). More concurrency reduces wall-clock time from download-complete to container-ready, but each concurrent unpack occupies one CPU core for decompression and one I/O queue slot for writing. Setting this above the vCPU count wastes scheduling overhead; setting it above the storage write bandwidth saturates the disk.

The number of layers in the image sets a practical ceiling: unpacking 64 layers concurrently on a 20-layer image gains nothing after the 20th slot.

**How the instance type affects this:**

vCPU count is the primary driver. Storage write throughput is the secondary driver. On instances backed by gp3 EBS (max 1,000 MiB/s), even a moderate number of concurrent unpacks can saturate the write path; on instances with NVMe RAID-0, the storage ceiling is much higher.

| Instance vCPUs / Storage | Recommended value | Notes |
|---|---|---|
| 4–16 vCPUs, EBS gp3 | `8–12` | Avoid overwhelming EBS write bandwidth |
| 16–64 vCPUs, EBS gp3 | `12–20` | EBS remains the ceiling; CPUs are available |
| 64–96 vCPUs, NVMe RAID-0 | `20–24` | NVMe removes storage ceiling; match to layer count |
| 128 vCPUs, NVMe RAID-0 (e.g. `c6i.32xlarge`, `g6.12/24xlarge`) | `32` | Matches typical LLM image layer count (30–50 layers) |
| 192 vCPUs, NVMe RAID-0 (e.g. `g6.48xlarge`, `p5.48xlarge`) | `48` | 30+ TB NVMe on p5 / 30 TB on g6.48xl saturates writes; 48 matches deep training image layer counts |

> **Defaults:** `1` (Bottlerocket), `12` (AL2023). A Bottlerocket default of 1 fully serialises decompression — always increase this.

---

#### `discard_unpacked_layers`

**What it does:** After a layer is downloaded and unpacked, SOCI can delete the original compressed blob. When set to `true`, only the unpacked (uncompressed) filesystem data is kept; the downloaded blob is discarded immediately.

**The trade-off:**

- `true` reduces peak disk usage. Without this setting, the node must hold both the compressed blob and the uncompressed unpacked data at the same time during the pull. For a 10 GB image that expands to 25 GB uncompressed, `false` requires up to 35 GB of transient disk space.
- `true` also reduces total disk write volume: the blob does not need to be written and then read back during unpack.
- `false` retains the blob, which is only useful if the same image will be pulled repeatedly from a local on-disk cache on the same node. On EKS with Karpenter, nodes are regularly replaced, so there is no long-term caching benefit.

**How the instance type affects this:** This parameter is not instance-type dependent. On any EKS node managed by Karpenter, set this to `true`.

> **Defaults:** `false` (Bottlerocket), `true` (AL2023).

---

### Tuning by instance profile

The table below summarises the recommended values for the most common instance profiles. These assume ECR as the registry and gp3 EBS at maximum throughput as the storage backend (or NVMe RAID-0 where available).

| Instance profile | Network | vCPUs | NVMe RAID-0 | `concurrent_download_chunk_size` | `max_concurrent_downloads` | `max_concurrent_unpacks` | `discard_unpacked_layers` |
|---|---|---|---|---|---|---|---|
| General (c5/m5/r5, up to 8xlarge) | ≤ 25 Gbps | 4–32 | No | `"16mb"` | `20` | `12` | `true` |
| Large (c5.18xl, m5.24xl, r5.24xl) | 25 Gbps | 72–96 | No | `"16mb"` | `20` | `20` | `true` |
| c6/m6/r6 32xlarge (`soci-snapshotter-br-c6-32xl`) | 50 Gbps | 128 | Optional (`d` suffix) | `"32mb"` | `25` | `32` | `true` |
| g6 12xl/24xl/48xl (`soci-snapshotter-br-g6`) | 50–100 Gbps | 48–192 | Yes | `"32mb"` | `25` | `32` | `true` |
| p5.48xlarge (`soci-snapshotter-br-p5`) | EFA / high TCP | 192 | Yes (30 TB) | `"32mb"` | `30` | `48` | `true` |

Each optimized profile has a dedicated `EC2NodeClass` and `NodePool` in this blueprint. The `NodePool` for each uses `instance-category`, `instance-generation`, and where appropriate `instance-size` requirements to pin scheduling to exactly the intended instance shape.

To learn more about all available configuration options, visit the [official SOCI snapshotter documentation](https://github.com/awslabs/soci-snapshotter/blob/main/docs/parallel-mode.md#configuration).

As installing a snapshotter to containerd and EKS requires several configuration, this is all being done for you automatically in AL2023 and Bottlerocket as SOCI is already pre-installed in the latest AMIs.

<details>
<summary>Amazon Linux 2023</summary>

SOCI snapshotter parallel mode can be enabled in AL2023 through featureGate named "FastImagePull", in AL2023 we use [`NodeConfig`](https://awslabs.github.io/amazon-eks-ami/nodeadm/doc/examples/#enabling-fast-image-pull-experimental) simplify various data plane configurations. The SOCI configuration values are the default ones, but we left it as guidance in case you want to override them. 


```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter
...
...
spec:
...
...
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
      containerd:
        config: |
          [plugins."io.containerd.snapshotter.v1.soci"]
            [plugins."io.containerd.snapshotter.v1.soci".blob]
              max_concurrent_downloads_per_image = 20
              concurrent_download_chunk_size = "16mb"
              max_concurrent_unpacks_per_image = 12
              discard_unpacked_layers = true

    --BOUNDARY--
```

Modifying SOCI snapshotter parallel mode configuration in AL2023 requires modifying the `/etc/soci-snapshotter-grpc/config.toml` file, this can be achieved by a `userData` script as additional to the `NodeConfig` configuration.

The following sets `max_concurrent_downloads_per_image` and `max_concurrent_unpacks_per_image` to `10` respectively

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter
...
...
spec:
...
...
  userData: |
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="//"

    --//
    Content-Type: text/x-shellscript; charset="us-ascii"

    #!/bin/bash
    max_concurrent_downloads_per_image=10
    max_concurrent_unpacks_per_image=10

    sed -i "s/^max_concurrent_downloads_per_image = .*$/max_concurrent_downloads_per_image = $max_concurrent_downloads_per_image/" /etc/soci-snapshotter-grpc/config.toml
    sed -i "s/^max_concurrent_unpacks_per_image = .*$/max_concurrent_unpacks_per_image = $max_concurrent_unpacks_per_image/" /etc/soci-snapshotter-grpc/config.toml

    --//
    Content-Type: application/node.eks.aws

    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      featureGates:
        FastImagePull: true
    --//
```

</details>

<details>
<summary>Bottlerocket</summary>

SOCI snapshotter parallel mode can be enabled and configured in Bottlerocket through the [Settings API](https://bottlerocket.dev/en/os/1.44.x/api/settings/container-runtime-plugins/#tag-soci-parallel-pull-configuration).

In Bottlerocket, SOCI's data dir is configured at `/var/lib/soci-snapshotter`, to take advantage of instances with NVMe disks, we will need to configure ephemeral storage through Bottlerocket's Settings API, with `[settings.bootstrap-commands.k8s-ephemeral-storage]` as you can see below, we added `/var/lib/soci-snapshotter` as a bind dir.

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: soci-snapshotter-br
...
...
spec:
...
...
  userData: |
    [settings.container-runtime]
    snapshotter = "soci"
    
    [settings.container-runtime-plugins.soci-snapshotter]
    pull-mode = "parallel-pull-unpack"
    
    [settings.container-runtime-plugins.soci-snapshotter.parallel-pull-unpack]
    max-concurrent-downloads-per-image = 20
    concurrent-download-chunk-size = "16mb"
    max-concurrent-unpacks-per-image = 12
    discard-unpacked-layers = true

    [settings.bootstrap-commands.k8s-ephemeral-storage]
    commands = [
        ["apiclient", "ephemeral-storage", "init"],
        ["apiclient", "ephemeral-storage" ,"bind", "--dirs", "/var/lib/soci-snapshotter"]
    ]
    essential = true
    mode = "always"
```
</details>

## Results

Wait until the pods from the sample workload are in running status:
```sh
> kubectl wait --for=condition=Ready pods --all --namespace default --timeout=300s
pod/vllm-59bfb6f86c-9nfxb condition met
pod/vllm-soci-6d9bfd996d-vhr4j condition met
pod/vllm-soci-br-74b59cc4bd-rq8cw condition met
```

The sample workload deploys three Deployments running [Amazon Deep Learning Container (DLC) for vLLM](https://docs.aws.amazon.com/deep-learning-containers/latest/devguide/dlc-vllm-x86-ec2.html) two using SOCI parallel pull/unpack mode (AL2023, Bottlerocket) and one remains using the default containerd implementation.
> ***NOTE*** The Amazon DLC for vLLM container image size is about **~10GB**

Let's examine the pull time for each Deployment:

The `vllm` deployment using the default containerd implementation results in pull time of **1m52.33s**.
```sh
> kubectl describe pod -l app=vllm | grep Pulled
  Normal   Pulled            7m2s   kubelet            Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.9-gpu-py312-ec2"
  in 1m52.33s (1m52.33s including waiting). Image size: 10778400361 bytes.
```

The `vllm-soci` deployment using SOCI snapshotter's parallel pull/unpack mode implementation results in pull time of **59.813s**.
```sh
> kubectl describe pod -l app=vllm-soci | grep Pulled
  Normal   Pulled            8m27s  kubelet            Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.9-gpu-py312-ec2"
  in 59.813s (59.813s including waiting). Image size: 10778400361 bytes.
```

The `vllm-soci-br` deployment using SOCI snapshotter's parallel pull/unpack mode implementation on Bottlerocket, results in pull time of **44.974s**.
```sh
> kubectl describe pod -l app=vllm-soci-br | grep Pulled
  Normal   Pulled            9m46s  kubelet            Successfully pulled image "763104351884.dkr.ecr.us-east-1.amazonaws.com/vllm:0.9-gpu-py312-ec2"
  in 44.974s (44.974s including waiting). Image size: 10778400361 bytes.
```

We can see that using SOCI snapshotter's improved container pull time by about **50%** on Amazon Linux 2023, and about **60%** on Bottlerocket, the reason for that is that Bottlerocket have an improved decompression library for Intel based CPUs ([bottlerocket-core-kit PR #443](https://github.com/bottlerocket-os/bottlerocket-core-kit/pull/443))


## Cleanup

To remove all objects created, simply run the following commands:

```sh
kubectl delete -f .
```

