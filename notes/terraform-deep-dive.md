# LabLumen — Terraform Deep Dive

> This document teaches the entire Terraform layer of LabLumen from first principles. Every concept, every file, every module, every design decision — explained so you can defend every line in front of a senior DevOps engineer or solutions architect.

---

## Table of Contents

1. [What is Terraform? — The Mental Model](#1-what-is-terraform--the-mental-model)
2. [Repository Structure — What Lives Where](#2-repository-structure--what-lives-where)
3. [The State Problem — backend.tf & bootstrap/](#3-the-state-problem--backendtf--bootstrap)
4. [versions.tf — Provider Pinning](#4-versionstf--provider-pinning)
5. [providers.tf — Configuring the Two Providers](#5-providerstf--configuring-the-two-providers)
6. [variables.tf — The Input Interface](#6-variablestf--the-input-interface)
7. [locals.tf — Derived, Account-Portable Values](#7-localstf--derived-account-portable-values)
8. [data.tf — Looking Up Pre-Existing Resources](#8-datatf--looking-up-pre-existing-resources)
9. [terraform.tfvars — The Single Config File](#9-terraformtfvars--the-single-config-file)
10. [main.tf — The Orchestrator](#10-maintf--the-orchestrator)
11. [Module Deep Dives](#11-module-deep-dives)
    - [modules/vpc](#modulesvpc)
    - [modules/eks](#moduleseks)
    - [modules/rds](#modulesrds)
    - [modules/s3](#moduless3)
    - [KMS (inline in main.tf)](#kms-inline-in-maintf)
    - [modules/ecr](#modulesecr)
    - [modules/cognito](#modulescognito)
    - [modules/sqs](#modulessqs)
    - [modules/ses](#modulesses)
    - [modules/secretsmanager](#modulessecretsmanager)
    - [modules/ssm](#modulesssm)
    - [modules/iam](#modulesiam)
12. [kubernetes.tf — The Cross-Provider Bridge](#12-kubernetestf--the-cross-provider-bridge)
13. [outputs.tf — The Handshake Layer](#13-outputstf--the-handshake-layer)
14. [The CI/CD Pipeline — terraform.yml](#14-the-cicd-pipeline--terraformyml)
15. [The Destroy Workflow — terraform-destroy.yml](#15-the-destroy-workflow--terraform-destroyyml)
16. [Checkov — IaC Security Scanning](#16-checkov--iac-security-scanning)
17. [Infracost — Cost Estimation in PRs](#17-infracost--cost-estimation-in-prs)
18. [Module Dependency Graph](#18-module-dependency-graph)
19. [Key Design Decisions & Defences](#19-key-design-decisions--defences)

---

## 1. What is Terraform? — The Mental Model

Terraform is an **Infrastructure as Code (IaC)** tool. Instead of clicking through the AWS console to create a VPC, you write code that describes the infrastructure you want. Terraform figures out in what order to create it, what already exists (and therefore doesn't need to be created), and what needs to be destroyed when you remove it.

### The three operations

```
terraform plan    → read current state + read your code → compute the DIFF (what needs to change)
terraform apply   → execute the plan (create/update/destroy AWS resources)
terraform destroy → tear down everything Terraform created
```

### The reconciliation model

Terraform has three sources of truth:
1. **Your code** — what you want the world to look like
2. **State file** — what Terraform believes the world looks like right now
3. **Real world** — what AWS actually has

`terraform plan` compares #1 (code) against #2 (state), then calls AWS to verify #3 (real world) against #2. The output is a plan: "I will create X, update Y, destroy Z." `terraform apply` executes that plan and updates the state file to match.

### Why state matters

Without state, Terraform cannot know that the VPC it created last week with CIDR `10.0.0.0/16` is the same VPC you have in your code. The state file is the memory of what Terraform created. **Losing the state file = losing the ability to manage your infrastructure safely.**

### What Terraform is NOT

Terraform does not configure software inside servers. It creates the AWS infrastructure (VPCs, EKS, RDS). What runs inside the cluster (ArgoCD, your services) is handled by ArgoCD and Kubernetes manifests. The boundary is explicit: Terraform owns AWS resources; Kubernetes/ArgoCD owns cluster resources.

---

## 2. Repository Structure — What Lives Where

```
lablumen-terraform/
├── backend.tf               ← Where to store the state file (S3)
├── versions.tf              ← Which Terraform/provider versions to use
├── providers.tf             ← Configure the AWS and Kubernetes providers
├── variables.tf             ← All input variables (the interface)
├── locals.tf                ← Computed values derived from variables
├── data.tf                  ← Look up pre-existing AWS resources
├── terraform.tfvars         ← Concrete values for all variables (committed to Git)
├── main.tf                  ← Root module: calls all child modules + inline resources
├── kubernetes.tf            ← Kubernetes resources (namespaces + ServiceAccounts)
├── outputs.tf               ← Values to expose after apply
│
├── modules/
│   ├── vpc/                 ← VPC, subnets, NAT GW, VPC endpoints
│   ├── eks/                 ← EKS cluster + Karpenter supporting resources
│   ├── rds/                 ← PostgreSQL instance + security group
│   ├── s3/                  ← Reports bucket + SAM artifacts bucket
│   ├── ecr/                 ← Container image repositories
│   ├── cognito/             ← User Pool + App Client + Groups
│   ├── sqs/                 ← Notifications queue
│   ├── ses/                 ← Email domain identity + DKIM
│   ├── secretsmanager/      ← Empty secret shells
│   ├── ssm/                 ← Non-sensitive config parameters
│   └── iam/                 ← GitHub OIDC + pipeline roles + IRSA roles
│
├── bootstrap/
│   └── main.tf              ← One-time setup: creates the S3 state bucket
│
└── .github/workflows/
    ├── terraform.yml        ← CI pipeline: scan → plan → apply
    └── terraform-destroy.yml ← Guarded full teardown
```

Every child module follows the same internal structure:
```
modules/<name>/
  main.tf       ← resource definitions
  variables.tf  ← what the parent must pass in
  outputs.tf    ← what the parent can read back
```

---

## 3. The State Problem — backend.tf & bootstrap/

### The chicken-and-egg problem

Terraform needs somewhere to store the state file before it can create anything. But the S3 bucket that stores the state is itself infrastructure — you need Terraform to create it. So how does the first `terraform init` work if the bucket doesn't exist yet?

**The solution: the bootstrap stack**

The `bootstrap/` directory is a **separate, independent Terraform configuration** (its own `main.tf`, no backend block — it uses local state). You run it once, manually, to create the S3 state bucket:

```bash
cd bootstrap/
terraform init   # uses local state (no backend block)
terraform apply  # creates the S3 bucket
```

After this, the bucket exists. The root stack's `backend.tf` can now reference it, and `terraform init` in the root stack uploads state to S3.

### backend.tf — the S3 remote backend

```hcl
terraform {
  backend "s3" {
    bucket       = "lablumen-tfstate-025392543842"
    key          = "global/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
```

**Every field explained:**

| Field | What it means |
|---|---|
| `bucket` | The S3 bucket name. MUST be a literal here — Terraform evaluates the backend block before variables/locals are parsed. Cannot use `var.` or `local.` here. |
| `key` | The path within the bucket for the state file. `global/terraform.tfstate` stores everything in one file. |
| `region` | Where the bucket lives. |
| `use_lockfile = true` | Terraform 1.10+ native S3 locking. Terraform writes a `global/terraform.tfstate.tflock` object in the bucket during an operation. Any concurrent `apply` that finds this file refuses to start. This replaced the old DynamoDB locking table — one less resource to manage. |
| `encrypt = true` | The state file is server-side encrypted. Combined with the bucket's AES-256 SSE, the state (which contains non-secret but sensitive infrastructure metadata) is encrypted at rest. |

**Why the bucket name includes the account ID:**
S3 bucket names are globally unique across ALL AWS accounts. By appending the account ID, you guarantee no naming collision. The same convention means the same Terraform code deploys cleanly in a different AWS account just by running the bootstrap stack there.

### bootstrap/main.tf — What it creates

```
S3 bucket: lablumen-tfstate-<account_id>
  ├── versioning: Enabled
  │   → if a bad apply corrupts the state, roll back to a previous version
  ├── server_side_encryption: AES-256
  ├── public access block: all four settings = true
  │   → state file can NEVER be made public
  └── prevent_destroy: false  (intentional — so `terraform destroy` in bootstrap can clean up)
```

No DynamoDB table. The S3-native `use_lockfile` approach (Terraform 1.10+) is cleaner and cheaper.

---

## 4. versions.tf — Provider Pinning

```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
  }
}
```

**`required_version = ">= 1.6"`** — ensures anyone running this code has at least Terraform 1.6. The CI pipeline pins to 1.15.5 exactly (via `TF_VERSION` in the workflow), so CI is deterministic even though the code accepts anything ≥ 1.6.

**`~> 5.60`** is a pessimistic constraint operator — allows `5.60.x`, `5.61`, `5.x.x` but NOT `6.x`. This means you get bug fixes and new resource support automatically, but breaking changes in a major version don't silently break your apply.

**`.terraform.lock.hcl`** — when you run `terraform init`, Terraform resolves the exact provider version (e.g., `5.62.0`) and writes a lock file. Every subsequent `terraform init` uses the locked version regardless of what `~> 5.60` allows. This makes every CI run use the exact same provider code. Commit the lock file to Git.

---

## 5. providers.tf — Configuring the Two Providers

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
```

**`default_tags`** is one of the most powerful Terraform patterns. Every single AWS resource created by this configuration automatically gets:
```
Project     = "lablumen"
ManagedBy   = "terraform"
Environment = "shared"
Owner       = "rnld101"
```

Without `default_tags`, you would have to add `tags = local.common_tags` to every resource block — 50+ places. With `default_tags`, you add it once and it applies everywhere. **A reviewer asking "are all your resources tagged?" — the answer is yes, enforced by the provider.**

```hcl
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}
```

The Kubernetes provider needs to authenticate to the cluster API server. Instead of using a static kubeconfig file (which would contain a long-lived token), it uses the `exec` block to call `aws eks get-token` at runtime. This generates a **short-lived token** from the current AWS credentials (the CI role). No static credentials stored anywhere.

**Why two providers?** The Kubernetes provider manages K8s resources (namespaces, ServiceAccounts) in `kubernetes.tf`. Without it, Terraform cannot create resources inside the cluster. The `host` and `cluster_ca_certificate` come from `module.eks` outputs — meaning Terraform automatically connects to the cluster it just created, without any manual kubeconfig copy.

---

## 6. variables.tf — The Input Interface

Variables are the public interface of the Terraform configuration. They make the code reusable across environments and accounts without editing module code.

### Variable types and defaults

Every variable has a `type` (Terraform enforces it at plan time) and optionally a `default`. Variables with no default are **required** — you must supply them in `terraform.tfvars` or as environment variables (`TF_VAR_<name>`).

**The one required variable with no default:**
```hcl
variable "bedrock_cross_account_role_arn" {
  type      = string
  sensitive = true   # never printed in plan/apply output
}
```
This has no default and is `sensitive`. It cannot be in `terraform.tfvars` (which is committed to Git). It is supplied via `TF_VAR_bedrock_cross_account_role_arn` set as a GitHub Actions secret. Terraform reads environment variables named `TF_VAR_<variable_name>` automatically.

**Important variables and why they exist as variables (not hardcoded):**

| Variable | Why it's a variable |
|---|---|
| `domain_name` | Every developer who forks this project has a different domain. Never hardcode. |
| `node_instance_types` | The org SCP restricts instance types. Variable allows adapting without code changes. |
| `db_instance_class` | Same SCP reason — `db.t4g.micro` is the only permitted class. |
| `cluster_admin_access_entries` | Map of human IAM ARNs to grant cluster admin. Different per person/account. |
| `vpc_cidr` / subnets | Different deployments may need different CIDR ranges. |
| `github_org` | Different users might fork to their own GitHub org. |

**Variable validation (why it matters):**
Without type annotations, Terraform accepts anything. With types (`string`, `number`, `list(string)`, `map(string)`), Terraform catches `vpc_cidr = 12345` at `plan` time — before any AWS API is called.

---

## 7. locals.tf — Derived, Account-Portable Values

```hcl
locals {
  cluster_name        = "${var.project}-eks"          # → "lablumen-eks"
  account_id          = data.aws_caller_identity.current.account_id

  reports_bucket_name = coalesce(var.reports_bucket_name, "${var.project}-reports-${local.account_id}")
  state_bucket_name   = coalesce(var.state_bucket_name,   "${var.project}-tfstate-${local.account_id}")
  sam_bucket_name     = "${var.project}-sam-${local.account_id}"

  image_registry      = "${local.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"

  common_tags = merge(var.tags, { Environment = var.environment, Owner = var.owner })

  acm_domain    = coalesce(var.acm_certificate_domain, "*.${var.domain_name}")
  frontend_fqdn = "${var.frontend_subdomain}.${var.domain_name}"   # → "app.rnld101.xyz"
  api_fqdn      = "${var.api_subdomain}.${var.domain_name}"        # → "api.rnld101.xyz"
  ses_from_address = "${var.ses_from_local_part}@${var.domain_name}"  # → "no-reply@rnld101.xyz"
}
```

**Why locals instead of variables for these values?**

Locals are **computed expressions** — they cannot be overridden by tfvars. Use locals for values that are always derived from other values (so they are always consistent) and variables for values that legitimately differ between deployments.

**`coalesce()` pattern:**
```hcl
reports_bucket_name = coalesce(var.reports_bucket_name, "${var.project}-reports-${local.account_id}")
```
`coalesce()` returns the first non-null argument. If `var.reports_bucket_name` is provided (not null), use it. Otherwise, derive a globally-unique name using the account ID. This gives you the best of both: sensible automatic names AND the ability to override when needed.

**Account portability is the whole point:**
Everything in `locals.tf` is derived. No AWS account ID is hardcoded (except in `backend.tf` where it must be a literal). The ECR registry URL `025392543842.dkr.ecr.us-east-1.amazonaws.com` is assembled in `locals.tf` from the discovered account ID. If you deploy to a new account, the correct registry URL is computed automatically.

---

## 8. data.tf — Looking Up Pre-Existing Resources

```hcl
data "aws_caller_identity" "current" {}

data "aws_route53_zone" "primary" {
  name         = var.domain_name
  private_zone = false
}

data "aws_acm_certificate" "primary" {
  domain      = local.acm_domain      # "*.rnld101.xyz"
  statuses    = ["ISSUED"]
  most_recent = true
}
```

**`data` sources** look up existing AWS resources without managing them. Terraform does not create or destroy data source resources — it only reads them.

**`aws_caller_identity`** — calls `sts:GetCallerIdentity` to discover the AWS account ID of whoever is running Terraform. No credentials hardcoded. This account ID drives bucket names, ECR URLs, and IAM ARN construction throughout the codebase.

**`aws_route53_zone.primary`** — the hosted zone for `rnld101.xyz` was created manually in the AWS console (creating a hosted zone in Terraform while it's also used to validate ACM certificates creates a circular dependency). Terraform only looks it up to get its `zone_id` (used to create SES DKIM records) and `arn` (used to scope ExternalDNS's IAM permissions).

**`aws_acm_certificate.primary`** — the `*.rnld101.xyz` wildcard certificate was created manually and validated via DNS. Terraform looks it up to get its ARN, which is referenced in Ingress annotations to tell the ALB which certificate to use for HTTPS termination.

**Why create the hosted zone and cert manually (not via Terraform)?**
If the Route 53 zone was created by Terraform, the NS records would need to be added to the domain registrar before the ACM certificate could be validated via DNS — but ACM validation creates records in Route 53, which requires the zone to exist. You'd be editing registrar DNS records mid-apply while Terraform waits. Manual creation before Terraform is the industry-standard approach for the apex zone and the ACM wildcard cert.

---

## 9. terraform.tfvars — The Single Config File

```hcl
aws_region  = "us-east-1"
project     = "lablumen"
environment = "shared"
owner       = "rnld101"
github_org  = "lablumen"

domain_name = "rnld101.xyz"

vpc_cidr         = "10.0.0.0/16"
azs              = ["us-east-1a", "us-east-1b"]
private_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
public_subnets   = ["10.0.101.0/24", "10.0.102.0/24"]
database_subnets = ["10.0.201.0/24", "10.0.202.0/24"]

cluster_version     = "1.31"
node_instance_types = ["c7i-flex.large"]
node_min_size       = 1
node_max_size       = 4
node_desired_size   = 2

db_engine_version = "16.4"
db_instance_class = "db.t4g.micro"

notifications_queue_name = "lablumen-notifications"
user_pool_name           = "lablumen-users"
ses_from_local_part      = "no-reply"

ecr_repositories = [
  "lablumen/appointment-service",
  "lablumen/report-service",
  "lablumen/notification-service",
  "lablumen/frontend",
]
```

**This file is committed to Git.** It contains no secrets — only public, non-sensitive configuration values. `bedrock_cross_account_role_arn` (the one sensitive variable) is NOT here — it comes from `TF_VAR_bedrock_cross_account_role_arn` set as a GitHub Actions secret.

**`*.auto.tfvars` is gitignored** — any personal overrides (like `cluster_admin_access_entries`) go in a local `secrets.auto.tfvars` file that never commits.

**Why `environment = "shared"`?** Both dev and prod namespaces run in the same EKS cluster. The Terraform-managed infrastructure (VPC, RDS, EKS cluster itself) is not per-environment — it is shared. The environment differentiation is at the Kubernetes namespace level (lablumen vs lablumen-dev), managed by ArgoCD.

---

## 10. main.tf — The Orchestrator

`main.tf` at the root calls every module and wires their outputs together. It is the dependency graph in code form. Reading `main.tf` tells you: what AWS resources exist and how they connect.

### How module calls work

```hcl
module "rds" {
  source = "./modules/rds"

  vpc_id     = module.vpc.vpc_id          # OUTPUT of vpc module used as INPUT to rds module
  subnet_ids = module.vpc.database_subnets
  vpc_cidr   = var.vpc_cidr
  ...
}
```

Terraform reads this and understands: the `rds` module depends on the `vpc` module (because it uses `module.vpc.*` outputs). So `vpc` must be fully created before `rds` starts. Terraform builds the complete dependency graph from these references and applies resources in the correct order, parallelising independent resources automatically.

### Inline resources in main.tf

Some resources are defined directly in `main.tf` (not in a child module):

**KMS CMK** — defined inline because it needs the `local.account_id` (from `data.tf`) and because it is referenced by multiple modules (ECR, Secrets Manager, S3). If it lived in a module, there would be circular import potential. Inline resources at the root level can reference any module output or data source without import cycles.

**Lambda security group** — the AI Lambda's SG references `module.vpc.vpc_id`. If placed in a module, that module would need to import both the VPC module and the Lambda module. Inline in root avoids this.

**S3 bucket policy for cross-account access** — attaches a resource-based policy to the reports bucket allowing the cross-account Bedrock role to read PDFs. Defined inline because it references both `module.s3.reports_bucket_id` and `var.bedrock_cross_account_role_arn` (a root-level variable).

**EKS Access Entries** — grant the `tf-apply` and `tf-plan` IAM roles cluster admin access. Defined inline because they reference both `module.eks.cluster_name` and `module.iam.*` role ARNs — cross-module wiring that is cleaner at root level.

---

## 11. Module Deep Dives

### modules/vpc

**What it creates:**
```
VPC (10.0.0.0/16, DNS hostnames enabled)
  ├── Public subnets:   10.0.101.0/24, 10.0.102.0/24  (us-east-1a, us-east-1b)
  │     Route: 0.0.0.0/0 → Internet Gateway
  │     Tags:  kubernetes.io/role/elb = 1
  ├── Private subnets:  10.0.1.0/24,   10.0.2.0/24
  │     Route: 0.0.0.0/0 → NAT Gateway (single, in us-east-1a)
  │     Tags:  karpenter.sh/discovery = lablumen-eks
  │            kubernetes.io/role/internal-elb = 1
  └── Database subnets: 10.0.201.0/24, 10.0.202.0/24
        NO route to internet or NAT

VPC Endpoint SG (TCP 443 in/out from 10.0.0.0/16)

Gateway Endpoint: S3 (free — added to private route tables)

Interface Endpoints (each creates 2 ENIs in private subnets):
  ssm, secretsmanager, bedrock-runtime, textract, ecr.api, ecr.dkr, logs, sqs
  private_dns_enabled = true  ← AWS SDK resolves to private ENI, no code changes needed
```

**Uses the community module** `terraform-aws-modules/vpc/aws ~> 5.8`. This module alone reduces ~300 lines of Internet Gateway, route table, subnet association, NAT Gateway resource blocks to ~25 lines.

**Subnet tags are critical:** The `kubernetes.io/role/elb = 1` tag on public subnets tells the AWS Load Balancer Controller where to place internet-facing ALBs. The `karpenter.sh/discovery = lablumen-eks` tag on private subnets tells Karpenter where to launch worker nodes. Without these tags, both controllers would fail silently.

**`single_nat_gateway = true`** — one NAT Gateway in us-east-1a serves both private subnets. Both AZs route `0.0.0.0/0` through it. If us-east-1a goes down, the NAT is lost and private-subnet pods lose internet access (for non-endpoint services like SES). Two NAT Gateways (one per AZ) would double the cost (~$32/month vs ~$16/month) for better AZ isolation. For a non-production platform this is the correct cost trade-off.

**Interface endpoints and `private_dns_enabled = true`:** When a pod calls `boto3.client('secretsmanager').get_secret_value(...)`, boto3 resolves `secretsmanager.us-east-1.amazonaws.com`. Normally this resolves to a public IP. With `private_dns_enabled = true` on the secretsmanager endpoint, AWS DNS returns the private ENI IP inside the VPC — so the call never leaves the AWS network. No code change needed in the application; it's all transparent at the DNS level.

---

### modules/eks

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = var.cluster_name    # "lablumen-eks"
  cluster_version = var.cluster_version # "1.31"

  cluster_endpoint_public_access = true

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false

  cluster_enabled_log_types              = ["api","audit","authenticator","controllerManager","scheduler"]
  cloudwatch_log_group_retention_in_days = 14

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids    # private subnets only

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types  # ["c7i-flex.large"]
      min_size       = var.node_min_size         # 1
      max_size       = var.node_max_size         # 4
      desired_size   = var.node_desired_size     # 2
    }
  }
}
```

**Authentication mode: `"API"` (EKS Access Entries)**
The old way (`CONFIGMAP` mode) required editing the `aws-auth` ConfigMap to give IAM roles Kubernetes access. One typo could lock out all admins permanently. The new `API` mode uses first-class EKS Access Entry resources — managed by Terraform, auditable, and not stored in a fragile ConfigMap.

**`enable_cluster_creator_admin_permissions = false`**
By default, whoever runs `terraform apply` automatically gets cluster admin forever. Disabling this means NO implicit grants — all access comes from explicit, auditable Access Entry resources created in `main.tf`. This is the "least-privilege default" approach.

**The Karpenter submodule** — within the same `modules/eks/main.tf`, a second module call:
```hcl
module "karpenter" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"
  ...
  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["kube-system:karpenter"]
  enable_pod_identity             = false   # using IRSA, not Pod Identity
}
```
Creates: Karpenter controller IAM role (IRSA), KarpenterNodeRole (instance profile for nodes), and the SQS interruption queue.

**Why workers in private subnets?** If nodes were in public subnets, their kubelet APIs would be directly internet-reachable — a massive attack surface. Private subnets mean even a misconfigured security group cannot expose a worker node to the internet. The ALB (in public subnets) is the only internet-facing component.

**Why `cluster_endpoint_public_access = true`?** The EKS API server is accessible from the internet (over TLS, authenticated with AWS SigV4). This is required for GitHub Actions (running on GitHub's runners, not inside the VPC) to run `kubectl` and `terraform` commands against the cluster. In a high-security environment, you'd use a private endpoint + VPN or AWS PrivateLink for CI runners. For this platform, public endpoint + IAM authentication is appropriate.

---

### modules/rds

```hcl
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.9"

  engine               = "postgres"
  engine_version       = "16.4"
  family               = "postgres16"
  instance_class       = "db.t4g.micro"
  allocated_storage    = 20

  db_name  = "lablumen"
  username = "lablumen"

  manage_master_user_password = true   # ← Secrets Manager-managed credentials

  multi_az               = false
  subnet_ids             = var.subnet_ids   # database subnets
  vpc_security_group_ids = [aws_security_group.rds.id]

  storage_encrypted   = true
  deletion_protection = false          # false for easy teardown in dev
  skip_final_snapshot = true           # no snapshot on destroy
}
```

**`manage_master_user_password = true`** — RDS generates a random master password, stores it in a Secrets Manager secret (different from your `lablumen/app/database-url` secret — this is an RDS-managed secret with a generated name). It can automatically rotate it. The password never appears in Terraform state. The `terraform output rds_master_user_secret_arn` tells you where to find it so you can read it when composing the DATABASE_URL.

**RDS security group** — only `ingress tcp 5432` from `10.0.0.0/16` (the entire VPC CIDR). No egress rule (RDS never initiates connections — AWS-managed backup and replication use separate internal paths). This is the most restrictive possible SG for RDS.

**Database subnet placement** — the subnet group uses the isolated database subnets (10.0.201.0/24, 10.0.202.0/24). These subnets have no route to the internet (no NAT, no IGW). Even if the RDS security group was misconfigured to allow all traffic, there is no network path from the internet to these subnets. Defense in depth.

**`deletion_protection = false`** — in production you would set this to `true` to prevent accidental destruction. For a dev/edu platform that needs to be torn down and rebuilt frequently, false is appropriate. On a real production database, always enable deletion protection.

---

### modules/s3

**Two buckets created:**

**Reports bucket:**
```hcl
module "reports_bucket" {
  bucket        = var.reports_bucket_name    # "lablumen-reports-025392543842"
  force_destroy = true                        # allow destroy even with objects inside

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  versioning = { enabled = true }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "aws:kms"   # uses the platform CMK (passed in from main.tf)
      }
    }
  }
}

resource "aws_s3_bucket_notification" "reports" {
  bucket      = module.reports_bucket.s3_bucket_id
  eventbridge = true    # ALL object events go to EventBridge default bus
}
```

**SAM artifacts bucket:**
```hcl
module "sam_artifacts_bucket" {
  bucket        = "lablumen-sam-025392543842"
  force_destroy = true
  # No KMS — deployment ZIPs are not sensitive
  # No versioning — artifacts are ephemeral deployment intermediates
}
```

**`eventbridge = true`** — the critical one. This is a single-line resource that forwards ALL S3 events (ObjectCreated, ObjectRemoved, etc.) to the EventBridge default bus. Without this, Lambda cannot be triggered by S3 uploads via EventBridge. The alternative (S3 direct notification to Lambda) was discussed in the AWS cloud services doc — EventBridge is the decoupled, future-proof approach.

**`force_destroy = true`** — normally, destroying a non-empty S3 bucket fails. `force_destroy = true` allows `terraform destroy` to delete all objects first, then delete the bucket. Without this, tearing down the dev platform would fail with "BucketNotEmpty" errors. For a production platform storing real patient reports, you would set `force_destroy = false` and archive data separately before teardown.

---

### KMS (inline in main.tf)

```hcl
resource "aws_kms_key" "platform" {
  description             = "Shared platform CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableIAMPolicies"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowSecretsManager"
        Effect    = "Allow"
        Principal = { Service = "secretsmanager.amazonaws.com" }
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
        Resource  = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "platform" {
  name          = "alias/lablumen-platform"
  target_key_id = aws_kms_key.platform.key_id
}
```

**The key policy is mandatory** — without it, a KMS key has NO access at all (even to the account root). Two required statements:

1. `EnableIAMPolicies` — allows the account root to delegate key access via IAM role policies. Without this, adding `kms:Decrypt` to an IAM role has NO effect — IAM and KMS policies are both required.

2. `AllowSecretsManager` — allows the Secrets Manager service principal to call `GenerateDataKey*` (to encrypt secret values when stored) and `Decrypt` (to decrypt them when read). Without this, creating a KMS-encrypted secret in Secrets Manager fails.

**After this, KMS permissions are in IAM policies** (in `modules/iam/main.tf`) — that's the delegation pattern. The key policy says "root can delegate," IAM policies say "this specific role gets Decrypt."

**`deletion_window_in_days = 7`** — the minimum. When you delete a KMS key, AWS holds it for this many days before permanent deletion. This gives you time to realize data encrypted with the key still needs decryption. The key is not billed during the window but also cannot be used.

**Two extra IAM policies in main.tf for node KMS access:**
```hcl
resource "aws_iam_role_policy" "eks_nodes_kms" {
  role = module.eks.node_group_iam_role_name    # managed node group's IAM role
  policy = jsonencode({
    Statement = [{ Effect = "Allow", Action = ["kms:Decrypt","kms:DescribeKey"],
                   Resource = aws_kms_key.platform.arn }]
  })
}

resource "aws_iam_role_policy" "karpenter_nodes_kms" {
  role = module.eks.karpenter_node_iam_role_name   # Karpenter-launched nodes
  ...
}
```
EKS worker nodes pull Docker images from ECR. ECR images are encrypted with the platform CMK. For a node to pull an encrypted image, it needs `kms:Decrypt`. These two policies grant that. Without them, new nodes would fail to start any pod with `ImagePullBackOff` errors (even though the image exists in ECR).

---

### modules/ecr

```hcl
resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)   # creates one resource per repo name

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the most recent N images"
      selection = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
      action = { type = "expire" }
    }]
  })
}
```

**`for_each = toset(var.repositories)`** — creates one ECR repo for each string in the list, named accordingly. To add a new service, add one line to `ecr_repositories` in `terraform.tfvars`.

**`image_tag_mutability = "IMMUTABLE"`** — once you push image tag `abc1234`, that tag points to exactly those image bytes forever. This guarantees rollbacks: if production is running `abc1234` and something breaks, deploying `abc1233` (the previous SHA) pulls the exact same image bytes that were tested. Mutable tags break this guarantee.

**Lifecycle policy** — ECR charges per GB stored. Without a lifecycle policy, every CI push (potentially 20+ per day) adds another image layer set. 30 days × 20 pushes/day = 600 images. With the lifecycle policy, only the most recent N images are kept. Older images are automatically expired.

---

### modules/cognito

```hcl
resource "aws_cognito_user_pool" "this" {
  name                     = var.user_pool_name   # "lablumen-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }
}

resource "aws_cognito_user_pool_client" "web" {
  generate_secret      = false   # public client (SPA)
  explicit_auth_flows  = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
  allowed_oauth_flows  = ["code"]
  allowed_oauth_scopes = ["email", "openid", "profile"]
  callback_urls        = var.callback_urls   # ["https://app.rnld101.xyz/callback", "http://localhost:5173/callback"]
  logout_urls          = var.logout_urls
}

resource "aws_cognito_user_group" "roles" {
  for_each = toset(["PATIENT", "LAB_STAFF", "LAB_ADMIN"])

  name         = each.value
  user_pool_id = aws_cognito_user_pool.this.id
}
```

**`generate_secret = false`** — a "public client" means no client secret. A Single Page Application runs entirely in the user's browser; any "secret" you embed in a SPA is trivially extractable. Cognito's public client flow authenticates users with SRP (the password never leaves the browser unprotected) without needing a secret.

**`ALLOW_USER_SRP_AUTH`** — Secure Remote Password protocol. The browser mathematically proves it knows the password WITHOUT sending it in plaintext or even hashed. Even if HTTPS is somehow compromised, the password itself was never transmitted.

**`allowed_oauth_flows = ["code"]`** — Authorization Code Flow. The user authenticates with Cognito, Cognito returns a code, the frontend exchanges the code for tokens. The alternative (`implicit` flow) returned tokens directly in the URL — visible in browser history and server logs. Authorization Code Flow is the current OAuth 2.0 standard.

**`for_each = toset([...])`** — creates three user groups with one resource block. `toset()` converts a list to a set (removing duplicates, not that there are any here). `for_each` on a set creates one instance per element with `each.key == each.value == "PATIENT"` (etc.).

**`callback_urls` includes localhost** — this lets developers log in during local development (`http://localhost:5173`) without needing a separate dev Cognito client.

---

### modules/sqs

```hcl
module "notifications_queue" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "~> 4.2"

  name                       = var.queue_name             # "lablumen-notifications"
  visibility_timeout_seconds = var.visibility_timeout_seconds  # default 30s
}
```

Standard queue, no FIFO, no DLQ (dead letter queue). The notification-service long-polls this queue. `visibility_timeout_seconds` is how long after a consumer receives a message that message is invisible to other consumers. If the consumer doesn't delete it within 30 seconds (e.g., it crashes), the message reappears and is retried.

---

### modules/ses

```hcl
resource "aws_sesv2_email_identity" "sender" {
  email_identity = var.domain_name   # "rnld101.xyz"
}

resource "aws_route53_record" "dkim" {
  count = 3

  zone_id = var.route53_zone_id
  name    = "${...tokens[count.index]}._domainkey.${var.domain_name}"
  type    = "CNAME"
  ttl     = 1800
  records = ["${...tokens[count.index]}.dkim.amazonses.com"]
}
```

**`count = 3`** — creates three Route 53 CNAME records, one per DKIM token. The `count.index` is 0, 1, 2. `aws_sesv2_email_identity.sender.dkim_signing_attributes[0].tokens[count.index]` accesses the DKIM token at index `count.index`.

**Why domain identity instead of email identity?** An email identity only verifies a single email address. A domain identity verifies the whole domain — you can send from any `@rnld101.xyz` address. It is the correct choice for a production platform.

**Why SESv2 resource (`aws_sesv2_email_identity`) instead of the older `aws_ses_email_identity`?** SES v2 is the current API; v1 is legacy. The v2 resource supports DKIM configuration and aligns with current AWS recommendations.

**The DKIM → Route 53 connection:** SES generates three CNAME pairs. By creating those Route 53 records in the same Terraform apply, the domain is automatically verified without manual console steps. When email clients receive a message from `no-reply@rnld101.xyz`, they look up the `_domainkey` CNAME record and verify the DKIM signature on the email. Verified → delivered to inbox. Unverified → spam folder.

---

### modules/secretsmanager

```hcl
resource "aws_secretsmanager_secret" "runtime" {
  for_each = var.runtime_secrets   # map of name → description

  name        = each.key           # "lablumen/app/database-url"
  description = each.value

  kms_key_id = var.kms_key_arn     # platform CMK

  recovery_window_in_days = var.secret_recovery_window_days  # 0 for dev
}
```

**`for_each = var.runtime_secrets`** — creates one Secrets Manager secret per map entry. Two secrets:
- `lablumen/app/database-url` (contains the full Postgres DSN, hand-populated)
- `lablumen/app/grafana-admin` (JSON with Grafana admin credentials, hand-populated)

**No `aws_secretsmanager_secret_version` resource** — Terraform creates the secret CONTAINER (name, encryption key, metadata) but writes NO value. This is the "empty shell" pattern. Advantages:
- Secret values never appear in Terraform state (the state file would be compromised)
- Secret values never appear in Git (same)
- A human engineer populates the value out-of-band via `aws secretsmanager put-secret-value`
- ESO reads secrets by name — it doesn't care who wrote the value

**`recovery_window_in_days = 0`** — normally, deleting a Secrets Manager secret has a 7–30 day recovery window. During this window, you cannot create a new secret with the same name. For a platform that is regularly torn down and rebuilt, `0` allows immediate re-creation. **In production, use the default (30 days) to protect against accidental deletion.**

---

### modules/ssm

```hcl
resource "aws_ssm_parameter" "config" {
  for_each = var.config   # map of short-name → value

  name      = "${var.path_prefix}/${each.key}"   # "/lablumen/config/region"
  type      = "String"    # not SecureString — these are non-sensitive
  value     = each.value
  overwrite = true        # re-apply updates the value
}
```

**`for_each` on a map** — creates one SSM parameter per map entry. The key becomes the parameter name suffix, the value becomes the stored value. The 15 parameters are all derived from module outputs assembled in `main.tf`:

```hcl
config = {
  "reports-bucket"        = module.s3.reports_bucket_id
  "sqs-url"               = module.sqs.queue_url
  "cognito-user-pool-id"  = module.cognito.user_pool_id
  "lambda-exec-role-arn"  = module.iam.ai_lambda_exec_role_arn
  "lambda-subnet-ids"     = join(",", module.vpc.private_subnets)
  ...
}
```

**Why `type = "String"` and not `SecureString`?** These values are not secrets. Bucket names, SQS queue URLs, Cognito pool IDs — any developer with read access to the AWS console can see these. Checkov flags `CKV2_AWS_34` (SSM params should be SecureString), but the `.checkov.yaml` suppresses it with a documented rationale: SecureString would require every reader to have KMS Decrypt permission, adding complexity with no security benefit for non-sensitive data.

**`overwrite = true`** — if you change a value in `main.tf` (e.g., the SQS queue URL changes because you recreated the queue), Terraform updates the SSM parameter in place. Without `overwrite = true`, a second apply would fail if the parameter already exists.

---

### modules/iam

The largest and most complex module. It creates all IAM roles — for both CI/CD pipelines and in-cluster workloads. Full breakdown:

#### GitHub OIDC Provider

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}
```

This tells AWS: "I trust JWTs signed by GitHub Actions (`token.actions.githubusercontent.com`) with audience `sts.amazonaws.com`." Once this provider exists, any GitHub Actions workflow can call `sts:AssumeRoleWithWebIdentity` with its GitHub-issued JWT and receive temporary AWS credentials — no static access keys ever.

#### Pipeline roles (GitHub OIDC → AWS)

**`lablumen-tf-plan`** (read-only):
- Trust policy: `token.actions.githubusercontent.com:sub` matches `repo:lablumen/lablumen-terraform:pull_request` OR `repo:lablumen/lablumen-terraform:ref:refs/heads/main`
- Permissions: `ReadOnlyAccess` + S3 state read/write (for `terraform plan` to read and update the state file)
- Used by: Terraform PR and plan job

**`lablumen-tf-apply`** (admin, production gated):
- Trust policy: `sub` equals exactly `repo:lablumen/lablumen-terraform:environment:production` (the `environment:` prefix is set only when the job runs in a GitHub Environment)
- Permissions: `AdministratorAccess` — needs to create/update/delete any AWS resource
- Used by: Terraform apply job, only after a required reviewer approves in the GitHub "production" Environment

**`lablumen-app-ci-ecr`** (ECR push):
- Trust policy: `sub` matches any of the 3 backend service repos (`repo:lablumen/lablumen-appointment-service:*`, etc.)
- Permissions: ECR auth + layer push + image push on the backend ECR repos + KMS Decrypt/GenerateDataKey for encrypted repos
- Used by: service CI on push to main

**`lablumen-frontend-build`** (ECR push, frontend only):
- Trust policy: `sub` matches only `repo:lablumen/lablumen-frontend:*`
- Permissions: ECR auth + push on the frontend ECR repo only
- Used by: frontend CI

#### IRSA roles (Kubernetes ServiceAccount → AWS)

All IRSA roles follow the same pattern — a trust policy using the cluster's OIDC provider:

```hcl
assume_role_policy = jsonencode({
  Statement = [{
    Effect    = "Allow"
    Principal = { Federated = var.oidc_provider_arn }
    Action    = "sts:AssumeRoleWithWebIdentity"
    Condition = {
      StringEquals = {
        "${local.oidc_issuer}:sub" = "system:serviceaccount:lablumen:report-service"
        "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
      }
    }
  }]
})
```

The `sub` claim is in the format `system:serviceaccount:<namespace>:<serviceaccount-name>`. This is a hard-coded Kubernetes identity format — the namespace and SA name must match exactly.

**IRSA roles created:**

| Role | Trust (namespace:SA) | Key Permissions |
|---|---|---|
| `lablumen-eso` | `external-secrets:lablumen-eso` | SM GetSecretValue, SSM GetParameter, KMS Decrypt |
| `lablumen-report-service` | `lablumen:report-service` AND `lablumen-dev:report-service` | S3 Get+Put, Bedrock InvokeModel |
| `lablumen-notification-service` | `lablumen:notification-service` AND `lablumen-dev:notification-service` | SQS Receive+Delete, SES SendEmail |
| `lablumen-lbc` | `kube-system:aws-load-balancer-controller` | Full LBC policy (managed via community module) |
| `lablumen-external-dns` | `kube-system:external-dns` | Route53 ChangeResourceRecordSets scoped to the hosted zone |
| `lablumen-ai-lambda-exec` | `lambda.amazonaws.com` (NOT IRSA — Lambda trust) | Textract, STS AssumeRole, S3 GetObject, SM GetSecretValue, KMS Decrypt |
| `lablumen-ai-lambda-deploy` | `repo:lablumen/lablumen-ai-service:*` (GitHub OIDC) | CloudFormation, Lambda, S3, SSM, KMS, IAM PassRole, EventBridge, EC2 describe |

**`iam-role-for-service-accounts-eks` community module** — for report-service, notification-service, LBC, and ExternalDNS, the IAM module uses `terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks`. This module constructs the correct IRSA trust policy automatically. For LBC, `attach_load_balancer_controller_policy = true` attaches the full managed ALB controller policy. For ExternalDNS, `attach_external_dns_policy = true` scopes Route53 access to the specified hosted zone ARN.

---

## 12. kubernetes.tf — The Cross-Provider Bridge

```hcl
# Creates namespaces and IRSA-annotated ServiceAccounts inside the EKS cluster
# using the Kubernetes provider (not AWS resources — these are Kubernetes resources).

resource "kubernetes_namespace" "external_secrets" {
  metadata { name = "external-secrets" }
  depends_on = [module.eks, aws_eks_access_policy_association.tf_apply_admin]
}

resource "kubernetes_service_account" "eso" {
  metadata {
    name      = "lablumen-eso"
    namespace = kubernetes_namespace.external_secrets.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = module.iam.eso_irsa_role_arn
    }
  }
}
```

This file is the **integration point between Terraform and Kubernetes**. It creates Kubernetes objects (using the Kubernetes provider) inside the EKS cluster that Terraform just created (using the AWS provider).

**The `depends_on` pattern:**
```hcl
depends_on = [module.eks, aws_eks_access_policy_association.tf_apply_admin]
```
The Kubernetes provider cannot create a namespace until the EKS cluster exists AND the `tf-apply` role has cluster-admin access (so the `aws eks get-token` call in the provider's `exec` block succeeds). `depends_on` forces Terraform to wait for both.

**Why does Terraform create ServiceAccounts instead of ArgoCD?**
IRSA role ARNs are Terraform outputs. They are only known after `terraform apply` completes. If ArgoCD created the ServiceAccounts via Helm, the IAM role ARN would need to be hardcoded in a values file — coupling Terraform outputs to ArgoCD config manually. Terraform creating the ServiceAccounts means the annotation is always correct without any manual copy-paste.

**The Helm charts use `serviceAccount.create: false`** for IRSA services — they expect the SA to already exist (created by Terraform). Only appointment-service (no IRSA) uses `serviceAccount.create: true` in the Helm chart.

**App-tier service accounts are created for BOTH namespaces:**
```hcl
locals {
  app_namespaces = ["lablumen", "lablumen-dev"]
  app_service_account_roles = {
    "report-service"       = module.iam.report_service_role_arn
    "notification-service" = module.iam.notification_service_role_arn
  }
  # Creates "lablumen/report-service", "lablumen-dev/report-service", etc.
  app_service_accounts = merge([
    for ns in local.app_namespaces : {
      for sa, role_arn in local.app_service_account_roles :
      "${ns}/${sa}" => { namespace = ns, name = sa, role_arn = role_arn }
    }
  ]...)
}

resource "kubernetes_service_account" "app" {
  for_each = local.app_service_accounts   # creates 4 SAs: 2 services × 2 namespaces
  ...
}
```

The IRSA trust policies on the IAM roles trust BOTH `lablumen:report-service` AND `lablumen-dev:report-service` — so one IAM role serves both environments.

---

## 13. outputs.tf — The Handshake Layer

Outputs are values computed after `terraform apply` that are printed to the terminal, stored in state, and readable by `terraform output`. They serve as the **handshake between Terraform and the other parts of the platform**.

### Critical outputs and what uses them

**Bootstrap handshake (used to configure lablumen-k8s):**
```
image_registry      → "025392543842.dkr.ecr.us-east-1.amazonaws.com"
                      → copy to lablumen-k8s/global-values.yaml global.imageRegistry
ecr_repository_urls → map of repo names → full ECR URLs
                      → used as reference; chart sets image.repository
```

**Database setup handshake:**
```
rds_endpoint                  → RDS hostname
rds_master_user_secret_arn    → SM ARN to find the RDS-generated password
database_url_template         → "postgresql+asyncpg://lablumen:<PASSWORD>@<endpoint>/lablumen"
                                → replace <PASSWORD>, put in lablumen/app/database-url SM secret
```

**Cluster access:**
```
cluster_name      → "lablumen-eks"
cluster_endpoint  → EKS API server URL (used in the bootstrap script + ArgoCD)
```

**IRSA role ARNs** — these are printed so engineers can verify the correct ARN is annotated on each ServiceAccount (which Terraform itself does — but outputs let you audit it manually).

**Why are outputs important?** After `terraform apply`, you run `terraform output` to get all these values in one place. The bootstrap script `scripts/bootstrap-argocd.sh` in the lablumen-k8s repo uses several of these. The `database_url_template` tells you exactly what to paste into Secrets Manager.

---

## 14. The CI/CD Pipeline — terraform.yml

Three jobs, run sequentially, triggered on changes to `.tf`, `.tfvars`, or the workflow file itself:

### Job 1: scan (Checkov IaC scanning)

```yaml
- name: Checkov IaC scan
  uses: bridgecrewio/checkov-action@master
  with:
    framework: terraform
    soft_fail: true                   # reports findings but doesn't block
    output_format: cli,sarif
```

- Runs on every PR and every push to main
- `soft_fail: true` — uploads SARIF results to GitHub Security tab but does NOT fail the pipeline. This is "report-only" mode. Checkov findings visible in GitHub Code Scanning → Security tab.
- `.checkov.yaml` in the repo root configures which checks to skip (with documented rationale for each skip)

### Job 2: plan (always runs after scan)

```yaml
- name: Configure AWS credentials (tf-plan, read-only)
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/lablumen-tf-plan

- run: terraform fmt -check -recursive   # fails if code isn't formatted
- run: terraform init -input=false
- run: terraform validate               # catches syntax errors
- run: terraform plan -out=tfplan

- name: Generate Infracost Cost Estimate
  run: infracost breakdown --path tfplan.json

- name: Post Infracost Comment
  if: github.event_name == 'pull_request'
  run: infracost comment github --pull-request ${{ github.event.pull_request.number }} ...

- name: Upload plan artifact
  uses: actions/upload-artifact@v4
  with:
    name: tfplan
    retention-days: 5
```

**`terraform fmt -check -recursive`** — Terraform has an opinionated formatter. This fails if any file isn't formatted exactly as `terraform fmt` would format it. Enforces consistent style without debate.

**`terraform validate`** — syntax and semantic checks without AWS API calls. Catches things like referencing a module output that doesn't exist, wrong variable types, or missing required arguments.

**`terraform plan -out=tfplan`** — the plan is saved to an artifact. The apply job downloads and runs this exact plan — so apply executes EXACTLY what plan computed, not a new plan that might differ (because someone applied manually between plan and apply).

**`terraform show -json tfplan > tfplan.json`** — converts the binary plan file to JSON, which Infracost can parse for cost estimates.

**The OIDC flow in the plan job:**
```
GitHub Actions runner (ubuntu-latest, not inside VPC)
  → requests OIDC JWT from GitHub (automatic, id-token: write permission required)
  → aws-actions/configure-aws-credentials calls STS AssumeRoleWithWebIdentity with the JWT
  → IAM trust policy: sub matches "repo:lablumen/lablumen-terraform:pull_request" → ALLOW
  → STS returns temporary credentials (valid 1 hour)
  → terraform plan runs with those credentials
  → calls S3 to read state, calls AWS APIs to read current resource states
```

### Job 3: apply (manual approval required)

```yaml
apply:
  needs: plan
  if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
  environment: production    # ← this line is the gate
```

**`environment: production`** — GitHub Actions Environments support "required reviewers." The job waits for a human reviewer to approve it in the GitHub UI before proceeding. This is the mandatory manual gate before any infrastructure change is applied to production.

**The OIDC flow in the apply job:**
```
Job runs in GitHub Environment 'production'
  → OIDC JWT sub becomes "repo:lablumen/lablumen-terraform:environment:production"
  → lablumen-tf-apply trust policy matches StringEquals on this exact sub value
  → STS AssumeRoleWithWebIdentity → AdministratorAccess credentials
  → downloads tfplan artifact (exact plan from the plan job)
  → terraform apply -input=false tfplan
```

The `environment:production` sub value is ONLY set when a job runs inside a GitHub Environment. The tf-apply trust policy only trusts this exact sub — meaning OIDC credentials for the apply role can NEVER be obtained from a workflow job that isn't in the production environment (even in the same repo). This is why the `StringEquals` condition on `sub` is more secure than `StringLike`.

---

## 15. The Destroy Workflow — terraform-destroy.yml

```yaml
on:
  workflow_dispatch:
    inputs:
      confirm:
        description: 'Type "destroy" to confirm'
        required: true

jobs:
  destroy:
    if: ${{ inputs.confirm == 'destroy' }}   # extra guard
    environment: production                   # required reviewer approval
```

**Why a two-phase destroy?**

The in-cluster controllers (AWS Load Balancer Controller, ExternalDNS, Karpenter) create AWS resources on demand:
- LBC creates ALBs and target groups (AWS resources outside the cluster)
- ExternalDNS creates Route 53 records
- Karpenter launches EC2 instances

If you ran `terraform destroy` immediately, Terraform would try to delete the VPC — but the VPC still has ENIs attached by the ALB and Karpenter EC2 nodes. AWS rejects deleting a VPC with active ENIs. Terraform destroy would fail with dependency violations.

**Phase 1: Kubernetes teardown (controllers clean up their AWS resources)**
```bash
# Stop ArgoCD from recreating what we delete
kubectl -n argocd scale statefulset/argocd-application-controller --replicas=0

# Delete Ingresses → LBC finalizers trigger ALB deletion
kubectl delete ingress --all --all-namespaces --timeout=300s

# Delete Karpenter nodes → EC2 instances terminated
kubectl delete nodeclaims.karpenter.sh --all --timeout=300s

# Wait for ALBs to drain before proceeding
until [ $(aws elbv2 describe-load-balancers ... | count) == 0 ]; do sleep 15; done
```

**Phase 2: Terraform destroy** — with ALBs gone and Karpenter EC2 nodes terminated, the VPC is clean. `terraform destroy -auto-approve` can now delete every resource in the correct reverse-dependency order.

**The "if cluster doesn't exist" guard:**
```bash
if ! aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  echo "Cluster not found — skipping k8s teardown."; exit 0
fi
```
If the cluster was already destroyed (partially), the Phase 1 kubectl commands would fail. This check makes the workflow idempotent — safe to re-run.

---

## 16. Checkov — IaC Security Scanning

**Checkov** is a static analysis tool for Infrastructure as Code. It reads Terraform files and checks them against a library of security best practices (called "checks"). Each check has a code like `CKV_AWS_18`.

### The .checkov.yaml suppression baseline

```yaml
skip-check:
  - CKV_TF_1       # module pinning — community modules use semver, not commit hashes
  - CKV2_AWS_5     # false positive: RDS SG attached inside module, Checkov can't trace cross-module
  - CKV2_AWS_57    # SM rotation — database-url uses RDS-managed rotation; grafana-admin is a non-prod secret
  - CKV_AWS_18     # S3 access logging on state bucket — circular complexity, not warranted
  - CKV_AWS_144    # cross-region replication for state bucket — non-prod, not warranted
  - CKV2_AWS_61    # lifecycle rules on state bucket — versioning already provides recovery
  - CKV2_AWS_62    # S3 event notifications on state bucket — operational noise
  - CKV2_AWS_34    # SSM SecureString — SSM params are non-sensitive by design
  - CKV_AWS_274    # tf-apply AdministratorAccess — required for full platform management, gated by OIDC
  - CKV_AWS_355    # Bedrock/Textract wildcard — AWS doesn't support resource-level restrictions
```

**Every suppression has a documented rationale in the YAML file.** This is the critical difference between security engineering and security theatre. A suppression without a rationale is a red flag — a suppression WITH a rationale shows you understand the risk and made a conscious decision.

**How to answer "Why is CKV_AWS_355 suppressed?"**

"Checkov flags `bedrock:InvokeModel` with `Resource: "*"` as an overly-broad IAM permission. However, AWS doesn't support resource-level restrictions for Bedrock InvokeModel — the IAM service authorization documentation explicitly states only `*` is valid as the resource for this action. Any more specific ARN would be rejected by IAM. This is a Checkov false positive on an AWS API limitation, not a real security gap."

---

## 17. Infracost — Cost Estimation in PRs

**Infracost** analyses the Terraform plan JSON and generates a cost breakdown. In the plan job:

```yaml
- name: Generate Infracost Cost Estimate
  run: infracost breakdown --path tfplan.json --format json --out-file /tmp/infracost.json

- name: Post Infracost Comment
  if: github.event_name == 'pull_request'
  run: infracost comment github --path /tmp/infracost.json --pull-request ${{ ... }} --behavior update
```

When a PR is opened that changes infrastructure (e.g., upgrading `db.t4g.micro` to `db.t4g.small`), Infracost posts a comment on the PR showing the monthly cost difference. This makes the cost impact visible to reviewers BEFORE the change is approved. It uses `--behavior update` to update the existing comment (rather than posting a new one per push), keeping the PR clean.

---

## 18. Module Dependency Graph

Terraform resolves this automatically from `module.*` references. This is the order resources are created:

```
Level 0 (no dependencies):
  data.aws_caller_identity.current   → discovers account_id
  data.aws_route53_zone.primary      → looks up Route53 zone
  data.aws_acm_certificate.primary   → looks up ACM cert

Level 1 (depends on data sources only):
  module.vpc          → needs account region (from provider)
  aws_kms_key         → needs local.account_id (from caller_identity)

Level 2 (depends on vpc + kms):
  module.eks          → needs vpc_id, subnet_ids
  module.rds          → needs vpc_id, database_subnets
  module.s3           → no VPC dependency (S3 is global)
  module.ecr          → needs kms_key_arn
  module.sqs          → no dependencies
  module.ses          → needs route53_zone_id (from data)
  module.secretsmanager → needs kms_key_arn
  module.cognito      → no dependencies
  aws_security_group.ai_lambda → needs module.vpc.vpc_id

Level 3 (depends on eks + vpc + other level-2 modules):
  module.iam          → needs oidc_provider_arn (from eks), reports_bucket_arn, queue_arn, ses_identity_arn, route53_zone_arn
  module.ssm          → needs ALL module outputs (stores them as SSM params)
  aws_s3_bucket_policy.reports_cross_account_read → needs module.s3, var.bedrock_cross_account_role_arn

Level 4 (depends on eks + iam):
  aws_eks_access_entry / aws_eks_access_policy_association → needs eks cluster name + iam role ARNs

Level 5 (depends on eks + iam + namespaces + access entries):
  kubernetes_namespace.* → needs cluster to exist + tf-apply to have cluster admin
  kubernetes_service_account.* → needs namespaces to exist
```

Terraform parallelises everything within the same level automatically. `module.cognito` and `module.sqs` (both level 2, no shared dependency) are created concurrently.

---

## 19. Key Design Decisions & Defences

### "Why modular structure instead of one big main.tf?"

Modules encapsulate related resources. The `modules/vpc/` module owns all VPC resources — when a VPC question comes up in a code review, there is one file to read. Without modules, a single `main.tf` would be 1,000+ lines. Modules also allow reuse: `module.vpc` is called once, but could be called multiple times to create multiple VPCs.

### "Why use community modules (`terraform-aws-modules`) instead of writing raw resources?"

The `terraform-aws-modules` organisation maintains battle-tested, production-grade Terraform modules backed by the community. The VPC module alone replaces ~300 lines of Internet Gateway, route table, subnet association, and NAT Gateway resource blocks. These modules implement best practices by default (e.g., the RDS module sets `manage_master_user_password = true` as an option). Using them speeds development and reduces bugs.

The risk is supply chain: a malicious update to a community module could inject backdoors. The `.terraform.lock.hcl` pin mitigates this — it pins to an exact version hash, and `terraform init -upgrade` is required to pull new versions deliberately.

### "Why is `bedrock_cross_account_role_arn` a `sensitive` variable?"

The ARN itself is not a secret (ARNs are identifiers, not credentials). However, it belongs to a different AWS account and revealing it could help attackers understand the account structure. Marking it `sensitive = true` prevents it from appearing in `terraform plan` output and in logs. It is also supplied via GitHub Actions secrets rather than `terraform.tfvars`, ensuring it never appears in Git history.

### "Why does the S3 backend have `use_lockfile = true` instead of a DynamoDB table?"

Before Terraform 1.10, S3 backends required a DynamoDB table for state locking. This meant every Terraform backend needed TWO AWS resources (S3 + DynamoDB) to function safely. Terraform 1.10 introduced S3-native locking via a `.tflock` object written in the same S3 bucket. One resource, same safety guarantee, lower operational overhead. The tricky part: the CI pipeline must use Terraform >= 1.10 — enforced by `TF_VERSION: "1.15.5"` in the workflow.

### "Why is AdministratorAccess on the tf-apply role not a problem?"

It IS broad — any reviewer should question it. The correct defence:
- **Scope:** AdministratorAccess on a role != AdministratorAccess given to a human. The role can only be assumed by a specific GitHub repo AND only when the job runs in the `production` GitHub Environment (requiring manual reviewer approval).
- **Time-bound:** Credentials from AssumeRoleWithWebIdentity last 1 hour maximum.
- **Audited:** Every AssumeRole call appears in CloudTrail.
- **No narrowing possible:** The role creates EKS clusters, VPCs, RDS instances, KMS keys, Cognito pools, IAM roles, ECR repos, SQS queues, SES identities, and more. A permission set narrower than `*/*` that still covers all of these would be hundreds of explicit statements — fragile and unmaintainable. This is the documented reason for the `CKV_AWS_274` Checkov suppression.

### "Why are Terraform state operations separated from application deployment?"

Terraform manages long-lived infrastructure (the EKS cluster, RDS, S3, VPC). ArgoCD manages workload deployments (what runs inside the cluster). Keeping them separate means:
- An infrastructure change (adding a VPC endpoint) goes through `terraform plan → approval → apply`
- An application change (new Docker image) goes through `git push → CI → ArgoCD sync`
- The two pipelines do not block each other
- The blast radius of each pipeline is limited to its domain

If Terraform also managed Kubernetes Deployments, a bad Terraform plan could simultaneously break infrastructure AND application deployments. Separation of concerns is a fundamental security and reliability principle.

---

## Quick-Reference: What Every File Does

| File | Purpose |
|---|---|
| `backend.tf` | Tells Terraform to store state in S3 with native locking |
| `versions.tf` | Pins provider versions; generates `.terraform.lock.hcl` |
| `providers.tf` | Configures AWS provider (region + default tags) and Kubernetes provider |
| `variables.tf` | Declares every input — the public interface of the configuration |
| `locals.tf` | Computed values (derived from variables + data) — account-portable |
| `data.tf` | Looks up existing Route53 zone, ACM cert, and account ID |
| `terraform.tfvars` | Concrete values for all non-sensitive variables (committed to Git) |
| `main.tf` | Calls every module; contains KMS, Lambda SG, bucket policy, EKS access entries |
| `kubernetes.tf` | Creates K8s namespaces and IRSA-annotated ServiceAccounts via Kubernetes provider |
| `outputs.tf` | Exposes key ARNs, URLs, and IDs after apply — the handshake layer |
| `bootstrap/main.tf` | One-time setup: creates the S3 state bucket (separate TF config) |
| `modules/vpc/main.tf` | VPC, 3 subnet tiers, single NAT, VPC endpoints (Gateway + Interface) |
| `modules/eks/main.tf` | EKS cluster + Karpenter IAM/SQS via submodule |
| `modules/rds/main.tf` | PostgreSQL 16, database subnet placement, SM-managed credentials |
| `modules/s3/main.tf` | Reports bucket (KMS, versioned, EventBridge) + SAM artifacts bucket |
| `modules/ecr/main.tf` | 4 ECR repos (IMMUTABLE, scan-on-push, KMS, lifecycle policy) |
| `modules/cognito/main.tf` | User Pool (SRP, email login) + Web Client + 3 Groups |
| `modules/sqs/main.tf` | Standard queue for notifications |
| `modules/ses/main.tf` | Domain identity + 3 DKIM CNAME records in Route53 |
| `modules/secretsmanager/main.tf` | Empty secret shells (name + KMS, no values) |
| `modules/ssm/main.tf` | 15 non-sensitive config parameters under `/lablumen/config/` |
| `modules/iam/main.tf` | GitHub OIDC provider + pipeline roles + all IRSA roles |
| `.checkov.yaml` | Documented Checkov check suppressions with rationale |
| `.github/workflows/terraform.yml` | 3-stage pipeline: Checkov → plan (+ Infracost) → apply (manual gate) |
| `.github/workflows/terraform-destroy.yml` | Guarded teardown: K8s phase-1 + TF destroy phase-2 |
