# Admin Stack

The Admin stack orchestrates OpenTofu, Ansible, and Kubernetes stacks, and configures shared resources such as the S3 bucket for kubeconfig and an SSH key context. It is intended to be run as an Administrative stack in Spacelift.

## Prerequisites

- AWS account and region
- Spacelift AWS integration ID
- Target Spacelift space for child stacks
- Subnet ID in the target VPC

Useful AWS commands to retrieve inputs:

```bash
export AWS_REGION=eu-west-1
aws ec2 describe-subnets \
  --filters "Name=default-for-az,Values=true" \
  --query "Subnets[*].{SubnetId:SubnetId,VpcId:VpcId,AvailabilityZone:AvailabilityZone,CidrBlock:CidrBlock}" \
  --output table \
  --region $AWS_REGION

aws ec2 describe-vpcs \
  --query "Vpcs[*].{VpcId:VpcId,CidrBlock:CidrBlock,IsDefault:IsDefault,Tags:Tags[?Key=='Name'].Value|[0]}" \
  --output table \
  --region $AWS_REGION
```

## Configuration in Spacelift

Set the following environment variables and inputs on the Admin stack:

- `AWS_DEFAULT_REGION`
- `TF_VAR_aws_default_region`
- `TF_VAR_aws_integration_id`
- `TF_VAR_resource_space_id`
- `TF_VAR_subnet_id`
- `TF_VAR_run_tag` (automatically set by the blueprint when used)

Enable the stack as Administrative and attach the AWS integration. Set Project Root to `stacks/admin`.

## Behavior

The Admin stack:

- Creates or selects an S3 bucket for kubeconfig artifacts
- Creates an SSH key context used by child stacks
- Creates and configures OpenTofu, Ansible, and Kubernetes stacks, wiring outputs to inputs

## Outputs

- S3 bucket name containing `kubeconfig-latest.yaml`
- Identifiers for child stacks and resources as applicable
