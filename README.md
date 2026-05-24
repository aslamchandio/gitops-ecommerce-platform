# Microservices E-Commerce Platform

A polyglot microservices web app that ingests products from the public [FakeStore API](https://fakestoreapi.com/products), displays them on an animated storefront, and deploys to **GCP GKE Standard** (Spot VMs via ComputeClass + Node Auto-Provisioning, exposed through the Kubernetes **Gateway API**) using **Artifact Registry**.

## Architecture

```
                 ┌──────────────────────────────────────┐
                 │       UI Service (Spring Boot)       │  ← Thymeleaf, animated theme
                 └──────────────────────────────────────┘
                       │            │              │
            ┌──────────┘            │              └──────────┐
            ▼                       ▼                         ▼
   ┌────────────────┐      ┌────────────────┐       ┌──────────────────┐
   │ Catalog (Go)   │      │ Cart (Spring)  │       │ Checkout (Node)  │
   │ + FakeStore    │      │ + Redis        │       │ → Order Service  │
   │   cron sync    │      │                │       │                  │
   └────────────────┘      └────────────────┘       └──────────────────┘
            │                                                 │
            ▼                                                 ▼
      ┌──────────┐                                    ┌──────────────┐
      │ Postgres │                                    │ Order (Spring)│
      └──────────┘                                    │ + Postgres    │
                                                      └──────────────┘
```

| Service     | Language          | Port | Storage   |
|-------------|-------------------|------|-----------|
| catalog     | Go 1.22           | 8081 | Postgres  |
| cart        | Java 21 / Spring  | 8082 | Redis     |
| checkout    | Node.js 20        | 8083 | —         |
| order       | Java 21 / Spring  | 8084 | Postgres  |
| ui          | Java 21 / Spring  | 8080 | —         |

## Quick start (local)

```bash
# 1. Generate AI product images (one-time, requires OPENAI_API_KEY)
python scripts/generate-images.py

# 2. Bring up the full stack
docker compose up --build

# 3. Open the storefront
open http://localhost:8080
```

The Catalog service runs a cron job every 6 hours that pulls fresh products from FakeStore API into Postgres. On first boot it seeds immediately.

## Deploy to GCP

```bash
cd infrastructure/terraform
terraform init && terraform apply

# Reserve the global LB IP referenced by the Gateway annotation
gcloud compute addresses create ecom-ip --global

# Build + push all images to Artifact Registry
../../scripts/build-and-push.sh <PROJECT_ID> <REGION>

# Apply ComputeClass, secrets, deployments, Gateway + HTTPRoute
../../scripts/deploy.sh <PROJECT_ID>

# Watch the Gateway provision the external HTTP LB (~5 min)
kubectl -n ecom get gateway ecom-gateway -w
```

The cluster is **GKE Standard** with Node Auto-Provisioning and a `ComputeClass`
([`k8s/05-compute-class.yaml`](k8s/05-compute-class.yaml)) that prefers **Spot VMs**
(~70% cheaper) with on-demand fallback. Public traffic enters through a
**Gateway + HTTPRoute** ([`k8s/60-gateway.yaml`](k8s/60-gateway.yaml)) — no Ingress.

See [`infrastructure/terraform/README.md`](infrastructure/terraform/README.md) for details.

## Project layout

```
.
├── catalog-service/      Go service + FakeStore sync
├── cart-service/         Spring Boot + Redis
├── checkout-service/     Node.js Express
├── order-service/        Spring Boot + Postgres
├── ui-service/           Spring Boot + Thymeleaf
├── infrastructure/
│   └── terraform/        GKE Standard + NAP + Artifact Registry + Cloud SQL + Redis
├── k8s/
│   ├── 00-namespace.yaml
│   ├── 05-compute-class.yaml   ComputeClass: Spot-first, on-demand fallback
│   ├── 10-50-*.yaml            One Deployment + Service + PDB per microservice
│   └── 60-gateway.yaml         Gateway + HTTPRoute + HealthCheckPolicy
├── scripts/              build/push/deploy + image generation
└── docker-compose.yml    Local dev stack
```
