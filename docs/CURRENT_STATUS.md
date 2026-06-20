# LabLumen — Current Status

> Living document. Update this whenever the deployment, resources, or feature state change.
> Last updated: 2026-06-20.

## TL;DR

Full product runs end-to-end on a single EC2 instance via docker-compose (nginx :80 →
3 FastAPI services + Postgres/pgvector + Redis). Auth wall (Cognito), patient booking, staff
operations + report upload, AI ingestion (pypdf → Nova summary → Titan embeddings), and
document-scoped RAG chat are all implemented and wired. The S3-triggered Lambda in
`serverless/` is intentionally parked for the future EKS migration (it can't reach the
docker-compose DB); ingestion runs inside report-service for this single-instance setup.

The frontend has been fully redesigned: 10+ routes under persistent sidebars (PatientLayout /
StaffLayout), a multi-step booking wizard, and the flagship **Report Workspace** (`/app/reports/:id`)
— PDF-primary layout with AI summary panel, biomarker strip, and floating chat button.

**✅ Verified end-to-end on 2026-06-18** against a live EC2: login + RBAC, patient profile +
booking, booking→SQS→SES email (SES: sent, 0 bounces), staff ops queue + status update, report
upload → pypdf extraction → Nova Lite summary → Titan embeddings → pgvector, presigned PDF view,
and grounded RAG chat. Patient→staff and no-token requests correctly 403.

## Deployment

- **Model**: single EC2 (Ubuntu 24.04) running `docker compose`. nginx serves the SPA on :80 and
  reverse-proxies `/api/v1/*` to the services (same-origin → no CORS).
- **Instance**: **terminated** — relaunch per `docs/IMPLEMENTATION.md` Step 2.
- **App URL**: `http://<NEW-EC2-PUBLIC-IP>` (set after each launch)
- **Deploy / redeploy** (on the instance):
  ```bash
  # Run git as ubuntu — SSM/root breaks .git ownership
  sudo chown -R ubuntu:ubuntu /home/ubuntu/lablumen   # only needed if root touched .git
  cd /home/ubuntu/lablumen
  sudo -u ubuntu git pull origin main
  sudo -u ubuntu docker compose up --build -d
  ```
- Repo: https://github.com/rnld101/lablumen (branch `main`).

## Provisioned AWS resources

| Resource | Value |
|---|---|
| Cognito User Pool | `us-east-1_3hMVOZPch` |
| Cognito App Client | `7eb2d3esnbfs3te482jgsfqp6t` (public client; USER_PASSWORD_AUTH + SRP) |
| Cognito groups | `PATIENT`, `LAB_STAFF`, `LAB_ADMIN` |
| S3 bucket | `lablumen-reports-130290476321` |
| SQS queue | `https://sqs.us-east-1.amazonaws.com/130290476321/lablumen-notifications` |
| SES sender (verified) | `rukesully@gmail.com` |
| Bedrock models | `amazon.titan-embed-text-v1` (embed), **`amazon.nova-lite-v1:0`** (text) |
| EC2 IAM role | `lablumen-ec2-role` (Bedrock, S3, SQS, SES, CognitoReadOnly, Textract, SSM) |
| EC2 instance profile | `lablumen-ec2-profile` |
| Security group | `sg-0cd62be1c32705ec0` (`lablumen-sg`; ports 22, 80, 8001–8003) |

## Test users (password for all: `Test12345!`)

| Email | Group | Notes |
|---|---|---|
| `rukesully@gmail.com` | PATIENT | **Use this patient** — email is SES-verified, so booking confirmation emails actually deliver (SES sandbox). |
| `patient@example.com` | PATIENT | Works, but SES sandbox won't deliver email to it. |
| `staff@example.com` | LAB_STAFF | Staff portal + report upload. |

## Feature status

| Area | Status | Notes |
|---|---|---|
| Auth wall + Cognito login | ✅ | Embedded login form (`amazon-cognito-identity-js`), ID token stored, route guards, staff-gated `/staff`. |
| Lazy user provisioning | ✅ | `users` row upserted from JWT on first authenticated request (appointment-service). |
| Lab catalog | ✅ | 9 seeded tests; live fetch. |
| Patient profiles | ✅ | Create/list; booking is per-profile. |
| Booking | ✅ | Redis slot-lock, multi-test cost total, slot picker, price snapshot, `appointment.booked` → SQS → SES email. |
| Appointments list | ✅ | Own (patient) / all (staff). |
| Staff ops queue | ✅ | Join grid: patient/test/when/status + report state; status toggle (PATCH). Staff-only guard enforced. |
| Report upload | ✅ | Staff multipart upload → S3 → `lab_reports` row → background ingestion. S3/DB errors surfaced in UI. |
| AI ingestion | ✅ | In report-service: **pypdf** text extraction → Nova Lite summary → chunk → Titan embeddings → pgvector. |
| Report view | ✅ | Presigned S3 GET URL (120s TTL), ownership-scoped. |
| RAG chat | ✅ | Multi-turn history, document-scoped cosine (`<=>`) over report chunks + Nova answer. Markdown rendered. Concise nurse persona; no repetitive sign-offs. |
| Notifications | ✅ | SQS consumer + SES email (sandbox: only verified recipients receive). |
| Frontend redesign | ✅ | 10+ routes, PatientLayout/StaffLayout sidebars, BookingWizard, Report Workspace. See `docs/FRONTEND_VISION.md`. |
| Report Workspace UI | ✅ | PDF primary (full left panel), AI summary right, floating chat button (FAB). Biomarker strip, AI status hero. |
| S3→Lambda ingestion | ⏸ Parked | Complete code in `serverless/ai-processing-pipeline/`; can't reach the compose DB. For EKS phase. |
| EKS migration | 📋 Planned | Architecture blueprint written: `docs/EKS_MIGRATION_BLUEPRINT.md`. 9-phase plan (P0–P9). |

## End-to-end demo script

1. Open http://54.198.249.16 → redirected to `/login`.
2. Sign in as **`rukesully@gmail.com` / `Test12345!`** (patient).
3. **Book a Lab Test**: add a patient profile (if none) → select 2 tests (cost total updates) →
   pick date + slot → **Book appointment**. Confirmation email lands at rukesully@gmail.com.
4. Sign out → sign in as **`staff@example.com`** → **Staff** tab → Operations Queue shows the new
   order(s). Toggle status; click **Upload PDF** on a row and pick a lab-report PDF/image.
5. Row flips to "Report uploaded"; ingestion runs in the background (Textract → Nova → Titan).
6. Sign back in as the patient → **My Reports** shows the report as **Ready** with an AI summary →
   **Preview** opens the presigned PDF → **Chat** answers questions grounded in that report only.

## Known limitations / notes

- **Bedrock text model = `amazon.nova-lite-v1:0` (not Nova 2 Lite).** An org SCP
  (`p-rn6vr8ok`) allows Bedrock only in **us-east-1**. Nova 2 Lite (`amazon.nova-2-lite-v1:0`)
  has no on-demand support — it requires a cross-region inference profile (`us.`/`global.`),
  which load-balances to us-east-2/us-west-2 and is **denied by the SCP**. Nova Lite v1 supports
  on-demand natively in us-east-1, so we use it. For the EKS phase, either keep Nova Lite v1 or get
  the SCP widened to permit the inference-profile regions, then switch `serverless/` + compose to
  `us.amazon.nova-2-lite-v1:0`. Titan embeddings are on-demand in us-east-1 (unaffected).
- **Deploying via SSM runs as `root`** — git in the `ubuntu`-owned repo then fails on "dubious
  ownership" / can't write `.git/FETCH_HEAD`, silently leaving stale code. Always run git as the
  repo owner: `sudo -u ubuntu git fetch/reset`, and if a root run already touched `.git`,
  `chown -R ubuntu:ubuntu /home/ubuntu/lablumen` first. (Plain SSH as `ubuntu` has no such issue.)
- **SES sandbox**: only verified addresses receive email. Demo as `rukesully@gmail.com`. To email
  arbitrary patients, request SES production access.
- **PDF extraction**: switched from Textract `detect_document_text` to **pypdf** for text
  extraction inside the compose stack. Textract is still used in the parked Lambda pipeline.
- **Ingestion** runs as a FastAPI BackgroundTask (no queue/retry). Fine for the demo; the EKS path
  uses the S3-triggered Lambda instead.
- **Secrets**: IDs live in `docker-compose.yml` for this test setup; production uses Secrets
  Manager (see terraform/k8s).
- `EC2 reboot` changes the public IP unless an Elastic IP is attached.

## How to pick up from here

- Code layout: `backend/{appointment,report,notification}-service/app`, `frontend/src`,
  `serverless/ai-processing-pipeline` (EKS-bound), `terraform/`, `k8s/`.
- Implementation runbook: `docs/IMPLEMENTATION.md`. EKS migration blueprint: `docs/EKS_MIGRATION_BLUEPRINT.md`.
- Frontend design spec: `docs/FRONTEND_VISION.md` (source of truth for layouts and components).

### Next milestones

| Priority | Item |
|---|---|
| 1 | **SES production access** — unblock real-patient email delivery |
| 2 | **EKS Phase 3 — P0/P1** — Terraform remote state + VPC 3-tier (`docs/EKS_MIGRATION_BLUEPRINT.md`) |
| 3 | **Lambda AI pipeline** — attach VPC config to `ai_lambda`; retire inline `report-service` AI path (EKS P6) |
| 4 | **Appointment cancellation** — patient-side cancel flow not yet implemented |
| 5 | **Secrets Manager** — move `docker-compose.yml` env vars to Secrets Manager for EKS readiness |
