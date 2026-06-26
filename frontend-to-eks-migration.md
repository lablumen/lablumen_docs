# Frontend: S3/CloudFront → EKS Migration

**Date:** 2026-06-24  
**Reason:** AWS account verification delay blocking CloudFront access. Frontend moved to run as a containerized service on EKS alongside all backend services.

---

## Files Changed

### lablumen-shared
| Action | File | Detail |
|---|---|---|
| Modified | `.github/workflows/service-pr.yml` | Added `runtime` input (`node\|python`, default `python`). Added `node-version`, `sonar-sources` inputs. Node path: setup-node + npm ci + npm run build + Snyk npm. Python path unchanged. SonarCloud uses `sonar-sources` input. Existing Python callers need no changes (runtime defaults to `python`). |
| Deleted | `.github/workflows/frontend-deploy.yml` | Entire S3 sync + CloudFront invalidation workflow removed. |

### lablumen-frontend
| Action | File | Detail |
|---|---|---|
| Rewritten | `.github/workflows/ci.yml` | PR → `service-pr.yml` (runtime: node, sonar-sources: src). Push to main → `service-build-push.yml` (ECR: lablumen/frontend, role: lablumen-frontend-build). Release → `service-release.yml` (retag SHA→semver). |

### lablumen-terraform
| Action | File | Detail |
|---|---|---|
| Deleted | `modules/cloudfront/` | Entire directory removed (main.tf, variables.tf, outputs.tf). |
| Modified | `modules/s3/main.tf` | Removed `module.frontend_bucket` block. |
| Modified | `modules/s3/variables.tf` | Removed `frontend_bucket_name` variable. |
| Modified | `modules/s3/outputs.tf` | Removed `frontend_bucket_id`, `frontend_bucket_arn`, `frontend_bucket_regional_domain_name` outputs. |
| Modified | `locals.tf` | Removed `frontend_bucket_name` local. Updated `frontend_fqdn` comment (now feeds k8s ingress host). |
| Modified | `data.tf` | Updated ACM cert comment (now for ALB, not CloudFront). |
| Modified | `modules/iam/outputs.tf` | Renamed `frontend_deploy_role_arn` → `frontend_build_role_arn`. Resource reference updated from `aws_iam_role.frontend_deploy` → `aws_iam_role.frontend_build`. |

### lablumen-k8s
| Action | File | Detail |
|---|---|---|
| Created | `services/frontend/values.yaml` | Base values: name=frontend, service.port=80 (nginx), ingress enabled with ALB group. |
| Created | `services/frontend/values-dev.yaml` | Dev overrides: image.tag (bumped by CI), ingress host + cert ARN placeholders. |
| Created | `services/frontend/values-prod.yaml` | Prod overrides: image.tag, replicaCount=2, PDB enabled, ingress host + cert ARN placeholders. |

---

## Still TODO (manual steps)

### lablumen-terraform root main.tf (not yet created)
When you write the root `main.tf`, make sure to:
1. **Add `lablumen/frontend` to the ECR repositories list** in the `ecr` module call.
2. **Create the `lablumen-frontend-build` IAM role** in the `iam` module:
   - OIDC trust for `repo:lablumen/lablumen-frontend:*`
   - ECR push policy scoped to the `lablumen/frontend` ECR repo ARN
   - Do NOT create `frontend_deploy` role (that was the old S3 deployer).
3. **Do NOT call `module.cloudfront`** — the module directory has been deleted.
4. **Do NOT call `module.frontend_bucket`** — removed from `modules/s3/`.

### lablumen-k8s values files
Fill in the placeholder values before deploying:
- `services/frontend/values.yaml` → `image.repository`: set to `<account_id>.dkr.ecr.<region>.amazonaws.com/lablumen/frontend`
- `services/frontend/values-dev.yaml` → `ingress.host` and `ingress.annotations.certificate-arn`
- `services/frontend/values-prod.yaml` → `ingress.host` and `ingress.annotations.certificate-arn`

These values come from terraform outputs:
- Registry: `module.ecr.repository_urls["lablumen/frontend"]`
- ACM cert ARN: `data.aws_acm_certificate.primary.arn`
- Frontend hostname: `local.frontend_fqdn`

### GitHub repository variables/secrets (lablumen-frontend repo)
Ensure these are set:
- `vars.AWS_ACCOUNT_ID`
- `vars.SONAR_ORGANIZATION`
- `secrets.SONAR_TOKEN`
- `secrets.SNYK_TOKEN`
- `secrets.K8S_REPO_PAT`

---

## Architecture after this change

```
Browser → Route53 → ALB (EKS IngressGroup: lablumen) → frontend pod (nginx:80)
                                                              ↓ proxy /api/v1/reports/*
                                                         report-service:8000
                                                              ↓ proxy /api/v1/*
                                                         appointment-service:8000
```

The nginx container in the frontend pod proxies all API traffic to backend k8s Services by their
cluster-internal DNS names (`report-service`, `appointment-service`, `notification-service`).
This is already wired in `lablumen-frontend/nginx.conf` — no changes needed there.
