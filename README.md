# Java Application Kubernetes Container with OOM Dumping and S3 Backup

This repository demonstrates how to run a Java application inside a Kubernetes-compatible container with dynamic memory tuning and automatic dump capture on Out-Of-Memory (OOM) before the pod is killed. When the JVM hits an OOM error, thread and heap dumps are generated, bundled, and uploaded to an external S3 bucket for post-mortem analysis.

The solution is based on two artifacts: a `docker-entrypoint.sh` script that detects cgroup limits, computes JVM options, and handles dump creation; and a Dockerfile that assembles the runtime image with all necessary tools and libraries.

---

## Features

- Automatic detection of container memory limit via cgroups v1/v2  
- JVM heap and off-heap sizing calculated as percentages of available RAM  
- OnOutOfMemoryError hook that:
  - Generates thread dumps (`jattach` + `jcmd`)  
  - Generates heap dumps (`jattach` + `jcmd`)  
  - Archives all dumps into a timestamped tar.gz  
  - Uploads archive to S3 (configurable bucket/prefix)  
  - Force-kills the Java process to allow Kubernetes to restart the pod  

- Non-root container setup for improved security  
- Alpine-based runtime with minimal footprint  

---

## Requirements

- An AWS S3 bucket with write permissions  
- Environment variables:

  | Variable               | Description                                 |
  |------------------------|---------------------------------------------|
  | `S3_BUCKET_BACKUP`     | Name of the S3 bucket for storing dumps     |
  | `TAG_APPLICATION_NAME` | Application name or tag used in dump paths  |
  | `PROFILE`              | Spring profile (default: prod)              |
  | `ARTIFACT_NAME`        | Name of the JAR artifact to execute         |
  | AWS credentials        | Provided via mounted volume or IAM role     |

---

## How It Works

1. At container startup, `docker-entrypoint.sh` reads the cgroup memory limit (v1 or v2).  
2. JVM flags (`-Xms`, `-Xmx`, `-XX:MaxMetaspaceSize`, etc.) are calculated based on percentages of that limit.  
3. The Java application is launched with:
   - `-XX:+HeapDumpOnOutOfMemoryError`
   - `-XX:OnOutOfMemoryError="/docker-entrypoint.sh makedump %p"`
4. On OOM, the entrypoint script runs in “makedump” mode and:
   - Generates thread dumps and heap dumps via `jattach` and `jcmd`
   - Archives the dump files into `/tmp/<host>-<timestamp>.dump.tar.gz`
   - Uploads the archive to `s3://<S3_BUCKET_BACKUP>/JAVA_APP_DUMPS/<TAG_APPLICATION_NAME>/`
   - Kills the Java process so Kubernetes can restart the container

---

## Usage

1. Build the Docker image:
   ```bash
   docker build \
     --build-arg PROFILE=prod \
     --build-arg ARTIFACT_NAME=myapp.jar \
     -t myorg/java-app-with-dump:latest .
   ```
2. Inject AWS credentials (via Secret, volume, or IAM role) and set S3_BUCKET_BACKUP and TAG_APPLICATION_NAME in your Kubernetes manifest.
3. Deploy the pod. When the JVM triggers an OOM, the dumps will land in your S3 bucket before the pod is terminated.

## Dockerfile
  ```Dockerfile
# Actual container when arch=linux/amd64
FROM eclipse-temurin:24-jdk-alpine AS final

# Define build arguments
ARG TARGETARCH
ARG TARGETPLATFORM
ARG BUILDPLATFORM
ARG PROFILE=prod

# Set environment variables
ENV PROFILE=${PROFILE}
ENV ARTIFACT_NAME=valueComesFromPipeline
ENV APP_HOME=/usr/app/
ENV HOME=/usr/app

# Copy working directory
WORKDIR $APP_HOME

# Copy application JAR and scripts
COPY build/libs/$ARTIFACT_NAME .
COPY ./docker-entrypoint.sh /docker-entrypoint.sh
COPY ./dump /usr/local/sbin/dump

# Install dependencies, setup permissions, and user
RUN apk update && \
    apk upgrade && \
    apk add jattach aws-cli py3-boto3 coreutils libc6-compat rsync curl postgresql-client bash openssl git py3-pip gcc jq --no-cache  && \
    mkdir -p /nonexistent $HOME/.aws && \
    chmod a+x /docker-entrypoint.sh /usr/local/sbin/dump && \
    chown -R nobody:nogroup $APP_HOME /nonexistent $HOME/.aws /docker-entrypoint.sh /usr/local/sbin/dump && \
    rm -rf /var/cache/apk/*

# Switch to non-root user
USER nobody
# Set entrypoint and expose port
ENTRYPOINT ["/docker-entrypoint.sh"]
EXPOSE 8080
```
## `docker-entrypoint.sh` Overview

- **Memory limit detection**  
  Uses `/sys/fs/cgroup` v1 or v2 files to determine the container’s RAM limit in MiB.

- **JVM options calculation**  
  Sets `Xms` at 30% and `Xmx` at 60% of available memory, plus fixed caps for metaspace, direct memory, CodeCache, and thread stack.

- **OOM dump handler**  
  A `makedump` function invoked by `-XX:OnOutOfMemoryError`, which:
  - Invokes `jattach` and `jcmd` to collect dumps  
  - Archives with `tar`  
  - Uploads to S3 via `aws s3 cp`  
  - Kills the JVM process to let Kubernetes restart

## License
This project is licensed under the MIT License.
