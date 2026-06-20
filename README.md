# LabLumen

A single-tenant healthcare lab platform: patients book appointments, lab staff upload result PDFs,
an AI pipeline (Amazon Textract + Bedrock) produces a plain-language summary and vector embeddings,
and patients chat with a **document-scoped RAG** assistant about their own report.

> Architecture source of truth: [`BLUEPRINT.md`](./BLUEPRINT.md). This README documents the
> **scaffold** — structure and skeletons that lint/validate/boot. Feature logic is filled in per the
> build order: Infra → GitOps → Microservices → AI pipeline.

## Stack

| Layer | Tech |
|---|---|
| Frontend | React + TypeScript + Vite + Tailwind + ShadCN + TanStack Query + React Router |
| Backend | FastAPI (3 services), SQLAlchemy (async), Alembic |
| Data | Amazon RDS PostgreSQL + `pgvector` |
| Cache/locks | Redis (self-hosted pod / local container) — JWKS cache + 5-min appointment slot-locks |
| AI | Amazon Bedrock — `amazon.titan-embed-text-v1` (1536-dim) + `amazon.nova-2-lite-v1:0`, raw `boto3` |
| Auth | Amazon Cognito (JWT verified in-process; roles via Cognito groups) |
| Infra | Terraform (`terraform-aws-modules/*`), EKS, ArgoCD GitOps, Helm |
| Async | S3-triggered AWS Lambda (synchronous Textract OCR) |

## Services

```
backend/appointment-service   scheduling, lab-test catalog, slot-locks; owns Alembic schema + seed
backend/report-service        S3 presigned URLs, document-scoped RAG chat
backend/notification-service  SQS consumer + SES email
serverless/ai-processing-pipeline   S3 object -> Textract -> Bedrock -> pgvector
```

## Local development

Requires Docker + Docker Compose (and `pnpm` for the frontend).

```bash
make up          # Postgres+pgvector, Redis, run migrations+seed, start the 3 services
make down        # tear down (removes volumes)
make migrate     # run Alembic migrations + seed only
make test        # run service smoke tests
make lint        # ruff

# frontend (separate terminal)
cd frontend && pnpm install && pnpm dev
```

Sanity check once up: `curl http://localhost:8001/api/v1/lab-tests` returns the seeded catalog.

## Layout

```
.github/workflows/   CI: Docker build & push to ECR
terraform/           IaC (registry modules), single centralized terraform.tfvars
k8s/                 ArgoCD app-of-apps, per-service Helm charts, platform addons
backend/             3 FastAPI services
serverless/          S3-triggered AI Lambda
frontend/            React SPA
```
# extras
