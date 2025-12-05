#───────────────────────────────────────────────────────────────────────────────
# EKS Cluster Configuration
# Only created when cluster_type = "eks"
#───────────────────────────────────────────────────────────────────────────────

module "eks" {
  count   = local.is_eks ? 1 : 0
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.run_tag}-eks"
  cluster_version = "1.28"

  # Networking
  vpc_id     = local.vpc_id_final
  subnet_ids = data.aws_subnets.default_vpc.ids

  # Cluster access
  cluster_endpoint_public_access = true

  # Enable IRSA for service accounts
  enable_irsa = true

  # Managed node groups (similar to k3s 3-node setup)
  eks_managed_node_groups = {
    default = {
      name           = "${var.run_tag}-nodes"
      instance_types = [var.instance_type]

      min_size     = 3
      max_size     = 3
      desired_size = 3

      disk_size = var.root_volume_size

      # Use the same AMI type as k3s (AL2023 is the modern default)
      ami_type = "AL2023_x86_64_STANDARD"

      labels = {
        Environment = "dev"
        ClusterType = "eks"
      }

      tags = {
        Environment = "dev"
        ClusterType = "eks"
      }
    }
  }

  # Cluster addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  tags = {
    Environment = "dev"
    ClusterType = "eks"
    RunTag      = var.run_tag
  }
}

#───────────────────────────────────────────────────────────────────────────────
# Generate kubeconfig and upload to S3
# This allows the Kubernetes stack to use the same flow as k3s
#───────────────────────────────────────────────────────────────────────────────

resource "local_file" "eks_kubeconfig" {
  count    = local.is_eks ? 1 : 0
  filename = "${path.module}/kubeconfig-eks.yaml"

  content = <<-KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${module.eks[0].cluster_endpoint}
    certificate-authority-data: ${module.eks[0].cluster_certificate_authority_data}
  name: ${module.eks[0].cluster_name}
contexts:
- context:
    cluster: ${module.eks[0].cluster_name}
    user: ${module.eks[0].cluster_name}
  name: ${module.eks[0].cluster_name}
current-context: ${module.eks[0].cluster_name}
users:
- name: ${module.eks[0].cluster_name}
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws
      args:
        - eks
        - get-token
        - --cluster-name
        - ${module.eks[0].cluster_name}
        - --region
        - ${var.aws_default_region}
KUBECONFIG

  depends_on = [module.eks]
}

# Upload kubeconfig to S3 (same location as k3s uses)
resource "aws_s3_object" "eks_kubeconfig" {
  count  = local.is_eks && var.kubeconfig_s3_bucket != "" ? 1 : 0
  bucket = var.kubeconfig_s3_bucket
  key    = "kubeconfig-latest.yaml"
  source = local_file.eks_kubeconfig[0].filename

  depends_on = [local_file.eks_kubeconfig]
}

#───────────────────────────────────────────────────────────────────────────────
# EKS Outputs
#───────────────────────────────────────────────────────────────────────────────

output "eks_info" {
  value = local.is_eks ? {
    cluster_name                   = module.eks[0].cluster_name
    cluster_endpoint               = module.eks[0].cluster_endpoint
    cluster_version                = module.eks[0].cluster_version
    cluster_security_group_id      = module.eks[0].cluster_security_group_id
    node_security_group_id         = module.eks[0].node_security_group_id
    cluster_iam_role_arn           = module.eks[0].cluster_iam_role_arn
    oidc_provider_arn              = module.eks[0].oidc_provider_arn
    cluster_certificate_authority  = module.eks[0].cluster_certificate_authority_data
  } : null
  description = "EKS cluster information (only populated when cluster_type = eks)"
}

output "eks_node_groups" {
  value = local.is_eks ? {
    for k, v in module.eks[0].eks_managed_node_groups : k => {
      node_group_id          = v.node_group_id
      node_group_arn         = v.node_group_arn
      node_group_status      = v.node_group_status
      node_group_autoscaling_group_names = v.node_group_autoscaling_group_names
    }
  } : {}
  description = "EKS managed node groups information"
}
