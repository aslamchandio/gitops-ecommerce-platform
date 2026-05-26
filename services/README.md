# Services

Five microservices, three runtimes, one consistent contract. Each folder is a self-contained build unit with its own `Dockerfile` — the CI matrix builds all of them in parallel on every `v*` tag.

```
services/
├── catalog-service/    Go 1.22 · Postgres · FakeStore sync (6h cron)
├── cart-service/       Java 21 · Spring Boot · Redis
├── checkout-service/   Node.js 20 · Express · orchestrates cart → order
├── order-service/      Java 21 · Spring Boot · Postgres
└── ui-service/         Java 21 · Spring Boot · Thymeleaf · ViewModelAdvice · WebMvcConfig
```

| Service        | Port | Storage  | Build | Image base                       |
|----------------|------|----------|-------|----------------------------------|
| `ui-service`   | 8080 | —        | Maven | `eclipse-temurin:21-jre-alpine`  |
| `catalog-service` | 8081 | Postgres | `go build` | `gcr.io/distroless/static`    |
| `cart-service` | 8082 | Redis    | Maven | `eclipse-temurin:21-jre-alpine`  |
| `checkout-service` | 8083 | —    | `npm ci` | `node:20-alpine`              |
| `order-service` | 8084 | Postgres | Maven | `eclipse-temurin:21-jre-alpine` |

All Dockerfiles are **multi-stage** — heavy build images (maven, go SDK) stay out of the final image. Runtime images are minimal (Alpine JRE, distroless static, Node Alpine).

---

## Common conventions

### Environment contract

Every service reads its dependencies from environment variables (no hardcoded hostnames). The same image runs locally (compose) and in production (GKE) by varying the env:

| Variable               | Local (compose)         | Production (k8s env)        |
|------------------------|-------------------------|-----------------------------|
| `CATALOG_SERVICE_URL`  | `http://catalog-service:8081` | `http://catalog-service:8081` (in-cluster DNS) |
| `CART_SERVICE_URL`     | `http://cart-service:8082`    | `http://cart-service:8082` |
| `CHECKOUT_SERVICE_URL` | `http://checkout-service:8083`| `http://checkout-service:8083` |
| `ORDER_SERVICE_URL`    | `http://order-service:8084`   | `http://order-service:8084` |
| `DB_HOST` / `SPRING_DATASOURCE_URL` | postgres container | Cloud SQL private IP |
| `SPRING_REDIS_HOST`    | redis container         | Memorystore private IP      |
| `APP_VERSION`          | `dev` (Dockerfile default) | short git SHA (CI build-arg) |
| `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE` | unset (HikariCP default = 10) | `5` (capped — see Capacity below) |

K8s injects these via the `Deployment.spec.template.spec.containers[].env` list. See `k8s/10..50-*.yaml` for the production wiring.

### Health + metrics endpoints

| Service | Endpoint | Used by |
|---|---|---|
| Spring Boot services | `/actuator/health/readiness` | GKE `HealthCheckPolicy` (load balancer); k8s readiness probe |
| Spring Boot services | `/actuator/prometheus` | GMP scrape (via [`k8s/90-podmonitoring.yaml`](../k8s/90-podmonitoring.yaml)) |
| `catalog-service` (Go) | `/health` | k8s readiness probe |
| `checkout-service` (Node) | `/health` | k8s readiness probe |

`/actuator/prometheus` is currently only on the **3 Java services** (`ui`, `cart`, `order`) — Micrometer dependency (`micrometer-registry-prometheus` in `pom.xml`) + the endpoint added to `management.endpoints.web.exposure.include` in `application.yml`. Go and Node services don't yet expose a `/metrics` endpoint — adding one is the next step before they show up in Grafana.

### Cache-Control (ui-service only)

`ui-service` ships [`WebMvcConfig.java`](ui-service/src/main/java/com/ecom/ui/config/WebMvcConfig.java) which:

- Sets `Cache-Control: no-cache, no-store, must-revalidate` on HTML responses
- Serves `/css/**` and `/js/**` with `Cache-Control: max-age=1yr, immutable`

The build-time `APP_VERSION` (the short SHA) is rendered into `<link href="/css/styles.css?v=<sha>">`, so every release produces a new asset URL — browsers refetch automatically without manual cache invalidation.

---

## Local development

The repo-root [`docker-compose.yml`](../docker-compose.yml) wires the full mesh: Postgres (multi-DB), Redis, all 5 services, healthchecks, `depends_on`.

```bash
# From repo root
docker compose up --build -d
open http://localhost:8080
```

**Workflow rule (compose-first):** every code change is validated through compose with a full purchase-flow smoke test **before** tagging for production. Catches inter-service regressions that single-service unit tests can't.

Rebuild a single service after edits:

```bash
docker compose build ui-service && docker compose up -d ui-service
```

---

## CI / release

Triggered by a `v*` tag push. For each service in parallel:

1. **WIF auth** to GCP — no JSON keys.
2. `docker buildx build --push` with `--build-arg GIT_SHA=<sha>`. Image gets three tags: `vN`, `<short-sha>`, `latest`.
3. **ui-service only**: a smoke step pulls the freshly-pushed image, runs it, asserts the `Cache-Control` headers + `?v=<sha>` query are present. Fails the build if missing.
4. `bump-manifests` job rewrites `k8s/*.yaml` to the new SHA and commits to `main`.
5. ArgoCD detects the new revision and rolls out.

Total time `git push` → live: **~3 minutes**.

See [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) for the full pipeline.

---

## Per-service notes

### `catalog-service`

- **Why Go**: this service has the chatty FakeStore sync cron loop; a tiny `distroless/static` image with a small RSS footprint makes the most sense for the highest-replica service.
- **Initial seed**: on boot, syncs all 20 FakeStore products into Postgres immediately, then re-runs every `SYNC_INTERVAL_HOURS` (default 6).
- **DB schema** is created in-process — no separate migration tool. See `main.go`.

### `cart-service`

- **State in Redis**: per-session cart hashes keyed by `ecom_sid` cookie. Items survive across pod restarts; lost only if Redis is wiped.
- **WebClient → catalog** to enrich line items with title/image at fetch time (avoids stale snapshots).

### `checkout-service`

- **Stateless orchestrator**: receives `{sessionId, shipping}` from `ui-service`, fetches the cart from `cart-service`, posts the order to `order-service`, returns `{orderId, total}` or `{error}`.
- **No retries** at this layer — the upstream services handle their own. Keeps this service trivial.

### `order-service`

- **Cloud SQL Postgres** for persisted orders. Schema in `OrderRepository` JPA entities.
- **Order ID** is auto-generated (`IDENTITY`).
- **HikariCP capped** at 5 connections per pod via `SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE=5` (see [`k8s/40-order.yaml`](../k8s/40-order.yaml)). With `minReplicas=2` the default pool of 10 per pod would consume 20 connections from this service alone and exhaust Cloud SQL on a scale event. See **Capacity planning** below.

### `ui-service`

- **Spring Boot 3 + Thymeleaf** — server-rendered HTML, no SPA framework.
- **`ViewModelAdvice`** (`@ControllerAdvice`) injects `appVersion` into every model so the layout fragment can append `?v=<sha>` to asset links.
- **`WebMvcConfig`** sets the cache headers (see above).
- **Static**: `static/css/styles.css` (~30 KB), `static/js/app.js` (~2 KB) — no build step, no bundler.
- **Themes**: light + dark via CSS variables + `localStorage`; localhost defaults to dark for distinct local feel.

---

## Metrics (Micrometer)

The 3 Spring Boot services (`ui`, `cart`, `order`) emit Prometheus metrics for GMP to scrape. Wiring is two lines per service:

```xml
<!-- pom.xml -->
<dependency>
  <groupId>io.micrometer</groupId>
  <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

```yaml
# application.yml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
```

That's enough — Spring Boot auto-configures the registry, and Actuator exposes `/actuator/prometheus` on the same HTTP port as the app. Micrometer ships defaults for JVM (`jvm_memory_*`, GC, threads), HTTP (`http_server_requests_seconds_*`), process (`process_cpu_usage`), HikariCP (`hikaricp_connections_*`), Tomcat (`tomcat_threads_*`, sessions), Logback (`logback_events_total`).

PodMonitoring CRDs in [`k8s/90-podmonitoring.yaml`](../k8s/90-podmonitoring.yaml) tell GMP to scrape them every 30s. Visualized in Grafana — see the [observability section in the root README](../README.md#observability) for the full pipeline + port-forward command.

> Catalog (Go) and Checkout (Node) don't yet expose `/metrics`. Adding them is a follow-up: `prometheus/client_golang` for Go, `prom-client` for Node, plus matching PodMonitoring entries.

---

## Capacity planning

The two services that connect to Cloud SQL Postgres (`catalog-service` Go pool, `order-service` HikariCP) share a `db-f1-micro` instance with `max_connections=75` (raised from the f1-micro default of ~25 via [`cloudsql.tf`](../infrastructure/terraform/cloudsql.tf)).

**Current budget at `minReplicas=2`:**

| Source | Per pod | Pods | Total |
|---|---|---|---|
| `order-service` HikariCP (capped) | 5 | 2 | 10 |
| `catalog-service` Go `sql.DB` pool | ~5 | 2 | ~10 |
| K8s readiness/liveness probes, ArgoCD checks | — | — | ~5 |
| Cloud SQL superuser reservation | — | — | 3 |
| **Total demand** | | | **~28** |
| **Ceiling (max_connections)** | | | **75** |
| **Headroom** | | | **~47** |

**If you scale further** — bumping `minReplicas` to 3+ or adding a new Postgres-using service — recompute this. The default HikariCP pool of 10 per pod is the fan-out trap. Pattern to follow:

```yaml
# in the Deployment env block
- name: SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE
  value: "5"
- name: SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE
  value: "1"
```
