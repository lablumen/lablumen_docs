# LabLumen Terraform Refactor + Pipeline Plan

Status: **awaiting go-ahead to implement** (Terraform repo + its pipeline first).
Companion: decisions are also logged in `extras/CLAUDE.md`.

## Goal
Restructure `lablumen-terraform` from scratch — keep what's needed, add what's missing, delete what
isn't — so it provisions **all** AWS infrastructure the LabLumen app needs, with one-module-per-AWS-service,
remote state, least-privilege CI/CD identity, and the EKS/k8s handshake the new `lablumen-k8s` expects.

## Confirmed decisions
1. **State backend:** one-time `scripts/bootstrap-state.sh` (AWS CLI) creates a versioned+encrypted S3
   bucket + DynamoDB lock table; root uses `backend "s3"` with `dynamodb_table`.
2. **Env model:** single environment / single cluster. dev + prod are k8s namespaces (`lablumen-dev` /
   `lablumen`) on one EKS cluster, one RDS.
3. **Modules:** strict one-per-AWS-service (names below).
4. **Pipelines:** inline workflows per repo (no shared repo).
5. **OIDC IAM roles (least privilege):** GitHub OIDC provider + `tf-plan` (ReadOnly+state, PR),
   `tf-apply` (Admin+state, main + GitHub Environment approval), `app-ci-ecr` (ECR push only),
   `frontend-deploy` (S3 put to site bucket + CloudFront invalidation only).
6. **Scanners:** SonarCloud (SAST, `SONAR_TOKEN`) + Snyk free (SCA, `SNYK_TOKEN`) + Trivy (image) in
   app CI; **Checkov** for the Terraform IaC scan stage.
7. **CD:** dev auto (CI writes `services/<svc>/values-dev.yaml` in lablumen-k8s on push to main);
   prod 100% manual (human edits `values-prod.yaml`).
8. **Observability:** lean — EKS control-plane log types → CloudWatch + Lambda log group(s). (Prometheus
   /Grafana stays a k8s bonus.)
9. **Frontend:** S3 static bucket + CloudFront (OAC, HTTPS); **drop** the `lablumen/frontend` ECR repo.
10. **EKS access:** Access Entries (`authentication_mode = "API"`); cluster-admin granted to a list of
    admin principal ARNs (you, for the ArgoCD bootstrap) + the `tf-apply` role.
11. **Domain/TLS:** parameterized `domain_name` (no hardcoded `rnld101.xyz`). Hosted zone + ACM cert are
    **looked up via data sources** (NOT created). DNS records created **dynamically**: CloudFront alias
    by Terraform; API/ingress records by an **external-dns** addon (Terraform makes its IRSA role; the
    addon goes in lablumen-k8s). HTTPS via the existing cert (ALB cert auto-discovery + CloudFront).
12. **Versions:** stay on the proven line — `aws ~> 5.60`, EKS module `~> 20.x`, kubernetes `~> 2.31`,
    and keep the existing tested module pins (vpc ~>5.8, rds ~>6.9, s3 ~>4.1, sqs ~>4.2, lambda ~>7.20,
    iam ~>5.44). EKS v20 already supports Access Entries. (Latest available is aws 6.51 / EKS 21.23 —
    deferred to avoid the v6 breaking blast radius we can't `init`-validate here.)
13. **Notifications:** none (GitHub-native).
14. **Build scope now:** Terraform repo + its pipeline + bootstrap script. App CI/CD, frontend deploy,
    and the k8s-side external-dns addon + ArgoCD bootstrap script are a **follow-up pass**.

## Target structure
```
lablumen-terraform/
├── README.md
├── versions.tf            # terraform >=1.6; aws ~>5.60; kubernetes ~>2.31
├── backend.tf             # backend "s3" { bucket, key, region, dynamodb_table, encrypt }  (ENABLED)
├── providers.tf           # aws (default_tags incl. Environment/Owner) + kubernetes (eks exec auth)
├── data.tf                # aws_route53_zone (by name) + aws_acm_certificate (by domain)  [lookups only]
├── locals.tf              # cluster_name, common tags
├── variables.tf           # incl. domain_name (no default), owner, environment, cluster_admin_principals,
│                          #       github_org, github_repos, acm_certificate_domain
├── terraform.tfvars       # NON-SECRET defaults only (NOT the domain — see note)
├── main.tf                # module wiring
├── kubernetes.tf          # namespaces + IRSA ServiceAccounts (new k8s contract)
├── outputs.tf
├── scripts/
│   └── bootstrap-state.sh # one-time: S3 state bucket (versioned/encrypted/block-public) + DynamoDB lock
├── .github/workflows/
│   └── terraform.yml      # checkov scan → plan → manual approval → apply (OIDC tf-plan/tf-apply)
└── modules/
    ├── vpc/               # (was network) VPC, subnets (public/private/db), NAT, S3 gw + interface endpoints
    ├── eks/               # cluster + managed node group + karpenter submodule + Access Entries + CP logging
    ├── rds/               # (was data) Postgres + SG, SM-managed master password
    ├── s3/                # (was storage) reports bucket (KMS) + frontend static-site bucket (OAC)
    ├── cloudfront/        # NEW: SPA distribution (OAC→site bucket, ACM cert) + Route53 alias record
    ├── ecr/              # repos (frontend repo removed)
    ├── sqs/               # (was messaging/queue) notifications queue
    ├── ses/               # (was messaging/email) sender identity
    ├── lambda/            # AI lambda + S3 trigger + log group
    ├── cognito/           # user pool + SPA client + role groups
    ├── secretsmanager/    # (was secrets/SM) runtime secret shells
    ├── ssm/               # (was secrets/SSM) non-sensitive config params
    └── iam/               # (was irsa + github-actions.tf) GitHub OIDC provider + 4 pipeline roles
                           #   + IRSA roles: eso(lablumen-eso), report, notification, lbc, external-dns, ai-lambda
```
No separate `cloudwatch` or `route53` module (EKS/Lambda own their logs; the only TF-managed record is
the CloudFront alias, owned by the `cloudfront` module) — avoids empty/overkill modules.

## Module-by-module mapping (keep / rename / create / delete)
| Current | Action | Target |
|---|---|---|
| `modules/network` | rename + keep | `modules/vpc` (unchanged resources) |
| `modules/eks` | keep + extend | add `authentication_mode="API"` + `access_entries`, `cluster_enabled_log_types`, log retention |
| `modules/data` | rename | `modules/rds` |
| `modules/storage` | rename + extend | `modules/s3` (add frontend static-site bucket) |
| — | **create** | `modules/cloudfront` (SPA distribution + alias record) |
| `modules/messaging` | split | `modules/sqs` + `modules/ses` |
| `modules/secrets` | split | `modules/secretsmanager` + `modules/ssm` |
| `modules/irsa` + root `github-actions.tf` | merge → rename | `modules/iam` (OIDC provider + pipeline roles + IRSA roles incl. external-dns) |
| `modules/ecr` | keep | drop `lablumen/frontend` from `ecr_repositories` |
| `modules/lambda`,`cognito` | keep | (lambda: add explicit log group) |
| root `versions.tf` backend block (commented) | enable | `backend.tf` |
| root `kubernetes.tf` | rewrite | new namespaces + SAs (below) |

## `kubernetes.tf` (new k8s contract)
- Namespaces: `external-secrets`, `lablumen`, **`lablumen-dev`**.
- IRSA ServiceAccounts (annotated with role ARNs from `modules/iam`):
  - `lablumen-eso` (ns external-secrets)  ← renamed from `external-secrets`
  - `karpenter`, `aws-load-balancer-controller`, **`external-dns`** (ns kube-system)
  - `report-service`, `notification-service` in **both** `lablumen` and `lablumen-dev`
- Service IRSA roles trust both `lablumen:<svc>` and `lablumen-dev:<svc>` subjects (one role per service,
  works in both namespaces). → **k8s follow-up:** set dev charts `serviceAccount.create:false` (Terraform
  owns dev SAs now) so no role ARN is hardcoded in the GitOps repo.
- appointment-service: no IRSA, no Terraform SA (its chart self-creates a plain SA in both namespaces).

## IAM (modules/iam) — pipeline roles + trust
- **GitHub OIDC provider** (token.actions.githubusercontent.com).
- `tf-plan`  → trust `repo:<org>/lablumen-terraform:pull_request`; ReadOnlyAccess + state bucket/lock RW.
- `tf-apply` → trust `repo:<org>/lablumen-terraform:ref:refs/heads/main` (+ GitHub Environment approval);
  AdministratorAccess + state bucket/lock RW.
- `app-ci-ecr` → trust `repo:<org>/lablumen-app:*`; `ecr:GetAuthorizationToken` + push to `lablumen/*` repos.
- `frontend-deploy` → trust `repo:<org>/lablumen-app:*`; `s3:PutObject/DeleteObject/ListBucket` on the
  site bucket + `cloudfront:CreateInvalidation` on the distribution.
- IRSA roles: eso (SM `lablumen/app/*` + SSM `/lablumen/config/*`), report-service (S3+Bedrock),
  notification-service (SQS+SES), lbc (LB controller policy), **external-dns** (Route53 change records on
  the looked-up hosted zone), ai-lambda (Textract+Bedrock+S3).

## Terraform pipeline (`.github/workflows/terraform.yml`)
- **PR (paths: `**/*.tf`, etc.):** `fmt -check` → `validate` → **Checkov** (SARIF to GitHub Security) →
  `plan` (assume `tf-plan` via OIDC) → post plan summary.
- **push to `main`:** scan → plan → **`apply`** job using GitHub Environment `production` (required
  reviewers = the manual approval gate) assuming `tf-apply` via OIDC.
- No static AWS keys (OIDC only). State locked via DynamoDB.

## Bootstrap & run order (operator runbook)
1. `scripts/bootstrap-state.sh` (once, local creds) → S3 state bucket + DynamoDB lock table.
2. Enable `backend.tf`, `terraform init` (migrate), set `TF_VAR_domain_name` etc., `terraform apply`
   (or via pipeline) → all AWS infra + EKS + namespaces/SAs.
3. App CI builds + pushes images to ECR (follow-up pass).
4. `lablumen-k8s/scripts/bootstrap-argocd.sh` (once) → kubeconfig, helm install argo-cd, apply root-app.
5. Thereafter: code change → CI image → CD writes values-dev → ArgoCD auto-syncs.

## Notes / guardrails
- **Domain is never hardcoded.** `domain_name` has no default; set via `TF_VAR_domain_name` (pipeline
  variable) or an untracked `*.auto.tfvars`. `acm_certificate_domain` defaults to `*.${domain_name}`.
- Tags: add `Environment` (default `shared`) + `Owner` (default `rnld101`) to provider `default_tags`
  (rubric). Both overridable.
- I cannot run `terraform fmt/init/validate` here (no terraform binary) — you'll run those; I'll keep
  syntax tight and pin proven versions.

## Cross-repo follow-ups (next pass, after this is approved)
- lablumen-app: CI (Sonar/Snyk/Trivy + ECR push by SHA via `app-ci-ecr`) + CD (write values-dev in
  lablumen-k8s) + frontend build/deploy (S3 sync + CF invalidation via `frontend-deploy`).
- lablumen-k8s: add `external-dns` addon (uses the IRSA role) + `scripts/bootstrap-argocd.sh`; flip dev
  report/notification SAs to `create:false`; set ingress hosts to `api.${domain}` + HTTPS.
