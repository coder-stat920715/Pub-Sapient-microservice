# Publicis Sapient — Senior Microservices & Cloud Engineer Reference Build

A production-grade Spring Boot 3 microservice deployed on ECS Fargate, behind
an ALB, inside a custom two-AZ VPC, provisioned entirely with modular
Terraform.

## Folder structure

```
Spring-microservice/
├── terraform/
│   ├── main.tf                       # root module wiring
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── vpc/                      # VPC, subnets, IGW, NAT, endpoints
│       ├── security-groups/          # ALB SG -> ECS Task SG chaining
│       ├── iam/                      # Task Execution Role vs Task Role
│       └── ecs/                      # ALB, target group, cluster, service
├── src/main/java/com/souptik/microservice/
│   ├── Application.java
│   ├── config/
│   │   ├── AwsConfig.java            # S3Client / SecretsManagerClient beans
│   │   └── WebConfig.java            # Tomcat connector tuning
│   ├── controller/
│   │   ├── SecretController.java
│   │   └── S3Controller.java
│   ├── service/
│   │   ├── SecretsManagerService.java
│   │   └── S3StorageService.java
│   └── exception/
│       ├── GlobalExceptionHandler.java
│       ├── ResourceNotFoundException.java
│       └── ErrorResponse.java
├── src/main/resources/
│   ├── application.yml
│   └── application-prod.yml
├── pom.xml
├── Dockerfile
└── .dockerignore
```

## How to run it

```bash
# Build & test locally
mvn clean package
docker build -t Spring-svc:local .
docker run -p 8080:8080 \
  -e AWS_REGION=us-east-1 \
  -e APP_S3_BUCKET_NAME=my-bucket \
  -e APP_SECRET_NAME=my-secret \
  Spring-svc:local

# Provision infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit values
terraform init
terraform plan
terraform apply
```

---

## Architectural defense — talking points for the interview

### 1. ECS Task Execution Role vs. ECS Task Role

These are two distinct IAM roles solving two distinct problems, and
conflating them is one of the most common ECS security mistakes:

- **Task Execution Role** is assumed by the **ECS agent** (control plane),
  before your container even starts. Its only job is to let the agent pull
  the image from ECR and stream container logs to CloudWatch. In this build
  it's scoped to one ECR repository ARN and one log group ARN — it has zero
  visibility into application data (no S3, no Secrets Manager).
- **Task Role** is assumed by **your application code** at runtime via the
  AWS SDK, using credentials delivered through the ECS container credentials
  endpoint (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`). This is what the
  Spring Boot app actually uses to call S3 and Secrets Manager, and it's
  scoped to exactly one bucket ARN and one secret ARN — no wildcards.

**Why it matters:** if an attacker achieves code execution inside the
container, they inherit the Task Role's permissions, never the Execution
Role's. Keeping the Execution Role minimal means a compromised task still
can't push arbitrary images or exfiltrate via broader log/ECR permissions.
Keeping the Task Role scoped to specific ARNs means a compromised task can't
pivot to other buckets or secrets in the same account.

### 2. VPC Endpoints vs. NAT Gateway routing

- **Cost:** NAT Gateway bills per-GB processed plus an hourly charge; every
  byte the app writes to S3/Secrets Manager through a NAT Gateway is billed
  twice (NAT processing + inter-AZ, if applicable). A **Gateway Endpoint**
  for S3 is free and adds a route-table entry only — no ENI, no hourly
  charge, no per-GB charge. An **Interface Endpoint** (Secrets Manager, ECR,
  CloudWatch Logs) does have an hourly + per-GB cost, but it's typically far
  lower than the equivalent NAT-routed traffic at any real scale, and it
  removes that traffic from the NAT Gateway's bandwidth ceiling entirely.
- **Security:** traffic to S3/Secrets Manager over an endpoint never leaves
  the AWS network backbone — it doesn't transit the Internet Gateway, isn't
  visible to internet-based traffic inspection, and can be further locked
  down with an endpoint policy (e.g. "only this bucket, only from this VPC").
  A NAT Gateway route, by contrast, sends that traffic out to the public
  service endpoint, relying purely on IAM and TLS for protection.
- **Blast radius:** this build also removes ECR and CloudWatch Logs traffic
  from the NAT path via Interface Endpoints, meaning the private subnets'
  NAT Gateway carries only genuinely "must egress to the public internet"
  traffic (e.g. calling a third-party API) — everything AWS-native goes over
  PrivateLink.
- I'd still defend keeping the NAT Gateway (rather than removing it
  entirely): it's the escape hatch for anything the endpoint list doesn't
  cover, and fully "endpoint-only, no NAT" designs are brittle whenever a new
  AWS service or third-party dependency shows up.

### 3. Security Group ingress rules — stateful firewalls vs. NACLs

- **Security Groups are stateful and instance/ENI-scoped.** I only need to
  define the *inbound* rule (ALB SG: 80/443 from `0.0.0.0/0`; ECS Task SG:
  8080 **from the ALB Security Group ID**, not a CIDR). The return traffic is
  automatically permitted — I never write a matching outbound rule for a
  response.
- **The ECS Task SG's source is the ALB SG's ID, not a CIDR block.** This is
  "security group chaining": as the ALB's ENIs scale up/down or get replaced,
  the rule stays correct with zero maintenance, and — critically — nothing
  outside that specific ALB (not even something else inside the VPC) can
  reach port 8080 on the tasks.
- **NACLs are stateless and subnet-scoped**, evaluated before security
  groups, and require explicit inbound *and* outbound rules (including for
  ephemeral return-traffic ports). I use the default "allow all" NACL here
  and let Security Groups do the enforcement — introducing custom NACLs
  would be the next layer I'd reach for if this needed defense-in-depth
  beyond SGs (e.g. explicitly blocking a known-bad CIDR range at the subnet
  boundary regardless of SG misconfiguration).

### 4. Spring Boot container awareness & graceful shutdown in ECS target groups

Getting zero-downtime deployments right requires every layer of the stack to
agree on timing, in this order:

1. ECS marks the task `DRAINING` and deregisters it from the target group.
2. The ALB stops routing *new* requests to it but — governed by
   `deregistration_delay` (30s here) — keeps the target reachable long enough
   for in-flight requests to finish.
3. ECS sends **SIGTERM** to the container's PID 1. Because the Dockerfile
   entrypoint uses `exec java ...` (not a bare `java ...` inside an
   unexeced shell), the JVM itself is PID 1 and receives the signal directly.
4. Spring's `server.shutdown=graceful` intercepts SIGTERM: the embedded
   Tomcat connector stops accepting new connections, and existing requests
   are allowed to complete, up to `spring.lifecycle.timeout-per-shutdown-phase`
   (30s).
5. If the JVM hasn't exited by the task definition's `stopTimeout` (40s —
   deliberately greater than Spring's 30s budget), ECS sends **SIGKILL**.

I also set `-XX:+UseContainerSupport` and `-XX:MaxRAMPercentage=75.0`
explicitly (belt-and-suspenders — they're default-on since JDK 11+, but I
state them for interview clarity and because some base images/flags can
still override the defaults): the JVM must read the **cgroup memory limit**
Fargate applies to the task, not the underlying host's total memory, or it
will size its heap far too large and get OOM-killed by the container runtime
instead of by its own GC. `-XX:+ExitOnOutOfMemoryError` ensures that if the
JVM does hit a real OOM, it exits immediately and lets ECS's health checks
and deployment circuit breaker restart the task, rather than continuing to
run in a degraded, unpredictable state.

Finally, Actuator's **split liveness/readiness probes** map cleanly onto two
different consumers: the container-level `HEALTHCHECK` in the Dockerfile
(and ECS's own container health check) hits `/actuator/health/liveness` —
"is the JVM alive at all" — while the **ALB target group** hits
`/actuator/health/readiness` — "is this instance ready to serve traffic,
including its dependencies." Splitting these means a task that's alive but
not yet ready (e.g. still initializing the Spring context) gets skipped by
the load balancer without being killed and restarted by ECS.
