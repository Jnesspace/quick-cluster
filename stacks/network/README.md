# Network Stack

Creates the network the cluster runs in: a VPC, one public subnet, an internet
gateway and its route table. It also creates the EC2 key pair and the S3 bucket
the Ansible and Kubernetes stacks use for the kubeconfig.

## Outputs

| Output | Used by |
|--------|---------|
| `subnet_id` | OpenTofu stack, as `TF_VAR_subnet_id` (stack dependency output reference) |
| `vpc_id` | Informational |

## Inputs

| Variable | Description |
|----------|-------------|
| `TF_VAR_ssh_public_key` | Public half of the SSH key Ansible uses |
| `TF_VAR_aws_private_key_name` | Key pair name, shared with the OpenTofu stack |
| `TF_VAR_kubeconfig_s3_bucket` | Bucket name, shared with the Ansible and Kubernetes stacks |
| `TF_VAR_run_tag` | Name tag for the resources (default `saturn-head`) |
