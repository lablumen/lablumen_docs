# LabLumen — AWS Infrastructure Architecture Diagram Prompt

---

Create a **professional AWS infrastructure architecture diagram** in the official AWS style. Use the **AWS Architecture Icons** (the flat, square-cornered service icons used in official AWS diagrams). Follow AWS diagram conventions: nested boxes for Region → VPC → AZ → Subnet, traffic flows top-to-bottom, managed services live outside the VPC.

---

## STYLE

- **Background:** White `#FFFFFF`
- **AWS Region box:** Light blue border `#007EB9`, label top-left: `AWS Region — us-east-1`
- **VPC box:** Light green border `#8CC04F`, label top-left: `VPC — lablumen-vpc (10.0.0.0/16)`
- **Subnet boxes:** Rounded rectangles — Public = light blue fill `#E3F2FD`, Private = light green fill `#E8F5E9`, Database = light purple fill `#F3E5F5`
- **AZ columns:** Two side-by-side columns inside the VPC, one per availability zone, labelled `us-east-1a` and `us-east-1b`
- **AWS icons:** Use official AWS Architecture Icons for every service (flat vector icons, not 3D)
- **Arrows:** Thin, black directional arrows with short labels
- **Font:** AWS standard — Ember or Open Sans

---

## OVERALL LAYOUT (top to bottom)

```
[Internet / Users]
        ↓
[Route53]   [ACM]          ← outside Region (global)
        ↓
┌──────────────────────────── AWS Region: us-east-1 ──────────────────────────────┐
│                                                                                  │
│  [ALB — internet-facing]    ← sits in public subnets, spans both AZs           │
│           ↓                                                                      │
│  ┌──────────────────────────── VPC (10.0.0.0/16) ──────────────────────────┐   │
│  │                                                                           │   │
│  │   ┌── AZ: us-east-1a ──────┐   ┌── AZ: us-east-1b ──────┐             │   │
│  │   │ [Public 10.0.101.0/24] │   │ [Public 10.0.102.0/24] │             │   │
│  │   │  NAT Gateway           │   │  NAT Gateway            │             │   │
│  │   │                        │   │                         │             │   │
│  │   │ [Private 10.0.1.0/24]  │   │ [Private 10.0.2.0/24]  │             │   │
│  │   │  EKS Worker Nodes      │   │  EKS Worker Nodes       │             │   │
│  │   │  (c7i-flex.large)      │   │  (c7i-flex.large)       │             │   │
│  │   │  ┌─────────────────┐   │   │  ┌─────────────────┐   │             │   │
│  │   │  │ K8s Pods:       │   │   │  │ K8s Pods:       │   │             │   │
│  │   │  │ • frontend      │   │   │  │ • frontend      │   │             │   │
│  │   │  │ • appt-service  │   │   │  │ • appt-service  │   │             │   │
│  │   │  │ • report-svc    │   │   │  │ • report-svc    │   │             │   │
│  │   │  │ • notif-svc     │   │   │  │ • notif-svc     │   │             │   │
│  │   │  │ • redis         │   │   │  │ • redis         │   │             │   │
│  │   │  └─────────────────┘   │   │  └─────────────────┘   │             │   │
│  │   │  Lambda ENI (ai-svc)   │   │                         │             │   │
│  │   │                        │   │                         │             │   │
│  │   │ [DB 10.0.201.0/24]     │   │ [DB 10.0.202.0/24]     │             │   │
│  │   │  RDS PostgreSQL        │   │  RDS (standby/replica)  │             │   │
│  │   └────────────────────────┘   └─────────────────────────┘             │   │
│  │                                                                           │   │
│  └───────────────────────────────────────────────────────────────────────────┘  │
│                                                                                  │
│  AWS Managed Services (outside VPC, inside region):                             │
│  [S3]  [SQS]  [SES]  [Cognito]  [ECR]  [KMS]  [Secrets Manager]  [SSM]        │
│  [EventBridge]  [Bedrock]  [Textract]  [CloudWatch]                             │
│                                                                                  │
└──────────────────────────────────────────────────────────────────────────────────┘

Outside region:
[IAM + GitHub OIDC]
```

---

## COMPONENTS — draw each with its official AWS icon

### Outside Region (Global)
- **Internet** — cloud/globe icon, label: `Users (Browser)`
- **Amazon Route53** — icon + label: `rnld101.xyz hosted zone`
- **AWS Certificate Manager (ACM)** — icon + label: `*.rnld101.xyz wildcard cert`
- **IAM** — icon + label: `GitHub OIDC · IRSA roles`

### Inside Region, Outside VPC
- **Application Load Balancer (ALB)** — icon + label: `internet-facing · IngressGroup: lablumen · HTTPS 443`
- **Amazon ECR** — icon + label: `4 container image repos (KMS encrypted)`
- **Amazon S3** — icon + label: `reports-bucket (KMS) · sam-artifacts-bucket`
- **Amazon SQS** — icon + label: `lablumen-notifications queue`
- **Amazon SES** — icon + label: `no-reply@rnld101.xyz · DKIM`
- **Amazon Cognito** — icon + label: `lablumen-users · patient / staff groups`
- **AWS KMS** — icon + label: `alias/lablumen-platform CMK`
- **AWS Secrets Manager** — icon + label: `database-url · grafana-admin`
- **AWS SSM Parameter Store** — icon + label: `14 config params`
- **Amazon EventBridge** — icon + label: `S3 Object Created rule`
- **Amazon Bedrock** — icon + label: `Nova Lite v1 · Titan Embed v1`
- **Amazon Textract** — icon + label: `PDF OCR`
- **Amazon CloudWatch** — icon + label: `EKS control plane logs`

### Inside VPC

#### Public Subnets (light blue, one per AZ)
- AZ us-east-1a — `10.0.101.0/24` — **NAT Gateway** icon
- AZ us-east-1b — `10.0.102.0/24` — **NAT Gateway** icon
- Note below both: `Internet Gateway → NAT Gateway → private subnets egress`

#### Private Subnets (light green, one per AZ)
- Label: `10.0.1.0/24` (AZ-a) and `10.0.2.0/24` (AZ-b)

Inside each private subnet, draw:

**EKS Worker Node** box (EC2 icon):
- Label: `c7i-flex.large (managed node group, min 1 / max 4)`
- Inside the node box draw small rounded pod boxes (2 columns of pods):
  - `frontend` (nginx)
  - `appointment-service`
  - `report-service`
  - `notification-service`
  - `redis`
- Below the managed nodes, add a separate box:
  - `Karpenter nodes` — label: `t3.medium / t3.large · on-demand · auto-provisioned`

**Lambda ENI** — small Lambda icon inside the private subnet:
- Label: `ai-service Lambda · VPC-attached ENI`

#### Database Subnets (light purple, one per AZ)
- Label: `10.0.201.0/24` (AZ-a) and `10.0.202.0/24` (AZ-b)
- **RDS PostgreSQL** icon inside:
  - AZ-a: `db.t4g.micro · PostgreSQL 16.4 · pgvector` (primary)
  - AZ-b: `(subnet reserved for Multi-AZ standby)` (lighter, dashed box)

#### EKS Control Plane (draw as a separate AWS-managed box at the top of the VPC section)
- **EKS** icon — label: `EKS Control Plane · v1.31 · lablumen-eks`
- Sub-label: `AWS managed · public endpoint`
- Arrow from EKS control plane → Worker Nodes: `manages`

---

## TRAFFIC FLOW ARROWS (numbered, draw in this order)

1. **Users → Route53** — label: `DNS: *.rnld101.xyz`
2. **Route53 → ALB** — label: `A record (ExternalDNS)`
3. **ACM → ALB** — label: `TLS cert (HTTPS 443)` *(dashed)*
4. **ALB → EKS Pods (private subnet)** — label: `target: pods (IP mode)`
5. **EKS Pods → NAT Gateway** — label: `egress to AWS APIs` *(dashed)*
6. **NAT Gateway → Internet Gateway** — label: `outbound`
7. **EKS Pods → RDS** — label: `PostgreSQL 5432`
8. **Lambda ENI → RDS** — label: `PostgreSQL 5432`
9. **EKS Pods → Secrets Manager** — label: `fetch secrets (IRSA)`
10. **EKS Pods → SSM** — label: `fetch config (IRSA)`
11. **EKS Pods → SQS** — label: `publish / consume`
12. **EKS Pods → S3** — label: `upload PDF / presigned URL`
13. **EKS Pods → Bedrock** — label: `RAG chat`
14. **EKS Pods → Cognito** — label: `validate JWT`
15. **Lambda ENI → Textract** — label: `OCR`
16. **Lambda ENI → Bedrock** — label: `summarise + embed`
17. **S3 → EventBridge → Lambda** — label: `PDF uploaded (trigger)` *(dashed)*
18. **notification-service pod → SES** — label: `send email`
19. **ECR → EKS Nodes** — label: `pull images (KMS decrypt)` *(dashed)*
20. **IAM / OIDC → ALB + Pods** — label: `OIDC trust (no static keys)` *(dashed, from outside)*

---

## LABELS / ANNOTATIONS (small grey text, not arrows)

Add these as small text annotations next to the relevant component:

- Next to **EKS pods**: `HPA · PDB · topology spread · rolling update`
- Next to **Karpenter nodes**: `WhenEmptyOrUnderutilized · 1m consolidation`
- Next to **RDS**: `isolated DB subnets · SM-managed creds`
- Next to **KMS**: `CMK — encrypts ECR + Secrets Manager`
- Next to **ALB**: `Shared IngressGroup: app / api / argocd / grafana`
- Next to **IAM**: `GitHub OIDC (CI) · IRSA (pods) — zero static credentials`

---

## TITLE & LEGEND

**Title:** `LabLumen — AWS Infrastructure Architecture`
**Subtitle:** `us-east-1 · EKS v1.31 · Terraform 1.15.5`

**Legend (bottom right):**
- Solid arrow = synchronous / data path
- Dashed arrow = async / management / control plane
- Light blue subnet = Public (internet-facing)
- Light green subnet = Private (workload)
- Light purple subnet = Database (isolated, no internet route)
