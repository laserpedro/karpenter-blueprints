# Karpenter Blueprint: Weekend Scale-to-Zero

## Purpose

For many teams, non-production workloads (staging, QA, development) run only during business hours and sit idle over weekends. Keeping EC2 nodes running while no work is scheduled wastes money. This blueprint shows how to automatically scale a NodePool to **zero nodes** over the weekend and restore it on Monday morning by combining two Karpenter features:

1. **Disruption budgets** — protect workloads from involuntary disruptions during business hours, and allow aggressive consolidation at all other times (including weekends).
2. **Kubernetes CronJobs** — scale the workload `Deployment` to zero replicas on Friday evening and back up on Monday morning. Once no pods need to be scheduled, Karpenter's `WhenEmptyOrUnderutilized` consolidation policy terminates the now-empty nodes automatically.

> **Why CronJobs instead of a pure Karpenter feature?**
> Karpenter provisions and deprovisions nodes in response to pod demand. To reach zero nodes you must first reach zero pending/running pods. The CronJobs drive that workload-level scale-down; Karpenter's consolidation then handles the node-level scale-down.

## Requirements

* A Kubernetes cluster with Karpenter installed. You can use the blueprint we've used to test this pattern at the cluster folder in the root of this repository.
* The `weekend-scaling-workload` `Deployment` (or a workload of your own) must have no [do-not-disrupt annotations](https://karpenter.sh/docs/concepts/disruption/#pod-level-controls) if you want nodes to drain fully.

## Deploy

If you're using the Terraform template provided in this repo, run the following commands to get the EKS cluster name and the IAM Role name for the Karpenter nodes:

```sh
export CLUSTER_NAME=$(terraform -chdir="../../cluster/terraform" output -raw cluster_name)
export KARPENTER_NODE_IAM_ROLE_NAME=$(terraform -chdir="../../cluster/terraform" output -raw node_instance_role_name)
```

> ***NOTE***: If you're not using Terraform, you need to get those values manually. `CLUSTER_NAME` is the name of your EKS cluster (not the ARN). `KARPENTER_NODE_IAM_ROLE_NAME` is the IAM role name (not the ARN) that Karpenter uses to launch EC2 instances.

Substitute the placeholders and deploy all resources:

```sh
sed -i '' "s/<<CLUSTER_NAME>>/$CLUSTER_NAME/g" weekend-scaling.yaml
sed -i '' "s/<<KARPENTER_NODE_IAM_ROLE_NAME>>/$KARPENTER_NODE_IAM_ROLE_NAME/g" weekend-scaling.yaml
kubectl apply -f .
```

Expected output:

```console
nodepool.karpenter.sh/weekend-scaling created
ec2nodeclass.karpenter.k8s.aws/weekend-scaling created
serviceaccount/weekend-scaler created
role.rbac.authorization.k8s.io/weekend-scaler created
rolebinding.rbac.authorization.k8s.io/weekend-scaler created
cronjob.batch/weekend-scale-down created
cronjob.batch/weekend-scale-up created
deployment.apps/weekend-scaling-workload created
```

Karpenter will provision nodes as the `weekend-scaling-workload` pods become `Pending`:

```sh
kubectl get nodes -l intent=weekend-scaling -w
```

### Adjusting the schedule

The CronJob schedules use UTC. Edit `workload.yaml` to match your timezone offset:

| Event | Default (UTC) | Cron expression |
|-------|--------------|-----------------|
| Scale down | Friday 18:00 UTC | `0 18 * * 5` |
| Scale up | Monday 08:00 UTC | `0 8 * * 1` |

If your team is in US Eastern (UTC-5), Friday 18:00 ET = Friday 23:00 UTC → `0 23 * * 5`.

### Adjusting the replica count

The scale-up CronJob restores the `Deployment` to **5 replicas**. Change the `--replicas` flag in the `weekend-scale-up` `CronJob` to match your normal weekday replica count.

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
| `nodes: "100%"` | Fri 18:00 → Mon 08:00 UTC (62 h) | All empty nodes terminated simultaneously — safe because the CronJob has already scaled all replicas to zero before this window opens |

The two budgets are mutually exclusive and cover the full week without overlap. Karpenter always applies the most restrictive budget when multiple are active simultaneously.

### Scale-down flow (Friday evening)

```
18:00 UTC Friday
  └── CronJob "weekend-scale-down" runs
        └── kubectl scale deployment/weekend-scaling-workload --replicas=0
              └── All pods terminated → nodes become Empty
                    └── Karpenter consolidation removes nodes → 0 nodes
```

### Scale-up flow (Monday morning)

```
08:00 UTC Monday
  └── CronJob "weekend-scale-up" runs
        └── kubectl scale deployment/weekend-scaling-workload --replicas=5
              └── Pods become Pending → Karpenter provisions new nodes
```

## Results

After the Friday scale-down CronJob fires you should observe:

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

On Monday, after the scale-up CronJob fires, new nodes are provisioned:

```sh
> kubectl get nodes -l intent=weekend-scaling
NAME                                          STATUS   ROLES    AGE   VERSION
ip-10-0-18-77.us-east-1.compute.internal      Ready    <none>   45s   v1.34.1-eks-677bac1
ip-10-0-34-190.us-east-1.compute.internal     Ready    <none>   50s   v1.34.1-eks-677bac1
ip-10-0-91-244.us-east-1.compute.internal     Ready    <none>   48s   v1.34.1-eks-677bac1
```

## Applying to your own workloads

The `workload.yaml` in this blueprint is a sample. To apply the weekend scaling pattern to your own `Deployments`:

1. Ensure pods use the `nodeSelector: intent: weekend-scaling` (or match the NodePool label via `nodeAffinity`).
2. Update the two `CronJob` commands to reference your `Deployment` name and desired replica counts.
3. If you manage multiple `Deployments`, extend the CronJob `command` to loop over each one, or create separate CronJob pairs per `Deployment`.

## Clean-up

```sh
kubectl delete -f .
```
