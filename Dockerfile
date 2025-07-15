# Dockerfile
# Custom Spacelift CI image: Alpine base with AWS CLI and kubectl

ARG BASE_IMAGE=alpine:3.21
FROM ${BASE_IMAGE} AS base

# Common dependencies
RUN apk update && apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    openssh-client \
    python3 \
    tzdata \
  && ln -sf /usr/bin/python3 /usr/bin/python

# AWS CLI stage (from Spacelift official image)
FROM base AS aws
COPY --from=ghcr.io/spacelift-io/aws-cli-alpine /usr/local/aws-cli/ /usr/local/aws-cli/
COPY --from=ghcr.io/spacelift-io/aws-cli-alpine /aws-cli-bin/     /usr/local/bin/

# Final image with kubectl
FROM aws AS final

# Install kubectl (latest stable)
RUN curl -Lo kubectl "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin/

# Verify installations
RUN aws --version \
    && kubectl version --client --short

# Create unprivileged 'spacelift' user
RUN adduser -D -u 1983 spacelift \
    && mkdir -p /home/spacelift \
    && chown spacelift:spacelift /home/spacelift

USER spacelift
WORKDIR /home/spacelift
