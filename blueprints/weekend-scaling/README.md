# Karpenter Blueprint: Weekend Scale-to-Zero

## Purpose

For many teams, non-production workloads (staging, QA, development) run only during business hours and sit idle over weekends. Keeping EC2 nodes running while no work is scheduled wastes money. This blueprint shows how to automatically scale a NodePool to **zero nodes** over the weekend and restore it on Monday morning by combining:

1. **Karpenter disruption budgets** — block all voluntary disruptions during the workweek to protect workloads that cannot tolerate consolidation, and allow unrestricted consolidation over the weekend once nodes are empty.
2. **KEDA cron scaler** — scale the workload `Deployment` to zero replicas on Friday evening and back up on Monday morning via a `ScaledObject`. Once no pods need to be scheduled, Karpenter's `WhenEmptyOrUnderutilized` consolidation policy terminates the now-empty nodes automatically.
3. **KEDA Prometheus scaler (Grafana Cloud)** — scale out beyond the weekday baseline when average pod memory exceeds a configurable threshold, using metrics from Grafana Cloud's managed Prometheus.

> **Why a workload scaler is needed**
> Karpenter provisions and deprovisions nodes in response to pod demand. To reach zero nodes you must first reach zero running pods. KEDA drives that workload-level scale-down; Karpenter's consolidation then handles the node-level scale-down.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the cluster folder in the root of this repository.
* [KEDA](https://keda.sh/docs/latest/deploy/) installed in the cluster (`helm install keda kedacore/keda --namespace keda`).
* A [Grafana Cloud](https://grafana.com/products/cloud/) account with a managed Prometheus stack. You will need:
  * The **Prometheus remote write endpoint URL** (e.g. `https://prometheus-prod-01-eu-west-0.grafana.net/api/prom`).
  * The **numeric instance ID** of your Prometheus stack (used as the basic-auth username).
  * A **Grafana Cloud API token** with `metrics:read` scope (used as the basic-auth password).
* The `weekend-scaling-workload` `Deployment` (or a workload of your own) must have no [do-not-disrupt annotations](https://karpenter.sh/docs/concepts/disruption/#pod-level-controls) if you want nodes to drain fully.

## Deploy

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). `KARPENTER_NODE_IAM_ROLE_NAME` is the IAM role name (not the ARN) that Karpenter uses to launch EC2 instances.

Set the Grafana Cloud variables alongside the cluster variables:

```sh
export GRAFANA_CLOUD_PROMETHEUS_URL=<your-prometheus-endpoint>   # e.g. prometheus-prod-01-eu-west-0.grafana.net/api/prom
export GRAFANA_CLOUD_INSTANCE_ID=<your-numeric-instance-id>
export GRAFANA_CLOUD_API_TOKEN=<your-api-token>
```

Substitute all placeholders and deploy:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" weekend-scaling.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" weekend-scaling.yaml
sed -i '' "s/<<GRAFANA_CLOUD_PROMETHEUS_URL>>/$GRAFANA_CLOUD_PROMETHEUS_URL/g" workload.yaml
sed -i '' "s/<<GRAFANA_CLOUD_INSTANCE_ID>>/$GRAFANA_CLOUD_INSTANCE_ID/g" workload.yaml
sed -i '' "s/<<GRAFANA_CLOUD_API_TOKEN>>/$GRAFANA_CLOUD_API_TOKEN/g" workload.yaml
kubectl apply -f .
```

Expected output:

```console
nodepool.karpenter.sh/weekend-scaling created
ec2nodeclass.karpenter.k8s.aws/weekend-scaling created
secret/grafana-cloud-auth created
triggerauthentication.keda.sh/grafana-cloud-auth created
deployment.apps/weekend-scaling-workload created
scaledobject.keda.sh/weekend-scaling-workload created
```

Karpenter will provision nodes as the `weekend-scaling-workload` pods become `Pending`:

```sh
kubectl get nodes -l intent=weekend-scaling -w
```

### Adjusting the schedule

The `ScaledObject` schedule uses UTC. Edit the `triggers[0].metadata` in `workload.yaml` to match your timezone offset:

| Event | Default (UTC) | Field |
|-------|--------------|-------|
| Scale up | Monday 08:00 UTC | `start: "0 8 * * 1"` |
| Scale down | Friday 18:00 UTC | `end: "0 18 * * 5"` |

If your team is in US Eastern (UTC-5), Friday 18:00 ET = Friday 23:00 UTC → `end: "0 23 * * 5"`.

You can also set `timezone` to a [tz database name](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones) (e.g. `America/New_York`) instead of adjusting the UTC offset manually.

### Adjusting the replica count

Change `desiredReplicas` and `maxReplicaCount` in the `ScaledObject` to match your normal weekday replica count.

## How It Works

### Disruption budgets in the NodePool

```yaml
disruption:
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 1m
  budgets:
  - nodes: "0"
    schedule: "0 8 * * 1"
    duration: 106h
  - nodes: "100%"
    schedule: "0 18 * * 5"
    duration: 62h
```

| Budget | When active | Effect |
|--------|------------|--------|
| `nodes: "0"` | Mon 08:00 → Fri 18:00 UTC (106 h) | No voluntary disruptions at all during the workweek — workloads that cannot tolerate consolidation (stateful services, strict PDBs, latency-sensitive apps) are fully protected |
| `nodes: "100%"` | Fri 18:00 → Mon 08:00 UTC (62 h) | All empty nodes terminated simultaneously — safe because KEDA has already scaled all replicas to zero before this window opens |

The two budgets are mutually exclusive and cover the full week without overlap.

### KEDA ScaledObject

KEDA creates an HPA targeting the `weekend-scaling-workload` Deployment and evaluates all triggers every polling interval, **taking the highest resulting replica count**.

**Cron trigger** — defines the weekday baseline and the weekend zero:

```yaml
- type: cron
  metadata:
    timezone: UTC
    start: "0 8 * * 1"   # window opens  — scale to desiredReplicas (5)
    end: "0 18 * * 5"    # window closes — scale to minReplicaCount (0)
    desiredReplicas: "5"
```

**Prometheus trigger** — scales out beyond the baseline when average pod memory exceeds the threshold:

```yaml
- type: prometheus
  metadata:
    serverAddress: "https://<<GRAFANA_CLOUD_PROMETHEUS_URL>>"
    metricName: avg_memory_working_set_mib
    threshold: "200"
    query: >-
      avg(container_memory_working_set_bytes{
        namespace="default", container="app",
        pod=~"weekend-scaling-workload-.*"
      }) / 1024 / 1024
  authenticationRef:
    name: grafana-cloud-auth
```

KEDA computes `ceil(metric_value / threshold)` for the Prometheus trigger and keeps the maximum across all triggers:

| Scenario | Cron result | Prometheus result | Effective replicas |
|----------|------------|-------------------|-------------------|
| Weekday, normal memory (150 MiB avg) | 5 | ceil(150/200) = 1 | **5** |
| Weekday, high memory (600 MiB avg) | 5 | ceil(600/200) = 3 | **5** |
| Weekday, very high memory (1200 MiB avg) | 5 | ceil(1200/200) = 6 | **6** |
| Weekend, no pods running | 0 | no data → ignored | **0** |

When pods are at zero over the weekend the Prometheus query returns no data. KEDA's default `noDataAction: ignore` means the trigger is skipped, leaving the cron result of 0 as the sole target.

### Scale-down flow (Friday evening)

```
18:00 UTC Friday
  └── KEDA cron window closes
        └── KEDA sets Deployment replicas → 0
              └── All pods terminated → nodes become Empty
                    └── Karpenter (nodes: "100%" budget now active) terminates all nodes → 0 nodes
```

### Scale-up flow (Monday morning)

```
08:00 UTC Monday
  └── KEDA cron window opens
        └── KEDA sets Deployment replicas → 5
              └── Pods become Pending → Karpenter provisions new nodes
```

## Results

After the Friday scale-down you should observe:

```sh
> kubectl get nodes -l intent=weekend-scaling
No resources found
```

And Karpenter events will confirm consolidation:

```sh
> kubectl get events --field-selector reason=DisruptionTerminating

LAST SEEN   TYPE     REASON                   OBJECT                                            MESSAGE
0s          Normal   DisruptionTerminating    node/ip-10-0-25-100.us-east-1.compute.internal    Disrupting Node: Underutilized/Delete
0s          Normal   DisruptionTerminating    node/ip-10-0-42-211.us-east-1.compute.internal    Disrupting Node: Empty/Delete
```

On Monday, after KEDA restores the replicas, new nodes are provisioned:

```sh
> kubectl get nodes -l intent=weekend-scaling
NAME                                          STATUS   ROLES    AGE   VERSION
ip-10-0-18-77.us-east-1.compute.internal      Ready    <none>   45s   v1.34.1-eks-677bac1
ip-10-0-34-190.us-east-1.compute.internal     Ready    <none>   50s   v1.34.1-eks-677bac1
ip-10-0-91-244.us-east-1.compute.internal     Ready    <none>   48s   v1.34.1-eks-677bac1
```

## Applying to your own workloads

The `workload.yaml` in this blueprint is a sample. To apply the weekend scaling pattern to your own `Deployments`:

1. Ensure pods use `nodeSelector: intent: weekend-scaling` (or match the NodePool label via `nodeAffinity`).
2. Create a `ScaledObject` for each `Deployment`, pointing `scaleTargetRef.name` at it and adjusting `desiredReplicas` / `maxReplicaCount` to match its normal weekday replica count.
3. Remove `spec.replicas` from managed `Deployments` — KEDA owns the replica count and will override it.
4. Update the Prometheus `query` to select pods belonging to your workload, and adjust `threshold` to the memory (in MiB) at which you want each additional replica to be provisioned.

## Clean-up

```sh
kubectl delete -f .
```
