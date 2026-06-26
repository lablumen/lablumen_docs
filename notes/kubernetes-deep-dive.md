# LabLumen — Kubernetes & EKS Deep Dive

> This document teaches the entire Kubernetes layer of LabLumen from first principles. Every object type is explained, every configuration choice is justified, and every line of connection between the cluster and AWS is traced. After reading this you will be able to defend any Kubernetes or EKS decision in front of senior engineers.

---

## Table of Contents

1. [Kubernetes Mental Model — Before Anything Else](#1-kubernetes-mental-model--before-anything-else)
2. [The Cluster at a Glance](#2-the-cluster-at-a-glance)
3. [Namespaces — Logical Isolation Inside One Cluster](#3-namespaces--logical-isolation-inside-one-cluster)
4. [The Helm Chart System](#4-the-helm-chart-system)
5. [Core Kubernetes Objects — What Each One Does](#5-core-kubernetes-objects--what-each-one-does)
6. [Per-Service Breakdown — What Lives in the Cluster](#6-per-service-breakdown--what-lives-in-the-cluster)
7. [Platform Addons — The Controllers That Make Everything Work](#7-platform-addons--the-controllers-that-make-everything-work)
8. [ArgoCD — GitOps & the App-of-Apps Pattern](#8-argocd--gitops--the-app-of-apps-pattern)
9. [Karpenter — Dynamic Node Provisioning](#9-karpenter--dynamic-node-provisioning)
10. [External Secrets Operator — AWS Secrets → K8s Secrets](#10-external-secrets-operator--aws-secrets--k8s-secrets)
11. [IRSA — How Pods Talk to AWS](#11-irsa--how-pods-talk-to-aws)
12. [Network Flow — Internet to Pod](#12-network-flow--internet-to-pod)
13. [Pod-to-Pod & Pod-to-AWS Communication Map](#13-pod-to-pod--pod-to-aws-communication-map)
14. [Security Hardening Inside Pods](#14-security-hardening-inside-pods)
15. [Dev vs Prod — How the Two Environments Differ](#15-dev-vs-prod--how-the-two-environments-differ)
16. [The Bootstrap Sequence — From Zero to Running Cluster](#16-the-bootstrap-sequence--from-zero-to-running-cluster)
17. [The Full CI/CD → GitOps Loop](#17-the-full-cicd--gitops-loop)
18. [Key Design Decisions & Defences](#18-key-design-decisions--defences)

---

## 1. Kubernetes Mental Model — Before Anything Else

Think of Kubernetes as a **declarative operating system for containers**. Instead of saying "run this command on this server," you say "I want this container running, with 2 replicas, restarted if it crashes, with these environment variables." Kubernetes figures out *how* to make that happen and *keeps it that way* forever.

### The control loop

Kubernetes has one fundamental pattern repeated everywhere: **the control loop** (also called the reconciliation loop):

```
DESIRED STATE (what you declared in YAML)
           ↕ compare
ACTUAL STATE  (what's actually running)
           ↓
CONTROLLER takes action to close the gap
```

Example: you declare `replicas: 2`. Kubernetes keeps counting. If one pod crashes, the count becomes 1. The controller notices the gap, launches a new pod, count becomes 2. You never issued a restart command — you declared what you want and Kubernetes enforces it continuously.

### Control plane vs data plane

| Layer | What it is | Who manages it in LabLumen |
|---|---|---|
| **Control plane** | API server, scheduler, etcd (state store), controller manager | AWS (EKS) — fully managed |
| **Data plane** | Worker nodes (EC2 instances) that run pods | You — via managed node group + Karpenter |

You talk to Kubernetes by sending YAML manifests to the **API server** (`kubectl apply`). The API server stores them in **etcd** (a distributed key-value store). Controllers watch etcd for changes and act.

---

## 2. The Cluster at a Glance

```
Cluster name:        lablumen-eks
Kubernetes version:  1.31
Region:              us-east-1
Authentication mode: API  (EKS Access Entries — not the old aws-auth ConfigMap)
OIDC issuer:         https://oidc.eks.us-east-1.amazonaws.com/id/<hash>
Control-plane logs:  api, audit, authenticator, controllerManager, scheduler → CloudWatch (14-day)
```

**EKS Access Entries (modern auth):**
In old EKS, the only way to give an IAM role access to the cluster was editing a ConfigMap called `aws-auth`. This was fragile — one typo could lock everyone out. The new `authentication_mode = "API"` uses **EKS Access Entries**, which are first-class API objects. The `tf-apply` IAM role (GitHub Actions CI for Terraform) is granted `AmazonEKSClusterAdminPolicy` via a Terraform-created Access Entry — no manual ConfigMap editing.

**`enable_cluster_creator_admin_permissions = false`:** by default EKS automatically grants admin to whoever created the cluster. Disabling this forces explicit, auditable Access Entry grants — no hidden backdoors.

**Managed Node Group (always-on base capacity):**
```
Instance type: t3.medium (2 vCPU, 4 GB)  — org SCP blocks t3.large
Min: 1  |  Desired: 2  |  Max: 4
Spread across: us-east-1a + us-east-1b
Lives in:      private subnets (10.0.1.0/24 + 10.0.2.0/24)
```
The managed node group provides a **warm floor** of capacity so ArgoCD and platform addons have somewhere to start. Karpenter then handles all **burst scaling** beyond this floor.

---

## 3. Namespaces — Logical Isolation Inside One Cluster

A **namespace** is a virtual cluster inside the real cluster. Resource names are unique per-namespace (two deployments named `appointment-service` can coexist in `lablumen` and `lablumen-dev`). RBAC policies and resource quotas can be applied per-namespace.

| Namespace | Created by | What lives here |
|---|---|---|
| `argocd` | bootstrap script | ArgoCD control plane, Applications, AppProject |
| `kube-system` | EKS | AWS Load Balancer Controller, ExternalDNS, Karpenter, Metrics Server |
| `external-secrets` | Terraform (`kubernetes.tf`) | External Secrets Operator controller |
| `lablumen` | Terraform (`kubernetes.tf`) | PRODUCTION: all 4 app services + Redis |
| `lablumen-dev` | Terraform (`kubernetes.tf`) | DEV: all 4 app services + Redis |
| `monitoring` | ArgoCD (CreateNamespace=true) | Prometheus, Grafana, Alertmanager |

**Why Terraform creates `lablumen` and `lablumen-dev` (not ArgoCD)?**
The IRSA-annotated ServiceAccounts for report-service and notification-service must be created by Terraform because the IAM role ARNs are Terraform outputs. Terraform creates the namespace first so it can immediately create the ServiceAccounts into it. ArgoCD then deploys workloads into those pre-existing namespaces.

---

## 4. The Helm Chart System

### What is Helm?

**Helm** is the package manager for Kubernetes. A **chart** is a template library — YAML files with `{{ .Values.something }}` placeholders. You provide a `values.yaml` file and Helm renders the templates into actual Kubernetes manifests.

### LabLumen's chart architecture

Instead of each microservice having its own redundant Deployment/Service/HPA YAML, LabLumen has a single **shared chart** at `charts/microservice/` that all backend services and the frontend reuse. Each service only needs:
1. `values.yaml` — its identity (name, image repo, SSM keys it needs, ingress path)
2. `values-dev.yaml` — dev overrides (image SHA, 1 replica, dev hostname)
3. `values-prod.yaml` — prod overrides (image version, 2+ replicas, prod hostname, autoscaling on)

The three values files are **layered** by ArgoCD in order: chart defaults → `global-values.yaml` → `services/<name>/values.yaml` → `services/<name>/values-{env}.yaml`. Later files override earlier ones.

```
Layer 1: charts/microservice/values.yaml          ← chart-level defaults (replicaCount: 2, etc.)
Layer 2: global-values.yaml                        ← sets global.imageRegistry (the ECR host)
Layer 3: services/appointment-service/values.yaml  ← service identity (name, repo, SSM keys)
Layer 4: services/appointment-service/values-dev.yaml  ← image SHA, dev hostname, 1 replica
```

**`global-values.yaml`** — the single place where the AWS account-specific ECR registry URL lives:
```yaml
global:
  imageRegistry: "025392543842.dkr.ecr.us-east-1.amazonaws.com"
```
Every service image reference becomes `025392543842.dkr.ecr.us-east-1.amazonaws.com/lablumen/appointment-service:abc1234`. On a new AWS account you change **one line** and all services update.

**Redis chart** (`charts/redis/`) is a simpler custom chart just for the Redis ephemeral cache — no complex value layering needed.

---

## 5. Core Kubernetes Objects — What Each One Does

This section explains every object type used in the cluster from scratch.

### Deployment

A **Deployment** declares a desired state for a set of Pods. It manages a **ReplicaSet** (which manages the actual pods). You almost never interact with ReplicaSets directly.

```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0   # never bring a pod DOWN before a new one is UP
      maxSurge: 1         # can have one EXTRA pod during the rollout
```
`maxUnavailable: 0` guarantees zero-downtime deployments. The new pod must pass its readiness probe before the old one is terminated.

### Pod

The smallest deployable unit in Kubernetes. One or more containers that:
- Share a network namespace (same IP, can communicate via localhost)
- Share mounted volumes
- Are scheduled to the same node

Every pod in LabLumen runs a single container (one service per pod).

### Service (ClusterIP)

A stable internal DNS name and virtual IP for a set of pods. Without a Service, pod IPs change every time a pod restarts. With a Service, other pods always talk to the same name (e.g., `http://appointment-service:80`) regardless of which pods are behind it.

```yaml
spec:
  type: ClusterIP   # cluster-internal only, not reachable from outside
  selector:
    app.kubernetes.io/name: appointment-service   # selects pods with this label
  ports:
    - port: 80         # Service listens on port 80
      targetPort: http  # forwards to the named port 8000 on the pod
```

**In-cluster DNS:** Kubernetes provides a DNS server (CoreDNS). A Service named `appointment-service` in namespace `lablumen` is reachable at:
- `http://appointment-service` (within the same namespace)
- `http://appointment-service.lablumen.svc.cluster.local` (fully qualified, from any namespace)

**This is how nginx routes to backends:** The nginx config has `proxy_pass http://appointment-service;` — it resolves to the ClusterIP via CoreDNS, which load-balances across the 2 pod replicas.

### HorizontalPodAutoscaler (HPA)

The HPA watches the Metrics Server for CPU utilisation. If the average CPU across all replicas exceeds the threshold, it adds replicas. If it falls below, it removes them.

```yaml
spec:
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70   # scale up when avg CPU > 70%
```

**Important:** HPA requires the Metrics Server to be running. Without metrics-server, the HPA reports `<unknown>` and never scales. This is why `metrics-server` is deployed as a platform addon at wave 0.

### PodDisruptionBudget (PDB)

A PDB guarantees a minimum number of pods stay running during **voluntary disruptions** (node drain, node upgrade, Karpenter consolidation). It does NOT protect against node failures — those are involuntary.

```yaml
spec:
  maxUnavailable: 1   # at most 1 pod can be down at any time
  selector:
    matchLabels:
      app.kubernetes.io/name: appointment-service
```

When Karpenter wants to remove an underused node, it first **cordons** it (marks it unschedulable) and **drains** it (evicts all pods). The PDB prevents eviction if it would bring running pods below the minimum. Karpenter will wait or cancel the consolidation rather than violate the PDB.

The PDB only renders when `replicas >= 2`. With 1 replica (dev), a PDB would block all node maintenance — so it's gated off in dev.

### Ingress

An Ingress defines HTTP/HTTPS routing rules from outside the cluster to internal Services. An **IngressClass** (`alb`) tells Kubernetes which controller (the AWS Load Balancer Controller) will process this Ingress and create the actual AWS ALB.

```yaml
spec:
  ingressClassName: alb
  rules:
    - host: api.rnld101.xyz
      http:
        paths:
          - path: /api/v1/reports
            backend:
              service:
                name: report-service
                port:
                  number: 80
```

The ALB Controller reads these rules and configures the ALB accordingly.

### ServiceAccount

A ServiceAccount is a Kubernetes identity for a pod. When IRSA is configured, the ServiceAccount bridges a pod's Kubernetes identity to an AWS IAM role. Without a ServiceAccount annotation pointing to an IAM role, a pod cannot call AWS APIs (or can only use the node's instance profile, which is shared by all pods on that node).

### ExternalSecret (Custom Resource)

An **ExternalSecret** is a custom Kubernetes object introduced by the External Secrets Operator. It tells ESO: "fetch these keys from this AWS source and create a Kubernetes Secret with this name." The resulting Kubernetes Secret is consumed by pods via `envFrom.secretRef`.

```yaml
kind: ExternalSecret
spec:
  target:
    name: appointment-service-secrets   # ← creates this K8s Secret
  data:
    - secretKey: DATABASE_URL            # ← env var name in the pod
      remoteRef:
        key: lablumen/app/database-url   # ← Secrets Manager secret name
```

### ClusterSecretStore

A **ClusterSecretStore** configures HOW the External Secrets Operator connects to an AWS service. It is cluster-scoped (not namespace-scoped), so all namespaces can reference it. LabLumen has two:

```yaml
aws-secrets-manager   # connects to Secrets Manager for DATABASE_URL + grafana-admin
aws-parameter-store   # connects to SSM for Cognito IDs, SQS URL, S3 bucket names, etc.
```

Both authenticate via the `lablumen-eso` ServiceAccount (IRSA).

### TopologySpreadConstraints

Tells the scheduler to spread pods across **multiple failure domains** (AZs and nodes):

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone    # spread across AZs
    whenUnsatisfiable: ScheduleAnyway           # soft constraint — don't block scheduling
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname          # spread across nodes
    whenUnsatisfiable: ScheduleAnyway
```

`maxSkew: 1` means at most 1 pod difference between the most-loaded and least-loaded zone. With 2 replicas and 2 AZs, this places one pod per AZ. If one AZ goes down, one pod remains.

### NetworkPolicy

A **NetworkPolicy** restricts which pods can send/receive traffic. In LabLumen the chart supports optional NetworkPolicies (default: disabled). When enabled, the policy sets **default-deny ingress** for that workload and then explicitly allows traffic from the same namespace and from listed namespaces (e.g., `kube-system` for the ALB controller health checks). Egress is left open (pods need DNS, RDS, and AWS APIs).

---

## 6. Per-Service Breakdown — What Lives in the Cluster

### appointment-service

```
Namespaces:   lablumen (prod), lablumen-dev (dev)
Image:        025392543842.dkr.ecr.us-east-1.amazonaws.com/lablumen/appointment-service:<sha>
Replicas:     2 prod (HPA 2→6 at 70% CPU), 1 dev (HPA off)
K8s Objects:  Deployment, Service (ClusterIP:80→8000), HPA (prod), PDB (prod), Ingress, ExternalSecret, ServiceAccount
```

**Ingress:** path `/api/v1`, group order 100 (catch-all for all API traffic not matched by a more-specific rule)

**ServiceAccount:** `create: true`, plain SA with NO IRSA annotation. The appointment-service makes no direct AWS API calls in its hot path. It writes to RDS (via `DATABASE_URL` from the K8s Secret) and publishes to SQS — for SQS it relies on the node's ambient IAM role (a known improvement point: should have its own IRSA role scoped to `sqs:SendMessage`).

**Environment variables (all injected from the ESO-synced K8s Secret):**
```
DATABASE_URL             ← Secrets Manager lablumen/app/database-url
AWS_REGION               ← SSM /lablumen/config/region
COGNITO_USER_POOL_ID     ← SSM /lablumen/config/cognito-user-pool-id
COGNITO_APP_CLIENT_ID    ← SSM /lablumen/config/cognito-app-client-id
NOTIFICATIONS_QUEUE_URL  ← SSM /lablumen/config/sqs-url
REDIS_URL                ← plain extraEnv: redis://redis:6379/0  (in-cluster DNS name)
```

Note: `REDIS_URL` is a plain env var (not a secret) pointing to `redis://redis:6379/0`. The name `redis` resolves via CoreDNS to the Redis ClusterIP Service.

---

### report-service

```
Namespaces:   lablumen (prod), lablumen-dev (dev)
Image:        .../lablumen/report-service:<sha>
Replicas:     2 prod (HPA 2→6 at 70% CPU), 1 dev (HPA off)
K8s Objects:  Deployment, Service, HPA (prod), PDB (prod), Ingress, ExternalSecret, ServiceAccount (pre-created by Terraform with IRSA)
```

**Ingress:** path `/api/v1/reports`, group order 10. **This is evaluated BEFORE appointment-service's `/api/v1` rule** (lower group order = higher priority). Without this ordering, `/api/v1/reports/upload` would match the appointment-service's `/api/v1` catch-all first and return a 404.

**IRSA:** The Terraform-created `report-service` ServiceAccount in both `lablumen` and `lablumen-dev` has:
```yaml
annotations:
  eks.amazonaws.com/role-arn: arn:aws:iam::025392543842:role/lablumen-report-service
```
This role allows: `s3:GetObject`, `s3:PutObject` on the reports bucket + `bedrock:InvokeModel`.

**Environment variables from the ESO-synced K8s Secret:**
```
DATABASE_URL               ← Secrets Manager
AWS_REGION                 ← SSM
COGNITO_USER_POOL_ID       ← SSM
COGNITO_APP_CLIENT_ID      ← SSM
REPORTS_S3_BUCKET          ← SSM /lablumen/config/reports-bucket
BEDROCK_EMBED_MODEL_ID     ← SSM /lablumen/config/bedrock-embed-model
BEDROCK_TEXT_MODEL_ID      ← SSM /lablumen/config/bedrock-text-model
PRESIGNED_URL_TTL_SECONDS  ← SSM /lablumen/config/presigned-url-ttl
```

---

### notification-service

```
Namespaces:   lablumen (prod), lablumen-dev (dev)
Image:        .../lablumen/notification-service:<sha>
Replicas:     2 prod (HPA OFF — SQS worker, replica count is the scaling lever), 1 dev
K8s Objects:  Deployment, Service, PDB (prod), ExternalSecret, ServiceAccount (pre-created by Terraform with IRSA)
NO Ingress:   This service receives SQS messages, not HTTP requests
```

**Why HPA is off for the notification-service:** HPA scales on CPU. The notification-service has near-zero CPU usage between SQS polls — it sleeps most of the time. CPU-based autoscaling would never trigger even when a queue backlog of 10,000 messages exists. The correct scaling mechanism for a queue consumer is to watch the SQS `ApproximateNumberOfMessages` metric (KEDA could do this, but wasn't added). At 2 replicas, both pods compete to consume messages — that doubles throughput. More replicas = faster drain.

**IRSA role allows:** `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes`, `ses:SendEmail`, `ses:SendRawEmail`.

**Environment variables:**
```
AWS_REGION              ← SSM
NOTIFICATIONS_QUEUE_URL ← SSM
SES_SENDER_EMAIL        ← SSM /lablumen/config/ses-sender
```
Note: no DATABASE_URL. The notification-service never touches the database.

---

### frontend (nginx)

```
Namespaces:   lablumen (prod), lablumen-dev (dev)
Image:        .../lablumen/frontend:<sha>  (nginx serving the Vite-built React SPA)
Replicas:     2 prod (HPA off), 1 dev
K8s Objects:  Deployment, Service, PDB (prod), Ingress, ExternalSecret, ServiceAccount (plain, no IRSA)
```

**What nginx does:**
1. Serves static files (HTML, JS, CSS) from `/usr/share/nginx/html` for the React SPA
2. Reverse-proxies `/api/v1/reports/` → `http://report-service:80`
3. Reverse-proxies `/api/v1/` → `http://appointment-service:80`
4. Returns `index.html` for any other path (React Router handles client-side routing)

The nginx container is the only entry point for traffic. External clients never call the backend pods directly — they always go through: `internet → ALB → nginx pod → backend service`.

**Why nginx is an API gateway here:** This keeps the ALB's routing rules simple (all traffic goes to one target group — the frontend). The path routing happens inside nginx at zero cost. Without this, each service would need its own target group and the ALB rule count would multiply.

**Cognito config via ESO (used to hardcode Vite env vars at runtime):**
```
VITE_COGNITO_USER_POOL_ID    ← SSM /lablumen/config/cognito-user-pool-id
VITE_COGNITO_APP_CLIENT_ID   ← SSM /lablumen/config/cognito-app-client-id
```
These `VITE_*` variables are injected into the nginx container environment. The Vite build uses `import.meta.env.VITE_*` to embed them into the JS bundle at build time — but here the pattern works by rebuilding the bundle during CI with these values.

**Extra volumes for read-only rootfs:**
The container runs with `readOnlyRootFilesystem: true` (a security hardening measure). nginx needs to write temp files:
```yaml
extraVolumeMounts:
  - name: nginx-cache  → /var/cache/nginx   (writable emptyDir)
  - name: nginx-run    → /var/run            (nginx PID file)
```
Without these, nginx would crash on startup because it cannot write to the read-only filesystem.

---

### Redis

```
Namespaces:   lablumen (prod), lablumen-dev (dev)
Image:        redis:7-alpine  (pulled from Docker Hub, not ECR)
Replicas:     1 (single, Recreate strategy)
K8s Objects:  Deployment, Service (ClusterIP:6379)
No Ingress:   Internal-only
No PDB:       Single replica, PDB would block all maintenance
```

**Completely ephemeral:** Redis is configured with `--save ""` (no RDB snapshots) and `--appendonly no` (no AOF persistence). If the Redis pod restarts, all slot locks are lost. This is intentional — a lock loss means the next booking attempt will succeed (the double-booking window is seconds, not permanent data loss). This is appropriate for a distributed lock that exists only to prevent racing HTTP requests.

**`Recreate` strategy:** Rolling updates for single-replica stateful services can cause split-brain (two Redis instances briefly). Recreate stops the old pod completely before starting the new one. The 1–5 second downtime is acceptable for a lock service (any in-flight booking during this window retries once the new Redis is ready).

**Connected to via:** `redis://redis:6379/0` — CoreDNS resolves `redis` to the Redis Service ClusterIP within the same namespace.

---

## 7. Platform Addons — The Controllers That Make Everything Work

Platform addons are not application services — they are **Kubernetes controllers** that extend what the cluster can do. They run in `kube-system` or dedicated namespaces and watch for custom resources or standard resources.

All platform addons are deployed by ArgoCD as Helm releases. Each is an ArgoCD `Application` pointing to a Helm chart in an external chart repository (not in the `lablumen-k8s` Git repo).

| Addon | Namespace | Wave | What it does |
|---|---|---|---|
| **karpenter-crd** | kube-system | -1 | Installs Karpenter CRDs (NodePool, EC2NodeClass) before the controller starts |
| **ArgoCD** | argocd | 0 | GitOps — watches Git, syncs Kubernetes state |
| **AWS Load Balancer Controller** | kube-system | 0 | Reads Ingress objects, creates/configures AWS ALBs |
| **ExternalDNS** | kube-system | 0 | Reads Ingress hosts, creates Route 53 A records |
| **External Secrets Operator** | external-secrets | 0 | Reads ExternalSecret CRs, fetches from AWS, creates K8s Secrets |
| **Karpenter** | kube-system | 0 | Dynamic node provisioning/deprovisioning |
| **Metrics Server** | kube-system | 0 | Collects CPU/memory metrics from nodes, feeds HPA |
| **Karpenter NodePool + EC2NodeClass** | kube-system | 1 | Configuration for Karpenter (what it can provision) |
| **ClusterSecretStores** | external-secrets | 1 | Configure ESO's AWS connections |
| **Grafana Admin Secret** | monitoring | 1 | ESO syncs the Grafana password before Grafana starts |
| **monitoring (kube-prometheus-stack)** | monitoring | 2 | Prometheus + Grafana + Alertmanager |
| **App services (dev + prod)** | lablumen + lablumen-dev | 2 | All 5 services via ApplicationSets |

### Why sync waves matter

ArgoCD syncs everything concurrently by default. Waves impose ordering. Without waves:
- The Karpenter controller (wave 0) would try to register its NodePool CRD handler but the CRD doesn't exist yet (wave -1 hasn't run)
- ExternalSecrets (wave 2) would try to use the ClusterSecretStore (wave 1) that doesn't exist yet

Wave ordering is: wave -1 → wave 0 → wave 1 → wave 2. Within a wave, resources sync concurrently.

### AWS Load Balancer Controller (LBC)

The LBC runs in `kube-system` and watches Kubernetes Ingress objects with `ingressClassName: alb`. When it sees one, it:
1. Calls the AWS EC2 and ELBv2 APIs to create/configure an ALB
2. Creates listeners, target groups, path-routing rules
3. Registers pod IPs as targets (target-type: ip)
4. Updates the Ingress object's `status.loadBalancer.ingress[0].hostname` with the ALB DNS name

ExternalDNS then reads that ALB DNS name and creates the Route 53 record.

The LBC's IAM permissions (via IRSA) include a large policy for managing ALBs, target groups, listeners, certificates, and WAF associations.

### ExternalDNS

ExternalDNS watches Ingress objects for host names. When it sees `host: api.rnld101.xyz`, it creates (or updates) a Route 53 A record:
```
api.rnld101.xyz → ALIAS → <alb-dns-name>.us-east-1.elb.amazonaws.com
```

Configuration:
- `policy: upsert-only` — never deletes DNS records. Safe: a misconfigured ExternalDNS cannot wipe your DNS zone.
- `registry: txt` — writes a TXT ownership record alongside each A record
- `txtOwnerId: lablumen-eks` — identifies which cluster owns each record (important if multiple clusters share a zone)
- `domainFilters: [rnld101.xyz]` — ExternalDNS only touches records in this domain, ignoring all others

### Metrics Server

The Metrics Server collects resource usage metrics (CPU and memory) from the kubelet on each node every 15 seconds and exposes them via the Kubernetes Metrics API. The HPA controller queries this API to make scaling decisions.

Without the Metrics Server, `kubectl top pods` returns an error and every HPA in the cluster shows `<unknown>/70%` for CPU — meaning they never scale.

EKS does **not** ship the Metrics Server by default (unlike GKE). This is why it is explicitly deployed as a platform addon.

### kube-prometheus-stack

The monitoring stack deploys multiple components in one Helm release:
- **Prometheus** — scrapes metrics from pods, nodes, and Kubernetes API. 2-day ephemeral retention (no PVC — if Prometheus pod restarts, metrics history resets).
- **Grafana** — dashboards, exposed at `grafana.rnld101.xyz` via the shared ALB. Admin credentials come from the ESO-synced `grafana-admin` Kubernetes Secret.
- **Alertmanager** — routes alerts from Prometheus to destinations (not configured for external destinations in dev, but the component runs).
- **kube-state-metrics** — exports Kubernetes object state as metrics (replica counts, pod status, deployment rollout progress)
- **node-exporter** — a DaemonSet that exports hardware/OS metrics from every node (CPU, disk, network)
- **prometheus-operator** — watches `ServiceMonitor` CRDs and auto-configures Prometheus scrape targets

---

## 8. ArgoCD — GitOps & the App-of-Apps Pattern

### What is GitOps?

GitOps means **Git is the single source of truth** for the cluster state. No human ever runs `kubectl apply` in production. Instead:
1. A developer pushes to Git
2. ArgoCD detects the change
3. ArgoCD applies the change to the cluster
4. If someone manually changes something in the cluster (drift), ArgoCD reverts it

Benefits: every deployment is peer-reviewed (Git PR), every change is auditable (Git history), rollback is `git revert`.

### App-of-Apps Pattern

A single ArgoCD **Application** is bootstrapped manually. This "root app" watches the Git repo and deploys **all other Applications and ApplicationSets**. Those then deploy everything else.

```
One kubectl apply: bootstrap/root-app.yaml
         ↓
  lablumen-root  (ArgoCD Application, watches the whole lablumen-k8s repo)
         ↓
  Syncs these paths:
    argocd/projects/lablumen.yaml          → AppProject (wave -1)
    argocd/apps/karpenter-nodepool.yaml    → Application (wave 1)
    argocd/apps/platform-config.yaml       → Application (wave 1)
    argocd/apps/monitoring-secret.yaml     → Application (wave 1)
    platform/addons/*.yaml                 → 8 Applications (wave 0)
    argocd/applicationsets/services-dev.yaml   → ApplicationSet (wave 2)
    argocd/applicationsets/services-prod.yaml  → ApplicationSet (wave 2)
```

### AppProject (lablumen)

An **AppProject** is ArgoCD's guardrail. It restricts:
- **Which Git repos** can be used as sources (`sourceRepos` list)
- **Which Kubernetes servers and namespaces** can be targeted (`destinations` list)
- **Which cluster-scoped resource types** can be managed (`clusterResourceWhitelist`)

The `lablumen` project allows:
- Source repos: the lablumen-k8s GitHub repo + the Helm chart repositories for each addon
- Destinations: 7 specific namespaces on the in-cluster server only (no external clusters)
- Cluster-scoped resources: Namespaces, CRDs, ClusterRoles, ClusterRoleBindings, and the addon-specific CRs (Karpenter, ESO, LBC)

The root app itself stays in the `default` project (ArgoCD's built-in project) because it manages ArgoCD's own objects in the `argocd` namespace — those would create a circular dependency if they were in the `lablumen` project.

### ApplicationSet

An **ApplicationSet** is an ArgoCD generator — it creates multiple Applications from a template. LabLumen uses the `list` generator:

```yaml
generators:
  - list:
      elements:
        - { name: appointment-service, chart: charts/microservice }
        - { name: report-service,      chart: charts/microservice }
        - { name: notification-service, chart: charts/microservice }
        - { name: redis,               chart: charts/redis }
        - { name: frontend,            chart: charts/microservice }
```

This creates 5 Applications for dev and 5 for prod — **10 ArgoCD Applications from two YAML files**. Adding a new service is adding one line to the list.

### Multi-source Applications

Each ArgoCD Application in the ApplicationSets uses **multi-source** — it pulls from two sources and merges them:
```yaml
sources:
  - repoURL: https://github.com/lablumen/lablumen-k8s.git
    ref: values                             # source #1: just a ref, no chart path
  - repoURL: https://github.com/lablumen/lablumen-k8s.git
    path: charts/microservice               # source #2: the Helm chart templates
    helm:
      valueFiles:
        - $values/global-values.yaml        # uses $values ref from source #1
        - $values/services/appointment-service/values.yaml
        - $values/services/appointment-service/values-dev.yaml
```

`$values` is a reference to source #1. This allows the chart templates to live in one path and the value files in another path — both from the same repo.

### Sync Policies

Every Application has:
```yaml
syncPolicy:
  automated:
    prune: true       # delete K8s resources that are removed from Git
    selfHeal: true    # revert any manual kubectl changes that drift from Git
```

Exception: ArgoCD's own Application (`platform/addons/argocd.yaml`) has `prune: false` — you never want ArgoCD to delete its own resources during self-management.

`syncOptions: CreateNamespace=true` tells ArgoCD to create the target namespace if it doesn't exist. This is used for the `monitoring` namespace (created by the monitoring stack application, not by Terraform).

---

## 9. Karpenter — Dynamic Node Provisioning

### The problem Karpenter solves

The Cluster Autoscaler (the traditional approach) scales **Auto Scaling Groups**. When a pod is pending, CA adds a new node to the ASG. Problems:
- Takes 3–5 minutes (ASG events are slow)
- Can only provision the one instance type configured in the ASG
- Very conservative about scale-down

Karpenter bypasses ASGs and **calls the EC2 API directly** to provision exactly the right instance for the pending pod.

### EC2NodeClass — the template for nodes

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
spec:
  role: "KarpenterNodeRole-lablumen-eks"       # instance profile (IAM role for the node)
  amiSelectorTerms:
    - alias: al2023@latest                      # Amazon Linux 2023, auto-matched to K8s 1.31
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: lablumen-eks    # discover private subnets by Terraform tag
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: lablumen-eks    # discover node SG by Terraform tag
```

Karpenter **discovers** subnets and security groups via AWS resource tags set by Terraform. This means the EC2NodeClass file NEVER needs to be edited after a Terraform re-apply — even if subnet IDs change, the tags remain the same.

### NodePool — the rules for what Karpenter can do

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
spec:
  template:
    spec:
      requirements:
        - key: karpenter.sh/capacity-type
          values: ["on-demand"]          # no Spot (reliability)
        - key: node.kubernetes.io/instance-type
          values: ["t3.medium", "t3.large"]  # only these types
  limits:
    cpu: "20"                            # safety cap: max 20 vCPUs total across all nodes
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m                 # remove underused nodes after 1 minute idle
```

**Safety cap `cpu: "20"`:** Without a limit, a burst of traffic + a bug in HPA could cause Karpenter to provision 50 nodes. The 20 vCPU cap means at most 10 t3.medium nodes (each 2 vCPU) — a predictable cost ceiling.

**Consolidation:** When pods are removed (deployment scaled down, HPA scaled down), Karpenter identifies nodes that are underutilised. It moves the remaining pods to other nodes (bin-packing), then terminates the empty node. This happens 1 minute after the node becomes underutilised.

### Karpenter interruption queue

Terraform creates an SQS queue named `Karpenter-lablumen-eks`. AWS sends **Spot interruption notices** and EC2 health events to this queue. Karpenter watches the queue and gracefully drains affected nodes before AWS terminates them. Since LabLumen uses on-demand nodes, this mainly handles EC2 instance retirement notices (AWS proactively retiring old hardware) — still useful for graceful drain.

---

## 10. External Secrets Operator — AWS Secrets → K8s Secrets

### The problem ESO solves

If you put secrets directly in Kubernetes Secrets (which are base64-encoded, not encrypted by default), they appear in Git if you commit the YAML file. External Secrets Operator decouples secret storage from Kubernetes — secrets stay in AWS, ESO fetches them and creates the Kubernetes Secret objects just-in-time.

### How it works in LabLumen — full chain

```
[1] Terraform creates the IRSA-annotated ServiceAccount `lablumen-eso` in the `external-secrets` namespace
    Annotation: eks.amazonaws.com/role-arn = arn:aws:iam::...:role/lablumen-eso

[2] ArgoCD deploys the ESO Helm chart (wave 0)
    Chart referencing the pre-existing SA (serviceAccount.create: false)

[3] ArgoCD deploys ClusterSecretStores (wave 1)
    Two ClusterSecretStores created in the `external-secrets` namespace:
      - aws-secrets-manager  (connects to Secrets Manager)
      - aws-parameter-store  (connects to SSM Parameter Store)
    Both authenticate using the lablumen-eso ServiceAccount's IRSA credentials

[4] ArgoCD deploys the microservice ApplicationSets (wave 2)
    Each service's Helm chart renders an ExternalSecret object

[5] ESO controller watches for ExternalSecret objects
    On each service's ExternalSecret:
      - Reads the `data` section (Secrets Manager sources)
      - Reads the `ssmData` section (SSM Parameter Store sources)
      - Authenticates to AWS using the lablumen-eso IRSA role
      - Fetches each value from AWS
      - Creates one Kubernetes Secret with all fetched values
      - Refreshes every 1 hour

[6] Pod is started with `envFrom.secretRef: <secret-name>`
    Kubernetes injects all key-value pairs from the Secret as environment variables
    Pod sees DATABASE_URL, COGNITO_USER_POOL_ID, etc. as plain env vars
    Pod has no AWS SDK dependency for secret access
```

### The dual-store pattern

The microservice chart's ExternalSecret template fetches from **two different stores in a single ExternalSecret object**:

```yaml
# From Secrets Manager (default store):
data:
  - secretKey: DATABASE_URL
    remoteRef:
      key: lablumen/app/database-url

# From SSM Parameter Store (overriding the store per-entry via sourceRef):
ssmData:
  - secretKey: COGNITO_USER_POOL_ID
    remoteRef:
      key: /lablumen/config/cognito-user-pool-id
    sourceRef:
      storeRef:
        name: aws-parameter-store
```

The result is one Kubernetes Secret per service containing ALL its environment variables — one `envFrom.secretRef` in the pod spec loads everything.

### Grafana admin secret

The monitoring stack's Grafana chart requires an existing Kubernetes Secret named `grafana-admin`. ESO creates this in the `monitoring` namespace from Secrets Manager secret `lablumen/app/grafana-admin`. The `monitoring-secret` ArgoCD Application runs at wave 1 (before the monitoring stack at wave 2) to ensure this Secret exists when Grafana starts.

---

## 11. IRSA — How Pods Talk to AWS

IRSA (IAM Roles for Service Accounts) is the most important pattern in the cluster for understanding cluster-to-AWS communication. It solves the fundamental problem: **how does a container running inside Kubernetes authenticate to AWS?**

### The old way (broken)

Without IRSA, the only AWS credentials available inside a pod are the EC2 instance's IAM role (accessible via the IMDS endpoint `169.254.169.254`). This means:
- Every pod on the same node shares the same AWS permissions
- If one pod is compromised, the attacker has all the permissions of every other pod on that node
- You cannot scope permissions to individual services

### How IRSA works

```
[1] EKS creates an OIDC Provider for the cluster:
    URL: https://oidc.eks.us-east-1.amazonaws.com/id/<hash>
    This makes the cluster a trusted identity provider in AWS

[2] Terraform creates an IAM role with a trust policy that allows:
    "System:serviceaccount:lablumen:report-service to assume this role"
    ...via AssumeRoleWithWebIdentity from the cluster's OIDC provider

[3] Terraform annotates the ServiceAccount in Kubernetes:
    kubernetes_service_account "report-service" {
      metadata {
        annotations = {
          "eks.amazonaws.com/role-arn" = "arn:aws:iam::...:role/lablumen-report-service"
        }
      }
    }

[4] Pod starts using the report-service ServiceAccount:
    EKS node injects a projected ServiceAccount token into the pod's filesystem:
    /var/run/secrets/eks.amazonaws.com/serviceaccount/token
    This is a time-limited JWT (expiry ~24h, auto-rotated) signed by the OIDC provider

[5] AWS SDK in the pod (boto3) picks up this token automatically:
    It calls sts:AssumeRoleWithWebIdentity presenting the JWT
    STS verifies the JWT signature against the cluster's OIDC public keys
    STS checks: does the JWT's sub (system:serviceaccount:lablumen:report-service) match the trust policy?
    If yes → returns temporary AWS credentials (access key + secret + token, valid 1h)

[6] Pod uses those temporary credentials for all AWS API calls (S3, Bedrock)
    SDK auto-refreshes credentials before they expire
```

### IRSA roles in LabLumen — who can assume what

| ServiceAccount | Namespace | IAM Role | AWS Permissions |
|---|---|---|---|
| `lablumen-eso` | external-secrets | lablumen-eso | SM GetSecretValue, SSM GetParameter, KMS Decrypt |
| `karpenter` | kube-system | karpenter controller role | EC2 launch/terminate, SQS interruption queue |
| `aws-load-balancer-controller` | kube-system | lablumen-lbc | Full LBC policy (ALB/TG/listener management) |
| `external-dns` | kube-system | lablumen-external-dns | Route53 ChangeResourceRecordSets in the hosted zone |
| `report-service` | lablumen + lablumen-dev | lablumen-report-service | S3 GetObject+PutObject, Bedrock InvokeModel |
| `notification-service` | lablumen + lablumen-dev | lablumen-notification-service | SQS Receive+Delete, SES SendEmail |

**`automountServiceAccountToken: false`** on every Deployment prevents the default K8s service account token (which grants API server access) from being automatically mounted. Only pods that need it (IRSA pods — where the token is projected separately) need it, and the IRSA token is a different projected volume from the default SA token.

---

## 12. Network Flow — Internet to Pod

### Path 1: Patient visits the frontend (app.rnld101.xyz)

```
1. Browser DNS: app.rnld101.xyz
   → Route 53 looks up the record
   → Returns the ALB DNS name (created by ExternalDNS from the Ingress)

2. Browser TLS: connects to ALB on port 443
   → ALB terminates TLS using the ACM wildcard cert (*.rnld101.xyz)
   → ACM cert was created manually, looked up by Terraform data block

3. ALB routing: evaluates IngressGroup rules (group.name: lablumen)
   All Ingresses sharing group.name=lablumen merge into ONE ALB.
   Rules are evaluated by group.order (ascending = higher priority):
     group.order 10  → /api/v1/reports/* → report-service target group
     group.order 100 → /api/v1/*         → appointment-service target group
     group.order 100 → /*                → frontend target group (path /)
     group.order 200 → argocd.rnld101.xyz/* → ArgoCD target group
     group.order 210 → grafana.rnld101.xyz/* → Grafana target group
   app.rnld101.xyz / matches → frontend target group

4. ALB forwards to a frontend pod IP (target-type: ip)
   Pods are registered directly by IP (no NodePort)
   ALB picks one frontend pod replica via round-robin

5. nginx in the frontend pod receives the HTTP request (port 80, unencrypted)
   nginx checks the path:
   → / and non-API paths → serves index.html from /usr/share/nginx/html
   → /api/v1/reports/ → proxy_pass http://report-service:80
   → /api/v1/ → proxy_pass http://appointment-service:80

6. For API requests: nginx forwards to the ClusterIP Service
   → CoreDNS resolves the service name to its ClusterIP
   → kube-proxy (iptables) routes the ClusterIP to one of the service's pod IPs
   → Request arrives at the backend pod
```

### Path 2: Staff API call (api.rnld101.xyz/api/v1/reports/upload)

```
Browser → ALB → ALB evaluates rules for host api.rnld101.xyz
  The ALB sees /api/v1/reports/ → group.order 10 → report-service target group directly
  (This service has its own Ingress on the api.rnld101.xyz host with path /api/v1/reports)
ALB forwards directly to report-service pod IP (bypasses nginx entirely)
```

Wait — both nginx AND report-service have Ingress objects? Yes. The frontend's Ingress covers `app.rnld101.xyz` and routes everything to nginx. The backend services have separate Ingress objects on `api.rnld101.xyz` and route directly to their own pods. The ingress groups just share the same ALB.

---

## 13. Pod-to-Pod & Pod-to-AWS Communication Map

### How pods communicate with each other (all in-cluster)

```
appointment-service → Redis
  Via: redis://redis:6379/0
  How: CoreDNS resolves `redis` to the Redis ClusterIP Service
  Purpose: distributed slot locking (SET NX EX)

nginx (frontend) → appointment-service
  Via: http://appointment-service:80 (HTTP, not HTTPS)
  How: nginx proxy_pass using CoreDNS resolution
  Purpose: routes /api/v1/* requests from browser

nginx (frontend) → report-service
  Via: http://report-service:80
  Purpose: routes /api/v1/reports/* requests from browser
```

### How pods communicate with AWS services

```
report-service ──IRSA──► S3 (via VPC Gateway Endpoint)
  Action: PutObject (upload) + GetObject (read for presigned URL)
  Path: private subnet → S3 gateway endpoint → S3 (never leaves AWS network)

report-service ──IRSA──► Bedrock (via VPC Interface Endpoint)
  Action: InvokeModel (Titan Embed + Nova Lite Converse)
  Path: private subnet → bedrock-runtime VPC endpoint → Bedrock
  Note: IRSA gives the pod credentials for the SAME account's Bedrock
        (if Bedrock access is cross-account, the service uses STS AssumeRole too)

notification-service ──IRSA──► SQS (via VPC Interface Endpoint)
  Action: ReceiveMessage (long-poll every 20s) + DeleteMessage (after send)
  Path: private subnet → SQS VPC endpoint → SQS

notification-service ──IRSA──► SES
  Action: SendEmail
  Path: private subnet → NAT Gateway (SES has no VPC endpoint) → internet → SES API

appointment-service ──node IAM──► SQS (via VPC Interface Endpoint)
  Action: SendMessage (fire-and-forget notifications)
  Note: uses node's instance profile role, not IRSA (known improvement point)

All services ──ESO IRSA──► Secrets Manager / SSM (on pod startup via ESO)
  ESO fetches the secrets and creates K8s Secrets
  Pods never call Secrets Manager directly (except the Lambda)

All services → RDS PostgreSQL
  Via: DATABASE_URL env var (injected by ESO from Secrets Manager)
  Connection: asyncpg async driver inside the VPC private subnet → database subnet
  No VPC endpoint for RDS (it's inside the VPC; endpoints are only needed for AWS API calls)
```

### Visual communication matrix

```
                    ┌──────────────────────────────────────────────────────────┐
                    │                    CLUSTER (EKS)                         │
                    │                                                          │
  Internet          │  kube-system namespace                                   │
     │              │    ┌─────────┐  ┌───────────┐  ┌────────┐               │
     ▼              │    │   LBC   │  │  ExtDNS   │  │Karpent │               │
  Route 53 ────────►│    └────┬────┘  └─────┬─────┘  └───┬────┘               │
  (DNS lookup)      │         │              │             │                   │
     │              │         ▼              ▼             ▼                   │
  ALB (443/TLS) ───►│    ALB (AWS)    Route53 A-rec  EC2 launch/term          │
     │              │         │                                                │
     ▼              │         ▼                                                │
  ┌──────┐          │  lablumen namespace                                      │
  │nginx │─────────►│    ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
  │(SPA) │ ClusterIP│    │ appointment  │  │   report     │  │notification  │ │
  └──────┘  Service │    │  -service    │  │  -service    │  │  -service    │ │
            ─────── │    └──────┬───────┘  └──────┬───────┘  └──────┬───────┘ │
                    │           │                  │                  │         │
                    │           │ ┌──────┐         │                 │         │
                    │           └►│Redis │         │                 │         │
                    │             └──────┘         │                 │         │
                    └─────────────────────┬────────┼─────────────────┼─────────┘
                                          │        │                 │
                                          ▼        ▼                 ▼
                                        RDS      S3 + Bedrock    SQS + SES
                                      (pgvec)   (IRSA: report)  (IRSA: notif)
```

---

## 14. Security Hardening Inside Pods

Every pod in the cluster runs with a strict security context defined in the shared Helm chart. This makes the containers as restricted as possible.

### Pod Security Context

```yaml
podSecurityContext:
  runAsNonRoot: true          # container CANNOT run as root (UID 0)
  runAsUser: 10001            # runs as UID 10001 (no OS privileges)
  fsGroup: 10001              # volumes are owned by this GID
  seccompProfile:
    type: RuntimeDefault       # enables the default seccomp profile (blocks dangerous syscalls)
```

`seccompProfile: RuntimeDefault` applies a whitelist of allowed Linux system calls. Calls used for container escapes (like `ptrace`, `unshare`) are blocked.

### Container Security Context

```yaml
containerSecurityContext:
  allowPrivilegeEscalation: false  # setuid binaries cannot escalate to root
  readOnlyRootFilesystem: true     # cannot write to the container filesystem
  capabilities:
    drop:
      - ALL                        # drops all Linux capabilities (NET_ADMIN, SYS_PTRACE, etc.)
```

`readOnlyRootFilesystem: true` is the strongest of these. Even if an attacker compromises the process, they cannot write a web shell to disk. The writable `/tmp` directory (an `emptyDir` volume) is explicitly mounted for legitimate temp file needs (e.g., Uvicorn's tmp sockets, file upload staging).

### `automountServiceAccountToken: false`

By default, Kubernetes mounts the service account token into every pod. This token grants API server access — not needed by application code. Disabling auto-mount removes one attack surface. The IRSA projected volume (a separate mechanism) is NOT affected by this setting.

### Why these hardening measures matter

If an attacker exploits a dependency vulnerability in a FastAPI pod:
- They run as UID 10001 — no `sudo`, no `su`, no root
- They cannot write files to disk — no persistence
- They cannot use privilege escalation — no setuid exploits
- Blocked syscalls prevent container escape attempts
- The pod's IRSA role limits AWS blast radius to exactly what that service needs

---

## 15. Dev vs Prod — How the Two Environments Differ

The same Helm chart, same Kubernetes cluster, but two namespaces with different configuration:

| Aspect | Dev (`lablumen-dev`) | Prod (`lablumen`) |
|---|---|---|
| **Image tag** | Git SHA (auto-updated by CI every push) e.g., `b80b335` | Semantic version set by human e.g., `v1.0.0` |
| **Replicas** | 1 (to save node capacity) | 2 (minimum for availability) |
| **HPA** | Disabled | Enabled (2→6 at 70% CPU) |
| **PDB** | Disabled (1 replica, PDB would block everything) | Enabled (maxUnavailable: 1) |
| **Ingress host** | `api-dev.rnld101.xyz`, `app-dev.rnld101.xyz` | `api.rnld101.xyz`, `app.rnld101.xyz` |
| **Image update** | Automatic (CI writes SHA to values-dev.yaml) | Manual (human promotes a tested version to values-prod.yaml) |
| **IRSA ServiceAccounts** | Pre-created by Terraform in `lablumen-dev` namespace (same IRSA roles trust both namespaces) | Pre-created by Terraform in `lablumen` namespace |
| **Notification-service SA** | `serviceAccount.create: false` (Terraform created it) | `serviceAccount.create: false` |
| **Appointment-service SA** | `serviceAccount.create: true` (chart creates a plain SA, no IRSA) | `serviceAccount.create: true` |

**Shared infrastructure:** Both environments connect to the SAME RDS database, the SAME SQS queue, and the SAME Secrets Manager secrets. In a true production system, dev would have its own database. For this platform, a schema-prefixing or database-level isolation approach would be needed if dev and prod data must be fully separated.

**Promotion flow (dev → prod):**
```
Push to main branch
    → GitHub Actions: build → Trivy → push to ECR → write SHA to values-dev.yaml
    → ArgoCD detects values-dev.yaml change → rolls out to lablumen-dev
    → QA/manual testing on api-dev.rnld101.xyz
    → Human creates a GitHub Release (v1.0.1)
    → GitHub Actions: build → push with semver tag → write "v1.0.1" to values-prod.yaml
    → ArgoCD detects values-prod.yaml change → rolls out to lablumen
```

---

## 16. The Bootstrap Sequence — From Zero to Running Cluster

This is the exact sequence of steps to go from a fresh AWS account to a fully running LabLumen platform.

```
STEP 1 — Bootstrap Terraform state
  cd lablumen-terraform/bootstrap && terraform apply
  Creates: S3 state bucket + versioning

STEP 2 — Apply main Terraform stack
  cd lablumen-terraform && terraform apply
  Creates: VPC, EKS cluster, RDS, S3, KMS, ECR, Cognito, SQS, SES, Secrets Manager shells,
           SSM parameters, IAM roles, Kubernetes namespaces, IRSA-annotated ServiceAccounts

STEP 3 — Populate secrets (manual, one-time)
  aws secretsmanager put-secret-value \
    --secret-id lablumen/app/database-url \
    --secret-string "postgresql+asyncpg://lablumen:<RDS-password>@<RDS-endpoint>:5432/lablumen"
  (RDS password is in the RDS-managed secret ARN from terraform output)

  aws secretsmanager put-secret-value \
    --secret-id lablumen/app/grafana-admin \
    --secret-string '{"admin-user":"admin","admin-password":"<strong-password>"}'

STEP 4 — Push first images to ECR (triggers from the service repos)
  Each service repo: push to main → GitHub Actions → build → ECR
  CI writes SHA to lablumen-k8s/services/<name>/values-dev.yaml

STEP 5 — Bootstrap ArgoCD
  scripts/bootstrap-argocd.sh
  Does:
    aws eks update-kubeconfig (get kubeconfig for the cluster)
    helm install argocd argo/argo-cd (initial ArgoCD install, version 7.6.0)
    kubectl apply -f bootstrap/root-app.yaml (App-of-Apps root)

STEP 6 — ArgoCD takes over (automated from here)
  Wave -1: lablumen AppProject + karpenter-crd (CRDs)
  Wave 0:  ArgoCD self (via argocd.yaml), LBC, ExternalDNS, ESO, Karpenter, Metrics Server
  Wave 1:  Karpenter NodePool + EC2NodeClass, ClusterSecretStores, Grafana admin secret
  Wave 2:  monitoring stack, all services-dev + services-prod ApplicationSets
           → 10 ArgoCD Applications spawned (5 dev + 5 prod services)
           → ESO syncs secrets from AWS
           → Pods start, pass health checks
           → LBC creates the ALB
           → ExternalDNS creates Route53 records

FULLY OPERATIONAL in approximately 10-15 minutes after Step 5
```

---

## 17. The Full CI/CD → GitOps Loop

Understanding this loop is essential — it's how code goes from a developer's laptop to running in the cluster.

### On every pull request (PR gate)

```
Developer opens PR → GitHub Actions triggers service-pr.yml workflow:
  1. Checkout source code
  2. Install Python deps + run Ruff linter + run pytest tests
  3. SonarCloud SAST scan (static analysis + quality gate — blocks merge if quality drops)
  4. Snyk SCA scan (checks requirements.txt for known vulnerable packages)
  5. docker build + Trivy scan (container CVE scan, never pushed)
  6. All 5 steps must pass → merge is allowed
```

### On merge to main (dev deploy)

```
Developer merges PR → GitHub Actions triggers service-build-push.yml:
  1. Checkout source code
  2. Derive 7-char git SHA (e.g., "abc1234")
  3. OIDC: assume lablumen-app-ci-ecr IAM role (no static credentials)
  4. aws-actions/amazon-ecr-login → get Docker auth token
  5. docker build -t <ECR-URL>/lablumen/appointment-service:abc1234 .
  6. Trivy gate on the built image (CRITICAL/HIGH → abort, don't push)
  7. docker push to ECR
  8. Checkout lablumen-k8s repo (using PAT with write access)
  9. yq -i ".image.tag = \"abc1234\"" services/appointment-service/values-dev.yaml
  10. git commit -m "cd(dev): appointment-service -> abc1234"
  11. git pull --rebase + git push (retry loop up to 5 times for concurrent service pushes)

ArgoCD (watching lablumen-k8s repo, polling every 3 minutes):
  12. Detects values-dev.yaml changed
  13. Renders the Helm chart with the new tag
  14. Computes the diff vs current cluster state
  15. Applies the diff: updates the Deployment with the new image tag
  16. Rolling update: new pod starts → passes readiness probe → old pod terminates
  17. Done in ~90 seconds
```

### On GitHub Release (prod deploy)

```
Human creates GitHub Release v1.0.1:
  1. GitHub Actions picks up the release event
  2. Builds image tagged "v1.0.1"
  3. Trivy scan → pushes to ECR
  4. Updates services/<name>/values-prod.yaml with "v1.0.1"
  5. ArgoCD detects the change → rolls out to lablumen namespace
```

### Race condition handling in the write-back

Multiple services can push to main simultaneously. If appointment-service and report-service both try to commit to lablumen-k8s at the same moment, one will win and the other will fail on `git push`. The retry loop:
```bash
for i in $(seq 1 5); do
  if git pull --rebase origin main && git push origin main; then exit 0; fi
  sleep 5
done
```
This is a simple optimistic concurrency solution. In 99.9% of cases, one retry is enough. After 5 attempts it fails the CI job (alerting the developer to investigate).

---

## 18. Key Design Decisions & Defences

### "Why one shared Helm chart instead of per-service charts?"

Duplication is the enemy of consistency. With per-service charts, a security fix to the pod security context requires changing 4 files. With one shared chart, you change one template and all services get the fix on the next sync. The per-service `values.yaml` files are the right level of customisation — they describe *what* is different, not *how* to deploy.

### "Why is the appointment-service ServiceAccount created by the chart (create: true) while report-service and notification-service SAs are created by Terraform (create: false)?"

Report-service and notification-service need IRSA — their ServiceAccounts must exist BEFORE the Helm chart deploys, because Terraform creates them with the `eks.amazonaws.com/role-arn` annotation wired to the correct IAM role ARN (a Terraform output). If the chart created the SA, the IAM role ARN would have to be hardcoded in a values file — breaking the Terraform → K8s single-source-of-truth.

Appointment-service needs no AWS IAM role (it only writes to RDS + publishes SQS via node credentials), so a plain SA created by the chart is fine.

### "Why does the frontend have `externalSecret.data: []` (empty Secrets Manager list)?"

The frontend has no database. It only needs Cognito IDs (User Pool ID + Client ID) from SSM — which are not sensitive (they are public identifiers in the OAuth2 spec). The ESO chart still creates the ExternalSecret object, but the `data` field (Secrets Manager sources) is empty. Only the `ssmData` field has entries.

### "Why is notification-service HPA disabled even in prod?"

HPA scales on CPU. The notification-service long-polls SQS every 20 seconds and sends emails — near-zero CPU. Even with a 10,000-message backlog, CPU stays flat. HPA would never trigger. The correct metric for a queue consumer is queue depth (`ApproximateNumberOfMessages`). KEDA (Kubernetes Event-driven Autoscaling) supports this but was not added. Instead, 2 replicas provide parallel consumption — each pod competes for messages via the SQS visibility timeout mechanism.

### "Why does ArgoCD self-manage with `prune: false`?"

ArgoCD manages its own Helm release via `platform/addons/argocd.yaml`. If `prune: true`, and a sync removed ArgoCD's own Application object, ArgoCD would try to delete itself — which would kill the controller mid-deletion, potentially in a broken state. `prune: false` means ArgoCD never removes its own resources, even if something is removed from the Helm chart.

### "Why not use Helm for the ClusterSecretStore — why is it a raw YAML file?"

The ClusterSecretStore references the `lablumen-eso` ServiceAccount by name. This name is set by Terraform and is a known constant. There is no environment-specific variation (same store works for both lablumen and lablumen-dev namespaces since ESO is cluster-scoped). A raw YAML file (`platform/config/cluster-secret-store.yaml`) deployed by the `platform-config` ArgoCD Application is the simplest solution — no Helm templating needed.

### "What happens if a developer makes a manual kubectl change in production?"

ArgoCD's `selfHeal: true` detects the drift within 3 minutes (the default sync interval) and reverts it to match Git. The developer's change is overwritten. If a change needs to be permanent, it must go through Git.

### "What if the lablumen-k8s repo is unavailable?"

ArgoCD caches the last successfully synced state. If the repo is unreachable, ArgoCD stops applying changes but the cluster continues running its last-known state. No pods are killed. The platform is resilient to Git repo outages during normal operation — only new deployments are blocked.

---

## Quick-Reference: What Every File Does

| File | What it does |
|---|---|
| `global-values.yaml` | Single location for the ECR registry URL (account-specific) |
| `charts/microservice/` | Shared Helm chart: Deployment + Service + HPA + PDB + Ingress + ExternalSecret + SA + NetworkPolicy |
| `charts/redis/` | Simple Redis Helm chart |
| `services/<name>/values.yaml` | Service identity: name, image repo, SSM keys, ingress path |
| `services/<name>/values-dev.yaml` | Dev overrides: image SHA (auto-updated by CI), dev hostname, 1 replica |
| `services/<name>/values-prod.yaml` | Prod overrides: semver tag (human-set), 2 replicas, prod hostname, autoscaling |
| `platform/addons/argocd.yaml` | ArgoCD self-management Application |
| `platform/addons/aws-load-balancer-controller.yaml` | LBC Application (creates ALBs from Ingress objects) |
| `platform/addons/external-dns.yaml` | ExternalDNS Application (creates Route53 records from Ingress hosts) |
| `platform/addons/external-secrets.yaml` | ESO Application (syncs AWS secrets to K8s Secrets) |
| `platform/addons/karpenter-crd.yaml` | Karpenter CRD Application (NodePool, EC2NodeClass types) |
| `platform/addons/karpenter.yaml` | Karpenter controller Application |
| `platform/addons/metrics-server.yaml` | Metrics Server Application (required for HPA to work) |
| `platform/addons/monitoring.yaml` | kube-prometheus-stack Application (Prometheus + Grafana) |
| `platform/config/cluster-secret-store.yaml` | Two ClusterSecretStores (Secrets Manager + SSM) |
| `platform/karpenter/nodepool.yaml` | NodePool: what Karpenter may provision, limits, consolidation policy |
| `platform/karpenter/ec2nodeclass.yaml` | EC2NodeClass: AMI, IAM role, subnet + SG discovery tags |
| `platform/monitoring/grafana-admin.externalsecret.yaml` | ESO syncs Grafana admin creds from Secrets Manager |
| `argocd/projects/lablumen.yaml` | AppProject: source repos, destination namespaces, allowed CRD types |
| `argocd/apps/karpenter-nodepool.yaml` | Application for Karpenter NodePool + EC2NodeClass (wave 1) |
| `argocd/apps/platform-config.yaml` | Application for ClusterSecretStores (wave 1) |
| `argocd/apps/monitoring-secret.yaml` | Application for Grafana admin secret (wave 1) |
| `argocd/applicationsets/services-dev.yaml` | ApplicationSet: generates 5 dev Applications |
| `argocd/applicationsets/services-prod.yaml` | ApplicationSet: generates 5 prod Applications |
| `bootstrap/root-app.yaml` | The ONE manifest that bootstraps everything |
| `scripts/bootstrap-argocd.sh` | Bootstrap script: kubeconfig + helm install ArgoCD + apply root app |
| `lablumen-terraform/kubernetes.tf` | Terraform: namespaces + IRSA-annotated ServiceAccounts |
| `lablumen-terraform/modules/eks/main.tf` | Terraform: EKS cluster + Karpenter submodule |
| `lablumen-shared/.github/workflows/service-build-push.yml` | Reusable CI: build + Trivy + push to ECR + write SHA to values-dev.yaml |
| `lablumen-shared/.github/workflows/service-pr.yml` | Reusable CI: lint + test + SonarCloud + Snyk + Trivy on PRs |
