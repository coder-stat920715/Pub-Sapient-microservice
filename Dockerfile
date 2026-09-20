# syntax=docker/dockerfile:1.7

##############################################################################
# STAGE 1: BUILD
# Uses a full JDK + Maven image, discarded entirely from the final image.
##############################################################################
FROM maven:3.9.9-eclipse-temurin-21-alpine AS build

WORKDIR /workspace

# Copy only the POM first to let Docker cache the dependency layer
# independently of source code changes.
COPY pom.xml .
RUN mvn -B dependency:go-offline

COPY src ./src
RUN mvn -B clean package -DskipTests \
    && mv target/microservice.jar target/app.jar

##############################################################################
# STAGE 2: RUNTIME
# Minimal JRE-only Alpine image. No shell utilities beyond busybox, no build
# tooling, no Maven -- drastically reduced attack surface vs. the build image.
##############################################################################
FROM eclipse-temurin:21-jre-alpine AS runtime

# Security hardening: run as a fixed, non-root, unprivileged UID/GID.
# UID 10001 is arbitrary but must be > 10000 to avoid colliding with any
# system account, and is referenced explicitly (not "nobody") so Kubernetes/
# ECS admission controls that require a numeric non-root UID are satisfied.
RUN addgroup -g 10001 appgroup \
    && adduser -D -u 10001 -G appgroup appuser

WORKDIR /app

COPY --from=build --chown=10001:10001 /workspace/target/app.jar ./app.jar

# Drop to the non-root user for every subsequent instruction and at runtime.
USER 10001

EXPOSE 8080

# JVM flags tuned for containerized/Fargate execution:
#  -XX:+UseContainerSupport   -> JVM reads cgroup limits, not host limits,
#                                 to size default thread pools/GC heuristics
#  -XX:MaxRAMPercentage=75.0  -> heap capped at 75% of the CONTAINER memory
#                                 limit (not host memory), leaving headroom
#                                 for thread stacks, metaspace, and the
#                                 native AWS SDK HTTP client buffers
#  -XX:+ExitOnOutOfMemoryError-> fail fast and let ECS restart the task
#                                 rather than limp along in a corrupted state
#  -XX:+UseG1GC               -> low-pause collector, a good default for a
#                                 request/response web service
ENV JAVA_OPTS="-XX:+UseContainerSupport \
    -XX:MaxRAMPercentage=75.0 \
    -XX:InitialRAMPercentage=50.0 \
    -XX:+UseG1GC \
    -XX:+ExitOnOutOfMemoryError \
    -Djava.security.egd=file:/dev/./urandom"

# exec form + sh -c so JAVA_OPTS expands, and exec replaces the shell as
# PID 1 so SIGTERM from ECS reaches the JVM directly (no signal swallowing).
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar app.jar"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD wget -q --spider http://localhost:8080/actuator/health/liveness || exit 1
