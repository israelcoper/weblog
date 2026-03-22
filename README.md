# Weblog

A Rails API application used as a learning project for deploying to AWS ECS — both manually via the AWS Console and using Infrastructure as Code (Terraform).

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Ruby 3.2.2 |
| Framework | Rails 7.2.3 (API-only) |
| Database | PostgreSQL |
| Web Server | Puma |
| Containerization | Docker |

---

## Infrastructure

| AWS Service | Purpose |
|-------------|---------|
| ECR | Private Docker image registry |
| ECS Fargate | Serverless container compute (no EC2 to manage) |
| RDS PostgreSQL | Managed relational database |
| CloudWatch Logs | Container log aggregation |

---

## Part 1 — Manual Deployment (AWS Console)

### Prerequisites
- AWS account with admin access
- AWS CLI configured (`aws configure --profile terraform`)
- Docker running locally

### Step 1 — Create RDS PostgreSQL

1. Go to **RDS → Create database**
2. Method: **Full configuration**
3. Engine: **PostgreSQL** | Template: **Free Tier**
4. DB identifier: `weblog-db` | Username: `weblog` | set a password
5. Instance: `db.t3.micro` | Storage: 20 GB gp2
6. Connectivity → Public access: **Yes**
7. VPC security group: create new → `weblog-rds-sg`
8. Click **Create database** (~5 min)

After creation: edit `weblog-rds-sg` inbound rules → add **PostgreSQL (5432)** from `0.0.0.0/0`

Note the **Endpoint** shown on the RDS instance page — you'll need it in Step 4.

### Step 2 — Push Image to ECR

```bash
# Create the repository (first time only)
aws ecr create-repository --repository-name weblog \
  --region ap-southeast-1 --profile terraform

# Authenticate Docker to ECR
aws ecr get-login-password --region ap-southeast-1 --profile terraform | \
  docker login --username AWS --password-stdin \
  <account-id>.dkr.ecr.ap-southeast-1.amazonaws.com

# Build for Fargate (requires linux/amd64)
docker build --platform linux/amd64 -t weblog .

# Tag and push
docker tag weblog:latest <account-id>.dkr.ecr.ap-southeast-1.amazonaws.com/weblog:latest
docker push <account-id>.dkr.ecr.ap-southeast-1.amazonaws.com/weblog:latest
```

> Get your account ID: `aws sts get-caller-identity --query Account --output text --profile terraform`

> **Note:** Always create the repository before pushing — `docker push` will fail with "repository does not exist" if skipped. Ensure the `--region` flag and the registry URL both use the same region where the repository was created.

### Step 3 — Create ECS Cluster

1. Go to **ECS → Clusters → Create Cluster**
2. Name: `weblog-cluster` | Infrastructure: **AWS Fargate**
3. Click **Create**

### Step 4 — Create Task Definition

1. Go to **ECS → Task Definitions → Create new task definition**
2. Family: `weblog-task` | Launch type: **Fargate**
3. CPU: `0.25 vCPU` | Memory: `0.5 GB`

**Container settings:**
- Name: `weblog`
- Image URI: `<account-id>.dkr.ecr.ap-southeast-1.amazonaws.com/weblog:latest`
- Port: `3000`

**Environment variables:**

| Key | Value |
|-----|-------|
| `RAILS_ENV` | `production` |
| `DATABASE_URL` | `postgres://weblog:<password>@<rds-endpoint>/weblog_production` |
| `SECRET_KEY_BASE` | output of `rails secret` run locally |
| `RAILS_LOG_TO_STDOUT` | `true` |

> **Note:** Double-check `DATABASE_URL` — if it's missing or has a typo, Rails will silently fall back to a local socket connection and the migration will fail. Task definitions are immutable; if you need to fix an env var, click **Create new revision** instead of editing.

### Step 5 — Run DB Migration (One-off Task)

1. Go to **ECS → Clusters → weblog-cluster → Run new task**
2. Launch type: Fargate | Task definition: `weblog-task`
3. Networking: default VPC, any public subnet
4. Security group: allow all outbound (port range: all)
5. Scroll down to **Container overrides** → expand it → find the `weblog` container → **Command override** field → enter: `bin/rails,db:create,db:migrate`
6. Click **Run task** and wait for it to stop with exit code `0`

> **Note:** If the task exits with code `1`, check the **Logs** tab. Common causes: `Permission denied on /app/tmp` means the Docker image was built without pre-creating the tmp directories (rebuild and push); socket connection errors mean `DATABASE_URL` is wrong in the task definition (create a new revision with the correct value).

### Step 6 — Create ECS Service

1. Go to **ECS → Clusters → weblog-cluster → Services → Create**
2. Launch type: Fargate | Task definition: `weblog-task`
3. Service name: `weblog-service` | Desired tasks: `1`
4. Networking: default VPC, public subnets
5. Security group: create `weblog-app-sg` → inbound TCP `3000` from `0.0.0.0/0`
6. Public IP: **Enabled**
7. Click **Create**

Access via the public IP shown on the running task:

```bash
curl http://<public-ip>:3000/up
```

A `200 OK` response confirms the app is running. (`/up` is Rails' built-in health check endpoint)

> **Note:** Do not open the URL in a browser directly — browsers may force HTTPS and show `SSL_ERROR_RX_RECORD_TOO_LONG`. Use `curl` or Chrome (avoid Firefox for plain HTTP IPs). If you see a `301 Moved Permanently` redirect to HTTPS, ensure `config.force_ssl = false` is set in `config/environments/production.rb`, then rebuild, push, and force a new deployment via **Update service → Force new deployment**.

### Teardown

Delete in this order to avoid dependency errors:

**1. Stop and delete the ECS Service**
1. Go to **ECS → Clusters → weblog-cluster → Services → weblog-service**
2. Click **Update service** → set **Desired tasks** to `0` → click **Update**
3. Wait ~30 seconds for the task to stop
4. Click **Delete service** → confirm

**2. Delete the ECS Cluster**
1. Go to **ECS → Clusters → weblog-cluster**
2. Click **Delete cluster** → confirm

**3. Delete the RDS Database**
1. Go to **RDS → Databases → weblog-db**
2. Click **Actions → Delete**
3. Uncheck **Create final snapshot**
4. Confirm deletion (~5 min)

**4. Delete the ECR Repository**
1. Go to **ECR → Repositories → weblog**
2. Click **Delete** → confirm

**5. Delete Security Groups**
1. Go to **EC2 → Security Groups**
2. Delete `weblog-app-sg`
3. Delete `weblog-rds-sg`

---

## Part 2 — Infrastructure as Code (Terraform)

Provisions the same AWS resources as Part 1 using Terraform. See the [`terraform/`](terraform/) directory.

### Prerequisites
- Terraform installed (`brew install terraform`)
- AWS CLI configured with `--profile terraform`

### Step 1 — Fill in Variables

Copy the sample and set values accordingly:

```bash
cp terraform/terraform.tfvars.sample terraform/terraform.tfvars
```

Then edit `terraform/terraform.tfvars`:

```hcl
db_password     = "your-strong-password"
secret_key_base = "output-of-rails-secret"
```

> Generate `secret_key_base` locally: `rails secret`

### Step 2 — Initialize and Apply

```bash
cd terraform
terraform init
terraform plan
terraform apply  # type 'yes' to confirm
```

### Step 3 — Push Image to ECR

After `terraform apply`, use the `ecr_url` output to push your image:

```bash
# Authenticate
aws ecr get-login-password --region ap-southeast-1 --profile terraform | \
  docker login --username AWS --password-stdin <ecr_url>

# Build, tag, push
docker build --platform linux/amd64 -t weblog .
docker tag weblog:latest <ecr_url>:latest
docker push <ecr_url>:latest
```

### Step 4 — Run DB Migration (One-off Task)

Same as Part 1 Step 5 — run a one-off ECS task with the command override:

```
bin/rails,db:create,db:migrate
```

### Step 5 — Verify

```bash
# Get the public IP from the running ECS task in the console, then:
curl http://<public-ip>:3000/up
```

A `200 OK` confirms the app is running.

### Teardown

```bash
cd terraform
terraform destroy  # type 'yes' to confirm
```

This deletes all provisioned resources. No manual cleanup needed.
