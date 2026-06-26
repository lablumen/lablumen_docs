# Account-Portability Refactor + New-Account Bootstrap

Status: **IMPLEMENTED 2026-06-23** across all 4 repos (fmt/validate + YAML-lint pass; helm not installed
locally so no `helm template`). Remaining: provide new account ID, commit+push, run the bootstrap.
Goal reframed (per review): optimize for **bootstrapping a fresh AWS account from zero with minimal
manual steps** — not routine migration.

## Principle
Account-specific values are **derived at runtime**; the only knobs are **AWS credentials + `AWS_ACCOUNT_ID`
+ region/project/env**. **DNS (Route53 zone + ACM cert) stays a manually-owned foundation** that Terraform
only *looks up* (you've already created the zone + verified the cert in the new account).

## Locked decisions
> Revised 2026-06-23 (decisions 1 & 2): for a single-account deployment we chose simplicity over the
> fully-portable variant — hardcoded `backend.tf` literal + a root-level `global-values.yaml`.
1. **State bucket:** literal `bucket` in `backend.tf` (plain `terraform init`); `bootstrap/` derives &
   outputs the matching name. Account move = update that one line. (Partial-backend `backend.hcl` was
   considered and dropped — overkill for one account.)
2. **k8s registry:** one root-level `global-values.yaml` holding `global.imageRegistry`; the
   ApplicationSets add it to `valueFiles`. One line per account. (Not under `services/` — that folder is
   per-service; this value is cross-service.)
3. **Role ARNs:** a single GitHub Variable `AWS_ACCOUNT_ID` per repo; workflows construct
   `arn:aws:iam::${vars.AWS_ACCOUNT_ID}:role/<fixed-name>`.
4. **Order:** refactor all repos first, then bootstrap the new account with the clean config.

---

## Changes by repo

### lablumen-terraform
- **Derive bucket names** (root `locals.tf` + `data.aws_caller_identity`):
  `reports_bucket_name = "${var.project}-reports-${account_id}"`, `frontend = "${var.project}-frontend-${account_id}"`.
  Remove the `*-101` literals from `terraform.tfvars` + the two `*_bucket_name` vars (or default them empty/unused).
- **Backend:** `backend.tf` holds the literal `bucket = "<project>-tfstate-<account_id>"` (plain
  `terraform init`). `bootstrap/` derives the same name from account ID and outputs `state_bucket`
  (copy into `backend.tf`). Update that one line per account.
- **DNS unchanged:** keep `data.aws_route53_zone` + `data.aws_acm_certificate` lookups (foundation).
- Add output `image_registry = "${account_id}.dkr.ecr.${region}.amazonaws.com"` for reference.
- Everything else already account-agnostic (OIDC provider, IRSA + pipeline roles, Cognito/SES/SSM).

### lablumen-shared
- `service-build-push.yml`: **remove the `ecr-registry` input**; after `amazon-ecr-login`, build the image
  name from `steps.login.outputs.registry` (fully dynamic). Keep `ecr-repository` (`lablumen/<svc>`) +
  `role-to-assume` inputs.

### lablumen-app
- `ci.yml` / `frontend.yml`: role ARNs → `arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/<name>`; drop the
  literal `ECR_REGISTRY` (now from the login output). Account ID = one repo Variable.
- `docker-compose.yml` (local dev): parameterize registry via a `.env` var, or leave (decision below).

### lablumen-k8s
- `charts/microservice/templates/deployment.yaml`: image →
  `{{ .Values.global.imageRegistry }}/{{ .Values.image.repository }}:{{ .Values.image.tag }}`.
- `services/<svc>/values.yaml`: `image.repository` → just `lablumen/<svc>` (no registry/account).
- New root-level `global-values.yaml`: `global: { imageRegistry: "<acct>.dkr.ecr.<region>.amazonaws.com" }`
  (one line, set at bootstrap). ApplicationSets (`services-dev`/`-prod`) add it to `valueFiles`.
- `charts/redis` unchanged (public `redis:7-alpine`, not from ECR).

---

## Bootstrap-from-zero runbook (new account)
1. Configure **admin credentials** for the new account (IAM admin user / SSO) → `aws configure`.
2. Set the knobs: GitHub Variable `AWS_ACCOUNT_ID` (app + terraform repos); `backend.tf` `bucket`
   literal; `global-values.yaml` registry line.
3. **DNS already done** (zone + ISSUED cert in the new account). 
4. `cd bootstrap && terraform init && terraform apply` (state bucket) → `cd ..`
   `terraform init` → `terraform apply -target=module.vpc -target=module.eks` → `terraform apply`.
5. Populate the `lablumen/app/database-url` secret; push repos → CI builds/pushes (OIDC works — no SCP);
   `bootstrap-argocd.sh`; verify; enable Bedrock model access.

## Stays manual (foundation / unavoidable — by design)
- Admin credentials for the new account (one-time).
- Route53 zone + ACM cert (**done**), registrar NS (**done**).
- Bedrock model access toggle (account-level).

## Net effect
Account-specific config collapses to: **creds + `AWS_ACCOUNT_ID` GH var + `backend.tf` bucket line +
`global-values.yaml` registry line**. No scattered account IDs in workflows, k8s values, or tfvars.
