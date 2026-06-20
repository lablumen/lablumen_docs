# LabLumen — EC2 + Docker Compose Deployment Guide

Single-instance setup. nginx (port 80) serves the SPA and proxies `/api/v1/` to the backend — no
CORS issues. All AWS resources (Cognito, S3, SQS, SES, Bedrock) have already been provisioned; you
only need a fresh EC2 to run this.

---

## Pre-Provisioned AWS Resources (already live — no action required)

| Resource | Value |
|---|---|
| **Cognito User Pool ID** | `us-east-1_3hMVOZPch` |
| **Cognito App Client ID** | `7eb2d3esnbfs3te482jgsfqp6t` |
| **S3 Bucket** | `lablumen-reports-130290476321` |
| **SQS Queue URL** | `https://sqs.us-east-1.amazonaws.com/130290476321/lablumen-notifications` |
| **SES Sender** | `rukesully@gmail.com` (verified in SES sandbox) |
| **EC2 IAM Role** | `lablumen-ec2-role` |
| **EC2 Instance Profile** | `lablumen-ec2-profile` |
| **Security Group** | `sg-0cd62be1c32705ec0` (`lablumen-sg`) |
| **Bedrock Models** | `amazon.titan-embed-text-v1` (embed) + `amazon.nova-lite-v1:0` (text) |

All values are baked into `docker-compose.yml` — no manual editing required after clone.

---

## Test Users (password for all: `Test12345!`)

| Email | Role | Notes |
|---|---|---|
| `rukesully@gmail.com` | PATIENT | Use this for end-to-end demo — SES-verified, emails deliver |
| `patient@example.com` | PATIENT | Works; SES sandbox won't deliver emails to it |
| `staff@example.com` | LAB_STAFF | Staff portal + report upload |

---

## Step 1 — Ensure Latest Code Is Pushed

If you made local changes, push them first:

```bash
git add -A
git commit -m "your message"
git push origin main
```

The bootstrap script clones from GitHub, so the EC2 always gets what's on `main`.

---

## Step 2 — Launch a New EC2 Instance (Console)

> The IAM user `rn1d` cannot launch EC2 via CLI (org SCP restriction). Use the AWS Console.

1. Go to **EC2 → Launch instance** in region **us-east-1**
2. Use these settings:

   | Setting | Value |
   |---|---|
   | Name | `lablumen-test` |
   | AMI | **Ubuntu 24.04 LTS** — `ami-0f8a61b66d1accaee` (us-east-1) |
   | Instance type | `t3.large` |
   | Key pair | `rnld2` (or any key you have access to) |
   | Security group | Select existing: `lablumen-sg` (`sg-0cd62be1c32705ec0`) |
   | Storage | 30 GB gp3 |
   | IAM instance profile | `lablumen-ec2-profile` |

3. Expand **Advanced details → User data** and paste this script:

```bash
#!/bin/bash
set -e
exec > /var/log/lablumen-setup.log 2>&1

echo "=== LabLumen bootstrap start $(date) ==="

apt-get update -y
apt-get install -y ca-certificates curl gnupg git

# Install Docker CE via official repo
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

cd /home/ubuntu
git clone https://github.com/rnld101/lablumen.git lablumen
chown -R ubuntu:ubuntu /home/ubuntu/lablumen

cd /home/ubuntu/lablumen
sudo -u ubuntu docker compose up --build -d

echo "=== LabLumen bootstrap done $(date) ==="
echo "App ready at: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)"
```

> **Private repo?** Replace the `git clone` line with:
> `git clone https://<YOUR_GITHUB_PAT>@github.com/rnld101/lablumen.git lablumen`

4. Click **Launch instance** and note the new **Instance ID** and **Public IP** once it starts.

---

## Step 3 — Wait for Bootstrap (~10–15 minutes)

The user-data script runs automatically on first boot. Image builds dominate the wait time.

**Option A — SSH (if you have the key):**
```bash
ssh -i /path/to/rnld2.pem ubuntu@<EC2-PUBLIC-IP>
tail -f /var/log/lablumen-setup.log
```

**Option B — AWS SSM Session Manager (no key needed):**
```bash
aws ssm start-session --target <INSTANCE-ID> --region us-east-1
sudo tail -f /var/log/lablumen-setup.log
```

Bootstrap is complete when you see:
```
=== LabLumen bootstrap done ...
App ready at: http://<EC2-PUBLIC-IP>
```

---

## Step 4 — Verify the Stack

```bash
EC2=<EC2-PUBLIC-IP>

# Health checks — all should return {"status":"ok"}
curl http://$EC2/health/appointment
curl http://$EC2/health/report
curl http://$EC2/health/notification

# Lab test catalog — should return 9 records
curl http://$EC2/api/v1/lab-tests
```

Open `http://<EC2-PUBLIC-IP>` in a browser — you should be redirected to `/login`.

---

## Step 5 — End-to-End Demo

1. Log in as **`rukesully@gmail.com` / `Test12345!`** (patient)
2. Create a patient profile → select 2 tests (cost total updates) → pick date + slot → **Book**
   - Confirmation email arrives at rukesully@gmail.com (SES sandbox delivers to verified addresses)
3. Log out → log in as **`staff@example.com` / `Test12345!`** → **Staff** tab
   - Operations Queue shows the booking → toggle status → click **Upload PDF** on a row
4. Ingestion runs in the background: Textract OCR → Nova summary → Titan embeddings → pgvector
5. Log back in as the patient → **My Reports** shows the report as **Ready** with an AI summary
   - **Preview** opens the presigned PDF (120s TTL)
   - **Chat** answers questions grounded in that specific report with a disclaimer

---

## Step 6 — Get a JWT for API Testing

```bash
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id 7eb2d3esnbfs3te482jgsfqp6t \
  --auth-parameters USERNAME=rukesully@gmail.com,PASSWORD='Test12345!' \
  --region us-east-1 \
  --query 'AuthenticationResult.IdToken' \
  --output text)

# Test a protected endpoint
curl -H "Authorization: Bearer $TOKEN" http://$EC2/api/v1/reports
```

---

## Architecture

```
Browser ──HTTP:80──► nginx (frontend container)
                         │
                         ├─ /api/v1/reports/*  ──► report-service:8000
                         ├─ /api/v1/*          ──► appointment-service:8000
                         ├─ /health/appointment ──► appointment-service /healthz
                         ├─ /health/report      ──► report-service /healthz
                         ├─ /health/notification ──► notification-service /healthz
                         └─ /*                 ──► React SPA (built + served by nginx)

Services in one Docker network:
  postgres (pgvector:pg16) · redis · appointment-service · report-service · notification-service · frontend
```

nginx reverse-proxy means the browser always calls the same origin → **zero CORS issues**.

---

## Redeploying After Code Changes

SSH or SSM into the instance, then:

```bash
# IMPORTANT: always run git as ubuntu (not root) to avoid .git ownership issues
cd /home/ubuntu/lablumen
sudo -u ubuntu git pull origin main
sudo -u ubuntu docker compose up --build -d

# If you ran any git commands as root accidentally, fix ownership first:
sudo chown -R ubuntu:ubuntu /home/ubuntu/lablumen
sudo -u ubuntu git pull origin main
sudo -u ubuntu docker compose up --build -d
```

Other useful commands:
```bash
docker compose logs -f                  # stream all logs
docker compose logs -f report-service   # single service
docker compose ps                       # container status
docker compose down -v                  # tear down + wipe volumes (destroys data)
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Browser shows blank/504 | Bootstrap still running — tail `/var/log/lablumen-setup.log` |
| `migrate` container keeps restarting | `docker compose logs migrate` — postgres not ready; run `docker compose restart migrate` |
| Lab catalog empty / 502 in console | `appointment-service` still starting. Wait 30s, refresh |
| SQS `AccessDenied` in notification-service logs | EC2 IAM profile not attached — verify instance uses `lablumen-ec2-profile` |
| Bedrock `AccessDenied` in report-service logs | Model access not enabled — go to Bedrock → Model access → enable Titan + Nova Lite |
| AI summary never appears (has_summary stays false) | Check `docker compose logs report-service` — Textract or Bedrock error. Textract needs a real PDF/image (not a blank file). |
| GitHub clone fails (exit 128) | Repo is private — use a PAT in the clone URL (see Step 2 note) |
| git `dubious ownership` / can't write `.git/FETCH_HEAD` | You ran git as root. Run `sudo chown -R ubuntu:ubuntu /home/ubuntu/lablumen`, then git as ubuntu (see Redeploying above) |

---

## Teardown

Terminate the instance to stop compute charges (S3/SQS/Cognito have no ongoing cost when idle):

```bash
aws ec2 terminate-instances --instance-ids <INSTANCE-ID> --region us-east-1
```

To fully clean up all provisioned AWS resources:

```bash
# Cognito
aws cognito-idp delete-user-pool --user-pool-id us-east-1_3hMVOZPch --region us-east-1

# S3
aws s3 rb s3://lablumen-reports-130290476321 --force

# SQS
aws sqs delete-queue \
  --queue-url https://sqs.us-east-1.amazonaws.com/130290476321/lablumen-notifications

# IAM
aws iam remove-role-from-instance-profile \
  --instance-profile-name lablumen-ec2-profile --role-name lablumen-ec2-role
aws iam delete-instance-profile --instance-profile-name lablumen-ec2-profile
aws iam detach-role-policy --role-name lablumen-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess
aws iam detach-role-policy --role-name lablumen-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam detach-role-policy --role-name lablumen-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSQSFullAccess
aws iam detach-role-policy --role-name lablumen-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSESFullAccess
aws iam detach-role-policy --role-name lablumen-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonCognitoReadOnly
aws iam detach-role-policy --role-name lablumen-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonTextractFullAccess
aws iam detach-role-policy --role-name lablumen-ec2-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name lablumen-ec2-role

# Security group (only works after all instances using it are terminated)
aws ec2 delete-security-group --group-id sg-0cd62be1c32705ec0 --region us-east-1
```

---

## Known Constraints

- **Bedrock text model = `amazon.nova-lite-v1:0`** — An org SCP (`p-rn6vr8ok`) restricts Bedrock
  to us-east-1. Nova 2 Lite (`nova-2-lite-v1:0`) requires a cross-region inference profile that
  load-balances to us-east-2/west-2, which the SCP blocks. Nova Lite v1 runs on-demand in us-east-1.
- **SES sandbox** — Only verified email addresses receive mail. Demo as `rukesully@gmail.com`.
  For arbitrary patient emails, request SES production access.
- **EC2 reboot changes the public IP** unless an Elastic IP is attached.
- **Git as root breaks `.git`** — SSM sessions run as root. Always use `sudo -u ubuntu git`.
