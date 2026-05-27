# Infrastructure — Terraform (GCP)

Provisions every piece of GCP infrastructure the project depends on: network, GKE cluster, data plane, image registry, TLS, ArgoCD, and the keyless CI identity. After `terraform apply`, the only manual step is pasting two outputs into GitHub Actions secrets — everything else is GitOps from there.

Every named resource is prefixed `<business_division>-<environment_name>-` (e.g. `it-prod-vpc`, `it-prod-standard`, `it-prod-ecom-postgres`). Flipping those two tfvars rebrands the whole stack without code changes. See [Naming convention + multi-region network](#naming-convention--multi-region-network) below for the details.

---

## What this provisions

| Layer            | Resources                                                                                 | File                                              |
|------------------|--------------------------------------------------------------------------------------------|---------------------------------------------------|
| Network          | Global VPC fanned out across every key in `var.regions`. Per region: optional `gke` / `vm` / `proxy` subnets + Cloud Router + Cloud NAT. Single global reservation pinned via `var.private_services_address` for Cloud SQL + Memorystore peering. | [`network.tf`](network.tf), [`locals.tf`](locals.tf), [`datasource.tf`](datasource.tf) |
| Compute          | GKE Standard regional cluster (3 zones) · minimal system pool · Node Auto-Provisioning · Gateway API enabled · **GMP enabled with 9 scrape components** | [`gke.tf`](gke.tf)                                |
| Data             | Cloud SQL Postgres (private, `max_connections=75` via `database_flags`) · Memorystore Redis (basic, private) | [`cloudsql.tf`](cloudsql.tf), [`redis.tf`](redis.tf) |
| Secrets          | Generated DB password (random_password) · GSM secret entry · K8s Secret + ConfigMap        | [`secrets.tf`](secrets.tf), [`secret_manager.tf`](secret_manager.tf) |
| Image registry   | Artifact Registry repo `ecom-microservices` with cleanup policy                            | [`artifact_registry.tf`](artifact_registry.tf)    |
| Ingress IP       | Reserved global external address pinned by the Gateway                                     | [`gateway_ip.tf`](gateway_ip.tf)                  |
| TLS              | Cert Manager certificate + CertificateMap + MapEntry binding `domain` → cert               | [`cert_map.tf`](cert_map.tf)                      |
| IAM              | GKE node SA (least-privilege) · workload SA bound via Workload Identity to read GSM secrets | [`iam.tf`](iam.tf)                                |
| GitOps           | ArgoCD via Helm chart `9.5.15` (ArgoCD v3.4.2) · `ecom` Application with auto-sync         | [`argocd.tf`](argocd.tf), [`argocd_application.tf`](argocd_application.tf) |
| Keyless CI       | Workload Identity Federation pool + GitHub OIDC provider · SA scoped to AR writer only     | [`github_oidc.tf`](github_oidc.tf)                |
| Observability    | GSA `grafana-gmp-reader` (`roles/monitoring.viewer`) + WI binding for in-cluster Grafana proxy KSA | [`grafana.tf`](grafana.tf)                        |
| API enablement   | All required GCP APIs enabled before dependents are created                                | [`apis.tf`](apis.tf)                              |

---

## Naming convention + multi-region network

### Naming

Two top-level variables drive every resource name:

```hcl
business_division = "it"     # naming prefix part 1
environment_name  = "prod"   # naming prefix part 2
```

[`locals.tf`](locals.tf) joins them into `local.name = "<biz>-<env>"`. Every named resource interpolates it:

```
it-prod-vpc                     it-prod-gke-us-central1
it-prod-standard                it-prod-ecom-postgres
it-prod-router-us-west1         it-prod-private-services
```

Spin a parallel `staging` stack by copying `terraform.tfvars`, changing `environment_name = "staging"` (plus the GCS state prefix and a non-overlapping CIDR layout), and `terraform apply`. The whole resource graph re-prefixes itself.

### Multi-region network

`var.regions` is a map(object) — one entry per GCP region. Add a key to expand the VPC into a new region; remove one to collapse. The cluster and data plane anchor to whichever key is in `var.gke_region`.

```hcl
# variables.tf (schema)
variable "regions" {
  type = map(object({
    vpc_cidr          = string                # /16 sliced into primary ranges via cidrsubnet
    subnet_newbits    = number                # 8 -> /24, 4 -> /20
    gke_pods_cidr     = optional(string)
    gke_services_cidr = optional(string)
    vm_subnet         = optional(bool, false)
    proxy_cidr        = optional(string)
  }))
}
```

Each subnet type is **independently opt-in** — a region only carries the subnets it actually needs:

| Subnet | Created when | Purpose |
|---|---|---|
| `<name>-gke-<region>` | both `gke_pods_cidr` + `gke_services_cidr` are set | GKE node subnet. Secondary pods + services ranges attach only in `var.gke_region`. |
| `<name>-vm-<region>` | `vm_subnet = true` | Plain Compute Engine / non-GKE workloads. |
| `<name>-proxy-<region>` | `proxy_cidr` is set | Reserved `REGIONAL_MANAGED_PROXY` slot for regional internal LB / Gateway envoys. |

Routers + Cloud NATs are created per region only when at least one egress-eligible subnet (gke or vm) exists there. The NAT uses dynamic `subnetwork` blocks so it attaches only the subnets actually present.

### CIDR slicing via `cidrsubnet`

[`locals.tf`](locals.tf) carves each region's `vpc_cidr` into primary ranges:

```hcl
gke_cidr = cidrsubnet(cfg.vpc_cidr, cfg.subnet_newbits, 1)   # position 1
vm_cidr  = cidrsubnet(cfg.vpc_cidr, cfg.subnet_newbits, 2)   # position 2
```

`proxy_cidr`, `gke_pods_cidr`, `gke_services_cidr` are passed in explicitly because they have size/positioning constraints that don't slice cleanly (`REGIONAL_MANAGED_PROXY` needs /23+, secondary ranges are typically much larger than the primary).

### Example layout (current `terraform.tfvars`)

```hcl
business_division = "it"
environment_name  = "prod"
gke_region        = "us-central1"

regions = {
  us-central1 = {
    vpc_cidr          = "192.168.0.0/16"
    subnet_newbits    = 4                 # /16 -> /20 subnets
    gke_pods_cidr     = "10.244.0.0/14"   # 262k pod IPs
    gke_services_cidr = "10.32.0.0/20"
    # No vm_subnet, no proxy_cidr -> only the gke subnet here
  }
  us-west1 = {
    vpc_cidr       = "172.26.0.0/16"
    subnet_newbits = 8                    # /16 -> /24 subnets
    vm_subnet      = true                 # only the vm subnet here
  }
}

private_services_address       = "10.77.0.0"   # pinned so SQL + Redis peering is deterministic
private_services_prefix_length = 16
```

That produces:

| Subnet | Region | CIDR | Notes |
|---|---|---|---|
| `it-prod-gke-us-central1` | us-central1 | `192.168.16.0/20` | + secondaries `10.244.0.0/14` (pods) + `10.32.0.0/20` (services) |
| `it-prod-vm-us-west1` | us-west1 | `172.26.2.0/24` | — |

Plus Cloud Router + Cloud NAT in each region, and a single global reservation `it-prod-private-services` (`10.77.0.0/16`) for Cloud SQL + Memorystore VPC peering.

### CIDR allocation map (current)

```
10.32.0.0/20     GKE services secondary  (cluster-internal Services)
10.77.0.0/16     Private services peering (Cloud SQL + Redis tenant project)
10.244.0.0/14    GKE pods secondary

172.16.0.0/28    GKE control plane master peering
172.26.2.0/24    us-west1 VM subnet primary

192.168.16.0/20  us-central1 GKE node primary
192.168.0.0/16   us-central1 VPC parent (sliced into /20s)
172.26.0.0/16    us-west1 VPC parent     (sliced into /24s)
```

Zero overlaps. Pin `private_services_address` instead of letting GCP auto-allocate so the range stays the same across rebuilds.

---

## First-time deploy

### 1. Authenticate + configure

```bash
gcloud auth application-default login
cp terraform.tfvars.example terraform.tfvars
# edit: project_id, domain, github_repo, master_authorized_networks
```

### 2. Apply

```bash
terraform init        # connects to the GCS backend (see backend.tf)
terraform apply
```

State lives in `gs://<your-tf-state-bucket>/prod/c1-ecommerce-project/` (the actual bucket name is set in [`backend.tf`](backend.tf) — kept out of this README so the value isn't searchable in public mirrors). `terraform init` pulls the existing state from there — no local `.tfstate` file is created. The bucket has versioning enabled so a bad apply can be rolled back via object generation history.

Takes ~15 minutes the first time (GKE cluster + Cloud SQL are the slow ones). The apply will:

- Provision all infra above
- Install ArgoCD with auto-sync enabled
- Create the `ecom` Application pointing at this repo's `k8s/` directory

### 3. Wire GitHub Actions to GCP

Values that land in the repo's **Settings → Secrets and variables → Actions**:

| Setting type | Name | Value | Used by |
|---|---|---|---|
| Secret | `GCP_WIF_PROVIDER`  | `terraform output github_actions_wif_provider` | all workflows |
| Secret | `GCP_SERVICE_ACCOUNT` | `terraform output github_actions_sa_email` | `ci.yml` (image build/push — Artifact Registry writer only) |
| Secret | `TF_RUNNER_SA` | `terraform-runner@<project>.iam.gserviceaccount.com` (created by [`scripts/create-tf-runner.sh`](../../scripts/create-tf-runner.sh) — see below) | `terraform-plan.yml`, `terraform-apply.yml`, `terraform-destroy.yml` |
| Secret | `ARGOCD_DEPLOY_KEY_PRIVATE` | contents of [`.argocd-deploy-key`](./.argocd-deploy-key) | `terraform-apply.yml` only |
| **Variable** | `PROJECT_ID` | your GCP project ID | all workflows |

CLI shortcut (after `terraform apply` AND running `create-tf-runner.sh`):

```bash
gh secret   set GCP_WIF_PROVIDER          --body "$(terraform output -raw github_actions_wif_provider)"
gh secret   set GCP_SERVICE_ACCOUNT       --body "$(terraform output -raw github_actions_sa_email)"
gh secret   set TF_RUNNER_SA              --body "terraform-runner@$(terraform output -raw -json | jq -r .project_id // 'YOUR-PROJECT').iam.gserviceaccount.com"
gh secret   set ARGOCD_DEPLOY_KEY_PRIVATE < infrastructure/terraform/.argocd-deploy-key
gh variable set PROJECT_ID                --body "<your-project-id>"
```

Two service accounts, two blast radii — never grant one SA both privileges:

- **`github-actions-ci`** ← used by `ci.yml`. Terraform-managed (`github_oidc.tf`). Only `roles/artifactregistry.writer` on `ecom-microservices`. Worst-case: rogue images in one AR repo.
- **`terraform-runner`** ← used by the three terraform workflows. **Bootstrap-managed via gcloud, NOT terraform** (see scripts below). `roles/owner` on the project. Why outside terraform: the SA terraform CI impersonates can't be created by the terraform CI workflow that needs it — chicken-and-egg. The WIF `attribute_condition` pins both to *this repo's* OIDC tokens — random workflows on github.com can't mint tokens for either SA.

#### Bootstrap / teardown of `terraform-runner` (manual, one-off)

```bash
# After `terraform apply` (which creates the WIF pool + provider):
./scripts/create-tf-runner.sh   # idempotent; safe to re-run

# Wire the GH secret:
gh secret set TF_RUNNER_SA \
  --repo aslamchandio/web-app-project \
  --body "terraform-runner@<project-id>.iam.gserviceaccount.com"

# To remove later (e.g. rotating to a fresh SA):
./scripts/delete-tf-runner.sh
```

Both scripts read overrides from `PROJECT_ID`, `PROJECT_NUMBER`, `REPO` env vars; defaults are this project's values. Re-creating after delete within 30 days undeletes the soft-deleted SA (preserving the unique ID); after 30 days it creates fresh.

The WIF provider is **repo-scoped** — only OIDC tokens from `var.github_repo` (e.g. `aslamchandio/web-app-project`) can mint tokens for the CI service account. The SA's only IAM grant is `roles/artifactregistry.writer` on the `ecom-microservices` repo (no project-wide permissions). If the workflow is ever compromised, blast radius is "can push images to one AR repo".

### 4. DNS

```bash
terraform output gateway_ip                # → A record for var.domain
```

Point your domain's A record at the printed IP. The Gateway is pinned to this reserved IP, so it survives cluster recreations.

### Terraform via GitHub Actions (optional)

Three workflows in [`.github/workflows/`](../../.github/workflows/) let you run terraform without a laptop. All use the dedicated `terraform-runner` SA via WIF (no JSON keys).

| Workflow | Trigger | Confirmation | Notes |
|---|---|---|---|
| [`terraform-plan.yml`](../../.github/workflows/terraform-plan.yml) | `pull_request` touching `infrastructure/terraform/**` | none — read-only | Posts the plan as a PR comment. Stubs the ArgoCD key with a throwaway since plan never pushes it. |
| [`terraform-apply.yml`](../../.github/workflows/terraform-apply.yml) | `workflow_dispatch` | type **`APPLY`** in the input | Two-step bootstrap: `-target` cluster + helm release first (so `kubernetes_manifest` can plan), then full apply. Materializes the real deploy key from `ARGOCD_DEPLOY_KEY_PRIVATE`. |
| [`terraform-destroy.yml`](../../.github/workflows/terraform-destroy.yml) | `workflow_dispatch` | type **`DESTROY-PROD-IT`** in the input | Posts a sanity check after destroy (lists any remaining GKE / SQL / Redis / VPC resources). |

**Recommended hardening before you trust apply / destroy:**

1. **GitHub Environments** — under repo Settings → Environments, create `production` and `production-destroy`, each with a required-reviewer rule (yourself or a co-owner). Uncomment the `environment:` line in the corresponding workflow. Now CLI confirmation **and** a UI click are needed.

2. **Branch protection on `main`** — require PR review + passing `terraform-plan` check before merge. Combined with the manual apply trigger this means no IaC change can reach production without (a) human-reviewed diff and (b) human-clicked apply.

3. **Plan-only first** — run `terraform-apply.yml` with `target_only = true` to provision just the cluster + helm release, then re-run with `target_only = false` for the full apply. Avoids surprises on first deploy.

CI-vs-laptop tradeoff: laptop apply is simpler (`terraform apply` from `infrastructure/terraform/`) but mixes "who applied" with "who's at the keyboard". CI apply gives an audit trail (workflow run logs are forever) and forces every change through a PR. Use whichever fits your workflow — both still talk to the same GCS state, so they don't conflict.

### 5. First release

```bash
git tag v1
git push origin v1
```

The CI workflow ([`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)) builds all 5 services in parallel, pushes images to Artifact Registry, rewrites `k8s/*.yaml` to the immutable short-SHA, and commits back to `main`. ArgoCD detects the new revision and rolls out within ~30 seconds. Total `git push` → live: ~3 minutes.

---

## ArgoCD configuration

The `ecom` Application ([`argocd_application.tf`](argocd_application.tf)) is configured for **full GitOps**: auto-sync, prune, self-heal. Two non-obvious bits:

### Why `ApplyOutOfSyncOnly` is **not** in the syncOptions

It was, and a v2 deploy silently reported `Synced` without actually applying the image bump. The stale-diff cache decided the Deployments were already InSync. Removed for correctness — sync takes a few extra seconds, deploys never silently no-op.

### Why ArgoCD chart is pinned to `9.5.15` (not 7.x)

Chart 7.x ships ArgoCD v2.13, which has a schema bug where it can't process Kubernetes 1.32+ Deployment status (specifically `.status.terminatingReplicas`, added in K8s 1.32 Beta). The Server-Side-Diff calculation crashes silently, and ArgoCD reports `Synced` without ever calling `Apply`. Chart 9.5.15 = ArgoCD v3.4.2 has the schema fix.

### `ignoreDifferences`

```hcl
ignoreDifferences = [
  { kind = "Service",    jqPathExpressions = [
      ".metadata.annotations.\"cloud.google.com/neg-status\"",   # controller-written
      ".metadata.annotations.\"cloud.google.com/neg\"",          # GKE re-serializes JSON
  ]},
  { kind = "Deployment", jsonPointers = ["/spec/replicas"] },    # HPA-owned
]
```

The `cloud.google.com/neg` entry was added after a permanent OutOfSync flap: GKE rewrites the JSON value to compact form (no spaces), but git had spaces. ArgoCD's string diff caught the whitespace as a difference forever. Ignoring the field lets GKE own the serialized form.

---

## Workload Identity Federation (no JSON keys)

The GitHub OIDC integration (`github_oidc.tf`) is the security-critical piece:

```
GitHub Actions runs in repo "aslamchandio/web-app-project"
  → emits short-lived OIDC token with claim "repository=aslamchandio/web-app-project"
  → presents it to Workload Identity Pool "github-pool"
  → attribute_condition: assertion.repository == "aslamchandio/web-app-project"  (HARD GATE)
  → pool issues a short-lived GCP access token impersonating SA "github-actions-ci"
  → SA has roles/artifactregistry.writer on repo "ecom-microservices" (ONLY)
```

The attribute condition is non-negotiable: without it, **any** github.com workflow could mint tokens for the SA. With it, only this repo can.

Service account permissions are deliberately minimal — Artifact Registry writer on one repo, nothing else. The workflow can't read other projects, can't touch GKE, can't read secrets. If the CI is ever compromised, the worst-case is rogue images in `ecom-microservices`.

---

## Observability: GMP + Grafana

### What's enabled in `gke.tf`

```hcl
monitoring_config {
  enable_components = [
    "SYSTEM_COMPONENTS",   # baseline GKE system metrics
    "CADVISOR",            # container_cpu_*, container_memory_*, container_fs_*, container_network_*
    "KUBELET",             # kubelet_running_pods, kubelet_runtime_operations_*
    "STORAGE",             # kubelet_volume_stats_* (PVC capacity/free)
    "POD",                 # kube_pod_*
    "DEPLOYMENT",          # kube_deployment_*
    "STATEFULSET", "DAEMONSET", "HPA",   # matching kube_* families
  ]
  managed_prometheus { enabled = true }
}
```

Each component is a separate managed scrape config that GMP runs inside the cluster — no DaemonSets to maintain, no node-exporter to deploy. Metrics show up under standard Prometheus names in PromQL via the in-cluster GMP query frontend (see [`k8s/95-gmp-frontend.yaml`](../../k8s/95-gmp-frontend.yaml)).

### `grafana.tf` — IAM for the GMP frontend

```
GSA grafana-gmp-reader
  ├─ roles/monitoring.viewer (project-level, read-only)
  └─ iam.workloadIdentityUser bound to
       serviceAccount:<project>.svc.id.goog[ecom/gmp-frontend]
```

The in-cluster `gmp-frontend` pod (KSA `gmp-frontend` in namespace `ecom`) impersonates the GSA via Workload Identity and forwards Grafana's PromQL queries to `monitoring.googleapis.com`. Grafana itself holds **zero GCP credentials** — if the Grafana pod is compromised, the attacker can read metrics through the in-cluster proxy but can't touch any other GCP API directly.

### Cost

Each ingested sample bills under Cloud Monitoring. First **250M samples/month per project are free**; a small cluster with 9 scrape components + 3 app `/actuator/prometheus` endpoints sits comfortably inside the free tier. The dominant series count comes from cAdvisor (per-container labels × node count); if you scale the cluster up, watch the Monitoring billing page.

### Local validation

GMP and Grafana are GKE-only — there's no managed prometheus in `docker-compose`. The compose-first smoke test confirms `/actuator/prometheus` returns valid metric output, but the scrape + dashboard pipeline only exists in production.

---

## Cost estimate (single region, idle traffic)

| Resource                           | ~Monthly USD                                  |
|------------------------------------|-----------------------------------------------|
| GKE Standard cluster management    | $74 (free for first cluster per billing account) |
| `system-pool` 3× `e2-small`        | ~$18                                          |
| App pods on Spot e2 (NAP-managed)  | ~$5–10                                        |
| Cloud SQL `db-f1-micro`            | ~$10                                          |
| Memorystore 1 GB Basic             | ~$25                                          |
| Global external HTTP LB            | ~$18                                          |
| Cloud NAT egress                   | ~$1–5                                         |
| Artifact Registry storage          | <$1                                           |
| ArgoCD                             | $0 (runs in cluster)                          |
| **Total**                          | **~$80–95** (or ~$150 if the cluster mgmt fee applies) |

Switching `gke-l7-global-external-managed` → `gke-l7-regional-external-managed` saves ~$10/mo at the cost of multi-region HA. Going single-zone saves another ~$10 at the cost of zonal HA.

---

## Day-2 ops

### Add or change a Terraform variable

Variables are declared in [`variables.tf`](variables.tf) with **no defaults** — all values live in `terraform.tfvars`. This makes a missing variable a hard fail at `plan` time instead of a silent fallback.

### Upgrade ArgoCD

Bump `argocd_chart_version` in `terraform.tfvars` and `terraform apply`. The Helm release will roll the controller, repo-server, and server pods (~2 min). Existing Applications survive.

### Rotate the DB password

Tainting the `random_password.db_password` resource regenerates it and rewrites `k8s/generated-config.yaml` (which is gitignored — Terraform owns it). Pods restart to pick it up via the workload-identity-mounted secret.

### Raise Cloud SQL connection ceiling

Edit the `database_flags { name = "max_connections" }` block in [`cloudsql.tf`](cloudsql.tf) and `terraform apply -target=google_sql_database_instance.postgres`. Causes a one-time Cloud SQL restart (~30s) — minimal downtime because of `minReplicas=2` + HikariCP's `fail-fast` retry on the next request.

**When to raise it:** if you bump `minReplicas` on `order-service` or `catalog-service` beyond 2, or add a new Postgres-using service. The current value (75) fits ~2-3 replicas of each Spring Boot service at HikariCP=5. Rough formula:

```
needed_max ≈ Σ(svc.replicas × svc.hikari_pool) + go_pool + probes(~5) + reservation(~3)
```

For db-f1-micro (0.6GB RAM), don't exceed ~100 — connections consume memory and the instance will start swapping.

### Remote state

State lives at `gs://<your-tf-state-bucket>/prod/c1-ecommerce-project/default.tfstate` — the bucket name is in [`backend.tf`](backend.tf) only (not in this README). The bucket has versioning enabled, so each `terraform apply` creates a new object generation:

```bash
# Capture the bucket once so the commands below stay generic.
BUCKET=$(grep -oP 'bucket\s*=\s*"\K[^"]+' backend.tf)
PREFIX=$(grep -oP 'prefix\s*=\s*"\K[^"]+' backend.tf)

# List historical state versions
gcloud storage ls -a "gs://$BUCKET/$PREFIX/default.tfstate"

# Roll back to a specific generation
gcloud storage cp \
  "gs://$BUCKET/$PREFIX/default.tfstate#<generation>" \
  "gs://$BUCKET/$PREFIX/default.tfstate"
```

To add a new environment under the same bucket, copy [`backend.tf`](backend.tf) to a new module directory with a different prefix (e.g. `staging/c1-ecommerce-project`). The `c1-` slug identifies this configuration; bump it (`c2-`, etc.) if you spin up parallel clusters.

### Destroy everything

```bash
terraform destroy
```

End-to-end time is ~12-15 min. Cloud SQL is the slow part (~5 min on its own), followed by the GKE cluster (~3 min) and the global LB resources (~1-2 min). Artifact Registry images are kept by default — delete the repo manually with `gcloud artifacts repositories delete ecom-microservices --location=us-central1` if you want them gone.

#### Structural protections baked in

A first-time naive `terraform destroy` of this stack hits five distinct blockers — each one is now mitigated in code:

| Blocker (raw GCP / TF behaviour) | Where the fix lives |
|---|---|
| GKE Gateway controller deletes the global LB **asynchronously** after Gateway/HTTPRoute removal. If the cluster is torn down first, the LB orphans and the CertificateMap delete fails with `can't delete certificate map that is referenced by a target proxy`. | [`argocd_application.tf`](argocd_application.tf): `time_sleep.argocd_cascade_grace` (90s) sits between `helm_release.argocd` and `kubernetes_manifest.ecom_application`. Destroy order pauses long enough for the controller to free the LB. |
| Postgres user owns objects in `catalog` + `orders` → `DROP USER` fails. | [`cloudsql.tf`](cloudsql.tf): `deletion_policy = "ABANDON"` on `google_sql_user.app`. The instance delete cascades to it. |
| Database drops race against still-open pod connections → `database "orders" is being accessed by other users`. | [`cloudsql.tf`](cloudsql.tf): `deletion_policy = "ABANDON"` on both `google_sql_database` resources. |
| GCP's `servicenetworking` producer-tenant holds the peering open for a 10-30 min internal-cleanup window → `FLOW_SN_DC_RESOURCE_PREVENTING_DELETE_CONNECTION`. | [`network.tf`](network.tf): `deletion_policy = "ABANDON"` on `google_service_networking_connection.private_vpc` + sibling `null_resource.private_vpc_peering_cleanup` with a destroy-time `gcloud compute networks peerings delete` that severs the consumer-side peering. |
| `kubernetes_manifest` requires a live cluster at plan time. After the cluster is destroyed, any subsequent `terraform destroy / plan / apply` fails with `cannot create REST client: no client config`. | [`versions.tf`](versions.tf): `try(...)` wrappers on `host`, `token`, and `cluster_ca_certificate` in the `kubernetes` + `helm` provider blocks. At apply-time the real cluster refs win; after destroy the placeholders let the provider init cleanly. |

The result: `terraform destroy` runs cleanly in one pass on a healthy stack. No manual gcloud cleanup, no `terraform state rm`, no order workarounds.

#### If something does get stuck

The most common residual orphan after a forced/interrupted destroy is the global LB stack. Sweep with:

```bash
# Run these in order — each entry depends on the next
gcloud compute forwarding-rules     list --global
gcloud compute target-https-proxies list
gcloud compute target-http-proxies  list
gcloud compute url-maps             list
gcloud compute backend-services     list
gcloud compute network-endpoint-groups list

# Delete what's left (replace NAME placeholders)
gcloud compute forwarding-rules     delete NAME --global --quiet
gcloud compute target-https-proxies delete NAME --quiet
# ...etc
```

If the service-networking peering is stuck (the producer-tenant grace period beat the destroy provisioner), force it from the consumer side:

```bash
gcloud compute networks peerings delete servicenetworking-googleapis-com \
  --network=ecom-vpc --project=$PROJECT_ID --quiet
```

The producer tenant connection self-reaps once both sides are severed; you don't need to chase the `qf*-tp` project.

---

## File map

```
infrastructure/terraform/
├── apis.tf                    GCP API enablement (gate for all dependent resources)
├── network.tf                 VPC + per-region gke/vm/proxy subnets + per-region Cloud Router/NAT + private services peering
├── locals.tf                  local.name = <biz>-<env>; cidrsubnet slicing per region; zone slices
├── datasource.tf              google_compute_zones for_each over var.regions (zone discovery)
├── gke.tf                     GKE cluster (on gke[var.gke_region]) + system pool + NAP + Gateway API + GMP components
├── cloudsql.tf                Cloud SQL Postgres + 2 databases + user (ABANDON deletion policies)
├── redis.tf                   Memorystore Redis (basic, private)
├── artifact_registry.tf       AR repo + cleanup policy (in var.gke_region)
├── gateway_ip.tf              Reserved global LB IP (name follows the prefix → it-prod-ecom-ip)
├── cert_map.tf                Cert Manager certificate + CertificateMap binding
├── iam.tf                     GKE node SA + workload SA + WI binding
├── argocd.tf                  Helm release of argo-cd chart (LB exposed, source-range locked)
├── argocd_application.tf      The "ecom" Application CR + time_sleep.argocd_cascade_grace
├── github_oidc.tf             WIF pool + provider + github-actions-ci SA (image push only)
│                              terraform-runner SA is bootstrapped separately by
│                              scripts/create-tf-runner.sh (chicken-and-egg avoidance)
├── grafana.tf                 GSA + WI binding for the in-cluster GMP query proxy (Grafana auth)
├── secrets.tf                 Generated DB password + K8s Secret
├── secret_manager.tf          GSM secret entries (workload-identity readable)
├── variables.tf               business_division, environment_name, regions(map), gke_region, etc.
├── outputs.tf                 Cluster name, gateway IP, WIF outputs, etc.
├── versions.tf                Terraform + provider version pins (incl. hashicorp/time)
├── backend.tf                 GCS remote state config (prefix: prod/c1-ecommerce-project)
├── terraform.tfvars.example   Template — copy to terraform.tfvars and fill in
└── terraform.tfvars           Your values (gitignored)
```
