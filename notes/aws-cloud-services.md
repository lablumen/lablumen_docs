# LabLumen — AWS Cloud Services Deep Dive

> This document covers every AWS service used in the LabLumen platform from first principles. For each service: what it is, how it works, exactly how it is configured in this project, the full flow it participates in, and a defence of why it was chosen over the alternatives. Read this and you will be able to answer any question a senior DevOps engineer or solutions architect throws at you.

---

## Table of Contents

1. [Amazon VPC](#1-amazon-vpc)
2. [Amazon EKS](#2-amazon-eks)
3. [Amazon EC2 + Karpenter](#3-amazon-ec2--karpenter)
4. [Amazon RDS (PostgreSQL + pgvector)](#4-amazon-rds-postgresql--pgvector)
5. [Amazon S3](#5-amazon-s3)
6. [AWS KMS](#6-aws-kms)
7. [Amazon ECR](#7-amazon-ecr)
8. [Amazon Cognito](#8-amazon-cognito)
9. [Amazon SQS](#9-amazon-sqs)
10. [Amazon SES](#10-amazon-ses)
11. [AWS Secrets Manager](#11-aws-secrets-manager)
12. [AWS SSM Parameter Store](#12-aws-ssm-parameter-store)
13. [AWS Lambda + AWS SAM](#13-aws-lambda--aws-sam)
14. [Amazon Bedrock](#14-amazon-bedrock)
15. [AWS Textract](#15-aws-textract)
16. [Amazon EventBridge](#16-amazon-eventbridge)
17. [Amazon Route 53](#17-amazon-route-53)
18. [AWS Certificate Manager (ACM)](#18-aws-certificate-manager-acm)
19. [AWS IAM + OIDC + IRSA](#19-aws-iam--oidc--irsa)
20. [Application Load Balancer (ALB)](#20-application-load-balancer-alb)
21. [AWS CloudWatch](#21-aws-cloudwatch)
22. [AWS STS](#22-aws-sts)
23. [AWS CloudFormation](#23-aws-cloudformation)
24. [VPC Endpoints (PrivateLink)](#24-vpc-endpoints-privatelink)
25. [Full Application Flow — Everything Together](#25-full-application-flow--everything-together)

---

## 1. Amazon VPC

### What is a VPC?

VPC stands for **Virtual Private Cloud**. Think of it as your own private section of the AWS cloud — like renting a floor in a shared office building where you control every door and lock. By default, nothing in a VPC is reachable from the internet and nothing can leave to the internet unless you explicitly open a path. A VPC is defined by an **IP address range** (CIDR block), and you divide that range into **subnets**.

### Core concepts

| Concept | What it is |
|---|---|
| **Subnet** | A subdivision of the VPC's IP range, tied to one Availability Zone |
| **Public subnet** | Has a route to the Internet Gateway — resources here can be reached from the internet (e.g., a load balancer) |
| **Private subnet** | No direct internet route — EKS worker nodes live here; they reach the internet only via NAT |
| **Database subnet** | Completely isolated — no NAT route, no IGW route. Only reachable from within the VPC |
| **Internet Gateway (IGW)** | The door to the internet, attached to the VPC; public subnets route through it |
| **NAT Gateway** | Sits in a public subnet. Lets private-subnet resources make outbound calls without being exposed inbound |
| **Route Table** | Rules that say "traffic for 0.0.0.0/0 (anywhere) goes through X" |
| **Security Group** | A stateful firewall attached to a resource; you specify which ports are allowed in/out |

### How it is configured in LabLumen

```
VPC CIDR: 10.0.0.0/16  (65,536 IPs)

PUBLIC SUBNETS   — us-east-1a: 10.0.101.0/24 | us-east-1b: 10.0.102.0/24
  Route: 0.0.0.0/0 → Internet Gateway
  ALB (Application Load Balancer) sits here — internet-facing
  NAT Gateway sits here

PRIVATE SUBNETS  — us-east-1a: 10.0.1.0/24  | us-east-1b: 10.0.2.0/24
  Route: 0.0.0.0/0 → NAT Gateway
  EKS worker nodes run here
  Lambda function ENIs (AI service) attach here
  VPC Interface Endpoints land here

DATABASE SUBNETS — us-east-1a: 10.0.201.0/24 | us-east-1b: 10.0.202.0/24
  No internet route at all
  RDS PostgreSQL instance lives here
```

**Subnet tags** — Terraform tags subnets so AWS controllers can auto-discover them:
- `kubernetes.io/role/elb = 1` on public subnets → tells the AWS Load Balancer Controller to put internet-facing ALBs here
- `karpenter.sh/discovery = lablumen-eks` on private subnets → Karpenter discovers which subnets to launch worker nodes into

**Single NAT Gateway** — One NAT in us-east-1a serves both private subnets. Two NATs (one per AZ) would give better availability if the first AZ goes down, but at double the cost. For this platform a single NAT is the correct cost-efficient choice.

**Security Groups:**
- RDS SG: TCP 5432 inbound from 10.0.0.0/16. No egress rule (RDS never initiates outbound connections).
- Lambda SG: egress TCP 5432 (to RDS) + TCP 443 (to AWS APIs via endpoints or NAT). No inbound.
- VPC Endpoints SG: TCP 443 in/out from the VPC CIDR — pods talk to AWS services over private IPs.

### Defence questions

**"Why not put EKS nodes in public subnets?"** If nodes were public, their kubelet APIs and any misconfigured NodePort services would face the internet. With private subnets, even a completely wrong security group rule can't expose a node directly — there is no internet route. Defense-in-depth.

**"Why a single VPC instead of one per service?"** Separate VPCs would require VPC Peering or Transit Gateway, which adds routing complexity, cost, and DNS management without a meaningful security gain at this scale. Services are isolated by security groups and IAM, which is sufficient.

**"Why not use AWS default VPC?"** The default VPC has all subnets public and no isolated database tier. Running RDS in a public subnet (even with security groups) is a security antipattern. Custom VPC gives us the three-tier network architecture (public / private / database) that is the industry standard for web platforms.

---

## 2. Amazon EKS

### What is EKS?

**Elastic Kubernetes Service** is AWS's managed Kubernetes offering. Kubernetes is an orchestration platform — it takes your Docker containers and decides which machines to run them on, restarts them if they crash, scales them when traffic increases, and handles rolling deployments with zero downtime.

In a self-managed Kubernetes setup you would run the **control plane** yourself (API server, etcd database, scheduler, controller manager). EKS removes that burden — AWS runs the control plane and you only manage the **worker nodes** (the EC2 machines running your application containers).

### Core Kubernetes concepts

| Concept | What it is |
|---|---|
| **Pod** | Smallest deployable unit; one or more containers bundled together |
| **Deployment** | Declares "I want N replicas of this pod" and manages rolling updates |
| **Service** | Stable internal DNS name and IP for a set of pods |
| **Ingress** | Rules for routing external HTTP/HTTPS traffic to internal Services by path or host |
| **Namespace** | Logical isolation within one cluster; LabLumen uses `lablumen` (prod) and `lablumen-dev` |
| **ServiceAccount** | Identity for a pod within Kubernetes, also the bridge to AWS IAM via IRSA |
| **HPA** | Horizontal Pod Autoscaler — scales replica count based on CPU/memory |
| **PDB** | PodDisruptionBudget — guarantees a minimum number of replicas stay up during node maintenance |

### How it is configured in LabLumen

**Cluster:**
- Kubernetes version 1.31
- Authentication mode: `API` (modern EKS Access Entries — no more the fragile `aws-auth` ConfigMap)
- `enable_cluster_creator_admin_permissions = false` — the creator is granted access via an explicit EKS Access Entry, not an automatic back-door. This is auditable.
- Control-plane logging to CloudWatch: api, audit, authenticator, controllerManager, scheduler — 14-day retention

**Managed Node Group (always-on base):**
- Instance type: `t3.medium` (2 vCPU, 4 GB RAM — org SCP blocks t3.large)
- Min: 1, Max: 4, Desired: 2 across two AZs

**What runs inside EKS:**

| Workload | Namespace | Notes |
|---|---|---|
| appointment-service | lablumen | 2 replicas prod, HPA to 6 |
| report-service | lablumen | 2 replicas prod, HPA to 6 |
| notification-service | lablumen | SQS consumer, no ingress |
| frontend (nginx) | lablumen | Serves the React SPA + reverse-proxies APIs |
| Redis | lablumen | In-cluster, ephemeral, slot locking |
| ArgoCD | argocd | GitOps controller |
| External Secrets Operator | external-secrets | Syncs AWS secrets to K8s Secrets |
| AWS Load Balancer Controller | kube-system | Provisions ALBs from Ingress objects |
| ExternalDNS | kube-system | Manages Route 53 records from Ingress objects |
| Karpenter | kube-system | Dynamic node provisioning |
| Prometheus + Grafana | monitoring | Observability stack |

**GitOps deployment model (ArgoCD App-of-Apps):**
- A single `kubectl apply -f bootstrap/root-app.yaml` creates the ArgoCD "root app"
- The root app watches the `lablumen-k8s` Git repo and recursively syncs: ArgoCD platform addons (wave 0) → config (wave 1) → microservices (wave 2)
- When a developer merges to main, GitHub Actions builds the Docker image, pushes to ECR, and commits the new 7-character SHA tag into `services/<name>/values-dev.yaml` in `lablumen-k8s`
- ArgoCD detects the Git change and performs a rolling deployment — no manual `kubectl` ever needed

### Defence questions

**"Why EKS over ECS (Elastic Container Service)?"**

| | EKS | ECS |
|---|---|---|
| Portability | Standard Kubernetes — any kubectl/Helm/ArgoCD knowledge applies | AWS-proprietary — Fargate launch types, Task Definitions |
| Ecosystem | Helm, ArgoCD, Karpenter, External Secrets Operator, Prometheus — all CNCF-standard | Fewer community tools; CodePipeline/CodeDeploy for CD |
| RBAC | Kubernetes RBAC, namespaces, NetworkPolicies | Limited namespace equivalent |
| GitOps | ArgoCD is Kubernetes-native | No equivalent |

EKS was chosen to use a standard, employer-recognisable DevOps toolchain. Any DevOps engineer hired in the future will recognise Helm, ArgoCD, and Karpenter immediately.

**"Why not just run containers directly on EC2?"** You would be writing your own orchestration — handling restarts, health checks, rolling deployments, service discovery, and autoscaling from scratch. Kubernetes solves all of those as a platform. The learning investment pays off immediately.

---

## 3. Amazon EC2 + Karpenter

### What is EC2?

**Elastic Compute Cloud** provides the virtual machines (instances) that are the worker nodes in EKS. In the EKS context, EC2 provides the underlying compute; Kubernetes handles the orchestration.

### What is Karpenter?

Karpenter is an open-source Kubernetes node autoscaler (originally from AWS, donated to CNCF). When Kubernetes cannot schedule a pod because there is not enough capacity on existing nodes, Karpenter provisions a new EC2 instance within seconds. When nodes become idle, Karpenter consolidates pods and terminates the empty nodes, reducing cost.

### How it is configured in LabLumen

**EC2NodeClass** — defines *how* to build a node:
```yaml
role: "KarpenterNodeRole-lablumen-eks"   # IAM instance profile
amiSelectorTerms:
  - alias: al2023@latest                  # Amazon Linux 2023, auto-matches EKS version
subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: lablumen-eks  # auto-discovers private subnets via tag
securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: lablumen-eks  # auto-discovers node security group via tag
```

**NodePool** — defines *what* Karpenter may provision and when it cleans up:
```yaml
requirements:
  - { key: karpenter.sh/capacity-type, values: ["on-demand"] }  # no spot (reliability)
  - { key: node.kubernetes.io/instance-type, values: ["t3.medium", "t3.large"] }
limits:
  cpu: "20"                          # safety cap: never exceed 20 vCPUs total
disruption:
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 1m               # reclaim idle nodes 1 minute after they empty
```

**Terraform provisions** the Karpenter IAM role and SQS interruption queue (receives EC2 Spot interruption notices so Karpenter can gracefully drain the node before AWS terminates it). The Karpenter Helm chart is deployed by ArgoCD (wave 0).

### Defence questions

**"Why Karpenter over Cluster Autoscaler?"**

| | Karpenter | Cluster Autoscaler |
|---|---|---|
| Speed | ~30 seconds to provision (calls EC2 directly) | 3–5 minutes (works via Auto Scaling Group events) |
| Instance choice | Picks the smallest, cheapest instance that fits the pending pod | Fixed to the ASG instance type |
| Consolidation | Actively moves pods and terminates underused nodes | Very conservative scale-down |
| Spot handling | SQS-based interruption queue + graceful drain | Limited |

**"Why on-demand and not Spot instances?"** Spot instances can be reclaimed by AWS with 2 minutes' warning, which can cause pod evictions mid-request. For a healthcare platform where in-flight lab report uploads and AI processing must not be interrupted, on-demand provides the reliability guarantee. Spot would be appropriate for batch or background workloads where retries are cheap.

---

## 4. Amazon RDS (PostgreSQL + pgvector)

### What is RDS?

**Relational Database Service** is AWS's managed database offering. Instead of running PostgreSQL on an EC2 instance and managing backups, patching, snapshots, and failover yourself, RDS handles all of that automatically. You connect to a DNS hostname and run SQL.

### Why PostgreSQL specifically?

PostgreSQL was chosen because of the **pgvector** extension — it adds vector data types and cosine/dot-product similarity search directly into Postgres. The AI chat feature stores 1536-dimensional embedding vectors (one per text chunk of a lab report) and performs fast approximate nearest-neighbour queries using an HNSW index. Without pgvector you would need a separate vector database service.

### How it is configured in LabLumen

- **Engine:** PostgreSQL 16.4
- **Instance class:** `db.t4g.micro` (2 vCPU, 1 GB RAM — org SCP restricts to micro-class instances only)
- **Storage:** 20 GB, encrypted at rest with KMS
- **Subnets:** Deployed into the **isolated database subnets** — no internet or NAT route
- **Security group:** TCP 5432 inbound only from the VPC CIDR (10.0.0.0/16)
- **Credentials:** `manage_master_user_password = true` — RDS generates a random password, stores it in Secrets Manager, and can rotate it automatically
- **Multi-AZ:** Disabled (cost saving for educational platform; enable for production HA)

**pgvector and the HNSW index** — from the Alembic migration:
```sql
CREATE EXTENSION IF NOT EXISTS vector;

CREATE INDEX ix_report_embeddings_hnsw
ON report_embeddings USING hnsw (embedding vector_cosine_ops);
```
HNSW (Hierarchical Navigable Small World) builds a multi-layer graph of vectors. Querying it finds the top-3 nearest chunks in milliseconds even with thousands of rows — far faster than a brute-force `ORDER BY embedding <=> query_vector LIMIT 3`.

**Shared database, service-owned schema:** All three data-touching services (appointment-service, report-service, AI Lambda) share one RDS instance. The appointment-service owns and runs all Alembic migrations on startup, including the tables used by the other services. Services are isolated at the API layer, not the database layer.

### Defence questions

**"Why RDS over self-managed Postgres on EC2?"**
RDS gives you automated backups, automated minor-version patching, Secrets Manager credential rotation, Enhanced Monitoring, and Multi-AZ failover. Every one of those would require significant engineering effort to replicate on a raw EC2 instance. For a platform storing patient data, you want the managed option.

**"Why not Aurora PostgreSQL?"**
Aurora Serverless v2 would auto-scale storage and compute, but its minimum cost is substantially higher than a `db.t4g.micro`. Additionally, the org SCP in this account explicitly blocks `CreateDBCluster` (Aurora). Standard RDS on a micro instance is the correct cost-efficient choice here. Aurora makes sense when you need multiple read replicas, unpredictable traffic spikes, or regional HA.

**"Why not DynamoDB?"**
DynamoDB is a NoSQL key-value/document store. It does not support complex SQL joins, foreign keys, or vector similarity search. The booking model requires relational joins across 6 tables. Forcing a relational model into DynamoDB would create a "NoSQL antipattern" of massive, deeply nested items and inefficient table-scan workarounds.

**"Why not a dedicated vector database like Pinecone or Weaviate?"**
Adding a separate vector database would mean a second data store to provision, secure, back up, and pay for. pgvector brings vector search inside the existing Postgres instance that already holds all application data. At the scale of LabLumen (hundreds to thousands of reports), pgvector's HNSW index is more than sufficient.

---

## 5. Amazon S3

### What is S3?

**Simple Storage Service** is AWS's object storage. Unlike a file system, S3 stores objects (files) in **buckets** with globally unique names and unique keys. It scales to unlimited data, is designed for 99.999999999% (11 nines) durability, and is the backbone of most AWS architectures.

### Three S3 buckets in LabLumen

**Bucket 1: Reports Bucket (`lablumen-reports-<account_id>`)**

The primary PHI (Protected Health Information) store. Lab report PDFs are uploaded here by staff via the report-service, then read by the AI Lambda for OCR processing.

Security configuration:
- All four S3 public-access block settings enabled — reports can never be made public, even by a misconfiguration
- **KMS encryption:** `sse_algorithm = "aws:kms"` using the platform CMK. Every stored object is encrypted with a unique data key wrapped by the CMK.
- **Versioning:** enabled. If a report is accidentally overwritten, previous versions are recoverable.
- **EventBridge notification:** `eventbridge = true` — every `ObjectCreated` event is forwarded to EventBridge, which triggers the AI Lambda.

How patients access reports — **presigned URLs:**
The report-service generates a time-limited presigned URL (2-minute TTL, SigV4 signed) and returns it to the browser. The browser then fetches the PDF directly from S3. The backend never proxies the file bytes.

**Why presigned URLs?** A 5 MB PDF proxied through the report-service pod would consume pod memory and bandwidth for every viewer. A presigned URL offloads the entire data transfer to S3, which is purpose-built for this. The short TTL means even a leaked URL expires within 2 minutes.

**Bucket 2: SAM Artifacts Bucket (`lablumen-sam-<account_id>`)**

Used by `sam deploy` to stage the Lambda deployment ZIP before CloudFormation picks it up. No KMS (deployment code is not sensitive). No versioning needed.

**Bucket 3: Terraform State Bucket (`lablumen-tfstate-<account_id>`)**

Stores the Terraform state file — the authoritative record of what infrastructure Terraform has created. Created by the `bootstrap/` stack (a separate Terraform configuration applied once before the main stack).

Configuration:
- AES-256 server-side encryption
- Versioning enabled (you can roll back to a previous state file if an apply corrupts it)
- `use_lockfile = true` in the backend block — Terraform 1.10+ S3-native locking. Terraform writes a `.tflock` object during operations to prevent concurrent applies. This replaces the old DynamoDB locking table.

### Defence questions

**"Why S3 for Terraform state instead of Terraform Cloud?"**
Terraform Cloud adds a UI and collaboration features but introduces a third-party dependency. For an AWS-native team, S3 + S3-native locking keeps everything within one AWS account, costs essentially nothing, and is audited in CloudTrail.

**"Why KMS encryption and not SSE-S3 for the reports bucket?"**
SSE-S3 uses AWS-managed keys that you have no visibility or control over. With KMS you can: see every decrypt call in CloudTrail, revoke access instantly by disabling the key, and restrict decryption to specific IAM roles. For a healthcare platform storing patient reports (PHI), CMK-controlled encryption is the appropriate choice.

**"Why not EFS (Elastic File System) for shared file storage?"**
EFS is a network file system — appropriate when multiple EC2 instances need a POSIX file tree. Report PDFs are write-once/read-many objects with no directory hierarchy requirement. S3's object model, presigned URL support, EventBridge integration, and 11-nines durability make it the correct tool.

---

## 6. AWS KMS

### What is KMS?

**Key Management Service** lets you create and control cryptographic keys used to encrypt your data. You never see the raw key material — KMS holds it securely and you call KMS to encrypt/decrypt. All key usage is logged in CloudTrail automatically.

### The platform Customer-Managed Key (CMK)

One CMK (`alias/lablumen-platform`) serves the entire platform:
- **ECR repositories** — image layers are encrypted with this key in storage
- **Secrets Manager secrets** — the database DSN and Grafana credentials are encrypted with this key
- **Reports S3 bucket** — every uploaded lab report PDF is encrypted with this key

**Key policy has two statements:**
1. `EnableIAMPolicies` — allows the account root to delegate key access via IAM policies. Without this, no IAM policy, however permissive, can grant key access.
2. `AllowSecretsManager` — allows the Secrets Manager service principal to call `GenerateDataKey*`, `Decrypt`, and `DescribeKey` so it can encrypt and decrypt secrets on behalf of callers.

**Key rotation:** `enable_key_rotation = true` — AWS rotates the key material annually. Old versions are retained so previously encrypted data can still be decrypted.

**Who gets KMS access (via IAM policies on their roles):**
- EKS nodes + Karpenter nodes → `kms:Decrypt`, `kms:DescribeKey` — to pull KMS-encrypted ECR image layers
- ESO (External Secrets Operator) → same — to decrypt KMS-encrypted Secrets Manager values
- AI Lambda → same — to decrypt the `lablumen/app/database-url` secret
- GitHub Actions CI (ECR push) → `kms:GenerateDataKey*`, `kms:Decrypt`, `kms:DescribeKey` — to push encrypted image layers

### Defence questions

**"Why a shared CMK instead of per-service keys?"**
Per-service keys are the most security-hardened approach (compromise of one key doesn't affect others). However, it multiplies key policies, IAM grants, and rotation events. For a single-tenant educational platform without regulatory key-isolation requirements, one CMK is pragmatic. In a regulated production environment handling PHI at scale, you would use separate CMKs for reports, secrets, and image storage.

**"Why KMS over S3-managed SSE (SSE-S3) for the reports bucket?"**
SSE-S3 uses AWS-internal keys with no visibility into usage. KMS gives you a CloudTrail audit trail of every decrypt call (who, what, when), the ability to revoke access instantly by disabling the key, and the ability to scope decryption to specific IAM roles. For PHI, that audit trail is what separates you from a compliance violation.

---

## 7. Amazon ECR

### What is ECR?

**Elastic Container Registry** is AWS's managed Docker image registry — like a private Docker Hub that lives inside your AWS account. When EKS wants to run your appointment-service pod, worker nodes pull the Docker image from ECR.

### How it is configured in LabLumen

Four repositories (one per containerised service): `lablumen/appointment-service`, `lablumen/report-service`, `lablumen/notification-service`, `lablumen/frontend`.

**Per-repository settings:**
- `image_tag_mutability = "IMMUTABLE"` — once an image is pushed with tag `abc1234`, that tag can never be overwritten. This guarantees that rolling back to a previous tag is identical to what was originally deployed.
- `scan_on_push = true` — AWS runs CVE scanning on every pushed image using Amazon Inspector / ECR Enhanced Scanning.
- **KMS encryption** with the platform CMK — image layers are encrypted at rest.
- **Lifecycle policy** — keeps only the most recent N images and expires older ones, preventing unbounded storage growth.

**Registry URL:** `<account_id>.dkr.ecr.us-east-1.amazonaws.com` — derived at runtime from `data.aws_caller_identity`, never hardcoded. This makes the Terraform code portable across AWS accounts.

**CI push flow (what happens on every merge to main):**
1. GitHub Actions runner assumes the `lablumen-app-ci-ecr` IAM role via OIDC (no static credentials)
2. `aws-actions/amazon-ecr-login@v2` exchanges the OIDC token for a Docker login token
3. Build the image, tag it with the 7-character git SHA (e.g., `abc1234`)
4. **Trivy gate** — scan the image for fixable CRITICAL/HIGH CVEs; fail the pipeline if found
5. Push to ECR only if Trivy passes
6. Write the SHA tag into `lablumen-k8s/services/<name>/values-dev.yaml` → ArgoCD deploys to dev

### Defence questions

**"Why ECR over Docker Hub?"**
- **Security:** Images stay within your AWS account. Pulling via VPC Endpoints means image bytes never traverse the public internet.
- **IAM-controlled access:** No username/password tokens that expire or leak — access is via IAM roles.
- **No rate limits:** Docker Hub imposes aggressive pull rate limits on free/team accounts. Under autoscaling, those limits can block node provisioning at the worst possible moment.
- **Cost:** ~$0.10/GB/month, negligible for a microservices platform.

**"Why IMMUTABLE tags?"**
Mutable tags (like `:latest`) mean `docker pull :latest` on Monday might give a different image than on Friday. IMMUTABLE tags guarantee that tag `abc1234` always refers to exactly the same image bytes, making deployments reproducible and rollbacks reliable.

---

## 8. Amazon Cognito

### What is Cognito?

**Cognito User Pools** is AWS's managed authentication service. It handles user registration, email verification, password hashing and salting, sign-in flows, and JWT token issuance — all without you writing any of that code.

The key design decision in LabLumen: Cognito is the **only authentication system**. There is no auth microservice, no `users` table with hashed passwords managed by application code, no session tokens. Every service verifies Cognito JWTs independently using the pool's published JWKS (public keys).

### How it is configured in LabLumen

**User Pool (`lablumen-users`):**
- `username_attributes = ["email"]` — users log in with email, not a separate username
- `auto_verified_attributes = ["email"]` — Cognito sends a code to the email at registration; the account is locked until confirmed
- Password policy: 8+ characters, lowercase + uppercase + digits required

**App Client (`lablumen-web`):**
- `generate_secret = false` — a public client (SPA). The client ID is not sensitive; there is no client secret to protect.
- `explicit_auth_flows = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]` — SRP (Secure Remote Password) flow; the password is never sent in plaintext, not even hashed.
- `allowed_oauth_flows = ["code"]` — authorization code flow (not implicit, which is deprecated and insecure)

**Groups (Cognito's RBAC mechanism):**
Three Cognito groups are created: `PATIENT`, `LAB_STAFF`, `LAB_ADMIN`. Users are manually assigned to groups in the Cognito console. Group membership is embedded in the JWT as the `cognito:groups` claim.

### How authentication flows end-to-end

```
1. User types email + password on /login
2. Frontend (amazon-cognito-identity-js): SRP handshake with Cognito
   — the password is never sent; Cognito proves the user knows it via a challenge-response
3. Cognito returns ID token (JWT signed with RS256, contains sub + email + cognito:groups)
4. Frontend stores the ID token in localStorage
5. Every API call: Authorization: Bearer <id_token>
6. Backend (appointment-service or report-service):
   PyJWKClient fetches Cognito's public JWKS (cached after first call per pod lifetime)
   jwt.decode() verifies the RS256 signature and expiry
   Reads sub (UUID), email, cognito:groups from the claims
7. ON FIRST REQUEST per user: INSERT INTO users (user_id, email) ... ON CONFLICT DO NOTHING
   — the database row is auto-provisioned from the token; no separate registration API needed
8. For staff-only endpoints: require_roles("LAB_STAFF", "LAB_ADMIN") checks the groups claim
```

### Defence questions

**"Why Cognito over building your own auth?"**
Building auth from scratch means: bcrypt/Argon2 hashing, timing-safe comparison, email verification flows, password-reset flows, JWT signing key management, token rotation, brute-force protection. Getting any one of these wrong in a healthcare platform is a serious incident. Cognito is SOC 2 and HIPAA BAA eligible; it handles all of this correctly.

**"Why Cognito over Auth0 or Okta?"**
Auth0 and Okta are excellent products. The reasons Cognito was chosen: it is AWS-native (no additional vendor relationship, no data leaving the AWS ecosystem), it is free up to 50,000 monthly active users, and admin operations are IAM-controlled. For a platform fully running on AWS, keeping identity within the same ecosystem simplifies the security boundary.

**"Why not use Cognito's hosted UI?"**
The hosted UI uses a redirect-based OAuth flow that takes the user away from the application for login, then back. The SRP flow via `amazon-cognito-identity-js` keeps the user on the same page, giving full control over the login UI design — appropriate for a healthcare SPA where user experience matters.

**"Why no separate auth microservice?"**
Each service verifying the JWT independently means: no network hop to an auth service on every request, no single point of failure for authentication, and no extra service to deploy and monitor. The Cognito JWKS endpoint is the shared source of truth — public keys are cached per-pod and verified cryptographically.

---

## 9. Amazon SQS

### What is SQS?

**Simple Queue Service** is AWS's managed message queue. A producer sends a message to the queue; the message is held reliably until a consumer reads and deletes it. The producer and consumer are completely decoupled — they can be deployed, restarted, or scaled independently.

### How it is configured in LabLumen

One queue: `lablumen-notifications` — a **standard queue** (not FIFO).

**Standard vs FIFO:**

| | Standard | FIFO |
|---|---|---|
| Ordering | Best-effort (messages may arrive slightly out of order) | Strict first-in-first-out |
| Throughput | Unlimited | 3,000 messages/second |
| Deduplication | Not built-in | Exactly-once delivery |
| Use case | Notifications, async work | Financial ledgers, order processing |

Notification emails don't need strict ordering — if "booking confirmed" and "report ready" are processed in either order, it doesn't matter. Standard queue is appropriate.

**Producer — appointment-service:**
After a successful booking is committed to Postgres, `sqs.send_message()` fires a JSON event:
```json
{ "type": "appointment.booked", "to_email": "patient@example.com", "data": {"appointment_date": "..."} }
```
This is **fire-and-forget**: if SQS publish fails (network hiccup, API error), the exception is caught, logged, and swallowed. The booking is already committed. An undelivered email is acceptable; a rolled-back booking is not.

**Consumer — notification-service:**
Runs an async background loop that long-polls SQS every 20 seconds (`WaitTimeSeconds=20`). Long-polling holds the connection open for up to 20 seconds waiting for messages, instead of returning immediately when the queue is empty — this dramatically reduces API call costs and CPU usage. On each successful email send, the message is explicitly deleted from SQS. On failure, the message is left on the queue; SQS's visibility timeout makes it invisible to other consumers during processing, then makes it visible again for retry. A DLQ (Dead Letter Queue) would capture messages that fail repeatedly — not explicitly configured here but trivial to add.

**Three event types handled:**
- `appointment.booked` → "Your LabLumen appointment is confirmed"
- `appointment.cancelled` → "Your LabLumen appointment was cancelled"
- `report.ready` → "Your LabLumen lab report is ready"

### Defence questions

**"Why SQS instead of calling SES directly from appointment-service?"**
If appointment-service called SES directly: a SES failure (rate limit, temporary API error) would either fail the booking or require retry logic inside the booking transaction. SQS decouples the two concerns — appointment-service says "something happened," notification-service decides what to do about it. They can be independently deployed, scaled, and replaced.

**"Why not SNS instead of SQS?"**
SNS (Simple Notification Service) is a pub/sub fan-out service — one message to many subscribers simultaneously. LabLumen has exactly one consumer (notification-service). SNS's fan-out capability adds no value here. If the platform later needed to simultaneously send email AND SMS AND push notifications, you'd put SNS in front of SQS (SNS → multiple SQS queues). Right now, SQS direct is simpler.

**"Why not Kafka / Amazon MSK?"**
Kafka is built for event streaming at massive scale — millions of events per second, long-term retention, replayed streams. LabLumen sends at most a few notifications per hour. Kafka's operational complexity (broker management, partition design, consumer groups, offset management) is not justified at this scale.

---

## 10. Amazon SES

### What is SES?

**Simple Email Service** is AWS's managed transactional email platform. It lets you send email at scale from your own domain without running a mail server. Running your own SMTP server would result in your domain being blacklisted as spam within days. SES handles IP reputation, deliverability, bounce handling, and DKIM signing.

### How it is configured in LabLumen

**Domain identity (not email identity):**
Rather than verifying a single email address like `no-reply@rnld101.xyz`, the entire domain `rnld101.xyz` is verified. This means any address `@rnld101.xyz` can send email, including `no-reply@rnld101.xyz`.

**Easy DKIM — 3 CNAME records in Route 53:**
Terraform creates the SESv2 domain identity and automatically adds 3 CNAME records:
```
<token1>._domainkey.rnld101.xyz → <token1>.dkim.amazonses.com
<token2>._domainkey.rnld101.xyz → <token2>.dkim.amazonses.com
<token3>._domainkey.rnld101.xyz → <token3>.dkim.amazonses.com
```
DKIM is a cryptographic email header that receiving mail servers verify to confirm the email genuinely came from the claimed domain. Without DKIM, emails go straight to spam. AWS handles the key generation and signing automatically once the CNAMEs are in DNS.

**notification-service sends via boto3:**
```python
_ses.send_email(
    Source="no-reply@rnld101.xyz",
    Destination={"ToAddresses": [event.to_email]},
    Message={"Subject": {...}, "Body": {"Text": {...}}}
)
```

**SES Sandbox → Production:** New AWS accounts start in SES sandbox mode (can only send to verified addresses). For a live deployment, submit a "Request Production Access" case to AWS Support to remove this restriction.

### Defence questions

**"Why SES over SendGrid or Postmark?"**
- AWS-native: access controlled by IAM roles, not a plain API key that could be leaked in code
- Cost: $0.10 per 1,000 emails — SendGrid's cheapest plan is $15/month for 50,000 emails
- No extra vendor: everything stays within the AWS billing account and security boundary

**"Why not SNS for sending emails?"**
SNS can send emails, but it uses a no-reply AWS-owned address, supports no custom HTML templates, and is designed for operational alerts (like CloudWatch alarms) — not customer-facing transactional email. SES is the correct service for branded email delivery.

---

## 11. AWS Secrets Manager

### What is Secrets Manager?

**Secrets Manager** stores sensitive runtime values — database passwords, connection strings, private keys — with encryption, access control, audit logging, and optional automatic rotation. Unlike environment variables or hardcoded values, Secrets Manager ensures secret material never appears in code, Git history, or Terraform state.

### How it is configured in LabLumen

Two secrets are created as **empty shells** by Terraform. The values are populated manually out-of-band (a human engineer assembles the DSN from the RDS console and pastes it in). Terraform creates the namespace (name + KMS key association) but writes no value:

| Secret name | Contents | Used by |
|---|---|---|
| `lablumen/app/database-url` | Full Postgres DSN: `postgresql+asyncpg://lablumen:<pw>@<rds-endpoint>:5432/lablumen` | appointment-service and report-service (via ESO), AI Lambda (direct fetch) |
| `lablumen/app/grafana-admin` | JSON: `{"admin-user":"admin","admin-password":"..."}` | ESO syncs into monitoring namespace for Grafana |

**How services consume the secret:**
- **EKS pods:** External Secrets Operator (ESO) reads from Secrets Manager using its IRSA role and writes a Kubernetes Secret. The pod's container mounts the Kubernetes Secret as an environment variable `DATABASE_URL`. The pod code sees a plain environment variable — it has no AWS SDK dependency for secrets.
- **AI Lambda:** `db.py` calls `secretsmanager.get_secret_value()` directly at cold start. The DSN is cached in a module-level variable for the Lambda execution environment's lifetime — subsequent invocations skip the Secrets Manager API call.

**All secrets encrypted with the platform KMS CMK.** To read a secret you need both `secretsmanager:GetSecretValue` AND `kms:Decrypt` on the CMK. Two IAM checks for one read — defence in depth.

**`secret_recovery_window_days = 0`** — set to zero so `terraform destroy` can immediately delete and re-create the secret shell without the default 7-day deletion recovery window blocking re-creation on the same name.

### Defence questions

**"Why Secrets Manager over putting DATABASE_URL directly in a Kubernetes Secret YAML?"**
If the connection string is in a YAML file (even base64-encoded), it is effectively in Git. Anyone with Git read access or `kubectl get secret` access sees the production database password. With Secrets Manager: the secret is never in Git, every access is logged in CloudTrail, and the secret can be rotated without redeployment.

**"What is the 'empty shell' pattern?"**
Terraform creates the secret container (name, description, KMS key) but does not manage the value. This separates infrastructure provisioning (Terraform) from secret management (a human ops step). Secret values never touch Terraform state, which would put them in the S3 state file.

---

## 12. AWS SSM Parameter Store

### What is SSM Parameter Store?

**Systems Manager Parameter Store** is a hierarchical key-value store for application configuration. It integrates with IAM and is free for standard parameters (plain String type). Unlike Secrets Manager, it is designed for non-sensitive configuration data, not secrets.

### How it is configured in LabLumen

Terraform writes 15 parameters under `/lablumen/config/`:

| Parameter | Value stored |
|---|---|
| `/lablumen/config/region` | `us-east-1` |
| `/lablumen/config/cognito-user-pool-id` | Cognito User Pool ID |
| `/lablumen/config/cognito-app-client-id` | Cognito App Client ID |
| `/lablumen/config/sqs-url` | Full SQS queue URL |
| `/lablumen/config/reports-bucket` | S3 bucket name for reports |
| `/lablumen/config/ses-sender` | `no-reply@rnld101.xyz` |
| `/lablumen/config/bedrock-embed-model` | `amazon.titan-embed-text-v1` |
| `/lablumen/config/bedrock-text-model` | `amazon.nova-lite-v1:0` |
| `/lablumen/config/presigned-url-ttl` | `3600` |
| `/lablumen/config/cors-origins` | `https://app.rnld101.xyz,...` |
| `/lablumen/config/lambda-exec-role-arn` | IAM role ARN for the Lambda |
| `/lablumen/config/lambda-subnet-ids` | Comma-separated private subnet IDs |
| `/lablumen/config/lambda-security-group-id` | Lambda security group ID |
| `/lablumen/config/sam-artifacts-bucket` | SAM deployment bucket name |
| `/lablumen/config/bedrock-cross-account-role-arn` | Cross-account Bedrock IAM role ARN |

**How they flow into applications:**

**EKS services** — External Secrets Operator reads from the `aws-parameter-store` ClusterSecretStore and creates Kubernetes Secrets. Each service's `values.yaml` lists which SSM keys map to which environment variable names:
```yaml
externalSecret:
  ssmData:
    - { secretKey: COGNITO_USER_POOL_ID, remoteKey: /lablumen/config/cognito-user-pool-id }
    - { secretKey: NOTIFICATIONS_QUEUE_URL, remoteKey: /lablumen/config/sqs-url }
```

**AI Lambda CI** — The `sam deploy` step reads the VPC/role parameters from SSM at deploy time:
```bash
exec_role_arn=$(aws ssm get-parameter --name "/lablumen/config/lambda-exec-role-arn" --query Parameter.Value --output text)
sam deploy --parameter-overrides "ExecutionRoleArn=$exec_role_arn" "SubnetIds=$subnet_ids" ...
```
This means the Lambda's VPC configuration and IAM role are never hardcoded in the SAM template — they come from Terraform outputs stored in SSM, creating a clean Terraform → SSM → SAM pipeline.

### Why separate Secrets Manager (sensitive) from SSM (config)?

**Secrets Manager:** supports automatic rotation, mandatory KMS encryption, richer audit trail, higher cost ($0.40/secret/month). Use for passwords, connection strings, API keys.

**SSM Parameter Store:** free for String type, no rotation, optional encryption. Use for Cognito pool IDs, bucket names, model names — things that need to be config-manageable but are not confidential.

---

## 13. AWS Lambda + AWS SAM

### What is Lambda?

**Lambda** is AWS's serverless compute service. You provide code and a trigger; AWS runs the code when the trigger fires — no server to provision, patch, or maintain. You pay per millisecond of execution, not for idle time. Perfect for event-driven, short-lived, stateless workloads.

### What is SAM?

**Serverless Application Model** is AWS's framework for defining Lambda functions as code. A `template.yaml` (a CloudFormation extension with the `Transform: AWS::Serverless-2016-10-31` macro) describes the function, its triggers, environment variables, and VPC config. `sam build` packages the code; `sam deploy` creates or updates the CloudFormation stack.

### How the AI Lambda is configured in LabLumen

**Trigger:** EventBridge rule — when a new object is created in the reports S3 bucket, EventBridge fires the Lambda.

**Runtime:** Python 3.12 | Memory: 512 MB | Timeout: 60 seconds

**VPC configuration:** The Lambda runs **inside the VPC** in private subnets with a dedicated security group. Required because RDS PostgreSQL only accepts connections from within the VPC CIDR. Running in a VPC adds a ~100ms cold start overhead due to ENI (Elastic Network Interface) attachment.

**IAM execution role permissions:**
- `textract:DetectDocumentText` — OCR
- `sts:AssumeRole` on the Bedrock cross-account role — AI inference
- `s3:GetObject` on the reports bucket — read the PDF
- `secretsmanager:GetSecretValue` on `lablumen/app/database-url` — get DB DSN at cold start
- `kms:Decrypt` on the platform CMK — decrypt the Secrets Manager value

**The AI processing pipeline per invocation:**
```
S3 ObjectCreated → EventBridge → Lambda cold start (if needed):
  ├─ Secrets Manager: fetch database-url DSN (cached for environment lifetime)
  └─ STS AssumeRole: create Bedrock client in cross-account (cached)

For each S3 object:
  1. resolve_report_id(s3_key) → SELECT report_id FROM lab_reports WHERE s3_url = key
  2. Textract detect_document_text(bucket, key) → raw text lines
  3. Bedrock Nova Lite converse() → plain-language summary (600 tokens, temp 0.2)
  4. chunk_text(raw_text) → ≤800-char paragraph-aware chunks
  5. For each chunk: Bedrock Titan Embed invoke_model() → 1536-dim vector
  6. psycopg3 (sync):
     UPDATE lab_reports SET ai_layman_summary = <summary> WHERE report_id = <id>
     INSERT INTO report_embeddings (report_id, chunk_content, embedding) VALUES ...
```

**SAM CI flow (GitHub Actions, on push to main):**
1. Assume `lablumen-ai-lambda-deploy` role via OIDC
2. Read VPC/role params from SSM (subnet IDs, SG ID, execution role ARN, Bedrock cross-account ARN)
3. `sam build --use-container` — builds in a Lambda-matching container for binary compatibility (critical for psycopg3's C extension)
4. `sam deploy --stack-name lablumen-ai --parameter-overrides ...` — CloudFormation creates/updates the stack

### Defence questions

**"Why Lambda for AI processing instead of a Kubernetes pod?"**
The AI processing is a batch job triggered by an event, not a long-running server. It needs to run once per report upload and complete within 60 seconds. If you ran this inside a Kubernetes pod, you'd need a queue + worker pod constantly polling for work. The pod would sit idle most of the time burning node CPU/memory. Lambda + EventBridge is precisely the architecture designed for event-driven, short-lived, stateless processing.

**"Why SAM instead of managing the Lambda via Terraform?"**
SAM's `--use-container` build compiles dependencies in a container matching the Lambda runtime, ensuring OS-level binary compatibility (crucial for psycopg3's C extension, which must match the Lambda OS). Additionally, SAM handles the CloudFormation transform macros that wire the EventBridge trigger to the function automatically. The split is intentional: Terraform owns durable infrastructure (VPC, RDS, S3, IAM roles); SAM owns the transient compute artifact.

**"Why doesn't the Lambda use psycopg async?"**
Lambda's `lambda_handler` function is synchronous — AWS invokes it as a plain Python function, not a coroutine. There is no running event loop into which to await async psycopg calls. The Lambda uses `psycopg` (sync) directly, while the EKS services use `asyncpg` via SQLAlchemy async (which do have an event loop via uvicorn/FastAPI).

---

## 14. Amazon Bedrock

### What is Amazon Bedrock?

**Amazon Bedrock** is a managed API for calling foundational AI (large language) models. Instead of running GPU instances yourself, you make HTTPS API calls. Bedrock provides access to models from Amazon, Anthropic, Meta, Mistral, Cohere, and others.

### Models used in LabLumen

**Amazon Titan Embed Text v1 (`amazon.titan-embed-text-v1`)**

An embedding model. It converts text into a 1536-dimensional vector (array of 1536 floats). Texts with similar meaning produce vectors that are close together in that 1536-dimensional space. Called via `bedrock.invoke_model()`.

Used in:
- AI Lambda: each text chunk of an OCR'd report → 1536-dim vector stored in `report_embeddings`
- report-service: each patient question → 1536-dim vector used for cosine similarity search

**Amazon Nova Lite v1 (`amazon.nova-lite-v1:0`)**

A fast, cost-efficient text generation model. Accepts a system prompt + conversation history + user message and generates a response. Called via the `bedrock.converse()` API (unified multi-turn conversation interface).

Used in:
- AI Lambda: generates the plain-language `ai_layman_summary` (600 tokens, temperature 0.2)
- report-service: answers patient questions in the chat interface (1024 tokens, temperature 0.2)

### RAG (Retrieval-Augmented Generation) — the chat feature explained

When a patient asks a question about their lab report, the system does NOT just ask Nova Lite "what does a high WBC count mean?" That would produce generic medical information, not answers grounded in this specific patient's results.

Instead:
1. The question is embedded with Titan Embed → 1536-dim question vector
2. pgvector finds the top-3 most semantically similar text chunks from this patient's report (`ORDER BY embedding <=> :qvec LIMIT 3` with the HNSW index)
3. The stored `ai_layman_summary` (full clinical picture) is prepended
4. Nova Lite receives: `[system prompt] + [report context + top-3 chunks] + [question] + [conversation history]`
5. Nova Lite answers only from what is in the context block — it cannot hallucinate facts from another patient's report

This is why the chat feels personalised: every answer is grounded in the actual numbers and text from that specific patient's PDF.

### Cross-account Bedrock

The org SCP (`p-rn6vr8ok`) restricts Bedrock calls to a separate AWS account (not the main application account). The Lambda assumes a cross-account role via STS `AssumeRole` at cold start to create a Bedrock client authenticated in that account. This is an org policy constraint, not a design choice — the architecture accommodates it cleanly.

### Defence questions

**"Why not use OpenAI GPT-4 or Gemini instead of Bedrock?"**

- **Data residency:** Patient health data (PHI) sent to OpenAI or Google servers creates HIPAA compliance concerns. Bedrock keeps all data within AWS.
- **IAM-controlled access:** Bedrock access is governed by IAM roles + SCPs. No API key that could be leaked in code or logs.
- **Cost model:** Bedrock on-demand charges per token, comparable to OpenAI, but stays within AWS billing.

**"Why Nova Lite and not a more powerful model?"**
Nova Lite is the only on-demand text model permitted under the org SCP. On-demand means no pre-provisioned throughput or capacity reservation commitment. For 600-token report summaries and 1024-token conversational answers about a lab report, Nova Lite is entirely sufficient — it handles medical terminology, plain-language explanation, and multi-turn conversation accurately.

**"Why not a fine-tuned model?"**
Fine-tuning requires a labelled dataset of (lab-report, plain-language-explanation) pairs. The RAG approach with a carefully crafted system prompt achieves similar personalisation without requiring training data, without re-deployment on model updates, and without the cost of fine-tuning infrastructure.

---

## 15. AWS Textract

### What is Textract?

**Textract** is AWS's managed OCR (Optical Character Recognition) service. It extracts text from documents — PDFs, PNGs, JPEGs, TIFFs — using machine learning. You pass it a reference to an S3 object and get back structured text.

### How it is configured in LabLumen

The AI Lambda calls `textract.detect_document_text()`:
```python
resp = textract.detect_document_text(
    Document={"S3Object": {"Bucket": bucket, "Name": key}}
)
lines = [b["Text"] for b in resp.get("Blocks", []) if b["BlockType"] == "LINE"]
text = "\n\n".join(lines)
```

`detect_document_text` is the **synchronous** API — the response comes back in one call, no polling. It processes a single page and returns `LINE` blocks (full text lines). The alternative `start_document_text_detection` is asynchronous (for multi-page documents) — it returns a job ID and you poll `get_document_text_detection`. For v1 of LabLumen, single-page documents are in scope; the async API is explicitly noted as out-of-scope.

Textract reads the S3 object **directly** using the Lambda's IAM role. The PDF bytes never flow through the Lambda's memory — Textract pulls them from S3 internally.

### Defence questions

**"Why Textract instead of a Python PDF text extraction library (pypdf, pdfplumber)?"**
Python PDF libraries extract the text layer that is embedded in the PDF's internal structure. This only works if the PDF was generated from a word processor or a digital system. A scanned document (a physical lab report printed and photographed) is just an image — there is no embedded text layer. Textract uses ML to detect text in images regardless of how the PDF was created, including handwriting, skewed scans, and blurry photos. For a lab platform where staff upload scanned physical reports, Textract is the correct tool.

**"Why not use AWS Rekognition for text detection?"**
Rekognition's `detect_text` API is designed for scene text in photographs (street signs, labels). Textract is specifically optimised for document layout — it understands paragraphs, tables, forms, and column alignment. For a structured medical lab report, Textract produces far cleaner output.

---

## 16. Amazon EventBridge

### What is EventBridge?

**EventBridge** is AWS's serverless event bus and routing layer. When something happens in AWS — an S3 object is created, an EC2 instance terminates, a Cognito user signs up — EventBridge emits a structured JSON event. You write **rules** that match events by pattern and route them to **targets** (Lambda, SQS, SNS, Step Functions, etc.).

### How it is configured in LabLumen

In the Terraform S3 module:
```terraform
resource "aws_s3_bucket_notification" "reports" {
  bucket      = module.reports_bucket.s3_bucket_id
  eventbridge = true   # all S3 events go to the default EventBridge bus
}
```

In the SAM `template.yaml`:
```yaml
Events:
  ReportUploaded:
    Type: EventBridgeRule
    Properties:
      Pattern:
        source: [aws.s3]
        detail-type: [Object Created]
        detail:
          bucket:
            name: [!Ref ReportsBucketName]  # only events from THIS bucket
```

SAM translates this into an EventBridge rule. When a new object appears in the reports bucket, EventBridge matches the event and invokes the AI Lambda.

### Defence questions

**"Why EventBridge instead of a direct S3-to-Lambda trigger?"**
S3 can trigger Lambda directly via an S3 notification. The differences:

| | S3 Direct Trigger | EventBridge |
|---|---|---|
| Fan-out | One Lambda per S3 notification config | Many rules, many targets for one event |
| Event filtering | Only by object key prefix/suffix | Full JSON pattern matching on any field |
| Replay | Not supported | EventBridge Archive supports event replay |
| Audit | No event log | All matched events visible in EventBridge |
| Future-proofing | Tight coupling | Add a virus scanner or thumbnail generator as a second rule without changing S3 config |

EventBridge is the AWS-recommended pattern for decoupled event-driven architectures. It costs the same as a direct trigger but provides far more architectural flexibility.

---

## 17. Amazon Route 53

### What is Route 53?

**Route 53** is AWS's managed DNS service. DNS translates human-readable names (`app.rnld101.xyz`) into IP addresses that browsers can connect to. Route 53 is named for TCP/UDP port 53, the standard DNS port.

### How it is configured in LabLumen

The hosted zone for `rnld101.xyz` was created **manually** (outside Terraform). Terraform only looks it up by name:
```terraform
data "aws_route53_zone" "primary" {
  name         = var.domain_name
  private_zone = false
}
```

**Records added by Terraform:**
- 3 DKIM CNAME records for SES email authentication (created by the SES module)

**Records managed dynamically by ExternalDNS (in-cluster Kubernetes controller):**
ExternalDNS watches Kubernetes Ingress objects and automatically creates/updates Route 53 A records pointing to the ALB DNS name. When an Ingress declares `host: app.rnld101.xyz`, ExternalDNS creates:
```
app.rnld101.xyz → ALIAS → lablumen-alb-xxx.us-east-1.elb.amazonaws.com
```

ExternalDNS uses IRSA — it has `route53:ChangeResourceRecordSets` scoped specifically to the `rnld101.xyz` hosted zone. It uses `upsert-only` policy (never deletes records it didn't create), `txt` registry (writes a TXT record alongside each A record as an ownership marker), and `lablumen-eks` as the owner ID.

**Live DNS records (created by ExternalDNS):**
- `app.rnld101.xyz` → ALB (frontend, React SPA)
- `api.rnld101.xyz` → ALB (backend API services)
- `grafana.rnld101.xyz` → ALB (Grafana monitoring)
- `argocd.rnld101.xyz` → ALB (ArgoCD UI)

### Defence questions

**"Why ExternalDNS instead of creating Route 53 records in Terraform?"**
Terraform-managed DNS records would mean: every time a new service is deployed or the ALB is replaced (e.g., after a cluster rebuild), someone must update Terraform and re-apply. ExternalDNS automates this — any developer who creates a correctly annotated Ingress gets DNS automatically, without touching Terraform. It follows the GitOps principle: the Ingress YAML is the source of truth, not a Terraform plan.

---

## 18. AWS Certificate Manager (ACM)

### What is ACM?

**Certificate Manager** provisions free SSL/TLS certificates for your domains. HTTPS requires a valid certificate; without it, browsers show a security warning and refuse to load the page. ACM certificates are used directly by AWS services (ALB, CloudFront) — you cannot download them and install them on a server.

### How it is configured in LabLumen

The certificate for `*.rnld101.xyz` (wildcard, covers all subdomains) was created **manually** and is only looked up by Terraform:
```terraform
data "aws_acm_certificate" "primary" {
  domain   = "*.rnld101.xyz"
  statuses = ["ISSUED"]    # must be ISSUED before terraform apply can proceed
  most_recent = true
}
```

The ALB Ingress annotations reference the ACM certificate ARN. The AWS Load Balancer Controller wires the certificate to the ALB's HTTPS listener (port 443). TLS is **terminated at the ALB** — the ALB decrypts HTTPS and forwards plain HTTP to the backend pods on port 80 (SSL offloading). All communication from browsers is encrypted; internal pod-to-pod traffic within the VPC is unencrypted.

A wildcard certificate covers `app.rnld101.xyz`, `api.rnld101.xyz`, `grafana.rnld101.xyz`, and `argocd.rnld101.xyz` with a single certificate — no new cert issuance needed when adding a subdomain.

### Defence questions

**"Why not use cert-manager with Let's Encrypt?"**
cert-manager is a Kubernetes controller that automatically issues and renews Let's Encrypt certificates. However: ACM certificates are free and renewed by AWS with no action required; ALB HTTPS termination is trivial (one annotation) when using ACM; cert-manager would require each pod to handle TLS termination itself, adding CPU overhead and configuration complexity. For a project using the AWS Load Balancer Controller, ACM is the simpler and correct choice.

**"Why TLS termination at the ALB and not end-to-end encryption?"**
End-to-end encryption (from browser → ALB → pod → pod) requires each service to have a certificate and handle TLS, which multiplies complexity. The VPC is a private, controlled network — traffic between the ALB and pods is not exposed to the internet. ALB termination is the standard pattern for web applications running in AWS. Mutual TLS (mTLS) between services inside the cluster would be appropriate for zero-trust environments, typically via a service mesh like Istio.

---

## 19. AWS IAM + OIDC + IRSA

### What is IAM?

**Identity and Access Management** is AWS's permission system. Every AWS API call is authenticated (who are you?) and authorised (are you allowed to do this?). IAM policies grant or deny specific actions on specific resources to specific principals (roles, users, services).

### The two key IAM patterns in LabLumen

**Pattern 1: GitHub Actions OIDC Federation (no static credentials anywhere)**

The traditional approach: create an IAM user, generate an access key + secret, paste them into GitHub Secrets. Problems: the secret never expires, it can be leaked in logs, and rotating it requires manual coordination.

**OIDC federation eliminates static credentials entirely:**
1. GitHub Actions issues each running workflow a short-lived JWT signed by `token.actions.githubusercontent.com`
2. The workflow calls STS `AssumeRoleWithWebIdentity` presenting this JWT
3. AWS verifies the JWT signature against GitHub's public JWKS
4. If the JWT's `sub` claim matches the IAM role's trust policy conditions, STS returns **temporary credentials** (valid for 1 hour, then expired)

Trust policies are scoped tightly to prevent one repo from assuming another repo's role:
- `lablumen-tf-plan` role → only the terraform repo, on PR or push to main
- `lablumen-tf-apply` role → only the terraform repo, in the `production` GitHub Environment (requires manual reviewer approval)
- `lablumen-app-ci-ecr` role → only the 3 backend service repos (appointment, report, notification)
- `lablumen-frontend-build` role → only the frontend repo
- `lablumen-ai-lambda-deploy` role → only the AI service repo

**Pattern 2: IRSA — IAM Roles for Service Accounts (pod-level AWS permissions)**

Without IRSA, the only way for a pod to call AWS is via the EC2 node's IAM instance profile — meaning every pod on that node shares the same AWS permissions. If one pod is compromised, the attacker gets the permissions of every other pod on the same node.

IRSA makes permissions **pod-level, not node-level:**
1. EKS has an OIDC provider (a URL like `oidc.eks.us-east-1.amazonaws.com/id/XXX`)
2. A Kubernetes ServiceAccount is annotated with an IAM role ARN: `eks.amazonaws.com/role-arn: arn:...`
3. When a pod using that ServiceAccount starts, the EKS node injects a short-lived JWT into the pod's filesystem (a projected volume)
4. The AWS SDK in the pod automatically exchanges that JWT for temporary credentials via STS
5. The IAM role's trust policy only allows this specific Kubernetes namespace + service account — no other pod can assume the role

**IRSA roles in LabLumen:**

| IAM Role | ServiceAccount | Permissions |
|---|---|---|
| `lablumen-report-service` | `lablumen/report-service` + `lablumen-dev/report-service` | S3 GetObject+PutObject on reports bucket, Bedrock InvokeModel |
| `lablumen-notification-service` | `lablumen/notification-service` + `lablumen-dev/notification-service` | SQS ReceiveMessage+DeleteMessage+GetQueueAttributes, SES SendEmail |
| `lablumen-eso` | `external-secrets/lablumen-eso` | SM GetSecretValue on `lablumen/app/*`, SSM GetParameter on `/lablumen/config/*`, KMS Decrypt |
| `lablumen-lbc` | `kube-system/aws-load-balancer-controller` | Full LBC policy (manage ALBs, target groups, listeners, WAF) |
| `lablumen-external-dns` | `kube-system/external-dns` | Route 53 ChangeResourceRecordSets in the hosted zone |
| Karpenter controller | `kube-system/karpenter` | EC2 launch/terminate/describe, SQS for interruption queue |

**appointment-service has no IRSA** — it connects to RDS via the DATABASE_URL environment variable (populated by ESO from Secrets Manager) and to Redis via an in-cluster Service DNS name. It publishes to SQS via the queue URL (from SSM via ESO), relying on the node's ambient credentials for SQS send. A more security-hardened design would give appointment-service an IRSA role scoped to `sqs:SendMessage` on the notifications queue — this is a known improvement point.

### Defence questions

**"Why OIDC federation over IAM users for CI/CD?"**
IAM user credentials are long-lived static secrets. A developer with access to the CI system can extract and misuse them. OIDC credentials last 1 hour and are bound to the specific GitHub repository and branch/environment — they cannot be extracted and reused outside of a running GitHub Actions job. This is the current AWS-recommended standard for CI/CD.

**"Why IRSA over kube2iam or kiam?"**
kube2iam and kiam are older projects that intercept EC2 metadata API calls from pods to dynamically swap credentials. They are fragile (race conditions, bypass vulnerabilities) and add network complexity. IRSA is AWS's native, supported solution that works at the pod level using projected service account tokens — no network interception required.

---

## 20. Application Load Balancer (ALB)

### What is an ALB?

An **Application Load Balancer** is a layer-7 (HTTP/HTTPS) load balancer managed by AWS. It receives incoming requests from the internet, terminates TLS, and forwards HTTP requests to the appropriate backend pods in EKS based on path or host routing rules.

### How it is configured in LabLumen

The ALB is **not created by Terraform** — it is created automatically by the **AWS Load Balancer Controller** (a Kubernetes controller) when it sees an Ingress object with `ingressClassName: alb`.

**Key Ingress annotations:**
```yaml
alb.ingress.kubernetes.io/scheme: internet-facing      # public ALB in public subnets
alb.ingress.kubernetes.io/target-type: ip              # routes directly to pod IPs (not node ports)
alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'  # only accept encrypted traffic
alb.ingress.kubernetes.io/group.name: lablumen          # all Ingresses share one ALB
alb.ingress.kubernetes.io/group.order: "..."            # priority for path matching
```

**Shared ALB (IngressGroup):** All four Ingress objects (appointment-service, report-service, frontend, grafana) share one ALB via `alb.ingress.kubernetes.io/group.name: lablumen`. Path routing rules:
- `/api/v1/reports/...` → report-service (groupOrder 10 — higher priority)
- `/api/v1/...` → appointment-service (groupOrder 100)
- `/` → frontend (groupOrder 100 — catch-all)
- `grafana.rnld101.xyz` → Grafana (groupOrder 210)

This consolidates all services behind one ALB, reducing cost (ALBs are charged per hour + per LCU).

**Target type: ip** — The ALB routes directly to pod IP addresses, bypassing the EC2 node's kube-proxy. This is the correct mode for EKS + VPC CNI, which assigns each pod a real VPC IP address.

**ExternalDNS** then creates a Route 53 A record pointing `app.rnld101.xyz` to the ALB's DNS name.

### Defence questions

**"Why not use an NLB (Network Load Balancer)?"**
An NLB operates at layer 4 (TCP/IP) and cannot inspect HTTP headers or paths. The ALB's path-based routing (`/api/v1/reports` → report-service, `/api/v1/` → appointment-service) requires layer-7 awareness. NLBs are appropriate when you need TCP load balancing for non-HTTP traffic (databases, raw TCP streams).

**"Why not use API Gateway in front of the services?"**
API Gateway adds request transformation, throttling, usage plans, and mock responses. For a microservices platform where the backend already handles authentication (Cognito JWT), rate limiting is not yet needed, and the services speak standard REST — API Gateway would add a layer of complexity and cost without benefit. The ALB provides path routing and SSL termination, which is all that is needed.

---

## 21. AWS CloudWatch

### What is CloudWatch?

**CloudWatch** is AWS's observability service — it collects logs, metrics, and alarms from AWS services and applications. In LabLumen, CloudWatch is used specifically for **EKS control-plane logging**.

### How it is configured in LabLumen

```terraform
cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
cloudwatch_log_group_retention_in_days = 14
```

Every action on the EKS API server (pod creation, authentication attempts, RBAC decisions) is logged to CloudWatch Logs under `/aws/eks/lablumen-eks/cluster`. These logs are:
- `api` — all API server requests
- `audit` — who did what to which Kubernetes object
- `authenticator` — Cognito/OIDC/IAM authentication events
- `controllerManager` — node lifecycle events
- `scheduler` — pod scheduling decisions

**14-day retention** — logs older than 14 days are automatically expired, controlling cost.

**Lambda logs** are automatically captured to CloudWatch by the Lambda runtime (the execution role has `AWSLambdaVPCAccessExecutionRole` which includes CloudWatch Logs permissions).

**Application-level observability** in-cluster is handled by **kube-prometheus-stack** (Prometheus + Grafana), not CloudWatch. This is a deliberate choice: Prometheus stores metrics inside the cluster (ephemeral, 2-day retention) while CloudWatch stores the control-plane audit trail outside the cluster.

### Defence questions

**"Why not use CloudWatch for application metrics too?"**
CloudWatch Container Insights can collect pod-level metrics, but it requires the CloudWatch agent running as a DaemonSet and costs per metric ingested. Prometheus is free (for in-cluster storage) and is the CNCF-standard observability stack that works with any Kubernetes cluster. Grafana dashboards for Kubernetes are widely available as pre-built community templates. For an organisation that might move away from AWS one day, Prometheus/Grafana is more portable.

---

## 22. AWS STS

### What is STS?

**Security Token Service** issues temporary security credentials. Every `AssumeRole` call goes through STS — it verifies the caller's identity and, if authorised, returns a temporary access key, secret, and session token valid for a configurable duration (15 minutes to 12 hours).

### Where STS is used in LabLumen

1. **GitHub Actions OIDC → STS AssumeRoleWithWebIdentity** — each CI job exchanges its GitHub-issued JWT for temporary AWS credentials
2. **IRSA → STS AssumeRoleWithWebIdentity** — each EKS pod with an IRSA-annotated ServiceAccount exchanges its projected K8s token for temporary AWS credentials
3. **Lambda cross-account Bedrock → STS AssumeRole** — the Lambda assumes an IAM role in the Bedrock-enabled account at cold start to create a Bedrock client

In case 3, the STS response (access key, secret, session token) is cached as the Bedrock boto3 client at module level — the client persists for the Lambda execution environment's lifetime (hours to days), and only a new cold start requires a new `AssumeRole` call.

---

## 23. AWS CloudFormation

### What is CloudFormation?

**CloudFormation** is AWS's native infrastructure-as-code service — similar to Terraform but AWS-only. SAM is built on top of CloudFormation. When you run `sam deploy`, SAM transforms the `template.yaml` into a CloudFormation template and creates/updates a **CloudFormation stack** named `lablumen-ai`.

### Where CloudFormation is used in LabLumen

CloudFormation is not used directly — SAM abstracts it. However, CloudFormation manages:
- The Lambda function resource
- The EventBridge rule
- The Lambda log group
- IAM passRole (SAM handles `iam:PassRole` automatically)

The `lablumen-ai-lambda-deploy` IAM role (assumed by GitHub Actions CI) has `cloudformation:*` scoped to stacks named `lablumen-ai*`, giving the CI pipeline permission to create/update/describe/delete only the AI stack — not any other CloudFormation stack.

---

## 24. VPC Endpoints (PrivateLink)

### What are VPC Endpoints?

By default, when a pod in a private subnet calls an AWS API (S3, SQS, ECR, Secrets Manager), the request routes through the NAT Gateway to the public internet, then to the AWS API's public endpoint. VPC Endpoints let you keep that traffic entirely within AWS's private network — no NAT Gateway, no internet traversal, lower latency, reduced cost.

### What is configured in LabLumen

**Gateway Endpoint (free — uses route table, no ENI):**
- S3 — all S3 traffic from private subnets goes directly to S3 without touching the NAT Gateway

**Interface Endpoints (cost: ~$7/month/endpoint — creates private ENIs):**
- `ssm` — SSM Parameter Store API (used by ESO and Lambda CI)
- `secretsmanager` — Secrets Manager API (used by ESO and Lambda)
- `bedrock-runtime` — Bedrock API (used by report-service and Lambda)
- `textract` — Textract API (used by Lambda)
- `ecr.api` + `ecr.dkr` — ECR APIs (used by EKS nodes to pull images)
- `logs` — CloudWatch Logs (used by Lambda and EKS for log streaming)
- `sqs` — SQS API (used by notification-service and Karpenter interruption queue)

**Why this matters:**
- Traffic to Secrets Manager, Bedrock, and ECR never leaves AWS's network — critical for PHI handling
- ECR image pulls do not consume NAT Gateway bandwidth (ECR images can be hundreds of MB per pull)
- The SQS endpoint means appointment-service's fire-and-forget SQS publish and notification-service's long-poll both go through PrivateLink — no internet exposure of notification data

---

## 25. Full Application Flow — Everything Together

This section traces every AWS service interaction across the four key user journeys.

---

### Journey 1: Patient Registers and Logs In

```
Browser → Cognito User Pool (SRP signup + email verification code)
  Cognito sends verification email via SES (or Cognito's built-in mechanism)
  User enters code → Cognito confirms account

Browser → Cognito SRP login flow
  Cognito returns ID token (JWT, RS256 signed, contains sub + email + cognito:groups=PATIENT)
  Frontend stores ID token in localStorage
```

No backend microservice is involved in login. Cognito handles it entirely.

---

### Journey 2: Patient Books an Appointment

```
Browser → POST /api/v1/appointments  (Authorization: Bearer <cognito_id_token>)
    ↓
Route 53 (app.rnld101.xyz → ALB DNS name)
    ↓
ALB (HTTPS 443, terminates TLS via ACM cert, routes to frontend target group)
    ↓
nginx pod (frontend container in EKS, namespace lablumen)
  nginx matches /api/v1/ → proxy_pass http://appointment-service
    ↓
appointment-service pod (IRSA: none, uses node credentials for SQS)
  [1] Cognito JWKS (cached): verify JWT signature, extract sub + email + cognito:groups
  [2] RDS Postgres (via DATABASE_URL from K8s Secret = ESO from Secrets Manager):
      INSERT INTO users (user_id, email) ON CONFLICT DO NOTHING
  [3] Redis (in-cluster Service DNS "redis:6379"):
      SET slot-lock:<date>T<time> 1 NX EX 300   ← acquire lock, returns True/False
  [4] RDS Postgres:
      INSERT INTO appointments (account_owner_id, date, time_slot, status='Booked')
      INSERT INTO appointment_test_mapping (appointment_id, test_id, patient_id, price_at_booking)
  [5] Redis: DEL slot-lock:<date>T<time>   ← release lock
  [6] SQS (via VPC Endpoint):
      send_message({ type: "appointment.booked", to_email: patient@..., data: {...} })
      [fire-and-forget — failure is caught, logged, and swallowed]
  ← 201 Created { appointment_id, date, time_slot, status }
    ↓
Browser shows booking confirmation toast
```

---

### Journey 3: Notification Email is Sent

```
SQS queue "lablumen-notifications" holds the "appointment.booked" message
    ↓
notification-service pod (IRSA: lablumen-notification-service)
  Background coroutine running consume_forever():
  [1] SQS (via VPC Endpoint, IRSA creds):
      receive_message(WaitTimeSeconds=20, MaxNumberOfMessages=10)
      [long-poll: holds connection 20s if queue empty]
  [2] Parse body as NotificationEvent (pydantic)
  [3] SES (via VPC Endpoint or NAT, IRSA creds):
      send_email(Source="no-reply@rnld101.xyz", To=patient@..., Subject="Your appointment is confirmed")
      [SES uses DKIM to sign the email — Route 53 has the CNAME records for verification]
  [4] SQS: delete_message(receipt_handle)   ← only after successful send
    ↓
Patient receives email from no-reply@rnld101.xyz
```

---

### Journey 4: Staff Uploads a Lab Report and AI Processes It

```
Staff browser → POST /api/v1/reports/upload (multipart form, PDF, mapping_id)
    ↓
ALB → nginx → report-service pod (IRSA: lablumen-report-service)
  [1] Cognito JWKS: verify JWT, confirm cognito:groups contains LAB_STAFF
  [2] RDS Postgres: SELECT mapping_id FROM appointment_test_mapping WHERE mapping_id = :mid  (exists check)
  [3] RDS Postgres: SELECT report_id FROM lab_reports WHERE mapping_id = :mid  (no duplicate check)
  [4] S3 (IRSA creds, via VPC Gateway Endpoint):
      put_object(bucket=lablumen-reports-<acct>, key=reports/<uuid>.pdf, body=<pdf_bytes>)
  [5] RDS Postgres:
      INSERT INTO lab_reports (report_id, mapping_id, s3_url=reports/<uuid>.pdf)
      UPDATE appointments SET status='Completed'
          WHERE appointment_id = (this appointment)
          AND all tests in it now have reports  [auto-complete on all-reports-done]
  ← 201 { report_id, status: "uploaded" }
Staff sees report uploaded; patient appointment flips to Completed
```

Concurrently, S3 fires an event:
```
S3 ObjectCreated event → EventBridge default bus (eventbridge=true on the bucket)
    ↓
EventBridge rule (SAM-created): source=aws.s3, detail-type=Object Created, bucket=lablumen-reports-<acct>
    ↓
Lambda function "lablumen-ai-AiProcessingFunction" (cold start if not warm):
  Cold start:
  [1] Secrets Manager (IRSA creds, via VPC Endpoint):
      get_secret_value("lablumen/app/database-url") → DSN (cached in module-level var)
  [2] STS AssumeRole (cross-account Bedrock role) → temp Bedrock credentials (cached as boto3 client)

  Per-invocation processing:
  [3] RDS Postgres (psycopg sync):
      SELECT report_id FROM lab_reports WHERE s3_url = 'reports/<uuid>.pdf'
  [4] Textract (via VPC Endpoint):
      detect_document_text(S3Object={Bucket, Key}) → list of LINE blocks → joined text
  [5] Bedrock Converse API (via VPC Endpoint, cross-account creds):
      Nova Lite: summarize(text) → plain-language 600-token summary
  [6] chunk_text(text) → 5-15 paragraph chunks of ≤800 chars each
  [7] For each chunk: Bedrock InvokeModel (Titan Embed):
      embed_text(chunk) → [f1, f2, ..., f1536]  (1536-dim vector)
  [8] RDS Postgres (psycopg sync):
      UPDATE lab_reports SET ai_layman_summary = <summary> WHERE report_id = <id>
      INSERT INTO report_embeddings (report_id, chunk_content, embedding) VALUES (...) × N
  Lambda returns { status: "ok" }
    ↓
Patient refreshes the Reports page and sees the AI summary is now available
```

---

### Journey 5: Patient Reads and Chats About Their Report

```
Browser → GET /api/v1/reports/<report_id>/view
    ↓
ALB → nginx (/api/v1/reports → report-service)
    ↓
report-service (IRSA: lablumen-report-service)
  [1] Cognito JWKS: verify JWT, extract sub
  [2] RDS Postgres: SELECT s3_url FROM lab_reports
      JOIN appointment_test_mapping ... JOIN appointments ...
      WHERE report_id = :rid AND a.account_owner_id = :sub
      [access control: patients can only view their own reports]
  [3] S3 generate_presigned_url(bucket, key, ExpiresIn=120, signature=SigV4)
      [S3 client configured with signature_version='s3v4' — required for KMS-encrypted objects]
  ← { url: "https://lablumen-reports-<acct>.s3.amazonaws.com/reports/<uuid>.pdf?X-Amz-Signature=...", expires_in: 120 }
    ↓
Browser fetches PDF directly from S3 via the presigned URL (2-minute TTL)
PDF renders in the browser iframe/viewer
```

Patient types a question in the chat:
```
Browser → POST /api/v1/reports/<report_id>/chat { question: "Is my haemoglobin low?", history: [...] }
    ↓
report-service
  [1] Cognito JWT verify + access control check (same as above)
  [2] Bedrock InvokeModel (Titan Embed, via VPC Endpoint, IRSA creds):
      embed_text("Is my haemoglobin low?") → question_vector [1536 floats]
  [3] RDS Postgres pgvector:
      SELECT ai_layman_summary FROM lab_reports WHERE report_id = :rid
      SELECT chunk_content FROM report_embeddings
          WHERE report_id = :rid
          ORDER BY embedding <=> :question_vector   [cosine similarity via HNSW index]
          LIMIT 3
  [4] Build context: summary + top-3 chunks
  [5] Bedrock Converse API (Nova Lite, via VPC Endpoint, IRSA creds):
      system=[lab nurse persona + strict rules]
      messages=[...conversation history..., {role:user, content: context + question}]
      inferenceConfig={maxTokens:1024, temperature:0.2}
  ← { answer: "Yes, your haemoglobin at 10.2 g/dL is below the normal range of 12–16...", disclaimer: "..." }
    ↓
AI response appears in the chat panel, grounded in the patient's actual report
```

---

## Summary: Every AWS Service at a Glance

| AWS Service | Category | What LabLumen uses it for |
|---|---|---|
| **VPC** | Networking | 3-tier network isolation: public (ALB), private (EKS/Lambda), database (RDS) |
| **EKS** | Compute | Kubernetes cluster running all containerised services |
| **EC2** | Compute | EKS worker nodes (t3.medium) — managed by EKS + Karpenter |
| **Karpenter** | Compute | Dynamic node autoscaling — provisions/removes nodes in seconds |
| **RDS (PostgreSQL)** | Database | Managed Postgres with pgvector for relational data + vector similarity |
| **S3** | Storage | Private encrypted report storage; Terraform state; SAM artifacts |
| **KMS** | Security | CMK encrypting ECR images, Secrets Manager values, S3 reports |
| **ECR** | Registry | Private Docker image registry for all 4 containerised services |
| **Cognito** | Auth | User Pool, SRP login, JWT issuance, group-based RBAC |
| **SQS** | Messaging | Decouples appointment-service (producer) from notification-service (consumer) |
| **SES** | Email | Sends booking confirmations and report-ready emails with DKIM |
| **Secrets Manager** | Secrets | Database DSN and Grafana credentials (KMS-encrypted, never in state) |
| **SSM Parameter Store** | Config | 15 non-sensitive config values (SQS URL, Cognito IDs, model names) |
| **Lambda** | Serverless | AI processing pipeline: OCR → summary → embeddings, triggered by S3 |
| **Bedrock** | AI | Nova Lite (text generation) + Titan Embed (embeddings) |
| **Textract** | AI/OCR | Extracts text from lab report PDFs and scanned images |
| **EventBridge** | Events | Routes S3 ObjectCreated events to the AI Lambda |
| **Route 53** | DNS | Hosted zone for rnld101.xyz; DKIM records; records managed by ExternalDNS |
| **ACM** | Certificates | Wildcard TLS cert for *.rnld101.xyz, used by the ALB for HTTPS |
| **IAM + OIDC + IRSA** | Identity | Pod-level AWS permissions; GitHub Actions OIDC federation (no static keys) |
| **ALB** | Load Balancing | Internet-facing HTTPS load balancer; path routing; TLS termination |
| **CloudWatch** | Observability | EKS control-plane logs (API, audit, authenticator); Lambda logs |
| **STS** | Identity | Temporary credentials for OIDC federation, IRSA, and cross-account Bedrock |
| **CloudFormation** | IaC | SAM uses it to create/update the `lablumen-ai` Lambda stack |
| **VPC Endpoints** | Networking | PrivateLink for S3, SQS, ECR, Secrets Manager, Bedrock, Textract, CloudWatch |
