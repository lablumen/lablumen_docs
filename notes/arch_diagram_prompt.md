# LabLumen — Application Architecture Diagram Prompt (v3)

Create a **simple, clean flow diagram** for LabLumen, a medical lab platform. Think of how a senior engineer would sketch this on a whiteboard — clear boxes, minimal arrows, easy to follow.

---

## STYLE

- White background
- Flat design — no shadows, no gradients, no AWS cloud icons
- Rounded rectangles for all boxes
- Clean sans-serif font (Inter or Roboto)
- Arrows are thin, straight, with 2-4 word labels only
- Lots of whitespace between components

---

## LAYOUT — 3 VERTICAL SWIM LANES side by side

Divide the diagram into 3 vertical columns with a thin dividing line and a label at the top of each:

```
| BOOKING FLOW     |   REPORTING FLOW    |   NOTIFICATION FLOW  |
```

At the very top (above all 3 lanes), place 2 user icons:
- 🧑 Patient
- 👩‍⚕️ Staff

And one shared box centred above everything:
- **Cognito** (yellow) — label: `Auth Service (JWT)`
  - Arrow from Patient → Cognito: `Login`
  - Arrow from Staff → Cognito: `Login`
  - Arrow from Cognito → down (to all 3 lanes): `JWT token`

---

## LANE 1 — BOOKING FLOW (left)

Components top to bottom:

1. **Frontend** (teal box)
   - `nginx · React SPA`

2. **appointment-service** (blue box)
   - `Python / FastAPI`

3. **Redis** (purple box)
   - `Slot-lock cache`

4. **PostgreSQL** (purple box)
   - `Appointments · Lab tests`

Arrows:
- Frontend → appointment-service: `book / list appointments`
- appointment-service → Redis: `slot-lock`
- appointment-service → PostgreSQL: `read / write`

---

## LANE 2 — REPORTING FLOW (centre)

Components top to bottom:

1. **Frontend** *(same box as Lane 1 — spans both lanes at top)*

2. **report-service** (blue box)
   - `Python / FastAPI`

3. **S3** (green box)
   - `PDF store`

4. **ai-service** (orange box)
   - `AWS Lambda`

5. **Bedrock + Textract** (green box, combined)
   - `OCR · Summarise · Embed`

6. **PostgreSQL** *(same box as Lane 1 — spans bottom)*
   - add to sub-label: `· Reports · Embeddings (pgvector)`

Arrows:
- Frontend → report-service: `upload PDF / view report / chat`
- report-service → S3: `store PDF`
- report-service → PostgreSQL: `read / write reports`
- report-service → Bedrock: `RAG chat (query-time)`
- S3 → ai-service: `triggers on upload` *(dashed arrow)*
- ai-service → Bedrock + Textract: `OCR → summarise → embed`
- ai-service → PostgreSQL: `save summary + vectors`

---

## LANE 3 — NOTIFICATION FLOW (right)

Components top to bottom:

1. **appointment-service** *(same box as Lane 1)*

2. **SQS** (purple box)
   - `lablumen-notifications`

3. **notification-service** (blue box)
   - `Python / FastAPI`

4. **SES** (green box)
   - `Email`

Arrows:
- appointment-service → SQS: `publish event` *(dashed)*
- SQS → notification-service: `consume event` *(dashed)*
- notification-service → SES: `send email`

---

## SHARED COMPONENTS (that appear in multiple lanes)

- **Frontend** box sits across the top of Lane 1 + Lane 2 (wide box)
- **PostgreSQL** box sits across the bottom of Lane 1 + Lane 2 (wide box)
- **appointment-service** appears in both Lane 1 and Lane 3 — draw it once with arrows going both right (to SQS) and down (to Redis/PostgreSQL)

---

## WHAT NOT TO DRAW

- No VPC, no ALB, no Route53
- No KMS, ECR, SSM
- No ArgoCD, Karpenter, Grafana
- No "EKS Cluster" border (it's implied)
- No callout sticky notes
- No more than 20 arrows total

---

## TITLE

**LabLumen — Application Architecture**
*(subtitle: Python · FastAPI · React · AWS Lambda)*

## LEGEND (tiny, bottom right)

`───` Synchronous &nbsp;&nbsp; `- - -` Async / event-driven
