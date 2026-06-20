# Unified Architecture Blueprint & Master Spec: LabConnect Platform (v1)

## 1. Directory Topology Specification

```
labconnect/
├── .github/workflows/              # Initial CI/CD triggers (Docker Build & Push)
├── terraform/                      # Infrastructure as Code (IaC) Base
│   ├── main.tf
│   ├── variables.tf
│   └── modules/
│       ├── vpc/ │ eks/ │ karpenter/ │ rds/ │ redis/ │ s3/
│       └── sqs/ │ ses/ │ cognito/   │ iam/ │ sg/    │ lambda/
├── k8s/                            # GitOps Infrastructure Manifests (ArgoCD Root)
│   ├── apps/                       # Application Chart Declarations
│   │   ├── auth-service/ │ appointment-service/
│   │   └── report-service/ │ notification-service/
│   └── platform-addons/            # Core Cluster Operators
│       ├── argocd/ │ karpenter/ │ aws-lb-controller/ │ csi-secrets/
│       └── hpa-metrics.yaml
├── backend/                        # Codebase Execution Layer
│   ├── auth-service/               # FastAPI + Cognito Validation Proxy
│   ├── appointment-service/        # FastAPI + Scheduling & Seed Engine
│   ├── report-service/             # FastAPI + Document Vectors & S3 Manager
│   └── notification-service/       # Python Background SQS Consumer Loop
├── serverless/
│   └── ai-processing-pipeline/    # S3-Triggered Python Lambda for RAG Embeddings
└── frontend/                       # Light Bento Client Application
    ├── src/
    │   ├── components/ui/          # ShadCN + Tailwind Design Components
    │   ├── hooks/                  # TanStack Query Hook Vectors
    │   └── routes/                 # React Router DOM Layouts

```

---

## 2. Normalized Database Relational Model & Seed Data

The underlying engine is **Amazon RDS PostgreSQL** with `pgvector` pre-installed. The data model handles cross-domain concerns using clear foreign key boundaries:

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS vector; -- Activates pgvector capabilities natively

CREATE TABLE users (
    user_id UUID PRIMARY KEY, -- Maps directly to AWS Cognito 'sub' claim UUID
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE user_roles (
    user_id UUID REFERENCES users(user_id) ON DELETE CASCADE,
    role_name VARCHAR(50) CHECK (role_name IN ('PATIENT', 'LAB_STAFF', 'LAB_ADMIN')),
    PRIMARY KEY (user_id, role_name)
);

CREATE TABLE patient_profiles (
    patient_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_owner_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    phone_number VARCHAR(20) NOT NULL,
    date_of_birth DATE NOT NULL,
    biological_gender VARCHAR(20) CHECK (biological_gender IN ('Male', 'Female', 'Other')),
    relationship_to_owner VARCHAR(50) NOT NULL, -- 'Self', 'Mother', 'Father', 'Child'
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE lab_tests (
    test_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    description TEXT NOT NULL,
    base_cost NUMERIC(10,2) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE
);

CREATE TABLE appointments (
    appointment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_owner_id UUID NOT NULL REFERENCES users(user_id),
    appointment_date DATE NOT NULL,
    time_slot TIME NOT NULL,
    status VARCHAR(50) DEFAULT 'Booked' CHECK (status IN ('Booked', 'Cancelled', 'Checked-In', 'Completed')),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE appointment_test_mapping (
    mapping_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    appointment_id UUID NOT NULL REFERENCES appointments(appointment_id) ON DELETE CASCADE,
    test_id UUID NOT NULL REFERENCES lab_tests(test_id),
    patient_id UUID NOT NULL REFERENCES patient_profiles(patient_id)
);

CREATE TABLE lab_reports (
    report_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    appointment_id UUID UNIQUE NOT NULL REFERENCES appointments(appointment_id),
    patient_id UUID NOT NULL REFERENCES patient_profiles(patient_id),
    s3_url VARCHAR(512) NOT NULL,
    ai_layman_summary TEXT DEFAULT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- RAG Vector Table: Stores isolated report chunks and vectors side-by-side
CREATE TABLE report_embeddings (
    embedding_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID REFERENCES lab_reports(report_id) ON DELETE CASCADE,
    chunk_content TEXT NOT NULL,
    embedding vector(1536) -- Configured for Amazon Bedrock Titan Text Embedding dimensions
);

-- High-performance vector index for rapid cosine similarity queries
CREATE INDEX ON report_embeddings USING hnsw (embedding vector_cosine_ops);

```

### Mandatory Seed Vector Configuration

The `appointment-service` must execute this exact seed array during its initialization sequence to populate the catalog:

```sql
INSERT INTO lab_tests (name, description, base_cost) VALUES
('Complete Blood Count (CBC)', 'Evaluates overall cellular health by measuring red blood cells, white blood cells, and platelets.', 45.00),
('Comprehensive Metabolic Panel (CMP)', 'Checks your body''s fluid balance, blood sugar levels, and liver and kidney functions.', 65.00),
('Lipid Profile', 'Measures cardiovascular risk by calculating total cholesterol, HDL, LDL, and triglycerides.', 50.00),
('Thyroid Function Panel', 'Evaluates metabolism speed by measuring TSH, Free T3, and Free T4 hormone levels.', 75.00),
('Hemoglobin A1c (HbA1c)', 'Provides a 3-month average of blood glucose levels to screen for diabetes.', 40.00),
('Urinalysis (UA)', 'Analyzes physical, chemical, and microscopic properties of urine to check for infections or kidney issues.', 30.00),
('Vitamin D & Vitamin B12 Panel', 'Measures essential nutrient absorption levels in the bloodstream.', 90.00),
('Liver Function Test (LFT)', 'Isolates specific liver enzymes like ALT, AST, ALP, and bilirubin to check for organ damage.', 55.00),
('Renal Function Panel (RFP)', 'Evaluates kidney health specifically using blood urea nitrogen (BUN), creatinine, and eGFR.', 60.00);

```

---

## 3. Network Isolation, Security, & Edge Routing Matrix

To keep data transit entirely secure, private, and fast, traffic routing is strictly separated into distinct public and private layers.

### Route 53 Multi-Record Configuration

Your Route 53 Hosted Zone splits public traffic directly at the DNS layer:

1. **Frontend Record (`app.yourlab.com`):** An `Alias` record pointing directly to an **Amazon CloudFront Distribution**. This distribution serves static, compiled React SPA resources securely cached at global edge locations.
2. **Backend Record (`api.yourlab.com`):** An `Alias` record pointing directly to your **Application Load Balancer (ALB)**.

### Secure Diagnostic Asset Streaming (Zero CDN Caching)

* **CloudFront Policy:** Amazon CloudFront is configured to handle static assets *only*. It has zero permission or route mapping to your patient medical records.
* **S3 Presigned URLs:** When a patient views a report, the `report-service` calls the S3 API using its local IAM Service Account Role to generate an **S3 Presigned URL**.
* **Tightened Expiration Window:** To enforce strict security compliance, the URL is hard-capped with a **2-minute expiration window**.
* **Frontend Execution:** The frontend receives this ephemeral URL string and renders the document instantly inside a browser preview modal overlay. The file remains entirely inside your private, non-public S3 bucket, completely bypassing public CDN caching.

### Private Subnet AWS Gateway Interfaces

Internal microservices bypass the public internet entirely when talking to AWS dependencies by using **AWS VPC Endpoints (PrivateLink)** configured inside your private subnets:

* **S3 Gateway Endpoint:** Injected directly into the private VPC route tables for zero-cost data transfer to your storage buckets.
* **Interface Endpoints:** Secure Private ENIs mapped inside private subnets with port 443 open to EKS worker nodes for:
* `com.amazonaws.[region].cognito-idp` (Authentication validation)
* `com.amazonaws.[region].bedrock-runtime` (AI Vectorizations and Chat generations)



---

## 4. End-to-End Scoped RAG AI Architecture

Your application uses a highly precise, **Document-Scoped Retrieval-Augmented Generation (RAG)** architecture. AI processing is isolated to the specific document being viewed, completely eliminating general data bleeding between patients.

### Data Upload & Ingestion RAG Pipeline

```
[ Lab Tech Uploads PDF ] ──► [ Amazon S3 Bucket ]
                                    │
                            (S3 Object Trigger)
                                    │
                                    ▼
                             [ AWS Lambda ]
                                    │
                         (Amazon Textract OCR)
                                    │
                                    ▼
                             [ AWS Lambda ] ──► (Generates Layman Summary via Bedrock Nova)
                                    │
                         (Chunks Text & Embeds via Bedrock Titan)
                                    │
                                    ▼
                         [ PostgreSQL Storage ] (Writes chunks + 1536 Vector arrays)

```

1. **File Generation:** The lab technician uploads a patient result file. `report-service` places the object inside a secure S3 folder.
2. **Event Notification Hook:** S3 fires an immediate event notice to an **AWS Lambda** python script.
3. **Structural Text OCR:** Lambda hands the document details to **Amazon Textract** to extract the values while perfectly preserving tabular structural alignment.
4. **Summary Generation:** Lambda sends the clean text payload to **Amazon Bedrock (Nova 2 Lite)** to write an empathetic, easy-to-read layman summary. This summary is written to the `lab_reports` table.
5. **Vector Chunk Ingestion:** Lambda splits the text into small paragraphs (chunks). It maps each chunk through the **Amazon Bedrock Titan Text Embedding** engine, generating a 1536-dimensional float array. These vector arrays and raw text chunks are saved straight to the `report_embeddings` table, tied uniquely to that single `report_id`.

### The Document-Scoped Chatbot Flow

When a user opens the chat widget for a specific report, the interaction is completely locked to that single context row:

1. The user asks a question: *"What does my high glucose level mean?"*
2. The request hits the endpoint `/api/v1/reports/{report_id}/chat` accompanied by the question string.
3. The system converts the user's question into a vector using Bedrock Titan.
4. **Scoped Vector Search:** The backend runs a vector cosine similarity search in PostgreSQL **strictly filtered by the current report ID**:
```sql
SELECT chunk_content 
FROM report_embeddings 
WHERE report_id = :target_report_id
ORDER BY embedding <=> :question_vector ASC
LIMIT 3;

```


5. **Context Construction:** PostgreSQL returns the top 3 most contextually relevant sentences *from that specific patient report only*.
6. **Response Generation:** The service bundles those exact snippets, the conversation history, and the user's question into a single prompt wrapper and calls **Amazon Bedrock (Nova 2 Lite)** via PrivateLink to generate an accurate, safe response.

---

## 5. Automated GitOps & Cluster Management (ArgoCD Lock)

Your EKS cluster operations run entirely through declarative **GitOps automation via ArgoCD**, completely eliminating manual server scripting.

```
[ GitHub Actions ] ──► Builds Docker Image ──► Pushes to Amazon ECR
                                                    │
                                            (Auto-Sync Poll)
                                                    │
                                                    ▼
[ ArgoCD GitOps Operator ] ◄────────────────────────┘
         │
         ├──► Watches `k8s/platform-addons/` ──► Deploys Karpenter, Load Balancer Controller, Secrets CSI
         └──► Watches `k8s/apps/`            ──► Rolls out rolling updates to Microservices

```

* **The Core Operator:** **ArgoCD** is deployed inside the `labconnect-system` namespace. It continuously monitors your GitHub repository's `k8s/` tree.
* **Cluster Infrastructure Manifests:** ArgoCD syncs and maintains your critical operations utilities:
* **AWS Load Balancer Controller:** Generates physical external Application Load Balancers based on ingress rules.
* **Karpenter:** Dynamically scales up EC2 compute capacity based on scheduling bottlenecks and deletes idle nodes instantly during off-peak windows.
* **Secrets Store CSI Driver:** Integrates with **AWS Secrets Manager** to present database keys, Cognito clients, and mail secrets directly into microservice pods without writing secrets to Git.


* **Application Rollouts:** When your GitHub Actions CI pipeline pushes a new container to **Amazon ECR**, ArgoCD automatically catches the update and runs a safe, zero-downtime rolling update deployment across your service pods.

---

## 6. Modular Multi-Step Development Plan

The coding agent must complete this project sequentially, ensuring each stage is verified before advancing. **Do not attempt a single-shot system generation.**

```
┌────────────────────────────────────────┐
│  STEP 1: Infrastructure Provisioning   │ ──► Deploy network VPC, Subnets, PrivateLink, RDS, Redis, S3, Cognito via Terraform
└───────────────────┬────────────────────┘
                    ▼
┌────────────────────────────────────────┐
│  STEP 2: GitOps & Bootstrap Injection  │ ──► Install ArgoCD, Karpenter, AWS LB Controller, CSI Secrets via Manifest Root
└───────────────────┬────────────────────┘
                    ▼
┌────────────────────────────────────────┐
│  STEP 3: Microservice Codebase Build   │ ──► Build the 4 backend microservices, apply UI, run DB Seed scripts
└───────────────────┬────────────────────┘
                    ▼
┌────────────────────────────────────────┐
│  STEP 4: AI Vector Pipeline Rollout    │ ──► Wire up Lambda, Textract OCR, Bedrock Nova RAG Chat routing logic
└────────────────────────────────────────┘

```

---

## 7. Execution Mandate For Your AI Agent (Claude Command)

To begin building the framework files, pass the following explicit instruction into your AI tool:

> *"Act as an expert Principal Cloud Architect and Lead Software Engineer. Read the attached locked **Comprehensive System Architecture Blueprint**. Do not write application code or components yet. Your first task is to create the first 4 architecture documents (**01-system-architecture.md, 02-domain-model.md, 03-database-schema.md, 04-api-contracts.md**) following the Phased Roadmap rules. Stop for my manual verification after document 04 is generated."*

---

Ah, good catch! I kept the backend, data, and infrastructure layers completely airtight but omitted the explicit visual layout blueprints.

Let's plug the UI spec straight back in so your coding agent has the exact design system rules, component maps, and screen matrix to generate your React/TypeScript frontend without guessing.

Here is the complete, absolute **A-Z End-to-End Blueprint** with the **UI Specification fully restored and integrated**.

---

# Unified Architecture Blueprint & Master Spec: LabConnect Platform (v1)

## 1. Directory Topology Specification

```
labconnect/
├── .github/workflows/              # Initial CI/CD triggers (Docker Build & Push)
├── terraform/                      # Infrastructure as Code (IaC) Base
│   ├── main.tf
│   ├── variables.tf
│   └── modules/
│       ├── vpc/ │ eks/ │ karpenter/ │ rds/ │ redis/ │ s3/
│       └── sqs/ │ ses/ │ cognito/   │ iam/ │ sg/    │ lambda/
├── k8s/                            # GitOps Infrastructure Manifests (ArgoCD Root)
│   ├── apps/                       # Application Chart Declarations
│   │   ├── auth-service/ │ appointment-service/
│   │   └── report-service/ │ notification-service/
│   └── platform-addons/            # Core Cluster Operators
│       ├── argocd/ │ karpenter/ │ aws-lb-controller/ │ csi-secrets/
│       └── hpa-metrics.yaml
├── backend/                        # Codebase Execution Layer
│   ├── auth-service/               # FastAPI + Cognito Validation Proxy
│   ├── appointment-service/        # FastAPI + Scheduling & Seed Engine
│   ├── report-service/             # FastAPI + Document Vectors & S3 Manager
│   └── notification-service/       # Python Background SQS Consumer Loop
├── serverless/
│   └── ai-processing-pipeline/    # S3-Triggered Python Lambda for RAG Embeddings
└── frontend/                       # Light Bento Client Application
    ├── src/
    │   ├── components/ui/          # ShadCN + Tailwind Design Components
    │   ├── hooks/                  # TanStack Query Hook Vectors
    │   └── routes/                 # React Router DOM Layouts

```

---

## 2. Normalized Database Relational Model & Seed Data

The underlying engine is **Amazon RDS PostgreSQL** with `pgvector` pre-installed. The data model handles cross-domain concerns using clear foreign key boundaries:

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS vector; -- Activates pgvector capabilities natively

CREATE TABLE users (
    user_id UUID PRIMARY KEY, -- Maps directly to AWS Cognito 'sub' claim UUID
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE user_roles (
    user_id UUID REFERENCES users(user_id) ON DELETE CASCADE,
    role_name VARCHAR(50) CHECK (role_name IN ('PATIENT', 'LAB_STAFF', 'LAB_ADMIN')),
    PRIMARY KEY (user_id, role_name)
);

CREATE TABLE patient_profiles (
    patient_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_owner_id UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    phone_number VARCHAR(20) NOT NULL,
    date_of_birth DATE NOT NULL,
    biological_gender VARCHAR(20) CHECK (biological_gender IN ('Male', 'Female', 'Other')),
    relationship_to_owner VARCHAR(50) NOT NULL, -- 'Self', 'Mother', 'Father', 'Child'
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE lab_tests (
    test_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name VARCHAR(255) NOT NULL,
    description TEXT NOT NULL,
    base_cost NUMERIC(10,2) NOT NULL,
    is_active BOOLEAN DEFAULT TRUE
);

CREATE TABLE appointments (
    appointment_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_owner_id UUID NOT NULL REFERENCES users(user_id),
    appointment_date DATE NOT NULL,
    time_slot TIME NOT NULL,
    status VARCHAR(50) DEFAULT 'Booked' CHECK (status IN ('Booked', 'Cancelled', 'Checked-In', 'Completed')),
    created_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE appointment_test_mapping (
    mapping_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    appointment_id UUID NOT NULL REFERENCES appointments(appointment_id) ON DELETE CASCADE,
    test_id UUID NOT NULL REFERENCES lab_tests(test_id),
    patient_id UUID NOT NULL REFERENCES patient_profiles(patient_id)
);

CREATE TABLE lab_reports (
    report_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    appointment_id UUID UNIQUE NOT NULL REFERENCES appointments(appointment_id),
    patient_id UUID NOT NULL REFERENCES patient_profiles(patient_id),
    s3_url VARCHAR(512) NOT NULL,
    ai_layman_summary TEXT DEFAULT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);

-- RAG Vector Table: Stores isolated report chunks and vectors side-by-side
CREATE TABLE report_embeddings (
    embedding_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    report_id UUID REFERENCES lab_reports(report_id) ON DELETE CASCADE,
    chunk_content TEXT NOT NULL,
    embedding vector(1536) -- Configured for Amazon Bedrock Titan Text Embedding dimensions
);

-- High-performance vector index for rapid cosine similarity queries
CREATE INDEX ON report_embeddings USING hnsw (embedding vector_cosine_ops);

```

### Mandatory Seed Vector Configuration

The `appointment-service` must execute this exact seed array during its initialization sequence to populate the catalog:

```sql
INSERT INTO lab_tests (name, description, base_cost) VALUES
('Complete Blood Count (CBC)', 'Evaluates overall cellular health by measuring red blood cells, white blood cells, and platelets.', 45.00),
('Comprehensive Metabolic Panel (CMP)', 'Checks your body''s fluid balance, blood sugar levels, and liver and kidney functions.', 65.00),
('Lipid Profile', 'Measures cardiovascular risk by calculating total cholesterol, HDL, LDL, and triglycerides.', 50.00),
('Thyroid Function Panel', 'Evaluates metabolism speed by measuring TSH, Free T3, and Free T4 hormone levels.', 75.00),
('Hemoglobin A1c (HbA1c)', 'Provides a 3-month average of blood glucose levels to screen for diabetes.', 40.00),
('Urinalysis (UA)', 'Analyzes physical, chemical, and microscopic properties of urine to check for infections or kidney issues.', 30.00),
('Vitamin D & Vitamin B12 Panel', 'Measures essential nutrient absorption levels in the bloodstream.', 90.00),
('Liver Function Test (LFT)', 'Isolates specific liver enzymes like ALT, AST, ALP, and bilirubin to check for organ damage.', 55.00),
('Renal Function Panel (RFP)', 'Evaluates kidney health specifically using blood urea nitrogen (BUN), creatinine, and eGFR.', 60.00);

```

---

## 3. UI/UX Design Token System & Layout Matrices (The Frontend Lock)

The application adheres strictly to a clinical, light-mode Bento UI aesthetic modeled around structured information processing, clean typography, and a clear desktop hierarchy. It **overrides** any default dark theme preferences.

### Style Tokens (Tailwind System Mapping)

```json
{
  "theme": {
    "colors": {
      "primary": "#008080",
      "background": "#FFFFFF",
      "surface": "#F8FAFC",
      "success": "#10B981",
      "warning": "#F59E0B",
      "danger": "#EF4444",
      "text-dark": "#0F172A",
      "text-muted": "#64748B"
    },
    "borderRadius": {
      "bento": "1rem"
    },
    "boxShadow": {
      "bento-diffused": "0 10px 25px -5px rgba(0, 128, 128, 0.05), 0 8px 10px -6px rgba(0, 0, 0, 0.02)"
    }
  }
}

```

### Visual Interface Grids & Content Priority

#### A. Patient Dashboard Layout Matrix

Designed as a multi-layered Bento grid with clear logical grouping:

```
+----------------------------------------------------------------------------+
|  TOP SPANNING ROW: HERO CARD                                               |
|  [Upcoming Appointment Summary: Test, Selected Family Profile, Date, Time] |
+----------------------------------------------------------------------------+
|  MID ROW LEFT BENTO (60% Width)     |  MID ROW RIGHT BENTO (40% Width)     |
|  [Latest Reports Matrix]            |  [Active Report AI Layman Summary]   |
|  - Table list of completed tests    |  - High-level, jargon-free wrap up   |
|  - Action button triggers Modal     |  - Direct link to open Interactive   |
|    Preview Window                   |    Chat Overlay Interface            |
+----------------------------------------------------------------------------+
|  LOWER SPANNING ROW: HISTORY LOG                                          |
|  [Historical Archive Layout: Complete tabular summary of all past tests]   |
+----------------------------------------------------------------------------+

```

#### B. Staff / Admin Dashboard Layout Matrix

Designed to drive execution tracking and operational throughput:

```
+--------------------------------───+--------------------------------───+
|  TOP LEFT BENTO (50% Width)       |  TOP RIGHT BENTO (50% Width)      |
|  [Today's Scheduled Volume count] |  [Pending PDF Report Uploads count] |
+--------------------------------───+--------------------------------───+
|  MID LEFT BENTO (50% Width)       |  MID RIGHT BENTO (50% Width)      |
|  [Active Patient Account Registry]|  [Lab System Catalog Settings]     |
+--------------------------------───+--------------------------------───+
|  LOWER MASTER TABLE LAYER                                             |
|  [Global Operations Queue: Row status controls 'Checked-In' / 'Upload']|
+--------------------------------───────────────────────────────────────+

```

#### C. Floating Diagnostic Preview Modal Overlay

Clicking a lab report fires an browser-native sandbox iframe embedded within a modal container. The window dims the main layout entirely using an translucent background layer, placing a prominent **"Download PDF Report"** button at the top header edge of the glass sheet.

---

## 4. Network Isolation, Security, & Edge Routing Matrix

To keep data transit entirely secure and private, traffic routing is strictly separated into distinct public and private layers.

### Route 53 Multi-Record Configuration

Your Route 53 Hosted Zone splits public traffic directly at the DNS layer:

1. **Frontend Record (`app.yourlab.com`):** An `Alias` record pointing directly to an **Amazon CloudFront Distribution**. This distribution serves static, compiled React SPA resources securely cached at global edge locations.
2. **Backend Record (`api.yourlab.com`):** An `Alias` record pointing directly to your **Application Load Balancer (ALB)**.

### Secure Diagnostic Asset Streaming (Zero CDN Caching)

* **CloudFront Policy:** Amazon CloudFront handles static assets *only*. It has zero permission or route mapping to your patient medical records.
* **S3 Presigned URLs:** When a patient views a report, the `report-service` calls the S3 API using its local IAM Service Account Role to generate an **S3 Presigned URL**.
* **Tightened Expiration Window:** To enforce strict security compliance, the URL is hard-capped with a **2-minute expiration window**.
* **Frontend Execution:** The frontend receives this ephemeral URL string and renders the document instantly inside the browser preview modal overlay. The file remains entirely inside your private, non-public S3 bucket, completely bypassing public CDN caching.

### Private Subnet AWS Gateway Interfaces

Internal microservices bypass the public internet entirely when talking to AWS dependencies by using **AWS VPC Endpoints (PrivateLink)** configured inside your private subnets:

* **S3 Gateway Endpoint:** Injected directly into the private VPC route tables for zero-cost data transfer to your storage buckets.
* **Interface Endpoints:** Secure Private ENIs mapped inside private subnets with port 443 open to EKS worker nodes for:
* `com.amazonaws.[region].cognito-idp` (Authentication validation)
* `com.amazonaws.[region].bedrock-runtime` (AI Vectorizations and Chat generations)



---

## 5. End-to-End Scoped RAG AI Architecture

Your application uses a highly precise, **Document-Scoped Retrieval-Augmented Generation (RAG)** architecture. AI processing is isolated to the specific document being viewed, completely eliminating general data bleeding between patients.

### Data Upload & Ingestion RAG Pipeline

```
[ Lab Tech Uploads PDF ] ──► [ Amazon S3 Bucket ]
                                    │
                            (S3 Object Trigger)
                                    │
                                    ▼
                             [ AWS Lambda ]
                                    │
                         (Amazon Textract OCR)
                                    │
                                    ▼
                             [ AWS Lambda ] ──► (Generates Layman Summary via Bedrock Nova)
                                    │
                         (Chunks Text & Embeds via Bedrock Titan)
                                    │
                                    ▼
                         [ PostgreSQL Storage ] (Writes chunks + 1536 Vector arrays)

```

1. **File Generation:** The lab technician uploads a patient result file. `report-service` places the object inside a secure S3 folder.
2. **Event Notification Hook:** S3 fires an immediate event notice to an **AWS Lambda** python script.
3. **Structural Text OCR:** Lambda hands the document details to **Amazon Textract** to extract the values while perfectly preserving tabular structural alignment.
4. **Summary Generation:** Lambda sends the clean text payload to **Amazon Bedrock (Nova 2 Lite)** to write an empathetic, easy-to-read layman summary. This summary is written to the `lab_reports` table.
5. **Vector Chunk Ingestion:** Lambda splits the text into small paragraphs (chunks). It maps each chunk through the **Amazon Bedrock Titan Text Embedding** engine, generating a 1536-dimensional float array. These vector arrays and raw text chunks are saved straight to the `report_embeddings` table, tied uniquely to that single `report_id`.

### The Document-Scoped Chatbot Flow

When a user opens the chat widget for a specific report, the interaction is completely locked to that single context row:

1. The user asks a question: *"What does my high glucose level mean?"*
2. The request hits the endpoint `/api/v1/reports/{report_id}/chat` accompanied by the question string.
3. The system converts the user's question into a vector using Bedrock Titan.
4. **Scoped Vector Search:** The backend runs a vector cosine similarity search in PostgreSQL **strictly filtered by the current report ID**:
```sql
SELECT chunk_content 
FROM report_embeddings 
WHERE report_id = :target_report_id
ORDER BY embedding <=> :question_vector ASC
LIMIT 3;

```



```
5.  **Context Construction:** PostgreSQL returns the top 3 most contextually relevant sentences *from that specific patient report only*.
6.  **Response Generation:** The service bundles those exact snippets, the conversation history, and the user's question into a single prompt wrapper and calls **Amazon Bedrock (Nova 2 Lite)** via PrivateLink to generate an accurate, safe response.

---

## 6. Automated GitOps & Cluster Management (ArgoCD Lock)

Your EKS cluster operations run entirely through declarative **GitOps automation via ArgoCD**, completely eliminating manual server scripting.


```

[ GitHub Actions ] ──► Builds Docker Image ──► Pushes to Amazon ECR
│
(Auto-Sync Poll)
│
▼
[ ArgoCD GitOps Operator ] ◄────────────────────────┘
│
├──► Watches `k8s/platform-addons/` ──► Deploys Karpenter, Load Balancer Controller, Secrets CSI
└──► Watches `k8s/apps/`            ──► Rolls out rolling updates to Microservices

```

* **The Core Operator:** **ArgoCD** is deployed inside the `labconnect-system` namespace. It continuously monitors your GitHub repository's `k8s/` tree.
* **Cluster Infrastructure Manifests:** ArgoCD syncs and maintains your critical operations utilities:
    * **AWS Load Balancer Controller:** Generates physical external Application Load Balancers based on ingress rules.
    * **Karpenter:** Dynamically scales up EC2 compute capacity based on scheduling bottlenecks and deletes idle nodes instantly during off-peak windows.
    * **Secrets Store CSI Driver:** Integrates with **AWS Secrets Manager** to present database keys, Cognito clients, and mail secrets directly into microservice pods without writing secrets to Git.
* **Application Rollouts:** When your GitHub Actions CI pipeline pushes a new container to **Amazon ECR**, ArgoCD automatically catches the update and runs a safe, zero- downtime rolling update deployment across your service pods.

---

## 7. Modular Multi-Step Development Plan

The coding agent must complete this project sequentially, ensuring each stage is verified before advancing. **Do not attempt a single-shot system generation.**


```

┌────────────────────────────────────────┐
│  STEP 1: Infrastructure Provisioning   │ ──► Deploy network VPC, Subnets, PrivateLink, RDS, Redis, S3, Cognito via Terraform
└───────────────────┬────────────────────┘
▼
┌────────────────────────────────────────┐
│  STEP 2: GitOps & Bootstrap Injection  │ ──► Install ArgoCD, Karpenter, AWS LB Controller, CSI Secrets via Manifest Root
└───────────────────┬────────────────────┘
▼
┌────────────────────────────────────────┐
│  STEP 3: Microservice Codebase Build   │ ──► Build the 4 backend microservices, apply UI layout tokens, run DB Seed scripts
└───────────────────┬────────────────────┘
▼
┌────────────────────────────────────────┐
│  STEP 4: AI Vector Pipeline Rollout    │ ──► Wire up Lambda, Textract OCR, Bedrock Nova RAG Chat routing logic
└────────────────────────────────────────┘

```

---

## 8. Execution Mandate For Your AI Agent (Claude Command)

To begin building the framework files, pass the following explicit instruction into your AI tool:

> *"Act as an expert Principal Cloud Architect and Lead Software Engineer. Read the attached locked **Comprehensive System Architecture Blueprint**. Do not write application code or components yet. Your first task is to create the first 5 architecture documents (**01-system-architecture.md, 02-domain-model.md, 03-database-schema.md, 04-api-contracts.md, 05-frontend-design-system.md**) following the Phased Roadmap rules. Stop for my manual verification after document 05 is generated."*

```