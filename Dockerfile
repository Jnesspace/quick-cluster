FROM public.ecr.aws/spacelift/runner-terraform:latest
WORKDIR /tmp
# Temporarily elevating permissions
USER root

# Install spacectl
RUN apk add spacectl --repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing

# Install Helm
RUN apk add --no-cache curl bash openssl && \
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Back to the restricted "spacelift" user
USER spacelift