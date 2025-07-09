# Tofusible K3s Cluster

Tofusible is a simple and easy-to-use OpenTofu module and Ansible dynamic inventory (\[Open]**Tofu**\[An]**sible**) made specifically for using OpenTofu with Ansible in Spacelift to deploy K3s Kubernetes clusters.

It allows you to create virtual machines in OpenTofu (or Terraform) with any provider you wish and automatically deploys a K3s cluster using Ansible, outputting the kubeconfig for immediate access.

## What This Deploys

- **3 EC2 instances** running Ubuntu 22.04 LTS
- **K3s Kubernetes cluster** with 1 server node and 2 agent nodes
- **Automatic security group** with all necessary K3s ports
- **Complete kubeconfig** output for immediate cluster access

## Quick Start

### Prerequisites

Before deploying, you'll need to gather some information from your AWS account:

```bash
# Set your desired AWS region
export AWS_REGION=eu-west-1  # Change to your preferred region

# Find a subnet to deploy your instances in
aws ec2 describe-subnets \
  --filters "Name=default-for-az,Values=true" \
  --query "Subnets[*].{SubnetId:SubnetId,VpcId:VpcId,AvailabilityZone:AvailabilityZone}" \
  --output table \
  --region $AWS_REGION

# List your VPCs if you need to find a specific one
aws ec2 describe-vpcs \
  --query "Vpcs[*].{VpcId:VpcId,CidrBlock:CidrBlock,IsDefault:IsDefault,Tags:Tags[?Key=='Name'].Value|[0]}" \
  --output table \
  --region $AWS_REGION
```

### Deploy with Spacelift

1. **Create an admin stack** in Spacelift pointing to `stacks/admin`
2. **Mark it as Administrative** in Settings → Behavior
3. **Attach AWS integration** in Settings → Integrations
4. **Set environment variables** (see `stacks/admin/README.md` for details)
5. **Deploy** - it will automatically create OpenTofu and Ansible child stacks

The setup will create a 3-node K3s cluster and output the kubeconfig for immediate use.

### Access Your Cluster

After deployment, the Ansible playbook will output the complete kubeconfig. Save it to access your cluster:

```bash
# Save the kubeconfig from the Ansible output
echo "KUBECONFIG_CONTENT_HERE" > ~/.kube/config

# Test cluster access
kubectl get nodes
kubectl get pods -A
```

## How It Works

This repository serves as both the source for the Tofusible OpenTofu module and Ansible Dynamic inventory as well as an example of how to use it.
Each directory contains a `README.md` file with instructions on how to use the module or inventory and all the files within are commented to a high degree to help you understand what is happening.
Feel free to dig around in this repository to see how it works and how you can use it in your own projects.

### High Level Overview

From a high level, the process is as follows:
1. You create virtual machines with OpenTofu - using the provider natively
   - The examples included in this repository use `aws_ec2_instance`'s as examples, but you are not limited to this provider.
2. You use the `tofusible_host` module to gather information about the virtual machines you created.
3. You output the `tofusible_host`s as a list of hosts in OpenTofu (using native OpenTofu outputs).
4. You use the [Spacelift stack dependency](https://docs.spacelift.io/concepts/stack/stack-dependencies#stack-dependencies) feature to pass the output to an Ansible stack.
5. The ansible stack uses the `tofusible` dynamic inventory plugin to read that output and generate a dynamic inventory based off it.
6. Ansible then uses that dynamic inventory to configure the virtual machines you created.

### Directory Structure

This example/source repo has many directories in it, browse around to each directory and check out their README's to see how they work and what they are doing.

- `modules/tofusible_host` - The OpenTofu module that gathers information about the virtual machines you created.
- `stacks/admin` - The Spacelift admin stack that sets up the OpenTofu and Ansible stacks as well as creates the stack dependency between them.
- `stacks/tofu` - The OpenTofu stack that creates the virtual machines.
- `stacks/ansible` - The Ansible stack that configures the virtual machines.
  - This directory also has an `inventory_plugins` directory that contains the `tofusible.py` dynamic inventory plugin.

