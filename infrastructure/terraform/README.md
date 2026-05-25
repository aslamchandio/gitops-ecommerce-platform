# Infrastructure — Terraform (GCP)

Provisions every piece of GCP infrastructure the project depends on: network, GKE cluster, data plane, image registry, TLS, ArgoCD, and the keyless CI identity. After `terraform apply`, the only manual step is pasting two outputs into GitHub Actions secrets — everything else is GitOps from there.

---

## What this provisions

| Layer            | Resources                                                                                 | File                                              |
|------------------|--------------------------------------------------------------------------------------------|---------------------------------------------------|
| Network          | VPC + subnet + Cloud NAT + private services access (private IPs for SQL/Redis)              | [`network.tf`](network.tf)                        |
| Compute          | GKE Standard regional cluster (3 zones) · minimal system pool · Node Auto-Provisioning · Gateway API enabled | [`gke.tf`](gke.tf)                                |
| Data             | Cloud SQL Postgres (private) · Memorystore Redis (basic, private)                          | [`cloudsql.tf`](cloudsql.tf), [`redis.tf`](redis.tf) |
| Secrets          | Generated DB password (random_password) · GSM secret entry · K8s Secret + ConfigMap        | [`secrets.tf`](secrets.tf), [`secret_manager.tf`](secret_manager.tf) |
| Image registry   | Artifact Registry repo `ecom-microservices` with cleanup policy                            | [`artifact_registry.tf`](artifact_registry.tf)    |
| Ingress IP       | Reserved global external address pinned by the Gateway                                     | [`gateway_ip.tf`](gateway_ip.tf)                  |
| TLS              | Cert Manager certificate + CertificateMap + MapEntry binding `domain` → cert               | [`cert_map.tf`](cert_map.tf)                      |
| IAM              | GKE node SA (least-privilege) · workload SA bound via Workload Identity to read GSM secrets | [`iam.tf`](iam.tf)                                |
| GitOps           | ArgoCD via Helm chart `9.5.15` (ArgoCD v3.4.2) · `ecom` Application with auto-sync         | [`argocd.tf`](argocd.tf), [`argocd_application.tf`](argocd_application.tf) |
| Keyless CI       | Workload Identity Federation pool + GitHub OIDC provider · SA scoped to AR writer only     | [`github_oidc.tf`](github_oidc.tf)                |
| API enablement   | All required GCP APIs enabled before dependents are created                                | [`apis.tf`](apis.tf)                              |

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
terraform init
terraform apply
```

Takes ~15 minutes the first time (GKE cluster + Cloud SQL are the slow ones). The apply will:

- Provision all infra above
- Install ArgoCD with auto-sync enabled
- Create the `ecom` Application pointing at this repo's `k8s/` directory

### 3. Wire GitHub Actions to GCP

Three values land in the repo's **Settings → Secrets and variables → Actions**:

| Setting type | Name | Value (terraform output) | Why this type |
|---|---|---|---|
| Secret | `GCP_WIF_PROVIDER`  | `terraform output github_actions_wif_provider` | URL identifies your pool/provider — kept masked |
| Secret | `GCP_SERVICE_ACCOUNT` | `terraform output github_actions_sa_email` | SA email — kept masked |
| **Variable** | `PROJECT_ID` | `terraform output -raw -json | jq -r .project_id.value` (or just the value of `var.project_id`) | Not sensitive (visible in image URLs anyway) and you'll want to edit it without a commit |

CLI shortcut:

```bash
gh secret   set GCP_WIF_PROVIDER    --body "$(terraform output -raw github_actions_wif_provider)"
gh secret   set GCP_SERVICE_ACCOUNT --body "$(terraform output -raw github_actions_sa_email)"
gh variable set PROJECT_ID          --body "<your-project-id>"
```

The WIF provider is **repo-scoped** — only OIDC tokens from `var.github_repo` (e.g. `aslamchandio/web-app-project`) can mint tokens for the CI service account. The SA's only IAM grant is `roles/artifactregistry.writer` on the `ecom-microservices` repo (no project-wide permissions). If the workflow is ever compromised, blast radius is "can push images to one AR repo".

### 4. DNS

```bash
terraform output gateway_ip                # → A record for var.domain
```

Point your domain's A record at the printed IP. The Gateway is pinned to this reserved IP, so it survives cluster recreations.

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

### Destroy everything

```bash
terraform destroy
```

Cloud SQL takes ~5 minutes to delete. Artifact Registry images are kept by default — delete the repo manually if you want them gone.

---

## File map

```
infrastructure/terraform/
├── apis.tf                    GCP API enablement (gate for all dependent resources)
├── network.tf                 VPC, subnet, Cloud NAT, private services access
├── gke.tf                     GKE cluster + system pool + NAP + Gateway API
├── cloudsql.tf                Cloud SQL Postgres + 2 databases
├── redis.tf                   Memorystore Redis (basic, private)
├── artifact_registry.tf       AR repo + cleanup policy
├── gateway_ip.tf              Reserved global LB IP
├── cert_map.tf                Cert Manager certificate + CertificateMap binding
├── iam.tf                     GKE node SA + workload SA + WI binding
├── argocd.tf                  Helm release of argo-cd chart (LB exposed, source-range locked)
├── argocd_application.tf      The "ecom" Application CR pointing at k8s/
├── github_oidc.tf             WIF pool + provider + repo-scoped service account
├── secrets.tf                 Generated DB password + K8s Secret
├── secret_manager.tf          GSM secret entries (workload-identity readable)
├── variables.tf               Declarations only (no defaults — fail fast)
├── outputs.tf                 Cluster name, gateway IP, WIF outputs, etc.
├── versions.tf                Terraform + provider version pins
├── terraform.tfvars.example   Template — copy to terraform.tfvars and fill in
└── terraform.tfvars           Your values (gitignored)
```
