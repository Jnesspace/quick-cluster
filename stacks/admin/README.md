# The Admin Stack

This admin stack creates the OpenTofu and Ansible stacks as well as creates the stack dependency between them.
This is not _super_ necessary but it makes explaining all the parts of the process easier because you can see how the ansible and the opentofu stacks are configured.

Feel free to look at the OpenTofu files in this stack to see how the child stacks should be configured.

## Prerequisites

Before setting up this stack, you'll need to gather some information from your AWS account and Spacelift environment.

### Finding Your AWS Resources

Use these AWS CLI commands to find the required values for your environment:

```bash
# Set your desired AWS region
export AWS_REGION=eu-west-1  # Change to your preferred region

# Find available subnets in your default VPC
aws ec2 describe-subnets \
  --filters "Name=default-for-az,Values=true" \
  --query "Subnets[*].{SubnetId:SubnetId,VpcId:VpcId,AvailabilityZone:AvailabilityZone,CidrBlock:CidrBlock}" \
  --output table \
  --region $AWS_REGION

# Or find subnets in a specific VPC
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=vpc-xxxxxxxxx" \
  --query "Subnets[*].{SubnetId:SubnetId,AvailabilityZone:AvailabilityZone,CidrBlock:CidrBlock}" \
  --output table \
  --region $AWS_REGION

# List your VPCs to find the right one
aws ec2 describe-vpcs \
  --query "Vpcs[*].{VpcId:VpcId,CidrBlock:CidrBlock,IsDefault:IsDefault,Tags:Tags[?Key=='Name'].Value|[0]}" \
  --output table \
  --region $AWS_REGION
```

## Spin this thing up

You can create an admin stack and point it to this directory and it will setup the whole `tofusible` show so you can see how it works.

### Admin stack configuration

You need to configure this admin stack to match your environment and your AWS account.

When setting up the admin stack, the following environment variables should be added to it:

- `AWS_DEFAULT_REGION` - The region you want to deploy to (e.g., `eu-west-1`)
- `TF_VAR_aws_default_region` - This should match the above variable
- `TF_VAR_aws_integration_id` - The AWS Integration ID from your Spacelift account
- `TF_VAR_resource_space_id` - The Space ID where you want to create the child stacks
- `TF_VAR_subnet_id` - A subnet ID from your AWS account (use the AWS CLI commands above)
- `TF_VAR_run_tag` - Unique tag for this deployment; ensures all stacks share the same prefix (automatically set by the Blueprint)

**Note:** The security group is now created automatically by the OpenTofu stack, so you don't need to specify one.

> **Blueprint Note:**
> If you use the Blueprint, `TF_VAR_run_tag` is set for you and all stacks will share the same unique prefix for isolation and collision avoidance.

### Finding Your Spacelift IDs

To find your Spacelift-specific values:

1. **Space ID**: Go to Spacelift → Spaces → Copy the ID from your desired space
2. **AWS Integration ID**: Go to Spacelift → Integrations → AWS → Copy the integration ID
3. **Worker Pool**: The stack uses the public worker pool by default (set to `null`)

### Required Stack Settings

The admin stack must be configured as follows:

1. ✅ **Administrative Stack**: Enable this in Settings → Behavior
2. ✅ **AWS Integration**: Attach your AWS integration in Settings → Integrations
3. ✅ **Repository**: Point to your `Quick-Cluster` repository
4. ✅ **Project Root**: Set to `stacks/admin`

### Example Environment Variables

```bash
AWS_DEFAULT_REGION=eu-west-1
TF_VAR_aws_default_region=eu-west-1
TF_VAR_aws_integration_id=01JAZPBRW3K2YB0K7F58NZSDY6
TF_VAR_resource_space_id=quick-01JZR5VAZ8P96ZPJ10SZW3XJT4
TF_VAR_subnet_id=subnet-091efd76f6357ee16
```

You can see an example of this stack being stood up in our demo environment [here](https://github.com/spacelift-solutions/demo/blob/main/admin/stacks_opentofu_spacelift.tf#L1) (just note we're using the default variables in the demo environment, so you'd still need to add those).