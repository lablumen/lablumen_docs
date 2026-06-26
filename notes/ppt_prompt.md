# LabLumen Platform — AI PPT Maker Prompt

> Use this prompt verbatim in your AI PPT tool. Every fact here is verified from source code.
> Do NOT add CloudFront, S3 static hosting, or SPA CDN — the frontend runs as an nginx container in EKS.

---

## PROMPT START

Create a professional, dark-themed presentation titled **"LabLumen — Cloud-Native Medical Lab Platform"** for a review audience of **senior DevOps engineers and solution architects**.

**Design system:**
- Background: deep navy (`#0A1234`)
- Primary accent: teal (`#00ACA2`)
- Body text: light grey (`#CDD7E8`)
- Highlight/callouts: amber (`#FF9114`)
- Success bullets: green (`#32C85A`)
- Cards/panels: slightly lighter navy (`#101C44`)
- Slide dimensions: 16:9 widescreen

**Tone:** Concise. Technical. No fluff. Every bullet is a real, verifiable implementation detail.

---

## SLIDE STRUCTURE (29 slides)

---

### SLIDE 1 — Title
- Title: **LabLumen**
- Subtitle: Cloud-Native Medical Laboratory Platform on AWS EKS
- Tagline: Python · FastAPI · React · Terraform · Kubernetes · GitOps · CI/CD
- Bottom footer: `github.com/lablumen` | `rnld101.xyz` | AWS · us-east-1

---

### SLIDE 2 — Agenda
Six numbered sections as cards:
1. The Application
2. Cloud Infrastructure & AWS Services
3. Terraform — Infrastructure as Code
4. Kubernetes on EKS & GitOps
5. GitHub Actions — CI/CD Pipelines
6. Security Summary & Results

---

### SLIDE 3 — SECTION DIVIDER: "01 · The Application"

---

### SLIDE 4 — Project Overview

**Left column — What is LabLumen?**
- Cloud-native medical laboratory appointment and report management platform
- Patients book lab tests, staff upload PDF reports, AI extracts and indexes biomarkers
- Role-based access via AWS Cognito (patient / staff groups)
- Live at `app.rnld101.xyz` · `api.rnld101.xyz` · `grafana.rnld101.xyz`

**Right column — Evaluation Pillars:**
| Pillar | Weight |
|---|---|
| Infrastructure as Code (Terraform) | 25% |
| Kubernetes (EKS) | 25% |
| CI/CD (GitHub Actions) | 25% |
| Cloud Integration (AWS) | 25% |

Bonus: ArgoCD GitOps · AI Pipeline · Grafana · Infracost · Trunk-based Dev

---

### SLIDE 5 — Tech Stack (4 cards)

**Card 1 — Backend Services**
- Python 3.12 + FastAPI
- Alembic migrations (run on startup via lifespan)
- PostgreSQL 16.4 on RDS (db.t4g.micro, Graviton)
- pgvector extension for AI vector search
- Redis (in-cluster) for appointment slot-locking
- SQS for async event-driven messaging

**Card 2 — Frontend**
- React 18 + TypeScript + Vite
- nginx:1.27-alpine container (NOT CloudFront / S3)
- Built with node:22-alpine, served from nginx
- Cognito env vars injected at container start via `inject-env.sh`
- Deployed to EKS via ArgoCD, same as backend services

**Card 3 — Platform / Infrastructure**
- AWS EKS v1.31 (Kubernetes)
- Karpenter node auto-provisioner
- ArgoCD (GitOps, App-of-Apps)
- Helm charts (custom `microservice` + `redis` charts)
- External Secrets Operator (ESO)
- AWS ALB (one shared IngressGroup for all services)
- Terraform 1.15.5 (IaC)

**Card 4 — AI / Serverless**
- AWS Lambda (Python 3.12, SAM-deployed)
- Amazon Textract (PDF text extraction)
- Amazon Bedrock Nova Lite v1 (summarisation + RAG chat)
- Amazon Titan Embed Text v1 (vector embeddings)
- pgvector (vector storage in RDS Postgres)
- EventBridge rule (S3 Object Created → Lambda trigger)

---

### SLIDE 6 — Microservices Overview (table)

| Service | Runtime | Deploy | Purpose |
|---|---|---|---|
| appointment-service | Python/FastAPI | EKS pod | Book tests, Redis slot-lock, SQS publish |
| report-service | Python/FastAPI | EKS pod | Upload PDFs, S3 presigned URLs, Bedrock RAG |
| notification-service | Python/FastAPI | EKS pod | SQS long-poll consumer, SES email send |
| frontend | React + nginx | EKS pod | UI served by nginx, proxies /api/v1 internally |
| ai-service | Python Lambda | AWS SAM | Textract → Bedrock → pgvector pipeline |
| redis | Redis | EKS pod | Appointment slot-lock cache |

All three backend services + frontend share the same reusable Helm chart (`charts/microservice`).

---

### SLIDE 7 — PLACEHOLDER (black slide, teal border)
Label: **Application Architecture Diagram**
Sub-label: *(Add system architecture diagram here)*

---

### SLIDE 8 — Event-Driven Architecture

**Synchronous Path (HTTP):**
Browser → ALB (HTTPS 443) → nginx frontend pod → `/api/v1` proxy → backend pods → RDS

**Async Path (SQS):**
appointment-service publishes booking event → `lablumen-notifications` SQS queue → notification-service long-polls → SES sends email

**AI Pipeline (EventBridge):**
Staff uploads PDF → S3 reports bucket → EventBridge (Object Created) → Lambda → Textract (text extract) → Bedrock Nova Lite (summarise) → Titan Embed (vector) → pgvector in RDS → patient can RAG-chat reports in UI

**Frontend proxy:**
nginx serves React SPA and proxies all `/api/v1/...` requests to backend services within the cluster. No CloudFront. No external CDN.

---

### SLIDE 9 — SECTION DIVIDER: "02 · Cloud Infrastructure & AWS Services"

---

### SLIDE 10 — AWS Services Used (4 cards)

**Card 1 — Compute & Networking**
- EKS v1.31 (managed control plane)
- EC2 managed node group (c7i-flex.large, min 1 / max 4 / desired 2)
- Karpenter dynamic nodes (t3.medium / t3.large, on-demand)
- VPC: 10.0.0.0/16, 2 AZs (us-east-1a/b), public + private + DB subnets
- AWS ALB (one shared ALB via IngressGroup `lablumen`)
- Route53 (hosted zone `rnld101.xyz`, ExternalDNS manages records)

**Card 2 — Storage & Messaging**
- RDS PostgreSQL 16.4 (db.t4g.micro, isolated DB subnets, Secrets Manager creds)
- S3 reports bucket (KMS-encrypted, versioned, PHI store)
- S3 SAM artifacts bucket (Lambda deployment packages)
- SQS `lablumen-notifications` (appointment → notification queue)
- Redis in-cluster (slot-lock for concurrent bookings)

**Card 3 — Identity & Security**
- Cognito (user pool `lablumen-users`, patient + staff groups, Hosted UI)
- KMS CMK `alias/lablumen-platform` (encrypts ECR images + Secrets Manager values, annual key rotation)
- Secrets Manager (`lablumen/app/database-url`, `lablumen/app/grafana-admin`)
- SSM Parameter Store (non-sensitive config: bucket names, SQS URL, Cognito IDs, CORS, Bedrock model IDs)
- GitHub OIDC federation (zero static AWS credentials in CI)
- IRSA (zero static AWS credentials in pods)

**Card 4 — AI & Email**
- AWS Lambda (ai-processing, Python 3.12, 512 MB, 60s timeout, runs in VPC)
- Amazon Textract (PDF OCR, called from Lambda)
- Amazon Bedrock Nova Lite v1:0 (only on-demand text model allowed by org SCP)
- Amazon Titan Embed Text v1 (1536-dim embeddings)
- SES (domain identity `rnld101.xyz`, DKIM CNAMEs in Route53, sends from `no-reply@rnld101.xyz`)
- ACM wildcard cert `*.rnld101.xyz` (ALB TLS termination)

---

### SLIDE 11 — PLACEHOLDER (black slide, teal border)
Label: **AWS Infrastructure Architecture Diagram**
Sub-label: *(Add AWS architecture diagram here)*

---

### SLIDE 12 — SECTION DIVIDER: "03 · Terraform — Infrastructure as Code"

---

### SLIDE 13 — Terraform Overview

**Left column — Key Design Decisions:**
- Modular structure: 11 purpose-built modules (no monolithic tf)
- S3 remote state with **native locking** (`use_lockfile = true`, Terraform ≥ 1.10) — no DynamoDB table needed
- `terraform.tfvars` committed (public config only) · `secrets.auto.tfvars` gitignored
- One shared KMS CMK encrypts ECR repos + Secrets Manager secrets
- Lambda SG defined in root (references VPC outputs without module cycle)

**Right column — Backend config snippet:**
```hcl
# backend.tf
terraform {
  backend "s3" {
    bucket       = "lablumen-tfstate-<account_id>"
    key          = "lablumen/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true   # native S3 locking, no DynamoDB
  }
}
```

**OIDC trust (no static creds):**
- `lablumen-tf-plan` role: read-only, assumed on every PR
- `lablumen-tf-apply` role: admin, assumed only after manual approval

---

### SLIDE 14 — Terraform Modules

**11 modules:**
```
modules/
├── vpc/           # VPC, subnets, NAT GW, S3/interface VPC endpoints
├── eks/           # EKS v1.31, managed node group, Karpenter IRSA, OIDC provider
├── rds/           # PostgreSQL 16.4, DB subnet group, SG, SM-managed creds
├── s3/            # Reports bucket + SAM artifacts bucket (KMS encrypted, versioned)
├── ecr/           # 4 container repos (KMS encrypted, immutable tags)
├── sqs/           # lablumen-notifications queue
├── ses/           # Domain identity, DKIM CNAMEs in Route53
├── cognito/       # User pool, SPA client, patient/staff groups
├── secretsmanager/# Empty secret shells (DATABASE_URL, grafana-admin)
├── ssm/           # Non-sensitive config params (14 params)
└── iam/           # GitHub OIDC roles + 6 IRSA roles (appointment, report,
                   #   notification, frontend, ESO, external-dns, ai-lambda)
```

**Standalone root resources:**
- `aws_kms_key.platform` (CMK, annual rotation, 7-day deletion)
- `aws_security_group.ai_lambda` (egress: 5432 RDS + 443 AWS APIs)
- EKS Access Entries (tf-plan, tf-apply, admin user — required post-EKS v1.28)

---

### SLIDE 15 — SECTION DIVIDER: "04 · Kubernetes on EKS & GitOps"

---

### SLIDE 16 — Cluster Layout

**Namespaces:**
| Namespace | Contents |
|---|---|
| `argocd` | ArgoCD control plane (self-managed) |
| `lablumen-dev` | Dev: appointment, report, notification, frontend, redis |
| `lablumen` | Prod: same 5 services |
| `monitoring` | kube-prometheus-stack (Prometheus + Grafana + Alertmanager) |
| `external-secrets` | External Secrets Operator |
| `kube-system` | AWS LBC, Karpenter, metrics-server |

**Platform Add-ons (ArgoCD-managed Helm releases):**
- ArgoCD 7.6.0 (self-manages own upgrades)
- AWS Load Balancer Controller 1.8.2 (IRSA, manages shared ALB)
- ExternalDNS (IRSA, writes Route53 A records from Ingress)
- External Secrets Operator 0.10.5 (IRSA `lablumen-eso`, ClusterSecretStore)
- kube-prometheus-stack 87.0.1 (Grafana at `grafana.rnld101.xyz`)
- Karpenter + CRDs
- metrics-server

**Reusable Helm Charts:**
- `charts/microservice` — shared chart used by all 5 services including nginx frontend
- `charts/redis` — in-cluster Redis for slot-locking

---

### SLIDE 17 — K8s Workload Features

**Left column — Security Hardening (every pod):**
```yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 10001
  fsGroup: 10001
  seccompProfile:
    type: RuntimeDefault
containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
```

**Right column — Resilience:**
- HPA: min 2 / max 6 replicas, CPU target 70% (backend services)
- PodDisruptionBudget: maxUnavailable 1
- Topology spread: spread across AZs AND nodes (maxSkew 1)
- Rolling update: maxUnavailable 0, maxSurge 1 (zero-downtime deploys)
- Startup / readiness / liveness probes on every deployment

**Secrets (External Secrets Operator):**
- ClusterSecretStore for Secrets Manager → `DATABASE_URL` per service
- ClusterSecretStore for SSM → non-sensitive config (SQS URL, bucket name, Cognito IDs, etc.)
- Frontend: SSM-sourced `VITE_COGNITO_USER_POOL_ID` and `VITE_COGNITO_APP_CLIENT_ID`
- Refresh interval: 1h · No secrets ever committed to Git

---

### SLIDE 18 — ArgoCD GitOps

**App-of-Apps pattern:**
```
bootstrap/root-app.yaml  ← manually applied ONCE
└── argocd/projects/lablumen.yaml       (wave -1)
└── platform/addons/*.yaml              (wave  0)
└── argocd/apps/platform-config.yaml    (wave  1)
└── argocd/applicationsets/services-dev.yaml  (wave  2)
└── argocd/applicationsets/services-prod.yaml (wave  2)
```

**ApplicationSet (list generator, multi-source):**
- 5 services × 2 envs = 10 app instances from 2 YAML files
- Multi-source: `global-values.yaml` + `services/<svc>/values.yaml` + `values-{dev,prod}.yaml`
- Auto-sync: prune + selfHeal enabled

**GitOps Promotion Flow:**
```
PR merged to main
  → CI builds image, tags :sha, pushes to ECR
  → CI commits sha into values-dev.yaml in lablumen-k8s
  → ArgoCD detects drift → syncs dev namespace (lablumen-dev)

GitHub Release published
  → CI retags ECR image :sha → :semver (manifest copy, no rebuild)
  → CI commits semver into values-prod.yaml in lablumen-k8s
  → ArgoCD detects drift → syncs prod namespace (lablumen)
```

---

### SLIDE 19 — PLACEHOLDER (black slide, teal border)
Label: **ArgoCD Dashboard Screenshot**
Sub-label: *(All 16 apps Healthy — 5 dev + 5 prod services + 6 platform addons)*

---

### SLIDE 20 — Karpenter + Monitoring

**Left — Karpenter Node Auto-Provisioner:**
```yaml
# nodepool.yaml
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          values: ["on-demand"]
        - key: node.kubernetes.io/instance-type
          values: ["t3.medium", "t3.large"]
  limits:
    cpu: "20"   # safety cap: max 20 vCPUs
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
```
- EC2NodeClass: AL2023 AMI, subnets + SGs via `karpenter.sh/discovery` tags
- Initial managed node group: c7i-flex.large (2 vCPU / 4 GB)

**Right — Monitoring Stack:**
- kube-prometheus-stack 87.0.1
- Prometheus: 2-day retention, ephemeral storage (emptyDir)
- Grafana: exposed at `grafana.rnld101.xyz` via shared ALB
- Admin secret synced via ESO from Secrets Manager
- Alertmanager: ephemeral, internal only
- kube-state-metrics + node-exporter (cluster + node metrics)

---

### SLIDE 21 — PLACEHOLDER (black slide, teal border)
Label: **Grafana Dashboard Screenshot**
Sub-label: *(Cluster metrics: CPU, memory, pod health, node utilisation)*

---

### SLIDE 22 — SECTION DIVIDER: "05 · GitHub Actions — CI/CD"

---

### SLIDE 23 — Polyrepo CI/CD Architecture

**Repos:**
- `lablumen-shared` — 3 reusable workflows (the source of truth for CI logic)
- `lablumen-appointment-service` — calls shared workflows
- `lablumen-report-service` — calls shared workflows
- `lablumen-notification-service` — calls shared workflows
- `lablumen-frontend` — calls shared workflows (Node runtime)
- `lablumen-ai-service` — own pipeline (SAM deploy)
- `lablumen-terraform` — own pipeline (scan → plan → apply)
- `lablumen-k8s` — GitOps target (no CI pipeline; only updated by other repos)

**3 Reusable Workflows (lablumen-shared):**
| Workflow | Trigger | Does |
|---|---|---|
| `service-pr.yml` | Pull Request | Lint + Test + SAST + SCA + container scan |
| `service-build-push.yml` | Push to main | Build → Trivy gate → ECR push → GitOps write-back (values-dev) |
| `service-release.yml` | GitHub Release | ECR manifest copy (SHA→semver) → GitOps write-back (values-prod) |

**Branching Strategy (Trunk-based):**
- `main` is protected: PRs only, no direct push
- Branch protection: required status checks (all PR jobs must pass)
- Merge to main = automatic dev deploy
- GitHub Release = production promotion

---

### SLIDE 24 — PR Security Gate

**Flow (4 parallel jobs after checkout):**

```
lint-and-test (Python: Ruff + Pytest | Node: npm build)
     ↓
┌─────────────────────────────────────────────┐
│  sast          │  sca           │ container  │
│  SonarCloud    │  Snyk          │ scan       │
│  quality gate  │  severity:high │ Trivy      │
│  wait=true     │  (hard fail)   │ CRIT/HIGH  │
│  (hard fail)   │                │ (hard fail)│
└─────────────────────────────────────────────┘
```

- SonarCloud: full history checkout (fetch-depth: 0), qualitygate.wait=true — PR blocks if gate fails
- Snyk SCA: checks dependencies for known CVEs, severity-threshold=high
- Trivy container scan: builds image temporarily (NEVER pushed), fails on CRITICAL/HIGH unfixed vulns
- ALL jobs hard-fail: PR cannot merge if any check fails

---

### SLIDE 25 — PLACEHOLDER (black slide, teal border)
Label: **CI Pipeline Run Screenshot**
Sub-label: *(GitHub Actions: PR gate showing lint, SAST, SCA, container scan jobs)*

---

### SLIDE 26 — PLACEHOLDER (black slide, teal border)
Label: **SonarCloud SAST Screenshot**
Sub-label: *(SonarCloud project dashboard — quality gate passed)*

---

### SLIDE 27 — Dev Deploy + Production Release

**Dev Deploy (push to main → `service-build-push.yml`):**
1. GitHub OIDC → assume `lablumen-<svc>-build` role (no static AWS keys)
2. ECR login (registry from `ecr-login` action)
3. `docker build -t <registry>/<repo>:<sha7>`
4. Trivy gate (CRITICAL/HIGH fail → abort before push)
5. `docker push` to ECR
6. Checkout `lablumen-k8s`, `yq -i ".image.tag = \"<sha7>\""` in `values-dev.yaml`
7. `git commit + git pull --rebase + git push` (up to 5 retries for concurrent pushes)
8. ArgoCD auto-syncs → rolling deploy in `lablumen-dev`

**Production Release (`service-release.yml`):**
1. Triggered by GitHub Release published on the same commit already in DEV
2. GitHub OIDC → assume build role
3. `aws ecr batch-get-image` → get manifest of `:sha7`
4. `aws ecr put-image` → copy manifest as `:<semver>` (no Docker rebuild, no layer copy)
5. Bump `values-prod.yaml` with semver tag → rebase-retry push to lablumen-k8s
6. ArgoCD auto-syncs → rolling deploy in `lablumen` (prod)

**Build-once / promote-by-retag:** The exact same image bytes go to prod that passed all dev validation. Immutable ECR tags prevent accidental overwrites.

---

### SLIDE 28 — Terraform Pipeline

**4-stage pipeline (`lablumen-terraform/.github/workflows/terraform.yml`):**

```
┌──────────┐   ┌──────────────────────┐   ┌───────────────────┐
│  scan    │ → │  plan                │ → │  apply            │
│ Checkov  │   │  OIDC: tf-plan role  │   │  OIDC: tf-apply   │
│ soft_fail│   │  fmt-check + validate│   │  production Env   │
│ → SARIF  │   │  terraform plan      │   │  (manual approval │
│ → GitHub │   │  Infracost breakdown │   │   gate)           │
│ Security │   │  PR comment + logs   │   │  downloads tfplan │
│ tab      │   │  upload tfplan       │   │  artifact, applies│
└──────────┘   └──────────────────────┘   └───────────────────┘
```

- Checkov: scans all `.tf` files, `soft_fail: true`, SARIF uploaded to GitHub Security tab
- Infracost: runs against the saved plan JSON, prints to logs, posts PR comment on PRs
- Apply only runs on push to main (not PRs), behind `production` GitHub Environment (required reviewer = manual gate)
- Separate least-privilege roles: tf-plan (read) vs tf-apply (admin) — both OIDC, zero static credentials

---

### SLIDE 29 — PLACEHOLDER (black slide, teal border)
Label: **Infracost Cost Estimate Screenshot**
Sub-label: *(Monthly cost breakdown from terraform plan — posted as PR comment)*

---

### SLIDE 30 — SECTION DIVIDER: "06 · Security & Results"

---

### SLIDE 31 — Security End-to-End (4 cards)

**Card 1 — Zero Static Credentials**
- GitHub OIDC: all CI jobs assume short-lived IAM roles (no AWS_ACCESS_KEY_ID stored)
- IRSA: every pod has its own least-privilege IRSA role (no shared keys in pods)
- Separate CI roles: tf-plan (read-only) vs tf-apply (admin) vs per-service ECR push roles
- Frontend pod: no IRSA annotation (no AWS calls from the nginx container)

**Card 2 — Code Security Gates**
- Ruff (Python lint) / npm build (TS type-check) — every PR
- SonarCloud SAST — every PR, quality gate hard-blocks merge
- Snyk SCA — every PR, severity high hard-fail
- Trivy container scan — every PR (image never pushed) + every merge (before ECR push)
- Checkov IaC scan — every tf change, SARIF to GitHub Security tab

**Card 3 — Runtime Security**
- All pods: `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: [ALL]`, `seccompProfile: RuntimeDefault`
- No secret in Git — ESO pulls from Secrets Manager + SSM at 1h refresh
- KMS CMK encrypts ECR image layers and Secrets Manager values (annual key rotation)
- RDS in isolated DB subnets — only Lambda SG and EKS pod SGs can reach port 5432
- Alembic advisory lock: safe concurrent pod startup migrations

**Card 4 — Gate Summary**
| Stage | Tool | Fail condition |
|---|---|---|
| PR | Ruff / npm build | lint error |
| PR | SonarCloud | quality gate failed |
| PR | Snyk | CVE severity ≥ HIGH |
| PR + merge | Trivy | CRIT/HIGH unfixed vuln |
| TF PR + push | Checkov | soft fail (SARIF logged) |
| TF push | manual gate | required reviewer approval |

---

### SLIDE 32 — Platform Achievements (4 cards)

**Card 1 — Infrastructure (IaC)**
- 11 Terraform modules, fully modular
- S3 native state locking (no DynamoDB, TF 1.15.5)
- All AWS resources tagged (project, environment, owner)
- Infracost on every plan — cost visibility before apply

**Card 2 — Application (Kubernetes)**
- 5 services in K8s (3 backend + nginx frontend + redis) + 1 Lambda
- HPA + PDB + topology spread on all production workloads
- Zero-downtime rolling deploys (maxUnavailable: 0)
- External Secrets Operator — no secrets in Git, ever

**Card 3 — DevOps (CI/CD)**
- 3 reusable workflows shared across 5 service repos
- Build-once / promote-by-retag (manifest copy, no rebuild for prod)
- GitOps write-back with rebase-retry (handles concurrent polyrepo pushes)
- Trunk-based development with branch protection

**Card 4 — Bonus Pillars Achieved**
- ArgoCD App-of-Apps (16 apps, all Healthy when live)
- AI pipeline (Textract + Bedrock + pgvector RAG)
- Grafana + Prometheus observability
- Infracost cost estimation on every PR
- GitHub OIDC + IRSA (zero static credentials everywhere)

---

### SLIDE 33 — Thank You / Q&A

**Live URLs (when deployed):**
- Frontend: `https://app.rnld101.xyz`
- API: `https://api.rnld101.xyz`
- ArgoCD: `https://argocd.rnld101.xyz`
- Grafana: `https://grafana.rnld101.xyz`

**Repos (github.com/lablumen):**
`lablumen-appointment-service` · `lablumen-report-service` · `lablumen-notification-service` · `lablumen-frontend` · `lablumen-ai-service` · `lablumen-shared` · `lablumen-k8s` · `lablumen-terraform`

**Infrastructure (when live):**
AWS · us-east-1 · EKS v1.31 · Terraform 1.15.5 · ArgoCD 7.6.0

Questions?

---

## PLACEHOLDER SLIDES SUMMARY

Insert the following screenshots in the marked placeholder slides:

| Slide | Placeholder | What to insert |
|---|---|---|
| 7 | Application Architecture Diagram | Draw.io / Lucidchart system overview: browser → ALB → nginx → backend pods → RDS / SQS / S3 |
| 11 | AWS Infrastructure Architecture | AWS architecture: VPC, subnets, EKS, RDS, S3, Lambda, Cognito, SQS, SES, Route53, ALB |
| 19 | ArgoCD Dashboard | Screenshot of ArgoCD UI showing 16 Healthy apps |
| 21 | Grafana Dashboard | Screenshot of Grafana with cluster CPU/memory panels |
| 25 | CI Pipeline Run | GitHub Actions run showing 4 PR gate jobs all passing |
| 26 | SonarCloud SAST | SonarCloud project page showing quality gate Passed |
| 29 | Infracost Cost Estimate | Infracost PR comment or breakdown showing monthly cost |

---

## KEY FACTS TO GET RIGHT (verified from source code)

**DO include:**
- Frontend is a **nginx:1.27-alpine container** deployed in EKS via ArgoCD (same `microservice` Helm chart as backend)
- Frontend calls **relative `/api/v1/...` URLs** — nginx proxies internally within the cluster
- Cognito config injected at container start via **`inject-env.sh`** (replaces `__VITE_COGNITO_*__` placeholders)
- **One shared ALB** (IngressGroup `lablumen`) serves: frontend, backend API, ArgoCD UI, Grafana — NOT separate load balancers
- Karpenter NodePool: **t3.medium / t3.large** (managed node group initial nodes: c7i-flex.large)
- AI service is **AWS Lambda** (SAM-deployed, NOT in K8s/EKS)
- Lambda trigger: **EventBridge rule** (S3 Object Created event) — not S3 direct trigger
- Dev namespace: **`lablumen-dev`** · Prod namespace: **`lablumen`**
- **4 ECR repositories** (appointment, report, notification, frontend) — no ECR for AI service (SAM deploys from S3)
- S3 state locking uses `use_lockfile = true` — **no DynamoDB** table
- Checkov is **soft_fail** (doesn't block pipeline, SARIF to GitHub Security tab)
- ArgoCD **self-manages its own upgrades** via an Application pointing to the argo-helm chart

**DO NOT include:**
- CloudFront (no CloudFront anywhere)
- S3 static website hosting (frontend is EKS nginx, not S3)
- SPA CDN origin (not applicable)
- c7i-flex.large for Karpenter (that's the managed node group, not Karpenter)
- DynamoDB for state locking (native S3 locking used)
- Separate ALBs per service (one shared IngressGroup)

## PROMPT END
