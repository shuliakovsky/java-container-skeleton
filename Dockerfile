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
