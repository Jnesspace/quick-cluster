#───────────────────────────────────────────────────────────────────────────────
# EKS Cluster Configuration
# Only created when cluster_type = "eks"
#───────────────────────────────────────────────────────────────────────────────

module "eks" {
  count   = local.is_eks ? 1 : 0
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${var.run_tag}-eks"
  cluster_version = var.eks_cluster_version

  # Networking
  vpc_id     = local.vpc_id_final
  subnet_ids = data.aws_subnets.default_vpc.ids

  # Cluster access - enable both API and ConfigMap for flexibility.
  # Keep the private endpoint on; restrict who can reach the public endpoint via
  # eks_public_access_cidrs (default open so public Spacelift workers still work —
  # narrow it to your worker egress / admin IPs to harden).
  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = var.eks_public_access_cidrs
  authentication_mode                  = "API_AND_CONFIG_MAP"

  # Grant admin access to the IAM role used by Spacelift
  # This creates an access entry for the role that creates the cluster,
  # allowing all stacks using the same AWS integration to access the cluster
  enable_cluster_creator_admin_permissions = true

  # Optionally grant a human/operator IAM principal cluster-admin so they can
  # reach the cluster with kubectl/Freelens after deploy (the creator entry above
  # only covers the Spacelift integration role). Set eks_admin_principal_arn to
  # your IAM user/role ARN.
  access_entries = var.eks_admin_principal_arn != "" ? {
    operator = {
      principal_arn = var.eks_admin_principal_arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  } : {}

  # Enable IRSA for service accounts
  enable_irsa = true

  # Disable CloudWatch logging (control plane logs disabled)
  cluster_enabled_log_types = []

  # Small managed "system" node group that bootstraps Karpenter and runs system
  # pods (coredns, the Karpenter controller, monitoring operators). Actual
  # workload capacity is provided elastically by Karpenter (see karpenter.tf), so
  # this group stays intentionally small.
  eks_managed_node_groups = {
    system = {
      name           = "${var.run_tag}-system"
      instance_types = [var.eks_system_instance_type]

      # Use a fixed (short) role name; the module's default name_prefix
      # "<run_tag>-system-eks-node-group-" can exceed AWS's 38-char prefix limit.
      iam_role_use_name_prefix = false
      iam_role_name            = "${var.run_tag}-system-ng"

      min_size     = 2
      max_size     = 3
      desired_size = 2

      ami_type = "AL2023_x86_64_STANDARD"

      # Encrypted root volume (don't rely on account-level "encrypt by default").
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.root_volume_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # Enforce IMDSv2 (the module defaults to this, but be explicit).
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
        instance_metadata_tags      = "disabled"
      }

      labels = {
        Environment               = "dev"
        ClusterType               = "eks"
        "karpenter.sh/controller" = "true"
      }

      tags = {
        Environment = "dev"
        ClusterType = "eks"
      }
    }
  }

  # Cluster addons. eks-pod-identity-agent powers EKS Pod Identity (used by
  # Karpenter and the EBS CSI driver); aws-ebs-csi-driver provides dynamic
  # EBS-backed PersistentVolumes (needed by kube-prometheus-stack and the
  # self-hosted Spacelift chart's in-cluster MinIO/Postgres).
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
    eks-pod-identity-agent = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi[0].arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
  }

  tags = {
    Environment = "dev"
    ClusterType = "eks"
    RunTag      = var.run_tag
  }
}

#───────────────────────────────────────────────────────────────────────────────
# IAM role for the EBS CSI driver, assumed via EKS Pod Identity.
#───────────────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "ebs_csi" {
  count = local.is_eks ? 1 : 0
  name  = "${var.run_tag}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = {
    ClusterType = "eks"
    RunTag      = var.run_tag
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = local.is_eks ? 1 : 0
  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
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
    cluster_name                  = module.eks[0].cluster_name
    cluster_endpoint              = module.eks[0].cluster_endpoint
    cluster_version               = module.eks[0].cluster_version
    cluster_security_group_id     = module.eks[0].cluster_security_group_id
    node_security_group_id        = module.eks[0].node_security_group_id
    cluster_iam_role_arn          = module.eks[0].cluster_iam_role_arn
    oidc_provider_arn             = module.eks[0].oidc_provider_arn
    cluster_certificate_authority = module.eks[0].cluster_certificate_authority_data
  } : null
  description = "EKS cluster information (only populated when cluster_type = eks)"
}

output "eks_node_groups" {
  value = local.is_eks ? {
    for k, v in module.eks[0].eks_managed_node_groups : k => {
      node_group_id                      = v.node_group_id
      node_group_arn                     = v.node_group_arn
      node_group_status                  = v.node_group_status
      node_group_autoscaling_group_names = v.node_group_autoscaling_group_names
    }
  } : {}
  description = "EKS managed node groups information"
}
