# Kubernetes manifests

ArgoCD's source of truth for what runs in the `ecom` namespace. This directory is what the [`ecom` Application](../infrastructure/terraform/argocd_application.tf) watches — every commit that touches a file here triggers an auto-sync to GKE.

```
k8s/
├── 00-namespace.yaml         ecom namespace
├── 05-compute-class.yaml     Spot-first ComputeClass (NAP scheduling target)
├── 10-catalog.yaml           Deployment + Service for catalog-service
├── 20-cart.yaml              Deployment + Service for cart-service
├── 30-checkout.yaml          Deployment + Service for checkout-service
├── 40-order.yaml             Deployment + Service for order-service
├── 50-ui.yaml                Deployment + Service for ui-service
├── 60-gateway.yaml           Gateway + 2 HTTPRoutes + HealthCheckPolicy + cache headers
├── 70-hpa.yaml               HorizontalPodAutoscaler per service (minReplicas=2)
├── 80-pdb.yaml               PodDisruptionBudget per service (maxUnavailable=1)
└── generated-config.yaml     ConfigMap with DB/Redis endpoints (terraform-managed, gitignored)
```

The cross-cutting concerns (autoscaling, disruption budgets) live in their own files alongside the per-service Deployment + Service so each "axis" is browsable from one place — same pattern Kustomize/Helm setups end up at.

The `00`/`05`/`10`/… numeric prefixes are for human readability; ArgoCD applies in dependency order automatically via Server-Side Apply.

---

## Image references

Every `image:` line is pinned to an **immutable short SHA**, not `vN` or `latest`:

```yaml
image: us-central1-docker.pkg.dev/<project>/ecom-microservices/ui-service:46b483c
```

The `bump-manifests` CI job ([`.github/workflows/ci.yml`](../.github/workflows/ci.yml)) rewrites these on every `v*` tag push and commits back to `main`. **Don't edit `image:` lines by hand** — the next release will overwrite the change.

To roll back, `git revert <bump-commit>` and ArgoCD re-applies the previous immutable SHA.

---

## ArgoCD sync semantics

The Application is configured for **full GitOps**:

| Setting | Value | Why |
|---|---|---|
| `automated.prune` | `true` | Resources removed from git get deleted from cluster |
| `automated.selfHeal` | `true` | Manual `kubectl edit` is reverted to git state |
| `automated.allowEmpty` | `false` | Prevents an accidentally-empty repo from wiping the namespace |
| `syncOptions.CreateNamespace` | `true` | ArgoCD creates `ecom` if missing |
| `syncOptions.PruneLast` | `true` | Leaf resources deleted before owners |
| `syncOptions.ServerSideApply` | `true` | Avoids drift against `last-applied-configuration` annotations |

### Why `ApplyOutOfSyncOnly` is intentionally **off**

It was on briefly and caused a v2 deploy to silently report `Synced` without actually applying the bumped image refs. The cached diff went stale; the controller decided the Deployments were InSync without re-checking. Removed in [`argocd_application.tf`](../infrastructure/terraform/argocd_application.tf) — the few extra seconds per sync are worth the correctness guarantee.

---

## `ignoreDifferences` — what the controller pretends not to see

```hcl
# infrastructure/terraform/argocd_application.tf
ignoreDifferences = [
  { kind = "Service",    jqPathExpressions = [
      ".metadata.annotations.\"cloud.google.com/neg-status\"",  # controller-written
      ".metadata.annotations.\"cloud.google.com/neg\"",         # GKE re-serializes JSON
  ]},
  { kind = "Deployment", jsonPointers = ["/spec/replicas"] },   # HPA-owned
]
```

Two failure modes these guard against:

1. **GKE re-serializes `cloud.google.com/neg` to compact JSON** (no spaces), but git had spaces. ArgoCD diffs strings → permanent OutOfSync flap. Ignoring the field lets GKE own the serialized form.

2. **HPA writes `spec.replicas`** every time it scales. Without the ignore, every autoscale event marks the Deployment OutOfSync.

If you add a new resource that has controller-managed annotations or status-mirrored spec fields, extend this list rather than fighting drift.

---

## Cache-Control at the Gateway

[`60-gateway.yaml`](60-gateway.yaml) `ui-route` uses `ResponseHeaderModifier` filters to set `Cache-Control` at the global load balancer:

| Path prefix | Header |
|---|---|
| `/css/`, `/js/` | `max-age=31536000, public, immutable` |
| `/` (catchall) | `no-cache, no-store, must-revalidate` + `Pragma: no-cache` + `Expires: 0` |

This is a **backstop** to the same headers emitted by `ui-service` (see [`WebMvcConfig.java`](../services/ui-service/src/main/java/com/ecom/ui/config/WebMvcConfig.java)) — if the app code ever stops setting them, the GLB still does. A CI smoke step asserts both layers on every release.

---

## Pods land on Spot via ComputeClass

App workloads opt into the Spot-first node pool with:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        cloud.google.com/compute-class: ecom-spot
      tolerations:
        - key: cloud.google.com/gke-spot
          operator: Equal
          value: "true"
          effect: NoSchedule
```

`05-compute-class.yaml` defines the priority list: Spot first, on-demand fallback. Node Auto-Provisioning creates and tears down nodes as pods come and go.

---

## Availability under Spot preemption

Spot VMs can be reclaimed by GCP at any time with ~30s notice. To avoid a "no healthy upstream" outage when that happens, every service uses three layers of redundancy:

| Layer | Where | Effect |
|---|---|---|
| **`minReplicas: 2`** | [`70-hpa.yaml`](70-hpa.yaml) | A single pod loss never takes the service to zero |
| **`topologySpreadConstraints` (hostname + zone)** | each `10..50-*.yaml` | The 2 replicas can't both land on the same Spot node — `whenUnsatisfiable: ScheduleAnyway` keeps it a soft constraint so pods still schedule if only one node exists |
| **`PodDisruptionBudget` `maxUnavailable: 1`** | [`80-pdb.yaml`](80-pdb.yaml) | Caps voluntary disruption (drains, cluster upgrades) to 1 pod at a time |

**Split of duties between PDB and topology spread:**

| Type of disruption | Mitigated by |
|---|---|
| Voluntary (node drain, cluster upgrade, `kubectl evict`) | PDB |
| Involuntary (Spot preemption, kernel panic, OOM kill) | topology spread + `minReplicas: 2` |

PDBs are **not consulted** during Spot preemption — they only constrain k8s-initiated evictions. Topology spread covers the involuntary case.

### Connection-pool fan-out when scaling

Bumping `minReplicas` doubles connection demand on shared backends (Cloud SQL, Redis). The `order-service` Spring Boot HikariCP pool is capped at 5 per pod via `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE` in [`40-order.yaml`](40-order.yaml), and Cloud SQL `max_connections` was raised to 75 in [`cloudsql.tf`](../infrastructure/terraform/cloudsql.tf). If you raise `minReplicas` further, recheck the math:

```
total_db_connections ≈ (replicas × HikariCP pool) + catalog_pool + probes + sidecars
```

---

## How to add a new service

1. Create `services/<svc>/Dockerfile` and source.
2. Add it to the matrix in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml#L40):
   ```yaml
   matrix:
     svc: [catalog-service, cart-service, checkout-service, order-service, ui-service, <svc>]
   ```
3. Add it to `docker-compose.yml` for local dev (compose-first workflow).
4. Create `k8s/<NN>-<svc>.yaml` with Deployment + Service, using the Spot ComputeClass selector + `topologySpreadConstraints` (hostname + zone, ScheduleAnyway) and pinning `image:` to the registry path (the bump job will rewrite the tag on next release).
5. If the service needs to be reachable externally, add a rule to `60-gateway.yaml`. Otherwise leave it cluster-internal.
6. Add an HPA entry to `70-hpa.yaml` (`minReplicas: 2` for prod resilience).
7. Add a PDB entry to `80-pdb.yaml` (`maxUnavailable: 1`).
7. Commit + push. Next `v*` tag will build/push the image and ArgoCD will deploy it.

---

## Operational notes

- **Don't edit live resources with `kubectl edit`** — ArgoCD's `selfHeal` reverts on the next reconcile (~30s). Change git instead.
- **Connection check**: `kubectl -n ecom get gateway,httproute,deployment,svc,pdb,hpa`
- **ArgoCD UI**: `kubectl -n argocd port-forward svc/argocd-server 8080:80` then visit `localhost:8080` (initial password via `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`).
- **Force sync**: usually unnecessary, but `kubectl -n argocd annotate app ecom argocd.argoproj.io/refresh=hard --overwrite` forces a re-read of the repo.
