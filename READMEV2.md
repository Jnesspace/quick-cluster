# Quick Cluster - K3s on AWS with Spacelift

Deploy a 3-node K3s cluster on AWS in ~15 minutes using OpenTofu + Ansible via Spacelift.

## What You Get
- **3-node K3s cluster** (1 control plane + 2 workers) on AWS EC2
- **Ready-to-use kubeconfig** for immediate access
- **Automatic networking** and security groups
- **GitOps workflow** through Spacelift

## Prerequisites
- AWS Account + Spacelift Account
- Fork this repo
- AWS CLI configured

## Setup

### 1. Get AWS Info
```bash
export AWS_REGION=eu-west-1
aws ec2 describe-subnets --filters "Name=default-for-az,Values=true" --query "Subnets[0].SubnetId" --output text --region $AWS_REGION
```
Save the **subnet ID** and **region**.

### 2. Create Spacelift Context
1. **Spacelift → Integrations → AWS** - Create integration, copy ID
2. **Spacelift → Contexts** - Create `quick-cluster-context` with:
   - `AWS_DEFAULT_REGION` = your region
   - `TF_VAR_aws_default_region` = same region  
   - `TF_VAR_aws_integration_id` = your integration ID
   - `TF_VAR_subnet_id` = your subnet ID

### 3. Create Admin Stack
1. **Spacelift → Stacks → Add stack**
2. Configure:
   - **Name**: `quick-cluster`
   - **Repository**: Your forked repo
   - **Project root**: `stacks/admin`
   - **Administrative**: ✅ Enable
   - **AWS Integration**: ✅ Attach
   - **Context**: ✅ Attach `quick-cluster-context`

### 4. Deploy
Click **"Trigger run"** and wait ~10 minutes. The admin stack automatically:
- **Creates SSH keys** → Generates RSA key pair for EC2 access
- **Creates AWS key pair** → Imports public key to AWS as "ssh_example_tofu_ansible"
- **Creates SSH context** → Mounts private key at `/mnt/workspace/spacelift.pem`
- **Creates child stacks** → OpenTofu Stack + Ansible Stack with SSH context attached
- **Provisions infrastructure** → 3 EC2 instances + security groups + S3 bucket

### 5. Access Cluster
```bash
# Download kubeconfig from S3 (bucket name in admin stack outputs)
aws s3 cp s3://YOUR_BUCKET_NAME/kubeconfig-latest.yaml ~/.kube/config

# Test cluster
kubectl get nodes
```

## How SSH Keys Work
The admin stack handles all SSH key management automatically:

1. **Generates RSA key pair** (4096-bit) using Terraform `tls_private_key` resource
2. **Creates AWS key pair** named `ssh_example_tofu_ansible` in your AWS account
3. **Creates Spacelift context** called `tofusible-ssh-key` with the private key
4. **Mounts private key** at `/mnt/workspace/spacelift.pem` in child stacks
5. **Attaches SSH context** to OpenTofu and Ansible stacks automatically

No manual SSH key creation or management required - it's all handled by the admin stack!

## Cleanup
Go to **OpenTofu Stack** → **Trigger run** → **Destroy**

---
**🎯 Total time**: ~15 minutes | **🛠️ Need help?** Check the logs in your Spacelift stacks