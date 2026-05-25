# Scripts

Operational and dev-environment helpers. **Production deploys do NOT use these** — the release flow is `git tag v* && git push` which is handled by [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) + ArgoCD.

| Script | Status | Purpose |
|---|---|---|
| [`init-multi-db.sh`](init-multi-db.sh) | **Active** | Postgres entrypoint hook for local `docker-compose` — creates `catalog` and `orders` databases on first boot |
| [`generate-images.py`](generate-images.py) | Optional | One-time OpenAI image generation for branded product photos (replaces FakeStore placeholders) |
| [`build-and-push.sh`](build-and-push.sh) | **Legacy / escape hatch** | Manually build and push all 5 service images to Artifact Registry. Superseded by CI but kept for emergency / first-bootstrap use |
| [`deploy.sh`](deploy.sh) | **Legacy / escape hatch** | Manually substitute image tags into `k8s/*.yaml` and `kubectl apply`. Superseded by ArgoCD GitOps but kept as a fallback |

---

## Active

### `init-multi-db.sh`

Postgres's official image supports a single `POSTGRES_DB`. We need two: `catalog` and `orders`. This script is mounted at `/docker-entrypoint-initdb.d/init-multi-db.sh` and runs on first container start when the data directory is empty.

Triggered via the `POSTGRES_MULTIPLE_DATABASES=catalog,orders` env var in [`docker-compose.yml`](../docker-compose.yml). Idempotent because Postgres only runs init scripts on first boot.

> Production uses **Cloud SQL** with both databases created by Terraform ([`cloudsql.tf`](../infrastructure/terraform/cloudsql.tf)). This script is local-compose-only.

### `generate-images.py`

Optional: regenerates AI-styled product images for each FakeStore product into `services/ui-service/src/main/resources/static/images/products/<id>.png`.

```bash
export OPENAI_API_KEY=sk-...
python scripts/generate-images.py
```

Run **once** when you want to replace the upstream FakeStore image URLs with locally-served, on-brand alternatives. Requires you to flip the `catalog-service` image URL rewrite (out of scope for default setup).

---

## Legacy / escape hatches

These pre-date the ArgoCD + GitHub Actions setup. They still work for emergencies (e.g. CI is down and you must ship a hotfix from your laptop) but **don't use them as the default deploy path** — manual deploys bypass the GitOps audit trail and can race with ArgoCD's self-heal.

### `build-and-push.sh`

```bash
scripts/build-and-push.sh <PROJECT_ID> [REGION] [TAG]
```

Builds all 5 services and pushes them to `${REGION}-docker.pkg.dev/${PROJECT_ID}/ecom-microservices/<svc>:<TAG>`. Defaults `TAG` to the short git SHA.

**Use case**: bootstrapping a fresh GCP project before the first GitHub Actions run. After that, prefer `git tag vN && git push origin vN` which does the same thing but in CI with WIF auth.

### `deploy.sh`

```bash
scripts/deploy.sh <PROJECT_ID> [REGION] [TAG]
```

Substitutes `<TAG>` into the `image:` lines of `k8s/*.yaml` and `kubectl apply -f k8s/`. Skips `generated-config.yaml` (terraform-managed).

**Use case**: emergency hotfix when ArgoCD is broken. **Will conflict with ArgoCD's self-heal** within ~30 seconds unless you also pause auto-sync (`kubectl -n argocd patch app ecom --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'`).

The normal path: commit the image change to `k8s/*.yaml`, push to `main`, ArgoCD picks it up.

---

## Adding a new script

Keep them executable and self-contained:

```bash
chmod +x scripts/new-script.sh
```

If the script becomes the canonical way to do something, add it to this table and either retire the legacy alternative or note which one is preferred.
