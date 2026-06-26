# Engineering Blueprint & Pipeline Guidelines for LabLumen Platform

This document serves as the master guideline and architectural contract for all development, automation, and infrastructure modifications across the LabLumen microservices platform. Every engineering agent or pipeline operator must strictly adhere to these practices to ensure production-grade security, deterministic GitOps execution, and clean separation of concerns.

---

## 1. Core Architectural Paradigm: Separation of Concerns

The LabLumen ecosystem is divided into three completely decoupled repositories. There must be **zero cross-repository compilation dependencies** and **no hardcoded infrastructure strings** in application or GitOps code.

```
+---------------------------------+      +--------------------------------+      +---------------------------------+
|  1. LABLUMEN-TERRAFORM          |      |  2. LABLUMEN-APP               |      |  3. LABLUMEN-K8S                |
|  (The Cloud Infrastructure)     |      |  (The Application Core)        |      |  (The GitOps / CD Engine)       |
|  - Subnets, EKS, RDS, ECR       |      |  - FastAPI Services Source     |      |  - Reusable Helm Charts         |
|  - Direct K8s ServiceAccounts   |      |  - Dockerfiles & Code Lints    |      |  - Environment Value Overlays   |
|  - Empty Secrets Placeholders   |      |  - App-Tier CI Container Push  |      |  - ArgoCD ApplicationSets       |
+---------------------------------+      +--------------------------------+      +---------------------------------+

```

### Repository Boundary Rules

1. **Infrastructure Repository (`lablumen-terraform`)**: Owns the lifecycle of the cloud state, network planes, managed node groups, storage, and identity configurations. It directly connects to the live cluster during `apply` to deploy base namespaces and pre-annotated `ServiceAccounts` required for AWS Identity and Pod handshake (IRSA).
2. **Application Repository (`lablumen-app`)**: Owns the software source code (FastAPI services). It compiles software binaries, executes security linters, and pushes immutable container images to Amazon ECR. It remains entirely blind to live cluster topologies, routing rules, or deployment manifests.
3. **GitOps Repository (`lablumen-k8s`)**: Owns the declarative state of the cluster workloads via Helm charts and ArgoCD patterns. Its manifests must remain **100% environment-blind and static**. It describes *how* to deploy software, while the target values are dynamically fed per environment branch or folder layout.

---

## 2. End-to-End Pipeline Matrix

Every independent pipeline must use tight, least-privilege security boundaries and run within its own lane.

```
========================================================================================
[ PIPELINE 1: INFRASTRUCTURE TRACE (Manual Gate) ]
========================================================================================
Commit Change -> GitHub Actions -> Run 'terraform plan' -> Pull Request Review -> Human Approval Gate -> 'terraform apply'
                                                                                                                │
   ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
   ▼
[1] Spin up VPC, EKS, Node Groups, Shared RDS Postgres Instance, and target ECR Repositories.
[2] Extract generated IAM Roles and write pre-annotated ServiceAccounts directly to EKS Control Plane.
[3] Provision empty, structured storage shell placeholders inside AWS Secrets Manager.

========================================================================================
[ PIPELINE 2: APPLICATION CI TRACE (Automated on Push) ]
========================================================================================
Code Push -> Trigger GitHub Actions Runner -> Run Unit Tests & Security Vulnerability Scans (Trivy)
                                                                                  │
   ┌──────────────────────────────────────────────────────────────────────────────┘
   ▼
[1] If scans pass, call AWS API out-of-band: 'aws ecr describe-repositories' to discover targets.
[2] Build container using the unique 'Git Commit SHA' as an immutable image tag (Never use 'latest').
[3] Push image artifact to the discovered Amazon ECR registry address.
[4] Automated Git Write-Back: Programmatically check out 'lablumen-k8s', execute 'yq' tool to update 
    'image.tag' value in 'values-dev.yaml', commit, and push back to GitOps repository.

========================================================================================
[ ENGINE 3: GITOPS RELOAD (Continuous ArgoCD Reconciliation Loop) ]
========================================================================================
ArgoCD Controller (Polling GitOps Repo) -> Detects version SHA modifications or structural variations
                                                                                  │
   ┌──────────────────────────────────────────────────────────────────────────────┘
   ▼
[1] Evaluates current cluster state against Git declarations.
[2] Launches pods with 'serviceAccount.create: false', forcing them to latch onto pre-created SAs.
[3] Synchronizes infrastructure components according to rigid Sync Wave order.

```

---

## 3. Dynamic Configuration & Variable Discovery

To decouple the environment tiers entirely, applications and pipelines must dynamically pull environmental variables and resource pointers using cloud discovery rather than hardcoded configuration maps.

### Configuration Properties Matrix

* **Dynamic Target Registration**: The Application CI pipeline determines its destination ECR endpoints at runtime by using specialized AWS CLI lookup directives matching our naming conventions:
```bash
export TARGET_ECR_URI=$(aws ecr describe-repositories \
  --repository-names "lablumen/report-service" \
  --query "repositories[0].repositoryUri" \
  --output text)

```


* **Environment Configuration Values**: Non-sensitive variables (such as operational log levels, domain routing rules, or cross-origin headers) flow seamlessly from AWS Systems Manager (SSM) Parameter Store using a unified hierarchical path setup matching `/lablumen/config/*`.
* **Container Environment Injection**: Microservice charts consume non-sensitive metadata configurations out-of-band. The External Secrets Operator maps the complete block directly using a `dataFrom` directive inside the deployment configurations.

---

## 4. Production-Grade Secret Orchestration

Plaintext credentials, database connection strings, or system private keys must never be committed to Git repositories or stored inside raw Terraform tracking files. All data values utilize out-of-band materialization via the External Secrets Operator (ESO).

### The Handshake Architecture

1. **The Infrastructure Layer**: Terraform configures the empty operational secret container shell named `lablumen/app/database-url` inside AWS Secrets Manager.
2. **The Operational Human Bridge**: A platform engineer populates the empty container directly via the AWS Console or secure CLI tools out-of-band, assembling the real Postgres DSN credentials:
```bash
aws secretsmanager put-secret-value \
  --secret-id "lablumen/app/database-url" \
  --secret-string "postgresql://lablumen_user:secure_password@rds-endpoint:5432/lablumen"

```


3. **The Cluster Decoupling Layer**: EKS coordinates container identities using AWS OIDC. The External Secrets Operator controller runs using the pre-annotated `ServiceAccount` identity called `lablumen-eso` which is granted specific, IAM-controlled read permissions to the Secrets Manager endpoints.

```
+---------------------+             +--------------------+             +-----------------------------+
| AWS Secrets Manager |  ────────►  | External Secrets   |  ────────►  | Native K8s Secret (Memory)  |
| (Encrypted Cloud)   |   (IRSA)    | Operator (Cluster) |  (Creates)  | [report-service-secrets]    |
+---------------------+             +--------------------+             +-----------------------------+
                                                                                      │
                                                                                      ▼ (envFrom.secretRef)
                                                                       +-----------------------------+
                                                                       | Running Application Pod     |
                                                                       | (Reads plain environment)   |
                                                                       +-----------------------------+

```

### Reusable Helm Configuration Spec

Inside `charts/microservice/templates/externalsecret.yaml`, the data extraction mapping is driven by values, allowing the underlying chart to remain entirely static:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ .Values.envSecretName }}
  namespace: {{ .Release.Namespace }}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: {{ .Values.envSecretName }}
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: lablumen/app/database-url

```

---

## 5. Automated GitOps Promotion & Release Controls

Promoting versions through environments must follow strict gates to insulate production spaces from rapid integration iterations.

### Environment Partition Model

* **Development Space (`lablumen-dev`)**: Moves automatically. The developer pushes code, the CI loop compiles the container, and the pipeline uses a programmatic machine key to rewrite the target image version tag inside `services/<svc>/values-dev.yaml`. ArgoCD processes the change instantly.
* **Production Space (`lablumen`)**: Controlled via human gates. Releasing changes requires an engineer to manually author an official Git Release Tag (e.g., `v1.2.0`) in the application repository. A human must then explicitly edit `services/<svc>/values-prod.yaml` to update the image tag reference.

### ArgoCD Sync-Wave Scheduling

To eliminate bootstrap synchronization races or resource configuration crashes on new cluster provisions, workloads are deployed in strict hierarchical order using the `argocd.argoproj.io/sync-wave` annotation:

| Grouping | Target Components | Sync Wave | Strategy Details |
| --- | --- | --- | --- |
| **Core Platform Addons** | `external-secrets`, `metrics-server`, `aws-load-balancer-controller`, `karpenter` | **Wave 0** | Hydrates operators, engines, and system custom resource definitions (CRDs) first. |
| **Cluster Secret Stores** | `ClusterSecretStore` mappings for AWS Systems Manager and Secrets Manager | **Wave 1** | Initializes after controllers are ready so that lookup engines hook up cleanly. |
| **Application Services** | `appointment-service`, `report-service`, `notification-service`, `redis` | **Wave 2** | Runs leaf application containers once processing, identity, and secret planes are active. |

---

## 6. Coding Agent Constraints & Chart Hardening Requirements

When constructing, refactoring, or updating any Kubernetes resources, the coding agent must enforce the following senior-level compliance rules:

1. **ServiceAccount Creation Contract**:
* Charts must expose a parametrized parameter block allowing individual toggle configuration:
```yaml
serviceAccount:
  create: {{ .Values.serviceAccount.create }}
  name: {{ .Values.serviceAccount.name }}

```


* **In Production**: `serviceAccount.create` must equal `false` for any component utilizing an AWS identity (Report, Notification, ESO, LBC, Karpenter). They must consume the pre-existing, secure accounts deployed by Terraform.


2. **Mandatory Security Context Hardening**:
All workloads must include a rigid, rootless container security configuration block:
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  fsGroup: 10001
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
  seccompProfile:
    type: RuntimeDefault

```


*If a service requires write access at runtime, the agent must declare an ephemeral `emptyDir` volume and mount it directly to `/tmp` rather than opening root filesystem access permissions.*
3. **Application Availability Assurances**:
* Every service must implement multi-tier availability validation using a robust three-part probe framework: an explicit `startupProbe` with liberal timing thresholds to handle cold-start conditions, alongside strict `livenessProbe` and `readinessProbe` definitions.
* Workloads with replica counts greater than or equal to 2 must feature an independent `PodDisruptionBudget` configured with `maxUnavailable: 1` to ensure traffic remains insulated during voluntary node drain operations or Karpenter scale-downs.
* Every pod deployment must specify explicit `topologySpreadConstraints` to distribute replicas evenly across multiple Availability Zones (`topology.kubernetes.io/zone`) and specific cluster hardware nodes (`kubernetes.io/hostname`).