#───────────────────────────────────────────────────────────────────────────────
# Karpenter (EKS only)
#
# Provisions the AWS-side prerequisites for Karpenter node autoscaling:
#   - Controller IAM role (assumed via EKS Pod Identity)
#   - Karpenter node IAM role + EKS access entry (so launched nodes can join)
#   - SQS interruption queue + EventBridge rules (spot/rebalance handling)
#
# The Karpenter Helm chart and the EC2NodeClass/NodePool are installed into the
# cluster by the Kubernetes stack (stacks/kubernetes/scripts/deploy-karpenter.sh),
# driven by the karpenter/config.json object this file publishes to S3.
#───────────────────────────────────────────────────────────────────────────────

module "karpenter" {
  count   = local.is_eks ? 1 : 0
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks[0].cluster_name

  # Karpenter v1.x requires the updated controller permissions.
  enable_v1_permissions = true

  # Use EKS Pod Identity for the controller (no IRSA annotation on the SA needed).
  create_pod_identity_association = true

  # Stable node IAM role name so the EC2NodeClass can reference it by name.
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.run_tag}-karpenter"

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = {
    ClusterType = "eks"
    RunTag      = var.run_tag
  }
}

# Publish everything the in-cluster installer needs to wire up Karpenter.
# Subnets/security group are passed by ID so we don't have to tag the shared
# default-VPC subnets (which would collide across parallel deployments).
resource "aws_s3_object" "karpenter_config" {
  count  = local.is_eks && var.kubeconfig_s3_bucket != "" ? 1 : 0
  bucket = var.kubeconfig_s3_bucket
  key    = "karpenter/config.json"

  content = jsonencode({
    cluster_name           = module.eks[0].cluster_name
    cluster_endpoint       = module.eks[0].cluster_endpoint
    karpenter_version      = var.karpenter_version
    queue_name             = module.karpenter[0].queue_name
    node_iam_role_name     = module.karpenter[0].node_iam_role_name
    node_security_group_id = module.eks[0].node_security_group_id
    subnet_ids             = data.aws_subnets.default_vpc.ids
  })

  server_side_encryption = "AES256"

  depends_on = [module.eks, module.karpenter]
}

output "karpenter_info" {
  value = local.is_eks ? {
    queue_name         = module.karpenter[0].queue_name
    node_iam_role_name = module.karpenter[0].node_iam_role_name
    node_iam_role_arn  = module.karpenter[0].node_iam_role_arn
  } : null
  description = "Karpenter resources (only populated when cluster_type = eks)"
}
