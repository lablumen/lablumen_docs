# LabLumen Platform — Bring-Up Runbook

> **Last updated:** 2026-06-24
> Source of truth for recreating the full platform from scratch on account 261523981519.

---

## Phase 0 — Pre-flight checks

Verify these manually before touching Terraform.

```bash
# 1. Confirm AWS identity is lablumen-admin (NOT root — root breaks EKS access entries)
aws sts get-caller-identity
# Expect: "Account": "261523981519", "Arn": "...user/lablumen-admin"

# 2. Confirm ACM wildcard cert is ISSUED
aws acm list-certificates --region us-east-1 \
  --query "CertificateSummaryList[?DomainName=='*.rnld101.xyz']"

# 3. Confirm Route53 zone exists
aws route53 list-hosted-zones-by-name --dns-name rnld101.xyz

# 4. Confirm state bucket exists (from the bootstrap/ stack)
aws s3 ls | grep lablumen-tfstate
```

**GitHub — confirm these are set on each repo before Phase 4:**

| Repo | Vars | Secrets |
|---|---|---|
| lablumen-terraform | `AWS_ACCOUNT_ID` | — |
| lablumen-appointment-service | `AWS_ACCOUNT_ID`, `SONAR_ORGANIZATION` | `SONAR_TOKEN`, `SNYK_TOKEN`, `K8S_REPO_PAT` |
| lablumen-report-service | same | same |
| lablumen-notification-service | same | same |
| lablumen-frontend | `AWS_ACCOUNT_ID`, `SONAR_ORGANIZATION` | `SONAR_TOKEN`, `SNYK_TOKEN`, `K8S_REPO_PAT` |
| lablumen-shared | — | — (must be public or org-accessible) |

---

## Phase 1 — State bootstrap + init

```bash
cd lablumen-terraform

# Only run bootstrap if the state bucket does not already exist:
cd bootstrap && terraform init && terraform apply && cd ..

# Init the root config against the existing state bucket
terraform init

# Validate (should be clean)
terraform validate && terraform fmt -recursive
```

---

## Phase 2 — VPC + EKS (targeted first apply)

Run locally as `lablumen-admin`. The creator-admin mechanism fires here, granting permanent cluster-admin without extra config.

```bash
terraform apply -target=module.vpc -target=module.eks
```

Wait ~10–15 min. Then:

```bash
# Update kubeconfig
aws eks update-kubeconfig --name lablumen-eks --region us-east-1

# Confirm nodes are Ready
kubectl get nodes
```

---

## Phase 3 — Full apply

```bash
terraform apply
```

Creates: RDS, all 4 ECR repos, SQS, SES + DKIM CNAMEs, Cognito, Secrets Manager shells, SSM params (14 keys), IAM roles (OIDC + all IRSA), k8s namespaces (`lablumen`, `lablumen-dev`, `external-secrets`) + all ServiceAccounts.

**After apply — 3 required manual actions:**

```bash
# 1. Populate the DB secret
#    Use `terraform output database_url_template` to get the exact format — it includes
#    the correct +asyncpg driver prefix and the RDS endpoint with a single :5432 port.
TEMPLATE=$(terraform output -raw database_url_template)
# → postgresql+asyncpg://lablumen:<PASSWORD>@<host>:5432/lablumen

PASS=$(aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw rds_master_user_secret_arn) \
  --query SecretString --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

DSN="${TEMPLATE/<PASSWORD>/$PASS}"

aws secretsmanager put-secret-value \
  --secret-id lablumen/app/database-url \
  --secret-string "$DSN"

# 2. Populate Grafana admin secret
aws secretsmanager put-secret-value \
  --secret-id lablumen/app/grafana-admin \
  --secret-string '{"admin-user":"admin","admin-password":"<choose-a-password>"}'

# 3. Update global-values.yaml with the new account registry
REGISTRY=$(terraform output -raw image_registry)
# → paste into lablumen-k8s/global-values.yaml:
#   global:
#     imageRegistry: "<paste here>"
```

After updating `global-values.yaml`, commit and push `lablumen-k8s` to GitHub.

---

## Phase 4 — CI (build all images)

For each service repo, trigger CI by pushing to main. Each push runs: Trivy scan → ECR push by 7-char SHA → yq writes `image.tag` back to `lablumen-k8s/services/<svc>/values-dev.yaml`.

```bash
# In each of: lablumen-appointment-service, lablumen-report-service,
#             lablumen-notification-service, lablumen-frontend
git commit --allow-empty -m "ci: trigger initial build" && git push
```

Wait for all 4 CI runs to succeed. Verify ECR repos have images:

```bash
aws ecr describe-images --repository-name lablumen/appointment-service --region us-east-1
aws ecr describe-images --repository-name lablumen/frontend --region us-east-1
# etc.
```

---

## Phase 5 — ArgoCD bootstrap

> **Requires Helm 3** — Helm 4 breaks ArgoCD install (kubeenv.RetryingRoundTripper timeout, learnt the hard way).

```bash
# Confirm Helm version — must be 3.x
helm version

cd lablumen-k8s
bash scripts/bootstrap-argocd.sh
```

This installs ArgoCD and applies the root-app, which triggers the App-of-Apps cascade:

| Wave | Apps |
|---|---|
| 0 | metrics-server, ESO (`lablumen-eso`), LBC, Karpenter, Karpenter CRDs, external-dns |
| 1 | ClusterSecretStores, monitoring-secret (ESO → Grafana creds) |
| 2 | All 5 services-dev + 5 services-prod + redis-dev + redis-prod + monitoring (Grafana/Prometheus) |

---

## Phase 6 — CD verify

```bash
# Watch all apps converge (target: 17 Synced/Healthy)
kubectl -n argocd get applications -w

# ArgoCD UI (once external-dns creates the record):
# https://argocd.rnld101.xyz  (admin / argocd-initial-admin-secret)

# Verify ESO synced secrets for each service (including frontend Cognito config)
kubectl -n lablumen-dev get externalsecrets
kubectl -n lablumen-dev get secrets

# Check pods are Running
kubectl -n lablumen-dev get pods

# Smoke tests
curl https://api-dev.rnld101.xyz/healthz
curl https://app-dev.rnld101.xyz
```

---

## Common failure modes

| Symptom | Fix |
|---|---|
| ESO `SecretSyncError` | Check `ssm:DescribeParameters` on the ESO IAM role — it's in place; verify the ClusterSecretStore is Healthy |
| SM secret "scheduled for deletion" | `aws secretsmanager restore-secret --secret-id lablumen/app/database-url` |
| ArgoCD install hangs / times out | Wrong Helm version — install Helm 3.17.x |
| `appointment-service` / `report-service` crash: `invalid literal for int` in DSN | Secret has wrong DSN format — use `terraform output database_url_template` and verify `+asyncpg` prefix and single `:5432` |
| `frontend` pod crashloop: `mkdir /var/cache/nginx failed (30: Read-only file system)` | emptyDir volumes for `/var/cache/nginx` and `/var/run` missing — check `extraVolumeMounts` in `services/frontend/values.yaml` |
| `frontend` blank white screen: `Both UserPoolId and ClientId are required` | ESO hasn't synced yet — check `kubectl -n lablumen-dev get externalsecret frontend-secrets` and the `aws-parameter-store` ClusterSecretStore status |
| `frontend` pod `ImagePullBackOff` | Phase 4 CI hasn't run yet — ECR image doesn't exist |
| `prod` pods `ImagePullBackOff` | Expected — prod uses placeholder `0.1.0` tag until you cut a GitHub Release |
| Karpenter `AccessDenied: iam:PassRole` | Role name mismatch between `ec2nodeclass.yaml` and the IAM role — Terraform now uses a deterministic name `KarpenterNodeRole-lablumen-eks`; verify it matches `aws iam get-role --role-name KarpenterNodeRole-lablumen-eks` |
| `external-dns` not creating records | Check AppProject `sourceRepos` includes the external-dns helm chart repo |
| Pending pod: `0/N nodes: Too many pods` | Karpenter scale-out; check controller logs: `kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter` |

---

## Post-bootstrap steps

```bash
# Rotate ArgoCD admin password, then delete the initial secret
kubectl -n argocd delete secret argocd-initial-admin-secret

# Retrieve Grafana admin password
aws secretsmanager get-secret-value \
  --secret-id lablumen/app/grafana-admin \
  --query SecretString --output text

# Prometheus (internal only — no ingress by design)
kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus 9090
```

---

## Promote to prod

1. In any service repo, create a GitHub Release (e.g. `v1.0.0`)
2. `service-release.yml` retags ECR `:sha` → `:semver` and writes `values-prod.yaml`
3. ArgoCD syncs the prod namespace automatically

---

## Optional: enable Bedrock (report AI)

AWS Console → Amazon Bedrock → Model access → enable **Nova Lite** in `us-east-1`.

---

## Destroy

Use the `terraform-destroy.yml` workflow (workflow_dispatch, confirm = `"destroy"`, gated by `production` environment). It scales down ArgoCD, drains ALBs, then runs `terraform destroy`. See `extras/CLAUDE.md §Update 2026-06-24` for the full procedure.
