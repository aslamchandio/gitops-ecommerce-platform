# Infrastructure (GCP)

Provisions everything needed to run the storefront on GCP:

- **GKE Standard** regional cluster (control plane in 3 zones)
  - Default node pool removed
  - Minimal **`system-pool`** (1× `e2-small`/zone) for kube-system + DaemonSets
  - **Node Auto-Provisioning** enabled — workload nodes are created on demand and scale to zero
  - **Gateway API** controller enabled (`CHANNEL_STANDARD`)
- **Artifact Registry** repository for service images
- **Cloud SQL** Postgres (private IP) with `catalog` and `orders` databases
- **Memorystore Redis** (basic tier) on the VPC
- **VPC + subnet + private services access** — SQL/Redis are not internet-exposed
- A dedicated **GKE node service account** with least-privilege IAM (logging, monitoring, AR pull)
- Generated **`k8s/generated-secrets.yaml`** with DB/Redis connection strings

App workload nodes are created via a **`ComputeClass`** ([`k8s/05-compute-class.yaml`](../../k8s/05-compute-class.yaml)) that prefers **Spot VMs** (~70% cheaper) with on-demand fallback. Workloads opt in with:

```yaml
nodeSelector:
  cloud.google.com/compute-class: ecom-spot
tolerations:
  - key: cloud.google.com/gke-spot
    operator: Equal
    value: "true"
    effect: NoSchedule
```

Public traffic enters through a **Gateway** + **HTTPRoute** ([`k8s/60-gateway.yaml`](../../k8s/60-gateway.yaml)) using the GA `gke-l7-global-external-managed` GatewayClass — no Ingress resources.

## Cost notes (single-region, idle traffic)

| Resource                          | ~Monthly USD |
|-----------------------------------|--------------|
| GKE Standard cluster management   | $74 (free for first cluster per billing account) |
| `system-pool` 3× e2-small         | ~$18 |
| App pods on Spot e2 (NAP-managed) | ~$5–10 |
| Cloud SQL `db-f1-micro`           | ~$10 |
| Memorystore 1 GB Basic            | ~$25 |
| Global external HTTP LB           | ~$18 |
| Artifact Registry storage         | <$1 |
| **Total**                         | **~$75–90** (or ~$150 if cluster fee applies) |

Switching to `gke-l7-regional-external-managed` and one zone saves ~$10–15/mo at the cost of HA.

## Apply

```bash
gcloud auth application-default login

cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars with your project_id

terraform init
terraform apply
```

`terraform apply` prints a `kubectl_connect_command`. Run it, then:

```bash
# Reserve the LB IP (referenced by the Gateway annotation)
gcloud compute addresses create ecom-ip --global

# Build, push, deploy
../../scripts/build-and-push.sh <PROJECT_ID> <REGION>
../../scripts/deploy.sh <PROJECT_ID>

# Watch the Gateway provision (takes 3–8 minutes for the LB to come up)
kubectl -n ecom get gateway ecom-gateway -w

# Then check the LB IP
gcloud compute addresses describe ecom-ip --global --format='value(address)'
```

Point your DNS A record at that IP, edit `hostnames:` in the HTTPRoute to match,
and re-apply.

## Tear down

```bash
terraform destroy
gcloud compute addresses delete ecom-ip --global --quiet
```
