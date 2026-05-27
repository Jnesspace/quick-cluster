FROM public.ecr.aws/spacelift/runner-terraform:latest
WORKDIR /tmp
# Temporarily elevating permissions
USER root

# Install spacectl
RUN apk add yq-go

# Back to the restricted "spacelift" user
USER spacelift