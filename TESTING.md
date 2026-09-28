# Testing Guide

Layered test plan: application → container → infrastructure → security → resilience.
Run each layer only once the previous one is green.

---

## 0. Prerequisites

| Tool | Version | Check |
|---|---|---|
| Java | 21 | `java -version` |
| Maven | 3.9+ | `mvn -version` |
| Docker | 24+ | `docker version` |
| Terraform | >= 1.6.0 | `terraform version` |
| AWS CLI | v2 | `aws --version` |
| Postman | Desktop or CLI (Newman) | `npx newman --version` |
| curl / jq | any | `curl --version` |

Configure AWS credentials for a profile that can assume/deploy (`aws configure` or SSO).

---

## 1. Unit & Build Testing (application layer)

```bash
cd Spring-microservice

# Compile + run tests
mvn clean verify

# Package the jar
mvn clean package -DskipTests
ls -lh target/microservice.jar
```

**Expected result:** `BUILD SUCCESS`, and `target/microservice.jar` exists.

**What to check if it fails:**
- Dependency resolution errors → check `~/.m2` proxy/mirror settings.
- Compilation errors in `exception/GlobalExceptionHandler.java` → confirm AWS SDK BOM version in `pom.xml` matches imports (`AwsServiceException`, `SdkClientException`).

---

## 2. Local Run — No Docker (fastest feedback loop)

```bash
export AWS_REGION=us-east-1
export APP_S3_BUCKET_NAME=my-dev-bucket
export APP_SECRET_NAME=my-dev-secret
# Requires local AWS credentials (aws configure) with access to that bucket/secret,
# OR stub/mock them out — see section 2a below if you don't want real AWS calls yet.

mvn spring-boot:run
```

In a second terminal:

```bash
curl -i http://localhost:8080/actuator/health
curl -i http://localhost:8080/actuator/health/liveness
curl -i http://localhost:8080/actuator/health/readiness
```

**Expected result:** all three return `HTTP 200` with `{"status":"UP"}` (readiness may show `503` for a second or two right after startup while the Spring context finishes initializing — that's the intended behavior the ALB relies on).

### 2a. Testing without real AWS credentials

If you just want to prove the web layer / exception handling works before wiring real AWS access:

```bash
# This will fail the AWS call and should surface as a clean 502/503,
# not a raw stack trace — proving GlobalExceptionHandler works.
curl -i http://localhost:8080/api/v1/secrets/anything/status
```

**Expected result:** `HTTP 502` or `HTTP 503` with a JSON body matching `ErrorResponse` (no AWS SDK internals, no stack trace, no request ID in the body). Confirm the full stack trace *did* land in the console log — that's where it belongs.

---

## 3. Docker Container Testing

```bash
docker build -t Spring-svc:local .

docker run -d --name pss-test -p 8080:8080 \
  -e AWS_REGION=us-east-1 \
  -e APP_S3_BUCKET_NAME=my-dev-bucket \
  -e APP_SECRET_NAME=my-dev-secret \
  -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
  -e AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN \
  Spring-svc:local
```

### 3.1 Verify non-root user (security hardening)

```bash
docker exec pss-test whoami        # expect: nothing printed / error, or uid 10001 (no /etc/passwd entry needed)
docker exec pss-test id            # expect: uid=10001 gid=10001
```

**Expected result:** UID is `10001`, never `0` (root).

### 3.2 Verify container-aware JVM flags took effect

```bash
docker stats pss-test --no-stream
docker exec pss-test cat /proc/1/status | grep -i vmrss
docker inspect pss-test | grep -i "\"Memory\""
```

Then compare against the reported heap:

```bash
curl -s http://localhost:8080/actuator/metrics/jvm.memory.max | jq
```

**Expected result:** `jvm.memory.max` value is roughly 75% of whatever `--memory` limit you gave the container (or the Fargate task memory once deployed) — **not** 75% of your laptop's total RAM. Run this same check with `docker run --memory=512m ...` and confirm the reported max heap scales down accordingly. This is the concrete proof that `-XX:+UseContainerSupport -XX:MaxRAMPercentage=75.0` works.

### 3.3 Verify Docker HEALTHCHECK

```bash
docker inspect --format='{{json .State.Health}}' pss-test | jq
```

**Expected result:** `"Status": "healthy"` after the 60s `start-period` elapses.

### 3.4 Verify graceful shutdown end-to-end

```bash
# Fire a slow/long-running request in the background, then immediately stop the container
curl -s http://localhost:8080/api/v1/files/large-object.txt &
docker stop -t 45 pss-test
docker logs pss-test --tail 30
```

**Expected result:** logs show Tomcat's graceful shutdown message (connector stopped accepting new connections, then "Commons-Daemon" / context closed) **before** the container exits — not an abrupt kill. If you `docker stop -t 5` instead (shorter than the 30s Spring budget), you should see the process killed mid-shutdown — this proves why the ECS `stopTimeout` (40s) must exceed Spring's `timeout-per-shutdown-phase` (30s).

```bash
docker rm -f pss-test
```

---

## 4. Postman Collection Testing

Files are in `postman/`:
- `Spring-Microservice.postman_collection.json`
- `Local-Docker.postman_environment.json`
- `AWS-ALB.postman_environment.json`

### 4.1 Import into Postman (GUI)

1. Postman → **Import** → drag in the collection JSON and both environment JSONs.
2. Top-right environment selector → choose **Local Docker** (while the container from Section 3 is running) or **AWS ALB (Deployed)** (after Section 5).
3. If using **AWS ALB**, edit that environment's `base_url` to `http://<terraform output alb_dns_name>` first.
4. Run folder **"1. Actuator - Health & Probes"** first, then **"2. Secrets Manager"**, then **"3. S3 Files"** (Upload must run before Get File, since Get File asserts on content the Upload request wrote), then **"4. Negative / IAM Boundary Tests"**.
5. Use **Runner** (bottom-left) to run the whole collection in sequence and see the pass/fail summary.

### 4.2 Run headlessly with Newman (CI-friendly)

```bash
npm install -g newman

newman run postman/Spring-Microservice.postman_collection.json \
  -e postman/Local-Docker.postman_environment.json \
  --reporters cli,json \
  --reporter-json-export postman/results-local.json
```

**Expected result:** Newman reports all assertions passed (`0 failing`). Folder 4 ("Negative / IAM Boundary Tests") is written to be run against the **AWS ALB** environment — against local Docker with your own broad credentials it may behave differently, since your local AWS profile likely has more permissions than the scoped Task Role.

### 4.3 What each folder proves

| Folder | Proves |
|---|---|
| 1. Actuator | Liveness/readiness split works; JVM respects container memory limits |
| 2. Secrets Manager | Task Role can read the one configured secret; 404 on unknown names; raw secret value is never returned in the HTTP response body |
| 3. S3 Files | Task Role can read/write the one configured bucket; validation (`@NotBlank`) rejects empty uploads with 400; missing keys return clean 404 via `GlobalExceptionHandler`, not a raw AWS stack trace |
| 4. IAM Boundary | AWS `AccessDenied`/service errors are translated to a generic 502 with no leaked ARNs, error codes, or request IDs — full detail goes to CloudWatch only |

---

## 5. Terraform Infrastructure Testing

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in real values first

terraform fmt -check -recursive
terraform init
terraform validate
terraform plan -out=tfplan
```

**Expected result:** `terraform validate` → `Success!`. `terraform plan` shows only resource **creations** on a first run (no unexpected destroys). Review the plan for exactly: 1 VPC, 4 subnets, 1 IGW, 1–2 NAT Gateways, 5 VPC endpoints, 2 security groups, 2 IAM roles + 2 policies, 1 ALB + listener + target group, 1 ECS cluster/service/task definition, 2 autoscaling resources.

```bash
terraform apply tfplan
terraform output
```

Record `alb_dns_name` — you'll need it for Sections 4 (AWS ALB Postman environment) and 6/7 below.

### 5.1 Push an image so the service can actually start

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <account_id>.dkr.ecr.us-east-1.amazonaws.com

docker tag Spring-svc:local <account_id>.dkr.ecr.us-east-1.amazonaws.com/Spring-svc-prod:latest
docker push <account_id>.dkr.ecr.us-east-1.amazonaws.com/Spring-svc-prod:latest

aws ecs update-service \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --service $(terraform output -raw ecs_service_name) \
  --force-new-deployment
```

### 5.2 Watch the deployment

```bash
aws ecs describe-services \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services $(terraform output -raw ecs_service_name) \
  --query 'services[0].deployments'
```

**Expected result:** `runningCount` reaches `desiredCount` and `rolloutState` becomes `COMPLETED` within a couple of minutes.

---

## 6. End-to-End Smoke Test Against the Real ALB

```bash
ALB=$(terraform output -raw alb_dns_name)

curl -i http://$ALB/actuator/health
curl -i http://$ALB/actuator/health/readiness
curl -i http://$ALB/api/v1/secrets/prod/Spring-svc/app-secrets/status
curl -i -X POST http://$ALB/api/v1/files/smoke-test/hello.txt -d "hello from smoke test"
curl -i http://$ALB/api/v1/files/smoke-test/hello.txt
```

Then run the full Postman collection against the **AWS ALB** environment (Section 4.2, swap `-e` to `postman/AWS-ALB.postman_environment.json`).

**Expected result:** identical behavior to local Docker testing, confirming the Task Role's scoped IAM policy is sufficient for the app's actual code paths (nothing more, nothing less).

---

## 7. Security & Networking Verification (the parts an interviewer will probe hardest)

### 7.1 Confirm the ECS task is NOT reachable directly (only via the ALB)

```bash
# Get a running task's private IP
TASK_ARN=$(aws ecs list-tasks --cluster $(terraform output -raw ecs_cluster_name) --query 'taskArns[0]' --output text)
aws ecs describe-tasks --cluster $(terraform output -raw ecs_cluster_name) --tasks $TASK_ARN \
  --query 'tasks[0].attachments[0].details[?name==`privateIPv4Address`].value' --output text
```

From **outside the VPC** (your laptop), attempting to reach that private IP on 8080 will simply time out — there's no route from the public internet to a private subnet, and even inside the VPC, the ECS Task Security Group's only ingress rule is "port 8080 from the ALB Security Group." Prove the second half from a bastion/Cloud9 instance placed in the **same VPC but not in the ALB security group**:

```bash
curl --max-time 5 -i http://<task-private-ip>:8080/actuator/health
```

**Expected result:** connection times out / refused. This is the concrete demonstration of security-group chaining working: private IP reachability inside the VPC is not enough — the *source security group* has to be the ALB's.

### 7.2 Confirm S3/Secrets Manager traffic never uses the NAT Gateway

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/NATGateway \
  --metric-name BytesOutToDestination \
  --dimensions Name=NatGatewayId,Value=<nat-gw-id> \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 --statistics Sum
```

Hit `/api/v1/secrets/.../status` and `/api/v1/files/...` several times, then re-run the same metric query.

**Expected result:** NAT Gateway bytes stay flat / near-zero for these calls. Cross-check with VPC endpoint activity instead:

```bash
aws logs filter-log-events \
  --log-group-name $(terraform output -raw log_group_name 2>/dev/null || echo /ecs/Spring-svc-prod) \
  --filter-pattern "Fetched secret"
```

### 7.3 IAM least-privilege verification with the policy simulator

```bash
TASK_ROLE_ARN=$(terraform output -raw ecs_task_role_arn)

# Should return "allowed" -- the configured bucket
aws iam simulate-principal-policy \
  --policy-source-arn $TASK_ROLE_ARN \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::my-dev-bucket/some-key

# Should return "explicitDeny" or "implicitDeny" -- a DIFFERENT bucket
aws iam simulate-principal-policy \
  --policy-source-arn $TASK_ROLE_ARN \
  --action-names s3:GetObject \
  --resource-arns arn:aws:s3:::some-other-teams-bucket/some-key
```

**Expected result:** first call → `allowed`; second call → `implicitDeny`. Repeat the same pattern for `secretsmanager:GetSecretValue` against the configured secret ARN vs. an unrelated one, and for the **Execution Role** confirm `s3:GetObject` and `secretsmanager:GetSecretValue` both come back `implicitDeny` (it should have neither permission at all).

### 7.4 Confirm the Execution Role can't be used for application data access

```bash
EXEC_ROLE_ARN=$(terraform output -raw ecs_task_execution_role_arn)

aws iam simulate-principal-policy \
  --policy-source-arn $EXEC_ROLE_ARN \
  --action-names s3:GetObject secretsmanager:GetSecretValue \
  --resource-arns "*"
```

**Expected result:** both actions `implicitDeny` — proving the two-role split actually holds under test, not just on paper.

---

## 8. Load & Resilience Testing

### 8.1 Basic load test (readiness under load)

```bash
# Apache Bench example -- swap for k6/Gatling/Locust if preferred
ab -n 2000 -c 50 http://$ALB/actuator/health/readiness
```

**Expected result:** 0% failed requests; p99 latency reasonable relative to `task_cpu`/`task_memory` sizing. If failures appear, check `aws ecs describe-services` for throttling/OOM-killed tasks before blaming the load generator.

### 8.2 Rolling deployment with zero downtime

```bash
# In one terminal: continuous polling
while true; do curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://$ALB/actuator/health; sleep 1; done

# In another terminal: force a new deployment (simulates a code release)
aws ecs update-service \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --service $(terraform output -raw ecs_service_name) \
  --force-new-deployment
```

**Expected result:** the polling loop shows an unbroken stream of `200` responses throughout the deployment — this is the deregistration-delay/graceful-shutdown/stopTimeout chain (Section README §4) working end-to-end in a real rolling deployment, not just in isolated Docker tests.

### 8.3 Deployment circuit breaker (rollback proof)

```bash
# Deliberately push a broken image tag (e.g. one that fails health checks) and update the service
aws ecs update-service --cluster <cluster> --service <service> --task-definition <bad-revision>
aws ecs describe-services --cluster <cluster> --services <service> --query 'services[0].deployments'
```

**Expected result:** `deployment_circuit_breaker { enable = true, rollback = true }` (set in `modules/ecs/main.tf`) automatically rolls the service back to the last healthy task definition after repeated health-check failures — confirm via `aws ecs describe-services` showing the deployment `rolloutState` as `FAILED` followed by a new rollback deployment reaching `COMPLETED`.

---

## 9. Cleanup

```bash
cd terraform
terraform destroy
```

**Expected result:** all resources removed in dependency order (ECS service → ALB/target group → NAT Gateways/EIPs → VPC endpoints → subnets/route tables → IGW → VPC; IAM roles/policies detached and deleted). Confirm zero residual cost by checking the AWS Billing console's "NAT Gateway" and "EC2-Other" (ENI/EIP) line items drop to zero for this project's tags.

---

## Quick Reference — Expected Status Codes

| Scenario | Endpoint | Expected |
|---|---|---|
| Healthy app | `GET /actuator/health` | 200 |
| Still starting | `GET /actuator/health/readiness` | 503 (briefly), then 200 |
| Known secret | `GET /api/v1/secrets/{valid}/status` | 200 |
| Unknown secret | `GET /api/v1/secrets/{invalid}/status` | 404 |
| Known S3 key | `GET /api/v1/files/{valid-key}` | 200 |
| Unknown S3 key | `GET /api/v1/files/{invalid-key}` | 404 |
| Empty upload body | `POST /api/v1/files/{key}` (blank body) | 400 |
| AWS service failure (throttling/outage) | any AWS-backed endpoint | 502 |
| Direct task IP, wrong source SG | `GET http://<task-ip>:8080/...` | connection refused/timeout |
