# LabLumen — Application Overview

## What Is LabLumen?

LabLumen is a **cloud-native laboratory management platform** built for diagnostic labs. It lets patients book lab test appointments, allows lab staff to manage those appointments and upload results, and delivers AI-powered explanations of those results back to patients — all through a single web interface.

The core value proposition in one sentence: **a patient books a blood test, a lab staff member uploads the PDF report, and the patient can immediately read a plain-English AI summary and have a conversation with an AI nurse about their results.**

---

## User Roles

There are two types of users in the system, both authenticated through AWS Cognito:

| Role | What they can do |
|---|---|
| **Patient** | Register, manage family member profiles, browse the lab test catalog, book appointments, view their own appointments, download their own reports, read AI summaries, and chat with the AI about their results |
| **Lab Staff / Lab Admin** | See all appointments in an operations queue, update appointment statuses (Booked → Checked-In → Completed → Cancelled), upload report PDFs against ordered tests |

Role membership is read from the `cognito:groups` claim on every JWT — there is no separate auth microservice. Each backend service verifies tokens in-process using Cognito's published JWKS.

---

## Services at a Glance

| Service | Type | Language / Framework | Purpose |
|---|---|---|---|
| **lablumen-frontend** | Container (nginx + Vite SPA) | TypeScript · React · TanStack Query · Tailwind CSS | Patient and staff UI |
| **lablumen-appointment-service** | Container (FastAPI) | Python 3.12 · SQLAlchemy · Alembic · asyncpg | Appointments, patients, lab test catalog |
| **lablumen-report-service** | Container (FastAPI) | Python 3.12 · SQLAlchemy · boto3 | Report upload, S3 presigned URLs, RAG chat |
| **lablumen-notification-service** | Container (FastAPI) | Python 3.12 · boto3 | SQS consumer → SES email sender |
| **lablumen-ai-service** | AWS Lambda | Python 3.12 · boto3 (SAM-deployed) | S3-triggered pipeline: OCR → summary → embeddings |
| **Redis** | In-cluster (Helm) | Redis | Distributed slot-locking for concurrent bookings |
| **PostgreSQL (RDS)** | AWS managed | PostgreSQL + pgvector extension | Single shared database for all containerised services |

---

## Detailed Service Breakdown

### 1. Frontend (`lablumen-frontend`)

A **React SPA** built with Vite, served by nginx inside a Docker container running in EKS.

nginx is the gateway for all traffic — it reverse-proxies API calls to the right backend:
- `/api/v1/reports/…` → report-service
- `/api/v1/…` → appointment-service

The SPA has two distinct portals sharing one Cognito login:
- **Patient portal** (`/app/…`) — home dashboard, booking wizard, appointments list, reports list, report workspace (PDF viewer + AI chat), family profiles manager
- **Staff portal** (`/staff/…`) — operations grid (all ordered tests with statuses), report upload picker, staff reports view

Authentication is handled by `amazon-cognito-identity-js` (SRP flow, public client). The Cognito ID token is stored in localStorage and sent as `Authorization: Bearer <token>` on every API call. If a 401 is received, the token is cleared and the user is redirected to `/login`.

**Tech stack:** React 18, React Router v6, TanStack Query, Tailwind CSS, shadcn/ui component library, TypeScript

---

### 2. Appointment Service (`lablumen-appointment-service`)

The **core transactional backend**. A FastAPI async application that owns the PostgreSQL schema (via Alembic migrations) and exposes the main CRUD surface.

**What it manages:**
- **Lab test catalog** — a seeded list of 9 tests (CBC, CMP, Lipid Profile, Thyroid, HbA1c, Urinalysis, Vitamin D/B12, LFT, RFP) with prices. The catalog is read-only from the frontend; prices are snapshotted at booking time.
- **Patient profiles** — an account owner (the Cognito user) can register multiple patient profiles (themselves, family members). Each profile has first/last name, phone, DOB, biological gender, and relationship to owner.
- **Appointments** — a booking contains a date, a time slot, and one or more `(test, patient)` pairs. Each pair is stored in `appointment_test_mapping` with the price snapshotted at booking time.
- **Appointment statuses** — `Booked → Checked-In → Completed` (or `Cancelled`). Staff update status via a PATCH endpoint.
- **Operations queue** — a staff-only endpoint that joins across appointments, test mappings, patient profiles, lab tests, and lab reports to produce a single flat grid row for each ordered test. This is what the staff dashboard displays.

**Slot locking:** When a patient books an appointment, the service acquires a Redis distributed lock on the `date+time_slot` key (NX SET with 5-minute TTL) before writing to Postgres. This prevents two concurrent requests from double-booking the same slot. The lock is always released in a `finally` block.

**Event publishing:** After a successful booking, the service fires-and-forgets an `appointment.booked` event to SQS. Failures to publish do not roll back the booking.

**Auth:** On every authenticated request, the service verifies the Cognito JWT in-process and does an upsert on the `users` table from the token's `sub` and `email` claims — so no separate user registration step is needed at the database layer.

---

### 3. Report Service (`lablumen-report-service`)

Handles everything related to **lab reports** — upload, viewing, and AI-powered chat.

**Upload flow (staff only):**
1. Staff picks an ordered test row from the ops queue that has no report yet
2. They upload a PDF via `POST /api/v1/reports/upload` (multipart form)
3. The service stores the PDF in a **private S3 bucket** and writes a row to `lab_reports` linking to the `appointment_test_mapping` row
4. When every test in an appointment has a report, the appointment status is automatically flipped to `Completed`
5. The S3 upload triggers the AI Lambda in the background

**Viewing (patient + staff):**
- `GET /api/v1/reports` — lists reports visible to the caller (patients see only their own; staff see all)
- `GET /api/v1/reports/{id}/view` — returns a **presigned S3 URL** (2-minute TTL, SigV4 signed) so the browser can fetch the PDF directly without the service proxying the bytes

**AI Chat (RAG):**
- `POST /api/v1/reports/{id}/chat` — the patient asks a question in natural language
- The service embeds the question using **Amazon Titan Embed** (1536-dim vector) via Bedrock
- It retrieves the top-3 most semantically similar chunks from the `report_embeddings` pgvector table using cosine similarity (`<=>` operator, HNSW index)
- It prepends the stored `ai_layman_summary` as a "full picture" context block
- It calls **Amazon Nova Lite** via the Converse API with a carefully crafted system prompt that makes the model respond like a warm, experienced laboratory nurse
- The conversation history is passed as prior turns to maintain context across multiple messages

Access control: a patient can only chat about reports that belong to their own appointments.

---

### 4. Notification Service (`lablumen-notification-service`)

A lightweight **event consumer** that translates SQS messages into emails.

It runs an async background loop (`consume_forever`) that long-polls the SQS queue (20-second wait). For each message it:
1. Parses a `NotificationEvent` (type, to_email, data dict)
2. Calls **Amazon SES** to send a formatted email
3. Deletes the message from SQS on success; leaves it on the queue on failure (redrive/DLQ handles retries)

**Event types it handles:**
- `appointment.booked` → "Your LabLumen appointment is confirmed"
- `appointment.cancelled` → "Your LabLumen appointment was cancelled"
- `report.ready` → "Your LabLumen lab report is ready"

The service also exposes a FastAPI health endpoint at `/healthz` (used by the ALB health check and K8s liveness probe). The SQS consumer runs as a background asyncio task started during FastAPI's lifespan.

---

### 5. AI Service (`lablumen-ai-service`)

A **serverless AWS Lambda** function (Python 3.12, SAM-deployed). It is not an EKS service — it lives outside the cluster entirely.

**Trigger:** S3 EventBridge notification whenever a new object is created in the reports bucket.

**Processing pipeline (per report):**
1. **Resolve** — look up the `report_id` in the `lab_reports` table by matching the S3 object key
2. **OCR** — call **AWS Textract** (`detect_document_text`) to extract text from the PDF/image
3. **Summarize** — call **Amazon Nova Lite** via Bedrock Converse API to produce a short, empathetic plain-language summary (max 600 tokens, temperature 0.2)
4. **Chunk** — split the extracted text into ≤800-character paragraph-aware chunks
5. **Embed** — for each chunk, call **Amazon Titan Embed** to get a 1536-dimensional vector
6. **Persist** — write the summary to `lab_reports.ai_layman_summary` and insert all chunks + vectors into `report_embeddings` using psycopg (sync, not async)

The Lambda reads the database DSN from **AWS Secrets Manager** (cached after cold start). Bedrock is accessed via cross-account IAM role assumption (STS AssumeRole) because the Bedrock-enabled account is different from the main application account (org SCP restricts Bedrock access to only Nova Lite v1).

---

## Database Schema

All five database-backed services (appointment, report, and AI Lambda) share **one PostgreSQL database** (RDS, `us-east-1`). The pgvector extension is enabled.

```
users
  user_id (PK = Cognito sub)
  email
  created_at

patient_profiles
  patient_id (PK)
  account_owner_id → users
  first_name, last_name, phone_number, date_of_birth, biological_gender, relationship_to_owner

lab_tests
  test_id (PK)
  name, description, base_cost, is_active
  (seeded with 9 tests via migration 0002)

appointments
  appointment_id (PK)
  account_owner_id → users
  appointment_date, time_slot
  status  [Booked | Checked-In | Completed | Cancelled]

appointment_test_mapping                    ← the core join table
  mapping_id (PK)
  appointment_id → appointments
  test_id → lab_tests
  patient_id → patient_profiles
  price_at_booking                          ← price snapshot at booking time

lab_reports
  report_id (PK)
  mapping_id → appointment_test_mapping     ← one report per ordered test (UNIQUE)
  s3_url                                    ← object key in the private reports bucket
  ai_layman_summary                         ← filled by the Lambda after processing

report_embeddings
  embedding_id (PK)
  report_id → lab_reports
  chunk_content                             ← raw text chunk
  embedding vector(1536)                    ← Titan embedding, HNSW cosine index
```

---

## How Services Are Connected — End-to-End Flows

### Flow 1: Patient Books an Appointment

```
Browser (React)
  → [POST /api/v1/appointments]  (Bearer JWT in header)
  → nginx (frontend pod in EKS)
  → appointment-service pod (EKS)
      → Cognito JWKS endpoint (JWT verify, first call only; cached)
      → Redis (acquire slot lock)
      → RDS Postgres (INSERT appointment + test mappings)
      → Redis (release lock)
      → SQS (publish appointment.booked event — fire and forget)
  ← 201 Created (appointment JSON)
Browser shows confirmation toast
```

### Flow 2: Notification Arrives

```
SQS queue (appointment.booked message sitting in queue)
  ← notification-service polls every 20s (long-poll)
      → SES (send "Your appointment is confirmed" email to patient)
      → SQS delete_message
Patient receives email
```

### Flow 3: Staff Uploads a Report

```
Browser (Staff portal)
  → [POST /api/v1/reports/upload] (multipart, Bearer JWT)
  → nginx → report-service pod (EKS)
      → Cognito JWKS (JWT verify)
      → S3 (PutObject — private reports bucket)
      → RDS Postgres (INSERT lab_reports row, UPDATE appointment status if all tests done)
  ← 201 { report_id, status: "uploaded" }

[S3 ObjectCreated event → EventBridge]
  → AI Lambda (cold start: reads DSN from Secrets Manager, creates Bedrock client via STS)
      → Textract (OCR the PDF)
      → Bedrock Nova Lite (summarize)
      → Bedrock Titan Embed (embed each chunk)
      → RDS Postgres (UPDATE lab_reports.ai_layman_summary, INSERT report_embeddings rows)
Lambda done; patient can now see the summary on next page load
```

### Flow 4: Patient Reads and Chats About Their Report

```
Browser (Patient portal — /app/reports/:id)
  → [GET /api/v1/reports/:id/view]
  → nginx → report-service
      → S3 generate_presigned_url (2-min TTL, SigV4)
  ← { url: "https://s3.amazonaws.com/...", expires_in: 120 }
Browser fetches PDF directly from S3 presigned URL (no proxy)

Patient types a question in the chat:
  → [POST /api/v1/reports/:id/chat] { question, history }
  → report-service
      → Bedrock Titan Embed (embed the question)
      → RDS pgvector (SELECT top-3 chunks by cosine distance)
      → RDS (SELECT ai_layman_summary)
      → Bedrock Nova Lite Converse API (system prompt + context + question + history)
  ← { answer, disclaimer }
```

---

## Tech Stack Summary

| Layer | Technology |
|---|---|
| **Frontend framework** | React 18 + TypeScript + Vite |
| **UI components** | Tailwind CSS + shadcn/ui |
| **Frontend data fetching** | TanStack Query (React Query) |
| **Backend framework** | FastAPI (Python 3.12, async/await throughout) |
| **ORM** | SQLAlchemy 2.x (async, mapped_column style) |
| **DB migrations** | Alembic |
| **Async Postgres driver** | asyncpg (via SQLAlchemy) |
| **Sync Postgres driver** | psycopg3 (Lambda only — Lambda has no event loop) |
| **Validation / settings** | Pydantic v2 + pydantic-settings |
| **Caching / locking** | Redis (redis.asyncio) |
| **Container runtime** | Docker (multi-stage builds, non-root user) |
| **Container orchestration** | Kubernetes (AWS EKS) |
| **GitOps** | ArgoCD (App-of-Apps pattern, ApplicationSets) |
| **Node autoscaling** | Karpenter |
| **Ingress** | AWS Load Balancer Controller (ALB, HTTPS) |
| **DNS** | ExternalDNS (Route 53) |
| **Secrets injection** | External Secrets Operator (SSM Parameter Store + Secrets Manager) |
| **Serverless** | AWS Lambda (SAM-deployed) |
| **AI models** | Amazon Nova Lite (text generation) + Amazon Titan Embed (embeddings) |
| **AI access** | Amazon Bedrock (Converse API + InvokeModel) |
| **OCR** | AWS Textract |
| **Vector search** | pgvector extension (HNSW index, cosine similarity) |
| **Message queue** | Amazon SQS (standard queue) |
| **Email** | Amazon SES |
| **Object storage** | Amazon S3 (private, KMS-encrypted) |
| **Database** | Amazon RDS PostgreSQL (shared by all services) |
| **Auth** | Amazon Cognito (User Pools, JWT/SRP flow, Cognito Groups for RBAC) |
| **Secrets** | AWS Secrets Manager (DB DSN), SSM Parameter Store (config) |
| **Infrastructure as Code** | Terraform |
| **CI/CD** | GitHub Actions |
| **Container registry** | Amazon ECR |
| **Monitoring** | kube-prometheus-stack (Prometheus + Grafana) |

---

## Key Design Decisions Worth Knowing

1. **No auth microservice.** Each backend service verifies Cognito JWTs independently using the pool's public JWKS. Role enforcement is done via the `cognito:groups` claim — no custom roles table queried at runtime.

2. **Shared database, service-owned schema.** All services hit the same RDS instance. The appointment-service owns and runs all Alembic migrations (including the `lab_reports` and `report_embeddings` tables used by the other services). This keeps schema management simple while preserving service boundaries at the API level.

3. **Price snapshot at booking.** The `appointment_test_mapping` table stores `price_at_booking` copied from the lab test catalog at the time of booking. This means historical bookings are not affected by future price changes.

4. **Fire-and-forget SQS.** The appointment-service publishes to SQS without waiting for a response, and swallows publish errors. The booking is already committed to Postgres — a notification failure does not fail the booking.

5. **Async Lambda pipeline.** The AI processing (OCR + summary + embeddings) is entirely outside the request path. The staff gets a `201` immediately after the PDF is stored in S3; the patient's AI summary becomes available asynchronously once the Lambda finishes.

6. **Document-scoped RAG.** The vector similarity search in the chat endpoint filters by `report_id` first, then finds the closest chunks. Context never bleeds between patients or reports.

7. **Redis slot locking.** Rather than a database-level unique constraint on `(appointment_date, time_slot)`, the service uses Redis `SET NX EX` to hold a lock during the Postgres write. This handles the race condition of two requests arriving simultaneously for the same slot.

8. **nginx as the in-cluster API gateway.** The frontend nginx container is not just a static file server — it doubles as a reverse proxy that routes API calls to the correct backend service based on URL prefix, eliminating a separate API Gateway or ingress complexity at the service-to-service level (services communicate via Kubernetes service names like `http://appointment-service` and `http://report-service`).
