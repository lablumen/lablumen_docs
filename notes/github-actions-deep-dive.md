# LabLumen — GitHub Actions & CI/CD Deep Dive

> Covers every workflow, every security tool, OIDC authentication, secrets vs variables, SAM, Checkov, Trivy, Snyk, SonarCloud, Infracost — from first principles, tied to the exact LabLumen configuration. Read this before your review.

---

## Table of Contents

1. [GitHub Actions Fundamentals](#1-github-actions-fundamentals)
2. [The Polyrepo CI/CD Architecture](#2-the-polyrepo-cicd-architecture)
3. [Trunk-Based Development in LabLumen](#3-trunk-based-development-in-lablumen)
4. [Reusable Workflows — The lablumen-shared Pattern](#4-reusable-workflows--the-lablumen-shared-pattern)
5. [OIDC Authentication — No Static Keys, Ever](#5-oidc-authentication--no-static-keys-ever)
6. [Secrets vs Variables — GitHub's Two Config Systems](#6-secrets-vs-variables--githubs-two-config-systems)
7. [Permissions Block — Least Privilege](#7-permissions-block--least-privilege)
8. [The PR Gate — service-pr.yml](#8-the-pr-gate--service-pryml)
9. [SAST — Static Application Security Testing (SonarCloud)](#9-sast--static-application-security-testing-sonarcloud)
10. [SCA — Software Composition Analysis (Snyk)](#10-sca--software-composition-analysis-snyk)
11. [Container Security Scanning — Trivy](#11-container-security-scanning--trivy)
12. [The Dev Deploy — service-build-push.yml](#12-the-dev-deploy--service-build-pushyml)
13. [GitOps Write-Back — The Image Tag Bump](#13-gitops-write-back--the-image-tag-bump)
14. [Production Promotion — service-release.yml](#14-production-promotion--service-releaseyml)
15. [The Build-Once / Promote Pattern](#15-the-build-once--promote-pattern)
16. [Frontend CI — Three Triggers in One Workflow](#16-frontend-ci--three-triggers-in-one-workflow)
17. [AI Service — SAM (AWS Serverless Application Model)](#17-ai-service--sam-aws-serverless-application-model)
18. [Terraform Pipeline — scan / plan / apply](#18-terraform-pipeline--scan--plan--apply)
19. [Checkov — IaC Security Scanning](#19-checkov--iac-security-scanning)
20. [Infracost — Cost Estimation on Every PR](#20-infracost--cost-estimation-on-every-pr)
21. [Terraform Destroy — The Guarded Teardown](#21-terraform-destroy--the-guarded-teardown)
22. [Artifacts — Passing Files Between Jobs](#22-artifacts--passing-files-between-jobs)
23. [GitHub Environments — The Approval Gate](#23-github-environments--the-approval-gate)
24. [The Complete CI/CD Journey — End to End](#24-the-complete-cicd-journey--end-to-end)
25. [Key Design Decisions & Defences](#25-key-design-decisions--defences)

---

## 1. GitHub Actions Fundamentals

### What is GitHub Actions?

GitHub Actions is GitHub's built-in CI/CD platform. It runs automation scripts (called **workflows**) in response to events (pushes, PRs, releases, manual triggers). Every workflow runs on a **runner** — a temporary Linux VM (or Windows/macOS) that GitHub provisions, runs your steps, then destroys.

### The anatomy of a workflow file

```yaml
name: ci                          # display name in the GitHub UI

on:                               # TRIGGER: what events fire this workflow
  pull_request:                   # fires on any PR opened/updated
  push:
    branches: [main]              # fires only when a push lands on main

permissions:                      # what GitHub API tokens this workflow can use
  id-token: write                 # required for OIDC authentication with AWS
  contents: read                  # can read repo contents

env:                              # workflow-level environment variables
  AWS_REGION: us-east-1

jobs:
  my-job:                         # job id (internal name)
    runs-on: ubuntu-latest        # what runner to use
    steps:
      - uses: actions/checkout@v4 # ACTION: a pre-built step (checkout the repo)
      - name: Run tests           # STEP: a named step
        run: pytest               # what command to execute
```

### Key concepts

| Term | Meaning |
|---|---|
| **Workflow** | A YAML file in `.github/workflows/`. One file = one workflow. |
| **Event / Trigger** | What causes the workflow to run (`push`, `pull_request`, `release`, `workflow_dispatch`, `workflow_call`). |
| **Job** | A group of steps. Each job runs on its own fresh runner (no shared filesystem between jobs by default). |
| **Step** | A single command (`run:`) or an action (`uses:`). Steps within a job share the same filesystem. |
| **Runner** | The VM that executes a job. `ubuntu-latest` = GitHub-hosted Ubuntu, free for public repos. |
| **Action** | A reusable step published to the GitHub Marketplace (e.g., `actions/checkout@v4`, `aws-actions/configure-aws-credentials@v4`). |
| **`@v4`** | Version pin on an action. Always pin actions — an unpinned `@main` would execute whatever code the action author pushes. |

### Job ordering and parallelism

By default, all jobs in a workflow run **in parallel**. Use `needs:` to make a job wait:

```yaml
jobs:
  lint:           # runs first (no needs)
  test:
    needs: lint   # waits for lint to succeed
  deploy:
    needs: [lint, test]   # waits for BOTH
```

---

## 2. The Polyrepo CI/CD Architecture

LabLumen uses a **polyrepo** structure — each service lives in its own repository:

```
lablumen-shared              ← Reusable workflows (the central pattern library)
lablumen-terraform           ← Infrastructure (its own CI pipeline)
lablumen-k8s                 ← GitOps config (ArgoCD reads this, no CI pipeline)
lablumen-appointment-service ← Service with ci.yml + release.yml
lablumen-report-service      ← Same
lablumen-notification-service ← Same
lablumen-frontend            ← Frontend with ci.yml (handles PR + push + release)
lablumen-ai-service          ← Lambda (SAM-based CI, different flow)
```

### Why does this design exist?

Each service can be built, tested, and deployed independently. A breaking change in the report-service doesn't block the appointment-service CI. Teams can move at different paces, with separate histories and release cadences.

The risk of polyrepo is **duplication** — if you write the CI pipeline separately for each service, you maintain 4+ copies. A Trivy version update means 4 PRs. **The lablumen-shared reusable workflow pattern solves this entirely.**

---

## 3. Trunk-Based Development in LabLumen

**Trunk-based development** means everyone commits to `main` (the trunk). No long-lived feature branches. Every commit to `main` is potentially deployable.

```
Developer workflow:
  1. Create a short-lived branch (e.g., feat/add-appointment-endpoint)
  2. Push — opens a PR
  3. PR triggers service-pr.yml (lint + test + SAST + SCA + Trivy)
  4. All checks pass → reviewer approves → merge to main
  5. Push to main triggers service-build-push.yml → image built + pushed to ECR + deployed to DEV
  6. Validate in DEV
  7. Create a GitHub Release (e.g., v1.2.0) → triggers service-release.yml → promoted to PROD
```

**There is no manual `docker build` or `kubectl apply` by any developer.** The pipeline handles everything. A developer's only deployment action is creating a GitHub Release.

---

## 4. Reusable Workflows — The lablumen-shared Pattern

### The problem reusable workflows solve

Without them, `lablumen-appointment-service/.github/workflows/ci.yml` would contain 170 lines of Trivy, Snyk, SonarCloud, ECR login, docker build, git tag bump logic. And so would `report-service`, `notification-service`, and `frontend`. Any change (e.g., upgrading Trivy severity threshold) requires 4 PRs.

### The solution: `workflow_call`

`lablumen-shared` contains three reusable workflows. They use `on: workflow_call:` instead of `push`/`pull_request`. This means **they cannot be triggered by events directly** — they are called by other workflows:

```yaml
# In lablumen-appointment-service/.github/workflows/ci.yml
jobs:
  pr:
    uses: lablumen/lablumen-shared/.github/workflows/service-pr.yml@main
    with:
      service-name: appointment-service
    secrets:
      SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
```

The `uses:` format `<org>/<repo>/.github/workflows/<file>.yml@<ref>` calls the workflow in a different repo at a specific Git ref. `@main` means always use the latest version of `service-pr.yml` on the main branch of `lablumen-shared`.

### The three shared workflows

| Workflow | Trigger context | What it does |
|---|---|---|
| `service-pr.yml` | Called on `pull_request` | lint + test + SAST (Sonar) + SCA (Snyk) + container scan (Trivy) |
| `service-build-push.yml` | Called on `push` to main | Build image, Trivy gate, push to ECR (OIDC), write SHA to values-dev.yaml |
| `service-release.yml` | Called on `release` | Retag ECR image SHA→semver, write semver to values-prod.yaml |

### Inputs and secrets in reusable workflows

Reusable workflows define `inputs:` (non-sensitive, visible in logs) and `secrets:` (sensitive, redacted in logs). Callers pass values explicitly:

```yaml
# In service-pr.yml (the reusable workflow)
on:
  workflow_call:
    inputs:
      service-name:
        required: true
        type: string
      runtime:
        required: false
        type: string
        default: python       # caller doesn't need to pass this if using Python
    secrets:
      SONAR_TOKEN:
        required: true

# In ci.yml (the caller)
jobs:
  pr:
    uses: lablumen/lablumen-shared/.github/workflows/service-pr.yml@main
    with:
      service-name: appointment-service
      # runtime: python   ← not passed, uses the default
    secrets:
      SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}   # caller passes its own secret
```

**Secrets do not flow automatically** between caller and callee. The caller must explicitly pass `secrets: { SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }} }`. This is intentional — the callee explicitly declares which secrets it needs, and the caller explicitly consents to passing them.

### `@main` vs pinned ref

Using `@main` means a single commit to `lablumen-shared` updates the pipeline behaviour for ALL services simultaneously. This is powerful (one fix propagates everywhere) and risky (one bug propagates everywhere). Pinning to a SHA like `@abc1234` would give stability at the cost of manual updates. For a controlled team on a single platform, `@main` is the right trade-off.

---

## 5. OIDC Authentication — No Static Keys, Ever

This is the single most important security design in the entire CI/CD system. Understand this deeply.

### The old (wrong) way

```yaml
# BAD — DO NOT DO THIS
env:
  AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
  AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
```

Static IAM access keys:
- Long-lived — valid for months/years until manually rotated
- Easily leaked — accidentally printed in logs, committed to Git, stored in GitHub secrets indefinitely
- Broad — the key has permissions; there's no binding to a specific workflow or repo
- Hard to audit — a stolen key's usage looks identical to legitimate usage

### The new (correct) way: OIDC federation

OIDC (OpenID Connect) is a standard for identity federation. GitHub is an OIDC identity provider. AWS is configured to trust GitHub's JWTs.

**How it works — step by step:**

```
1. Developer merges to main → push event fires the ci.yml workflow

2. GitHub runner starts. The job has `permissions: id-token: write`.
   This tells GitHub: "this job is allowed to request an OIDC token."

3. The `aws-actions/configure-aws-credentials@v4` action runs.
   It calls GitHub's OIDC endpoint: "give me a signed JWT for this job."
   
   GitHub issues a JWT containing:
     sub: "repo:lablumen/lablumen-appointment-service:ref:refs/heads/main"
     aud: "sts.amazonaws.com"
     iss: "https://token.actions.githubusercontent.com"
     repository: "lablumen/lablumen-appointment-service"
     workflow: "ci"
     ref: "refs/heads/main"
     sha: "abc1234..."
   
   This JWT is cryptographically signed by GitHub's private key.

4. The action calls: STS AssumeRoleWithWebIdentity
   - Role ARN: arn:aws:iam::025392543842:role/lablumen-app-ci-ecr
   - WebIdentityToken: the JWT from step 3

5. AWS STS verifies the JWT:
   - Is the signature from token.actions.githubusercontent.com? (matches the registered OIDC provider)
   - Does the trust policy condition match?
     Trust policy says: StringLike on sub = "repo:lablumen/lablumen-*:*"
     JWT sub = "repo:lablumen/lablumen-appointment-service:ref:refs/heads/main" ✓ MATCH

6. STS returns temporary credentials (AccessKeyId, SecretAccessKey, SessionToken)
   - These expire in 1 hour
   - These are automatically set in the runner's environment variables

7. All subsequent `aws` CLI and SDK calls in the job use these temporary credentials.

8. Job finishes → credentials expire → no cleanup needed → no rotation needed
```

### The trust policy — what makes it secure

The IAM role's trust policy specifies exactly which GitHub identities can assume it:

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::025392543842:oidc-provider/token.actions.githubusercontent.com"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
    },
    "StringLike": {
      "token.actions.githubusercontent.com:sub": "repo:lablumen/*"
    }
  }
}
```

**`StringEquals` on `aud`** — only JWTs with audience `sts.amazonaws.com` are valid. This is the correct audience for STS assume-role calls.

**`StringLike` on `sub`** — only repositories under the `lablumen` GitHub org can assume this role. A completely different GitHub account with a compromised token cannot assume this role.

**`StringEquals` vs `StringLike`** — the tf-apply role uses `StringEquals` (exact match on `repo:lablumen/lablumen-terraform:environment:production`) because only the specific Terraform production environment job should get admin credentials. The app-ci-ecr role uses `StringLike` to allow any of the 3 backend service repos.

### The five OIDC roles in LabLumen

| Role | Who can assume | What it can do |
|---|---|---|
| `lablumen-tf-plan` | `repo:lablumen/lablumen-terraform:*` (PR or main) | ReadOnlyAccess + S3 state read/write |
| `lablumen-tf-apply` | `repo:lablumen/lablumen-terraform:environment:production` ONLY | AdministratorAccess |
| `lablumen-app-ci-ecr` | `repo:lablumen/lablumen-*:*` (any backend service) | ECR push (3 backend repos) + KMS decrypt |
| `lablumen-frontend-build` | `repo:lablumen/lablumen-frontend:*` ONLY | ECR push (frontend repo only) |
| `lablumen-ai-lambda-deploy` | `repo:lablumen/lablumen-ai-service:*` | SAM deploy permissions (CloudFormation, Lambda, S3, SSM, IAM PassRole) |

### The `permissions: id-token: write` requirement

Without this in the workflow/job, GitHub will NOT issue an OIDC token. This is a safety mechanism — a workflow cannot accidentally obtain AWS credentials it wasn't explicitly set up to use.

```yaml
permissions:
  id-token: write    # allows the OIDC token request
  contents: read     # allows reading the repository
```

---

## 6. Secrets vs Variables — GitHub's Two Config Systems

GitHub has two separate systems for storing configuration at the organisation, repo, or environment level.

### GitHub Secrets

- **Encrypted** at rest
- **Redacted** in logs (if a value appears in output, GitHub replaces it with `***`)
- **Write-only** — you cannot read them back once set; you can only override or delete
- **Accessed in YAML as `${{ secrets.MY_SECRET }}`**
- **Passed into reusable workflows explicitly** (not inherited automatically)

**Secrets in LabLumen:**

| Secret | Where set | What it contains | Used by |
|---|---|---|---|
| `SONAR_TOKEN` | Org or repo | SonarCloud API token for SAST analysis | service-pr.yml |
| `SNYK_TOKEN` | Org or repo | Snyk API token for SCA analysis | service-pr.yml |
| `K8S_REPO_PAT` | Org or repo | GitHub Personal Access Token with write access to lablumen-k8s | service-build-push.yml + service-release.yml |
| `BEDROCK_CROSS_ACCOUNT_ROLE_ARN` | Terraform repo | Cross-account Bedrock IAM role ARN (marked sensitive in Terraform) | terraform.yml (as `TF_VAR_`) |
| `INFRACOST_API_KEY` | Terraform repo | Infracost API key for cost estimates | terraform.yml |
| `GITHUB_TOKEN` | Auto-provided | GitHub's own token for API access (posting PR comments, uploading SARIF) | terraform.yml |

**`GITHUB_TOKEN`** is special — GitHub automatically provides it for every workflow run. Its permissions are set by the `permissions:` block. You do NOT store this as a secret; it is referenced as `${{ secrets.GITHUB_TOKEN }}` and GitHub provides the value.

### GitHub Variables

- **Plaintext** — visible in logs if printed
- **Read-only** once set (but can be updated through the UI)
- **For non-sensitive configuration** — values that are useful to share across workflows but are not secrets
- **Accessed as `${{ vars.MY_VARIABLE }}`**

**Variables in LabLumen:**

| Variable | Value | Used by |
|---|---|---|
| `AWS_ACCOUNT_ID` | `025392543842` | All CI/CD workflows (to construct IAM role ARNs) |
| `SONAR_ORGANIZATION` | `lablumen` | service-pr.yml (passed as input to SonarCloud) |

**Why `AWS_ACCOUNT_ID` as a variable and not hardcoded?**
If the account changes (e.g., migrating to a new AWS org), you update one variable in GitHub settings instead of editing every workflow file in every repo.

**Why not a secret?**
Account IDs are not sensitive. They appear in CloudTrail, in the AWS console, in billing. Treating them as secrets adds friction without any security benefit.

### How they interact in practice

```yaml
# In ci.yml
jobs:
  deploy-dev:
    uses: lablumen/lablumen-shared/.github/workflows/service-build-push.yml@main
    with:
      # var.AWS_ACCOUNT_ID → plaintext, used to build the role ARN
      role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/lablumen-app-ci-ecr
    secrets:
      # Secret passed from this repo's secrets into the reusable workflow
      K8S_REPO_PAT: ${{ secrets.K8S_REPO_PAT }}
```

---

## 7. Permissions Block — Least Privilege

Every workflow (and the reusable workflows) has an explicit `permissions:` block:

```yaml
permissions:
  id-token: write     # required for OIDC token request
  contents: read      # read the repo (checkout). write would allow pushing to the repo.
  pull-requests: write # post comments on PRs (Terraform plan + Infracost)
  security-events: write # upload SARIF files to GitHub Security tab (Checkov)
```

**Without an explicit `permissions` block**, GitHub uses a permissive default (write access to everything). **With an explicit block**, only the listed permissions are granted; everything else is `none`.

This matters because `GITHUB_TOKEN` scoped to `contents: write` could be used to push to the repo. If a supply-chain attack compromised an action you're using, that action could use a permissive `GITHUB_TOKEN` to introduce malicious code. Explicit least-privilege permissions limit the blast radius.

**The Terraform workflow's `pull-requests: write`** is required so the plan job can post a comment on the PR with the `terraform plan` output and Infracost estimate. The frontend and service workflows don't post PR comments, so they don't need this permission.

---

## 8. The PR Gate — service-pr.yml

This workflow runs on every pull request. It is a **hard gate** — all four jobs must pass or the PR cannot be merged (configured in GitHub branch protection rules).

### Trigger and call pattern

```
Developer opens PR on lablumen-appointment-service
  → ci.yml fires on pull_request event
  → ci.yml job `pr` condition: github.event_name == 'pull_request'  ✓
  → calls service-pr.yml@main with:
      service-name: appointment-service
      service-path: .
      sonar-organization: lablumen
```

### Job 1: lint-and-test (runs first, gates the others)

```
For Python services:
  - actions/setup-python@v5 (install Python 3.12)
  - pip install -r requirements-dev.txt
  - ruff check <service-path>    ← fast linter/formatter checker
  - python -m pytest -q          ← unit tests

For Node (frontend):
  - actions/setup-node@v4 (Node 20, npm cache)
  - npm ci                       ← clean install from package-lock.json
  - npm run build                ← TypeScript compile (catches type errors)
```

**`ruff`** is a Rust-based Python linter, 10-100x faster than `flake8`/`pylint`. It checks style, imports, and common anti-patterns.

**`npm ci`** (not `npm install`) — `ci` installs exactly what's in `package-lock.json`, failing if the lock file is out of date. `npm install` could silently update dependencies. In CI, you want **determinism** — install what was committed, nothing else.

**`requirements-dev.txt` vs `requirements.txt`** — dev requirements include pytest, ruff, and test utilities. The `requirements.txt` (production) has only runtime dependencies. Test tools do not belong in production containers.

### Jobs 2, 3, 4: sast, sca, container-scan (run after lint-and-test, in parallel)

```yaml
sast:
  needs: lint-and-test
sca:
  needs: lint-and-test
container-scan:
  needs: lint-and-test
```

If `lint-and-test` fails (a test fails), none of the security scans start. There's no point running a vulnerability scan on code that doesn't even pass its own tests.

The three security jobs run **in parallel** (all `needs: lint-and-test` but no inter-dependencies). This keeps total PR CI time minimal.

---

## 9. SAST — Static Application Security Testing (SonarCloud)

### What SAST means

**Static Application Security Testing** analyses source code without running it. It looks for security vulnerabilities in the code itself: SQL injection, XSS, hardcoded secrets, insecure deserialization, improper error handling, broken cryptography, etc.

"Static" = the code is not executed. It's a code review done by a machine.

### SonarCloud

SonarCloud is the cloud-hosted version of SonarQube. You connect your GitHub repo, and it:
1. Reads your source code
2. Runs hundreds of built-in rules (OWASP Top 10 coverage, CWE mappings)
3. Computes metrics: code coverage, duplications, maintainability ratings
4. Applies a **Quality Gate** — a pass/fail decision on configurable thresholds

```yaml
- name: SonarCloud (SAST) + quality gate
  uses: SonarSource/sonarqube-scan-action@v3
  env:
    SONAR_TOKEN: ${{ secrets.SONAR_TOKEN }}
  with:
    projectBaseDir: ${{ inputs.service-path }}
    args: >
      -Dsonar.host.url=https://sonarcloud.io
      -Dsonar.organization=${{ inputs.sonar-organization }}
      -Dsonar.projectKey=${{ inputs.sonar-organization }}_lablumen-${{ inputs.service-name }}
      -Dsonar.sources=${{ inputs.sonar-sources }}
      -Dsonar.exclusions=**/tests/**,**/*.test.*,**/*.spec.*
      -Dsonar.qualitygate.wait=true
```

**Key parameters:**
- `sonar.projectKey` — unique identifier per service: `lablumen_lablumen-appointment-service`. Constructed from the org key + service name, so each service has its own Sonar project.
- `sonar.sources` — which directories to scan (`app` for Python services, `src` for frontend). Test directories are in `sonar.exclusions` — you don't want Sonar to flag test code as production vulnerabilities.
- `sonar.qualitygate.wait=true` — the action waits for Sonar to compute and apply the Quality Gate before returning. If the gate fails, the step fails and the PR is blocked.

**`fetch-depth: 0`** — the SAST job does `actions/checkout@v4` with `fetch-depth: 0` (full history). SonarCloud uses Git blame to understand which developer introduced which issue, and it computes "new code" vs "legacy code" differently. Full history is required for accurate blame data.

### What SonarCloud finds that unit tests don't

- A password hardcoded as a string literal (even in a comment)
- Use of `eval()` or `exec()` with user-supplied input
- SQL query built by string concatenation
- A try/except that swallows all exceptions silently
- Dependency on a deprecated crypto function (`MD5`, `SHA-1`)
- Code paths that only trigger under specific inputs — unit tests might miss them

### The SONAR_TOKEN

A SonarCloud API token generated in the SonarCloud dashboard. It allows the GitHub Actions runner to authenticate to SonarCloud and upload analysis results. Stored as a GitHub Secret so it never appears in logs.

---

## 10. SCA — Software Composition Analysis (Snyk)

### What SCA means

**Software Composition Analysis** scans your **dependencies** (the packages you `pip install` or `npm install`) for known vulnerabilities. Your own code might be secure, but if `requests==2.28.0` has a CVE, your service is vulnerable.

"Composition" = the combination of your code + third-party libraries. SCA analyses the third-party part.

### Snyk

Snyk maintains a database of known vulnerabilities (CVEs) for Python packages (PyPI), Node packages (npm), container base images, and more. It maps your `requirements.txt` or `package-lock.json` to this database.

```yaml
- name: Snyk (SCA) — Python
  env:
    SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
  run: |
    npm install -g snyk
    snyk test --file="${{ inputs.service-path }}/requirements.txt" --severity-threshold=high
```

**`--severity-threshold=high`** — only fail the build on HIGH or CRITICAL vulnerabilities. LOW and MEDIUM vulnerabilities generate a report but don't block the PR. This avoids false-alarm fatigue from cosmetic or theoretical vulnerabilities.

**`snyk test --file=requirements.txt`** — Snyk reads `requirements.txt`, checks each package+version against its database, and lists any known CVEs with:
- CVE ID (e.g., `CVE-2023-12345`)
- CVSS score (severity)
- Affected versions
- Fixed-in version (if a fix exists)
- Whether the path to the vulnerability is transitive (a dep-of-a-dep)

### SCA vs SAST

| | SAST | SCA |
|---|---|---|
| Scans | YOUR code | Third-party packages |
| Finds | Logic errors, injection flaws, hardcoded secrets | Known CVEs in dependencies |
| Example finding | `SELECT * FROM users WHERE id=" + user_input` | `fastapi==0.94.0` has CVE-2023-29159 |
| Tool in LabLumen | SonarCloud | Snyk |

Both are required. A service with perfect application code but a dependency with a Remote Code Execution CVE is still vulnerable.

---

## 11. Container Security Scanning — Trivy

### What Trivy does

**Trivy** (by Aqua Security) scans Docker images for vulnerabilities. A Docker image consists of:
1. A base OS layer (e.g., `python:3.12-slim` = Debian slim)
2. Your application dependencies layered on top

Even if your code and your Python packages are clean, the Debian packages in the base image might have known CVEs. Trivy scans ALL layers.

```yaml
- name: Build image (temporary, never pushed)
  run: docker build -t "scan:${{ inputs.service-name }}" "${{ inputs.service-path }}"

- name: Trivy container scan (fail on CRITICAL/HIGH)
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: "scan:${{ inputs.service-name }}"
    severity: "CRITICAL,HIGH"
    exit-code: "1"
    ignore-unfixed: true
    vuln-type: "os,library"
```

**Parameters explained:**

| Parameter | Value | What it means |
|---|---|---|
| `severity` | `CRITICAL,HIGH` | Only report/fail on CRITICAL and HIGH severity CVEs. |
| `exit-code` | `1` | Return exit code 1 (failure) if any CRITICAL/HIGH vulnerabilities found. This fails the step and blocks the PR. |
| `ignore-unfixed` | `true` | Skip vulnerabilities with no available fix. Reporting an unfixed CVE is noise — you can't do anything about it right now. |
| `vuln-type` | `os,library` | Scan both OS packages (apt/rpm/apk) and application libraries (pip/npm/gem). |

### PR gate vs deploy gate — Trivy runs TWICE

**In service-pr.yml (PR gate):**
- Builds the image from the PR's code (temporary tag `scan:<service-name>`)
- Scans it
- Does NOT push the image (it's only for scanning)
- Hard-fails the PR if CRITICAL/HIGH found

**In service-build-push.yml (deploy gate):**
```yaml
- name: Build
  run: docker build -t "$IMAGE:$TAG" .
  # ... (image is tagged with registry prefix but not yet pushed)

- name: Trivy gate (fail on CRITICAL/HIGH before push)
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: "${{ env.IMAGE }}:${{ steps.meta.outputs.tag }}"
    severity: "CRITICAL,HIGH"
    exit-code: "1"
    ignore-unfixed: true

- name: Push
  run: docker push "$IMAGE:$TAG"   # only runs if Trivy passed
```

**The image is built FIRST, scanned, and only pushed to ECR if it passes.** This means ECR only contains images that passed the Trivy gate. A vulnerable image never lands in your production registry.

### Why Trivy in addition to Snyk?

Snyk (SCA) scans `requirements.txt` — your declared Python dependencies. Trivy scans the **built image** — which includes OS packages (libc, openssl, etc.) that aren't in `requirements.txt`. They complement each other.

---

## 12. The Dev Deploy — service-build-push.yml

This workflow runs when a PR is merged to `main`. It:
1. Builds the Docker image tagged with the Git commit SHA (7 chars)
2. Runs Trivy gate
3. Pushes to ECR (using OIDC to get credentials)
4. Updates `lablumen-k8s/services/<service>/values-dev.yaml` with the new image tag

### The image tagging strategy

```yaml
- id: meta
  run: echo "tag=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
```

`GITHUB_SHA` is the full 40-character SHA of the commit that triggered the workflow. `${GITHUB_SHA::7}` takes the first 7 characters: `abc1234`. This becomes the Docker image tag.

**Why SHA tags instead of `latest`?**

If you always push `:latest`, ArgoCD can't tell if the image changed — the tag didn't change. With SHA tags:
- Every build produces a uniquely-tagged image: `appointment-service:abc1234`, `appointment-service:def5678`
- The `values-dev.yaml` stores the exact tag being deployed
- Rolling back means writing the old SHA tag back to the values file
- ArgoCD detects the values-dev.yaml change and deploys the specific image

**Combined with `IMMUTABLE` ECR tags**: once `abc1234` is pushed, that tag forever points to that exact image. You cannot accidentally overwrite it.

### The OIDC flow in the build job

```yaml
- name: Configure AWS credentials (OIDC)
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ inputs.role-to-assume }}   # lablumen-app-ci-ecr role ARN
    aws-region: ${{ inputs.aws-region }}

- id: login
  uses: aws-actions/amazon-ecr-login@v2
  # This action calls ecr.GetAuthorizationToken using the credentials from the step above
  # Returns: registry URL (e.g., 025392543842.dkr.ecr.us-east-1.amazonaws.com)
```

`amazon-ecr-login@v2` calls the AWS ECR API (`ecr:GetAuthorizationToken`) and runs `docker login` with the returned credentials. After this, `docker push` works without any explicit credentials — the Docker daemon handles it.

### What `steps.login.outputs.registry` is

The ECR login action outputs the registry URL: `025392543842.dkr.ecr.us-east-1.amazonaws.com`. This is used to build the full image reference:

```
025392543842.dkr.ecr.us-east-1.amazonaws.com/lablumen/appointment-service:abc1234
```

---

## 13. GitOps Write-Back — The Image Tag Bump

After pushing the image to ECR, the pipeline updates the Kubernetes values file in `lablumen-k8s`:

```yaml
- name: Checkout lablumen/lablumen-k8s
  uses: actions/checkout@v4
  with:
    repository: lablumen/lablumen-k8s
    token: ${{ secrets.K8S_REPO_PAT }}   # needs write access to a DIFFERENT repo
    path: k8s

- name: Bump dev image tag
  working-directory: k8s
  env:
    TAG: ${{ needs.build.outputs.tag }}   # the 7-char SHA from the build job
    SVC: ${{ inputs.service-name }}
  run: |
    git config user.name  "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    f="services/${SVC}/values-dev.yaml"
    yq -i ".image.tag = \"${TAG}\"" "$f"    # update the YAML in-place
    if git diff --quiet; then echo "already at ${TAG}"; exit 0; fi
    git add "$f"
    git commit -m "cd(dev): ${SVC} -> ${TAG}"
    for i in $(seq 1 5); do
      if git pull --rebase origin main && git push origin main; then echo "pushed"; exit 0; fi
      echo "push conflict, retry $i/5"; sleep 5
    done
    echo "::error::failed to push after retries"; exit 1
```

### Key concepts here

**`K8S_REPO_PAT`** — the `actions/checkout@v4` for a different repo requires authentication. The automatic `GITHUB_TOKEN` only has access to the current repo. A **Personal Access Token (PAT)** with `repo` write scope on `lablumen-k8s` is stored as a secret and used here.

**`yq -i ".image.tag = \"${TAG}\""`** — `yq` is a YAML processor (like `jq` for JSON). The `-i` flag edits the file in-place. This sets the `image.tag` field in `values-dev.yaml` to the new SHA.

**`git diff --quiet`** — if the tag in the file is already this SHA (idempotent re-run), there's nothing to commit. Exit early.

**The retry loop (the most important part):**
```bash
for i in $(seq 1 5); do
  if git pull --rebase origin main && git push origin main; then
    echo "pushed"; exit 0
  fi
  echo "push conflict, retry $i/5"; sleep 5
done
```

**Why is this needed?** Five services can merge to their respective repos within seconds of each other. Each triggers a pipeline that tries to `git push` to `lablumen-k8s/main`. If two pipelines push concurrently, one will fail with "non-fast-forward" (the remote is ahead of what it tried to push). The retry loop does `git pull --rebase` (gets the latest changes, replays its commit on top) and tries again. With 5 retries at 5-second intervals, concurrent pushes from all services will succeed in order.

Without this loop, concurrent service deploys would randomly fail.

### ArgoCD detects the change automatically

Once `lablumen-k8s` is updated, ArgoCD polls or receives a webhook, detects the `values-dev.yaml` change, sees the image tag changed from `abc1234` to `def5678`, and runs a Helm upgrade on the appointment-service deployment in the `lablumen-dev` namespace. No human intervention.

---

## 14. Production Promotion — service-release.yml

### Trigger: GitHub Release

A GitHub Release is created by a developer in the GitHub UI (or `gh release create`):
1. Navigate to the repo → Releases → Draft a new release
2. Choose a tag (e.g., `v1.2.0`) on the exact commit that was validated in DEV
3. Publish the release → `release: types: [published]` event fires

### What the workflow does

```yaml
- id: meta
  run: echo "sha=${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
  # GITHUB_SHA is the commit the release was created on = the DEV-deployed commit
  # The 7-char SHA = the existing ECR image tag in lablumen-k8s/values-dev.yaml
```

### The retag: `aws ecr put-image`

```bash
MANIFEST=$(aws ecr batch-get-image \
  --repository-name "$REPO" \
  --image-ids imageTag="$SHA" \
  --query 'images[0].imageManifest' \
  --output text)

aws ecr put-image \
  --repository-name "$REPO" \
  --image-tag "$SEMVER" \
  --image-manifest "$MANIFEST"
```

This **does NOT rebuild the image**. It copies the image manifest (the metadata that describes which layers the image consists of) and creates a new tag (`v1.2.0`) pointing to the same image layers as the SHA tag (`abc1234`).

Result: ECR now has:
```
lablumen/appointment-service:abc1234  → 200MB image layers
lablumen/appointment-service:v1.2.0  → same 200MB image layers (shared)
```

No bytes are duplicated. No Docker build runs. The same bits that were tested in DEV are promoted to PROD.

### GitOps write-back to values-prod.yaml

Same rebase-retry pattern as `service-build-push.yml`, but writes to `services/appointment-service/values-prod.yaml`:

```yaml
yq -i ".image.tag = \"${SEMVER}\"" "services/${SVC}/values-prod.yaml"
git commit -m "cd(prod): ${SVC} -> ${SEMVER}"
# retry loop: git pull --rebase + git push
```

ArgoCD detects the change to `values-prod.yaml`, sees image tag changed from `v1.1.0` to `v1.2.0`, runs Helm upgrade in the `lablumen` (production) namespace.

---

## 15. The Build-Once / Promote Pattern

This is a fundamental DevOps principle:

```
WRONG:   build image → test in DEV → build NEW image → deploy to PROD
CORRECT: build image → test in DEV → promote SAME image to PROD
```

**Why the WRONG way is dangerous:**
If you build a new image for production, the build might:
- Pick up a newer version of a base image with different behaviour
- Include a new (possibly vulnerable) dependency version
- Include uncommitted local changes on the build machine
- Be compiled with different environment variables

You tested IMAGE_A but deployed IMAGE_B. PROD is never tested.

**Why the CORRECT way works:**
The SHA tag is the guarantee. `abc1234` was built once, tested in DEV, validated by real traffic, then promoted. The same SHA (`abc1234`) is retagged to `v1.2.0` and deployed to PROD. Not rebuilt — retagged. The bytes that run in production are identical to the bytes that ran in DEV.

The `aws ecr batch-get-image` + `aws ecr put-image` approach implements this at the manifest level — not even a Docker pull/push is needed.

---

## 16. Frontend CI — Three Triggers in One Workflow

The frontend has all three events in a single `ci.yml` (the backend services split them into `ci.yml` and `release.yml`):

```yaml
on:
  pull_request:          # PR gate
  push:
    branches: [main]     # DEV deploy
  release:
    types: [published]   # PROD promotion

jobs:
  pr:
    if: github.event_name == 'pull_request'
    uses: ...service-pr.yml@main
    with:
      runtime: node
      sonar-sources: src    # frontend source is in src/, not app/

  build:
    if: github.event_name == 'push'
    uses: ...service-build-push.yml@main
    with:
      role-to-assume: ...lablumen-frontend-build   # different role from backend services

  release:
    if: github.event_name == 'release'
    uses: ...service-release.yml@main
    with:
      role-to-assume: ...lablumen-frontend-build
```

The `if:` conditions on each job mean only one job runs per trigger. On a push to main, only `build` runs (not `pr` or `release`).

**`lablumen-frontend-build` role** — separate from `lablumen-app-ci-ecr`. The frontend role only has push access to `lablumen/frontend` ECR repo. The backend service roles have push access to the 3 backend ECR repos. Least privilege: frontend CI cannot push a backend image.

**`sonar-sources: src`** — the frontend TypeScript source is in `src/`. The `service-pr.yml` default is `app` (Python conventions). The frontend overrides this to `src`.

**Node `npm run build` as the test** — for the frontend, the "test" is a TypeScript compile. If there are type errors or import issues, `npm run build` fails. This is faster than running a full test suite and catches the most common frontend issues.

---

## 17. AI Service — SAM (AWS Serverless Application Model)

The AI service is a Lambda function, not a Kubernetes pod. Its CI/CD is fundamentally different.

### What is SAM?

**AWS Serverless Application Model (SAM)** is an AWS framework for deploying serverless applications (Lambda functions, API Gateway, DynamoDB tables, etc.). It extends CloudFormation with simpler syntax and a CLI tool.

**CloudFormation** is AWS's IaC service. Like Terraform but AWS-proprietary. You write YAML describing AWS resources, and CloudFormation creates/updates/deletes them. CloudFormation organises resources into **stacks** — groups of related resources managed together.

**SAM extends CloudFormation** with shorthand resource types like `AWS::Serverless::Function` which expands into a Lambda function + IAM role + CloudWatch log group + EventBridge rule in CloudFormation terms. One SAM resource replaces several CloudFormation resources.

### template.yaml — the SAM template

```yaml
AWSTemplateFormatVersion: "2010-09-09"
Transform: AWS::Serverless-2016-10-31    # ← tells CloudFormation to use SAM transformer
Description: LabLumen AI processing pipeline

Parameters:
  ReportsBucketName:
    Type: String   # passed in at deploy time from SSM params

Resources:
  AiProcessingFunction:
    Type: AWS::Serverless::Function
    Properties:
      CodeUri: .              # package the entire current directory as the Lambda ZIP
      Handler: src.handler.lambda_handler
      Role: !Ref ExecutionRoleArn    # uses the Terraform-managed IAM role
      VpcConfig:
        SubnetIds: !Split [",", !Ref SubnetIds]   # private subnets from Terraform SSM
        SecurityGroupIds:
          - !Ref SecurityGroupId    # Lambda SG from Terraform SSM
      Events:
        ReportUploaded:
          Type: EventBridgeRule    # triggers when S3 object is created in the reports bucket
          Properties:
            Pattern:
              source: [aws.s3]
              detail-type: ["Object Created"]
              detail:
                bucket:
                  name: [!Ref ReportsBucketName]
```

The `Parameters` section is the key to the Terraform-SAM handshake. Terraform creates the infra and writes values to SSM Parameter Store. SAM CI reads them from SSM. Neither needs hardcoded values.

### sam build + sam deploy — what happens

```yaml
- name: SAM build
  run: sam build --use-container
```

`sam build` packages the Lambda code into a deployment artifact. `--use-container` runs the build inside a Docker container matching the Lambda runtime (python3.12), ensuring native Python packages (like `psycopg2`) are compiled for Linux regardless of the CI runner's OS.

```yaml
- name: SAM deploy
  run: |
    sam deploy \
      --stack-name lablumen-ai \
      --s3-bucket "${{ steps.ssm.outputs.sam_bucket }}" \
      --region us-east-1 \
      --capabilities CAPABILITY_IAM \
      --no-confirm-changeset \
      --no-fail-on-empty-changeset \
      --parameter-overrides \
        "ReportsBucketName=${{ steps.ssm.outputs.reports_bucket }}" \
        "ExecutionRoleArn=${{ steps.ssm.outputs.exec_role_arn }}" \
        "SubnetIds=${{ steps.ssm.outputs.subnet_ids }}" \
        "SecurityGroupId=${{ steps.ssm.outputs.sg_id }}" \
        "BedrockCrossAccountRoleArn=${{ steps.ssm.outputs.bedrock_cross_account_role_arn }}"
```

**`--stack-name lablumen-ai`** — creates or updates a CloudFormation stack named `lablumen-ai`. CloudFormation is idempotent: if the stack already exists, it computes a changeset (what needs to change) and applies it.

**`--s3-bucket`** — SAM uploads the Lambda ZIP file to the SAM artifacts bucket (`lablumen-sam-<account_id>`), then tells CloudFormation where to find it. Lambda code must be in S3 for CloudFormation deployments.

**`--capabilities CAPABILITY_IAM`** — SAM creates IAM resources (the EventBridge rule has an IAM role to invoke Lambda). CloudFormation requires explicit acknowledgment that you know it's creating IAM resources.

**`--no-confirm-changeset`** — don't pause for human confirmation of the changeset in CI. The test job already validated the code; we want automatic deployment.

**`--no-fail-on-empty-changeset`** — if nothing changed (no code diff), SAM would error without this flag. With it, a no-op deploy succeeds cleanly. This makes re-runs of the CI pipeline idempotent.

### The SSM-to-SAM handshake

```yaml
- name: Read SAM deploy params from SSM
  id: ssm
  run: |
    get() { aws ssm get-parameter --name "/lablumen/config/$1" --query Parameter.Value --output text; }
    echo "exec_role_arn=$(get lambda-exec-role-arn)"      >> $GITHUB_OUTPUT
    echo "subnet_ids=$(get lambda-subnet-ids)"             >> $GITHUB_OUTPUT
    echo "sg_id=$(get lambda-security-group-id)"           >> $GITHUB_OUTPUT
    echo "sam_bucket=$(get sam-artifacts-bucket)"          >> $GITHUB_OUTPUT
    echo "reports_bucket=$(get reports-bucket)"            >> $GITHUB_OUTPUT
    echo "bedrock_cross_account_role_arn=$(get bedrock-cross-account-role-arn)" >> $GITHUB_OUTPUT
```

The `ai-lambda-deploy` OIDC role has SSM `GetParameter` permission on `/lablumen/config/*` paths. These 15 parameters were written by `terraform apply` (via `modules/ssm`). The SAM CI reads them without any hardcoded ARNs or bucket names.

The `echo "key=value" >> $GITHUB_OUTPUT` pattern writes to the **step output file** — values written here are accessible in later steps as `${{ steps.ssm.outputs.exec_role_arn }}`.

### Why SAM instead of Terraform for the Lambda?

Terraform's Lambda resource requires a ZIP file at plan time. SAM builds the ZIP from source during deployment. The Lambda source changes frequently (like a microservice), but the supporting infra (IAM role, SG, S3 bucket) changes rarely. Separating them means:
- Lambda deploys on every merge to main (via SAM, fast)
- IAM role/SG/bucket only re-deploys when Terraform config changes (via TF pipeline, with approval gate)
- The two pipelines operate independently without interference

---

## 18. Terraform Pipeline — scan / plan / apply

### Trigger: path filters

```yaml
on:
  pull_request:
    paths: ["**/*.tf", "**/*.tfvars", ".github/workflows/terraform.yml"]
  push:
    branches: [main]
    paths: ["**/*.tf", "**/*.tfvars", ".github/workflows/terraform.yml"]
  workflow_dispatch:    # manual trigger
```

**Path filters** — the Terraform pipeline only runs when a `.tf`, `.tfvars`, or the workflow file itself changes. A commit that only changes a README or a comment in `main.tf` that doesn't change any resource will not trigger a pipeline. This saves CI minutes and avoids unnecessary `terraform plan` runs.

**`workflow_dispatch:`** — allows manually triggering the workflow from the GitHub UI at any time. Useful for re-applying after a manual change or recovering from a partial apply.

### The TF_VAR_ environment variable mechanism

```yaml
env:
  TF_VAR_bedrock_cross_account_role_arn: ${{ secrets.BEDROCK_CROSS_ACCOUNT_ROLE_ARN }}
```

Terraform automatically reads environment variables named `TF_VAR_<variable_name>` and treats them as the value for that variable. This is how the sensitive `bedrock_cross_account_role_arn` variable is provided without appearing in `terraform.tfvars` (which is committed to Git) or in plan output (it's marked `sensitive = true` in `variables.tf`).

### Job 1: scan — Checkov

Runs on every PR and every push. Uploads SARIF to GitHub Security tab. See [section 19](#19-checkov--iac-security-scanning) for full details.

### Job 2: plan

```yaml
plan:
  needs: scan
  steps:
    - name: Configure AWS credentials (tf-plan, read-only)
      uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/lablumen-tf-plan
    
    - uses: hashicorp/setup-terraform@v3
      with:
        terraform_version: ${{ env.TF_VERSION }}   # "1.15.5" — pinned exact version
        terraform_wrapper: false                    # don't wrap terraform commands
    
    - run: terraform fmt -check -recursive    # fail if code isn't formatted
    - run: terraform init -input=false        # download providers + configure backend
    - run: terraform validate                 # syntax and semantic checks
    - run: terraform plan -input=false -no-color -out=tfplan   # compute the diff
    - run: terraform show -json tfplan > tfplan.json            # export plan as JSON
```

**`terraform_wrapper: false`** — the wrapper intercepts terraform output and reformats it. When you need to use the plan's exit code or parse its JSON output (for Infracost), the wrapper can interfere. Disabling it gives raw terraform output.

**`-input=false`** — prevents terraform from pausing and waiting for user input. In CI, there's no human to type; if input is needed, fail immediately.

**`-no-color`** — removes ANSI color codes from output. Log viewers in GitHub Actions don't always render ANSI colors correctly.

**`-out=tfplan`** — saves the computed plan as a binary file. The apply job downloads and executes this exact plan, not a freshly-computed one.

### Job 3: apply — the gated deploy

```yaml
apply:
  needs: plan
  if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
  environment: production    # THE GATE — requires human reviewer approval
  steps:
    - name: Configure AWS credentials (tf-apply, admin)
      with:
        role-to-assume: ...lablumen-tf-apply   # DIFFERENT role from plan job
    
    - name: Download plan artifact
      uses: actions/download-artifact@v4
      with:
        name: tfplan
    
    - run: terraform apply -input=false -no-color tfplan
```

**The `environment: production` line** is what creates the approval gate. GitHub waits for a configured reviewer to approve before the job starts. Without the human approval, the job sits in "waiting" state indefinitely.

**Two OIDC roles, different permissions** — the plan job assumes `lablumen-tf-plan` (ReadOnly). The apply job assumes `lablumen-tf-apply` (AdministratorAccess). The trust policy on `lablumen-tf-apply` is restricted to `environment:production` — this exact sub claim is only present when the job runs inside the `production` GitHub Environment. A forked copy of the workflow that doesn't have the environment configured cannot obtain tf-apply credentials.

---

## 19. Checkov — IaC Security Scanning

### What Checkov does

**Checkov** (by Bridgecrew/Prisma Cloud) is a static analysis tool for Infrastructure as Code. It reads Terraform files and checks them against hundreds of security rules (called checks) without running `terraform plan`.

Examples of things Checkov detects:
- S3 bucket with public read access enabled
- RDS instance with deletion protection disabled
- Security group with `0.0.0.0/0` on sensitive ports
- IAM role with `*` on all resources
- Lambda function without VPC configuration
- ECR repository with mutable image tags

```yaml
- name: Checkov IaC scan
  uses: bridgecrewio/checkov-action@master
  with:
    directory: .
    framework: terraform
    quiet: true
    soft_fail: true                    # report but don't block
    output_format: cli,sarif
    output_file_path: console,results.sarif

- name: Upload Checkov SARIF
  if: always()                         # upload even if checkov found issues
  uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: results.sarif
```

### SARIF — Security Analysis Results Interchange Format

SARIF is a JSON format for security findings. GitHub understands SARIF and displays findings in the **Security → Code Scanning** tab. Each finding shows the file, line number, severity, and description. This is the "GitHub Code Scanning" feature — it aggregates security findings from all scanners (Checkov, CodeQL, etc.) in one place.

### `soft_fail: true` — report-only mode

`soft_fail: true` means Checkov exits with code 0 even if it finds violations. The pipeline continues. The findings are still visible in the SARIF/Security tab but don't block merges.

This is the correct starting configuration. When you first run Checkov on an existing codebase, there may be dozens of findings — many of which are acceptable or false positives. Blocking the pipeline immediately would prevent all work from proceeding. The workflow is:
1. Start with `soft_fail: true`
2. Triage all findings
3. Suppress acceptable ones in `.checkov.yaml` with documented rationale
4. Fix real issues
5. Switch to `soft_fail: false` to harden the gate

### `.checkov.yaml` — documented suppressions

The `.checkov.yaml` file at the repo root configures which checks to skip and why:

```yaml
skip-check:
  - CKV_TF_1        # module pin: semver (~>) via Terraform Registry is sufficient for community modules
  - CKV2_AWS_5      # false-positive: RDS SG IS attached, but cross-module ref confuses Checkov
  - CKV2_AWS_57     # SM rotation: database-url uses RDS-managed rotation; grafana-admin is non-prod
  - CKV_AWS_18      # S3 access logging on state bucket: circular complexity not warranted here
  - CKV_AWS_144     # cross-region replication for state bucket: non-prod, overkill
  - CKV2_AWS_61     # lifecycle rules on state bucket: versioning already handles recovery
  - CKV2_AWS_62     # S3 event notifications on state bucket: unnecessary operational noise
  - CKV2_AWS_34     # SSM SecureString: SSM params are non-sensitive config by design
  - CKV_AWS_274     # tf-apply AdminAccess: required for full IaC; gated by OIDC + GH Environment approval
  - CKV_AWS_355     # Bedrock/Textract wildcard: AWS doesn't support resource-level IAM for these APIs
```

Every suppression has a documented reason. This is the critical difference between **a security engineer** (who understands and documents acceptable risk) and someone who just adds suppressions to make the pipeline green.

---

## 20. Infracost — Cost Estimation on Every PR

### What Infracost does

Infracost reads a `terraform plan` output and estimates the monthly AWS cost of the planned changes. When a PR adds a new RDS read replica or changes an instance type, Infracost shows the cost difference in a PR comment:

```
Monthly cost will increase by $45.12 (+23%)

┌─────────────────────────────────────────────────────────────────────┐
│ Project: lablumen-terraform                                         │
│                                                                     │
│ + aws_db_instance.this                                 $32.90/mo    │
│   + instance_class: db.t4g.small (was db.t4g.micro)                │
│                                                                     │
│ Monthly cost change: +$45.12                                        │
└─────────────────────────────────────────────────────────────────────┘
```

```yaml
- name: Setup Infracost
  uses: infracost/actions/setup@v3
  with:
    api-key: ${{ secrets.INFRACOST_API_KEY }}

- name: Generate Infracost Cost Estimate
  run: |
    infracost breakdown --path tfplan.json \
                        --format json \
                        --out-file /tmp/infracost.json
    infracost breakdown --path tfplan.json   # print to job logs

- name: Post Infracost Comment
  if: github.event_name == 'pull_request'
  run: |
    infracost comment github --path /tmp/infracost.json \
                             --github-token ${{ secrets.GITHUB_TOKEN }} \
                             --pull-request ${{ github.event.pull_request.number }} \
                             --behavior update   # update existing comment instead of creating a new one
```

**`tfplan.json`** — Infracost cannot read the binary `tfplan` file directly. The plan job runs `terraform show -json tfplan > tfplan.json` to export a JSON version. Infracost reads the JSON.

**`--behavior update`** — if a reviewer pushes another commit to the PR, Infracost updates the existing comment instead of adding a new one. This keeps the PR conversation clean.

**The INFRACOST_API_KEY** — Infracost Cloud provides the cost database. Free tier supports open-source projects. The API key authenticates the CLI to the Infracost Cloud service.

**Why this matters for the review:** Cost estimation in PRs means infrastructure cost changes are visible to reviewers BEFORE approval. A PR that accidentally removes a `count = 0` on a NAT Gateway would show a $32/month cost increase in the PR comment, letting reviewers catch the mistake.

---

## 21. Terraform Destroy — The Guarded Teardown

```yaml
on:
  workflow_dispatch:       # MANUAL ONLY — cannot be triggered by any push/PR
    inputs:
      confirm:
        description: 'Type "destroy" to confirm'
        required: true

jobs:
  destroy:
    if: ${{ inputs.confirm == 'destroy' }}    # typed confirmation check
    environment: production                    # human approval required
```

**Three safety layers:**
1. `workflow_dispatch` only — cannot be triggered automatically
2. Typed confirmation (`"destroy"`) — user must explicitly type the word
3. `environment: production` — required reviewer must approve in GitHub UI

Even with all three, a mistake could happen. The two-phase design ensures the destroy is safe.

**Phase 1 — Kubernetes teardown:**
```bash
# Stop ArgoCD from re-creating resources we're about to delete
kubectl -n argocd scale statefulset/argocd-application-controller --replicas=0

# LBC watches Ingress objects and creates ALBs. Deleting the Ingress → LBC finalizer → ALB deletion
kubectl delete ingress --all --all-namespaces --ignore-not-found --timeout=300s

# Karpenter-provisioned EC2 nodes won't be deleted by terraform destroy.
# Delete NodeClaims → Karpenter terminates the EC2 instances.
kubectl delete nodeclaims.karpenter.sh --all --timeout=300s

# Wait until the ALBs are gone (ALBs hold ENIs in the VPC subnets)
until [ ALB_COUNT == 0 ]; do sleep 15; done
```

**Phase 2 — terraform destroy:**
With ALBs and EC2 nodes gone, the VPC has no dangling ENIs. `terraform destroy -auto-approve` runs in reverse-dependency order (resources that others depend on are destroyed last).

**Why the cluster existence check?**
```bash
if ! aws eks describe-cluster --name "$CLUSTER" >/dev/null 2>&1; then
  echo "Cluster not found — skipping k8s teardown."; exit 0
fi
```
If the pipeline fails halfway and is re-run, the cluster might already be gone. Without this check, Phase 1 would fail on `kubectl` commands, stopping the destroy workflow. The check makes the workflow **idempotent** — safe to re-run.

---

## 22. Artifacts — Passing Files Between Jobs

Jobs run on different runners (different VMs). Files created in Job A are NOT available in Job B by default. **Artifacts** are the mechanism to pass files between jobs.

### How they're used in Terraform

**Plan job uploads `tfplan`:**
```yaml
- name: Upload plan artifact
  uses: actions/upload-artifact@v4
  with:
    name: tfplan
    path: tfplan
    retention-days: 5    # auto-delete after 5 days
```

**Apply job downloads `tfplan`:**
```yaml
- name: Download plan artifact
  uses: actions/download-artifact@v4
  with:
    name: tfplan

- run: terraform apply -input=false tfplan
```

**Why not re-plan in the apply job?**
If the apply job ran a fresh `terraform plan`, it would compute a NEW plan based on the current state of the world. Between plan and apply, someone might have run `terraform apply` manually, changing the state. The new plan could be different from what the reviewer approved. By saving and re-using the plan artifact, the apply job executes **exactly what was reviewed and approved** — not a potentially different plan.

This is a **correctness guarantee**, not just an optimisation.

---

## 23. GitHub Environments — The Approval Gate

A GitHub Environment is a named deployment target (configured in repo Settings → Environments). Environments can have:
- **Required reviewers** — named users/teams who must approve before a job runs
- **Wait timer** — delay between approval and execution
- **Secrets** — environment-specific secrets (override repo secrets)
- **Deployment protection rules** — custom rules via webhooks

```yaml
jobs:
  apply:
    environment: production    # this job waits for approval from required reviewers
```

When a job with `environment: production` is triggered:
1. GitHub notifies all configured required reviewers (Slack, email, GitHub notification)
2. Reviewers see the planned changes (the plan is visible in the job's logs)
3. A reviewer clicks "Approve and deploy" (or "Reject")
4. Only after approval does the job's steps execute

**The OIDC sub-claim implication:**
```
sub = "repo:lablumen/lablumen-terraform:environment:production"
```
The `environment:` prefix in the sub claim is ONLY present when the job is running inside a GitHub Environment. The `lablumen-tf-apply` trust policy uses `StringEquals` on this exact sub — meaning you cannot obtain tf-apply credentials from any job that isn't in the production environment, even if you fork the repo and modify the workflow.

---

## 24. The Complete CI/CD Journey — End to End

### Backend service: PR → DEV → PROD

```
Developer: creates branch, writes code, opens PR
  ↓
GitHub: PR event fires ci.yml → calls service-pr.yml
  ↓
service-pr.yml runs 4 jobs in parallel (after lint-test):
  ├── SAST: SonarCloud scans code for security vulnerabilities
  ├── SCA:  Snyk checks requirements.txt for CVEs in dependencies
  └── Container: Trivy builds image (not pushed), scans all layers

All pass → PR is unblocked → developer requests code review
Reviewer approves → merge to main
  ↓
push to main → ci.yml fires → calls service-build-push.yml
  ↓
build job:
  1. OIDC: get temp credentials (lablumen-app-ci-ecr role)
  2. ECR login (ecr:GetAuthorizationToken)
  3. docker build → image:abc1234
  4. Trivy scan → if CRITICAL/HIGH found: STOP (image not pushed to ECR)
  5. docker push → ECR stores image:abc1234

gitops job (after build succeeds):
  6. Checkout lablumen-k8s with K8S_REPO_PAT
  7. yq: update services/appointment-service/values-dev.yaml → image.tag: abc1234
  8. git commit "cd(dev): appointment-service -> abc1234"
  9. Retry: git pull --rebase && git push (up to 5 attempts)
  ↓
ArgoCD in EKS detects values-dev.yaml changed
  10. helm upgrade appointment-service in lablumen-dev namespace
  11. Old pod: abc1111 → New pod: abc1234
  ↓
Developer validates in DEV (https://dev.rnld101.xyz or internal)
  ↓
Developer creates GitHub Release v1.2.0 on commit abc1234
  ↓
release event → service-release.yml
  12. OIDC: same lablumen-app-ci-ecr role
  13. ECR: batch-get-image (get manifest for abc1234)
  14. ECR: put-image with tag v1.2.0 (retag, no rebuild)
  15. Checkout lablumen-k8s
  16. yq: update services/appointment-service/values-prod.yaml → image.tag: v1.2.0
  17. git commit "cd(prod): appointment-service -> v1.2.0"
  18. Retry push
  ↓
ArgoCD detects values-prod.yaml changed
  19. helm upgrade appointment-service in lablumen namespace (production)
  20. Blue/green rollout (rolling update strategy) → v1.1.0 → v1.2.0
```

### Infrastructure: PR → plan → apply

```
Developer: edits modules/vpc/main.tf to add a VPC endpoint
Opens PR
  ↓
terraform.yml fires:
  Job 1: Checkov scan → SARIF uploaded to Security tab
  Job 2 (after scan):
    - OIDC: lablumen-tf-plan role (ReadOnly)
    - terraform fmt -check (format validation)
    - terraform init (download providers, connect to S3 backend)
    - terraform validate (syntax check)
    - terraform plan → computes: "add 1 VPC endpoint, 2 ENIs"
    - Infracost: monthly cost +$7.30 → PR comment posted
    - tfplan artifact uploaded (retention 5 days)

PR comment shows: plan diff + cost impact
Reviewer sees the plan in logs + cost estimate in comment
Reviewer approves + merges
  ↓
push to main → terraform.yml fires again
  Job 1: Checkov (again)
  Job 2: Plan (again, fresh tfplan artifact)
  Job 3 (after plan, if on main):
    - `environment: production` → PAUSED waiting for reviewer
    - Reviewer approves in GitHub UI
    - OIDC: lablumen-tf-apply role (AdministratorAccess)
    - terraform init
    - Download tfplan artifact from Job 2
    - terraform apply tfplan → VPC endpoint created in AWS
```

---

## 25. Key Design Decisions & Defences

### "Why do you have a shared reusable workflow repo?"

"Four services need the same security gates: SAST, SCA, Trivy, and then the same ECR push + GitOps write-back on merge. Without `lablumen-shared`, I'd maintain four identical copies of ~170 lines of pipeline YAML. A Trivy version bump would require four PRs. `lablumen-shared` centralises the logic — one change propagates to all services at their next run. The trade-off is that a bug in `lablumen-shared` affects all services simultaneously. I mitigate this by having `lint-and-test` as the first gate — a broken pipeline would fail there, not during the security scans."

### "Why OIDC instead of stored AWS access keys?"

"Static IAM access keys are long-lived, potentially leaked through logs or history, and require manual rotation. OIDC tokens are issued per-job, expire in 1 hour, and are cryptographically bound to the specific repository and event. Even if a token was somehow intercepted, it's useless within an hour. The trust policy's `sub` claim conditions ensure only specific repos/workflows can assume each role. Static keys have no equivalent binding."

### "Why is the Trivy scan run twice — once on PR and once before push?"

"The PR Trivy scan (in `service-pr.yml`) catches container vulnerabilities before the code is merged. But the PR scans the code as-of the PR branch — the base image might be updated between the PR and the push to main. The second Trivy gate (in `service-build-push.yml`) scans the actually-built image, right before it's pushed to ECR. This guarantees ECR only contains images that passed the vulnerability gate at the exact moment they were built. If both pass, we have high confidence."

### "Why doesn't the AI service use the same ECR+ArgoCD pipeline as the other services?"

"The AI service is a Lambda function, not a containerised service. Lambda doesn't use container registries in the same way — it uses deployment ZIP packages managed by CloudFormation/SAM. SAM deploys Lambda via CloudFormation stacks, which is fundamentally different from updating a Kubernetes Deployment's image tag. Forcing Lambda into the Kubernetes pipeline would require awkward workarounds. SAM is the purpose-built tool for this deployment model. The supporting infrastructure (IAM role, SG, VPC) is still Terraform-managed — SAM only deploys the function code layer."

### "What happens if two services merge at the same time and both try to push to lablumen-k8s?"

"The retry loop in `service-build-push.yml` handles this. Each pipeline does `git pull --rebase` before `git push`. If push fails (because another service pushed first), it rebases its commit on top of the new HEAD and retries. With up to 5 retries at 5-second intervals, the window for all collisions to clear is 25 seconds. On a platform with 5 services, the probability of 5 concurrent merges within 25 seconds is extremely low. If it happened, the 6th retry would fail and the developer would re-run the pipeline — rare and recoverable."

### "What is `fetch-depth: 0` in the SAST job and why is it needed?"

"SonarCloud uses Git history in two ways: (1) blame annotations to show which developer introduced which issue, and (2) the concept of 'new code' vs 'existing code' — Sonar can be configured to only fail the Quality Gate on issues in new code (code changed in this PR), not in old/existing code. For this to work, Sonar needs the full commit history. `fetch-depth: 0` does a full `git clone` instead of the default shallow clone (depth 1). Without it, Sonar can't compute blame or new-code boundaries, and may report misleading results."

### "What happens if the tfplan artifact expires before the apply job runs?"

"Artifacts have a `retention-days: 5` setting. If a PR takes more than 5 days to get human approval, the artifact is deleted and the apply job would fail trying to download it. In practice, a 5-day window is very generous. If it expires, the developer re-runs the workflow to generate a fresh plan + new artifact, then the reviewer re-approves. This is a slight inconvenience but not a blocking issue. The alternative would be longer retention (more storage cost) or re-planning in the apply job (which loses the guarantee that apply executes exactly what was reviewed)."

---

## Quick Reference: All Workflows at a Glance

| Workflow | Repo | Trigger | Key steps |
|---|---|---|---|
| `service-pr.yml` | lablumen-shared | `workflow_call` (from PRs) | lint, test, SonarCloud SAST, Snyk SCA, Trivy container scan |
| `service-build-push.yml` | lablumen-shared | `workflow_call` (from main push) | OIDC→ECR login, docker build, Trivy gate, ECR push, values-dev.yaml bump + rebase-retry |
| `service-release.yml` | lablumen-shared | `workflow_call` (from GitHub Release) | OIDC→ECR login, retag SHA→semver, values-prod.yaml bump + rebase-retry |
| `ci.yml` (backend) | Each service | `pull_request` / `push(main)` | Delegates to service-pr.yml OR service-build-push.yml |
| `release.yml` (backend) | Each service | `release: published` | Delegates to service-release.yml |
| `ci.yml` (frontend) | lablumen-frontend | All three events | Delegates to all three shared workflows, node runtime, separate ECR role |
| `ci.yml` (ai-service) | lablumen-ai-service | `pull_request` / `push(main)` | ruff + pytest (PR), SAM build + SSM read + SAM deploy (main) |
| `terraform.yml` | lablumen-terraform | `push(main)` / `pull_request` on `.tf` files | Checkov scan, terraform plan + Infracost, human-gated terraform apply |
| `terraform-destroy.yml` | lablumen-terraform | `workflow_dispatch` only | Typed confirmation, production approval, K8s teardown phase, terraform destroy |

## Quick Reference: All Security Tools

| Tool | Category | Scans | Hard-fail threshold | Where results appear |
|---|---|---|---|---|
| **SonarCloud** | SAST | Application source code | Quality Gate (configurable) | Sonar dashboard + PR status check |
| **Snyk** | SCA | `requirements.txt` / `package-lock.json` | `--severity-threshold=high` | PR status check + Snyk dashboard |
| **Trivy** | Container scan | Docker image all layers (OS + libs) | CRITICAL, HIGH | PR status check (service-pr) + job log |
| **Checkov** | IaC scan | Terraform files | `soft_fail: true` (report-only) | GitHub Security → Code Scanning tab |
| **Infracost** | Cost analysis | Terraform plan JSON | No fail — informational only | PR comment (auto-updated) |
