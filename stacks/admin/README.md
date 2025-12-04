# Admin Stack

The administrative stack that orchestrates the Quick-Cluster deployment. It creates and manages all child stacks, shared resources, and inter-stack dependencies.

## Resources Created

- S3 bucket for kubeconfig storage
- SSH key pair (TLS private key + AWS key pair)
- Spacelift context for SSH key distribution
- Child stacks: OpenTofu, Ansible, Kubernetes
- Stack dependencies and environment variables

## Prerequisites

### AWS Resources

Identify a subnet in your target region:

```bash
export AWS_REGION=eu-west-1

# List subnets in default VPC
aws ec2 describe-subnets \
  --filters "Name=default-for-az,Values=true" \
  --query "Subnets[*].{SubnetId:SubnetId,VpcId:VpcId,AvailabilityZone:AvailabilityZone}" \
  --output table \
  --region $AWS_REGION

# List all VPCs
aws ec2 describe-vpcs \
  --query "Vpcs[*].{VpcId:VpcId,CidrBlock:CidrBlock,IsDefault:IsDefault}" \
  --output table \
  --region $AWS_REGION
```

### Spacelift Resources

- **Space ID**: Spacelift > Spaces > select space > copy ID
- **AWS Integration ID**: Spacelift > Integrations > AWS > copy integration ID

## Configuration

### Required Environment Variables

| Variable | Description |
|----------|-------------|
| `AWS_DEFAULT_REGION` | AWS region for deployment |
| `TF_VAR_aws_default_region` | Same as above (for OpenTofu) |
| `TF_VAR_aws_integration_id` | Spacelift AWS integration ID |
| `TF_VAR_resource_space_id` | Spacelift space ID for child stacks |
| `TF_VAR_subnet_id` | AWS subnet ID for EC2 instances |

### Optional Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TF_VAR_instance_type` | `t3.small` | EC2 instance type |
| `TF_VAR_root_volume_size` | `20` | Root volume size in GB |
| `TF_VAR_worker_pool_id` | `null` | Spacelift worker pool (null = public) |
| `TF_VAR_deploy_private_workers` | `0` | Number of private workers (0-10) |
| `TF_VAR_kubernetes_runner_image` | `public.ecr.aws/o6n6e5l1/jakeskuberneteshelmrunner:latest` | Runner image for Kubernetes stack |

### Stack Requirements

1. **Administrative**: Enable in Settings > Behavior
2. **AWS Integration**: Attach in Settings > Integrations
3. **Repository**: Point to Quick-Cluster repository
4. **Project Root**: Set to `stacks/admin`

## Example Configuration

```bash
AWS_DEFAULT_REGION=eu-west-1
TF_VAR_aws_default_region=eu-west-1
TF_VAR_aws_integration_id=01JAZPBRW3K2YB0K7F58NZSDY6
TF_VAR_resource_space_id=quick-01JZR5VAZ8P96ZPJ10SZW3XJT4
TF_VAR_subnet_id=subnet-091efd76f6357ee16
```

## Blueprint Usage

When deployed via the Spacelift Blueprint, `TF_VAR_run_tag` is automatically set to ensure all stacks share a unique prefix for isolation.
