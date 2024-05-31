data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

locals {
  cluster_version = "1.29"
  vpc_cidr        = "10.0.0.0/16"
  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  tags = {
    kubefirst = "true"
  }
}

################################################################################
# EKS Module
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.12.0"

  cluster_name                   = var.cluster_name
  cluster_version                = local.cluster_version
  cluster_endpoint_public_access = true
  create_kms_key                 = false
  cluster_encryption_config      = {}
  node_security_group_tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = null
    "kubernetes.io/workload"                    = "CriticalAddonsOnly"
  }
  cluster_addons = {
    # AWS launch CoreDNS itself with their add-on https://docs.aws.amazon.com/eks/latest/userguide/managing-coredns.html
    coredns = {
      most_recent       = true
      resolve_conflicts = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.aws_ebs_csi_driver.iam_role_arn
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent              = true
      before_compute           = true
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
      configuration_values = jsonencode({
        env = {
          # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  eks_managed_node_groups = {
    # Default node group - as provided by AWS EKS
    criticalAddonsOnly = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = ["t4g.medium"] # ["<NODE_TYPE>"]

      desired_size = 3 # tonumber("<NODE_COUNT>") # tonumber() is used for a string token value
      min_size     = 2 # tonumber("<NODE_COUNT>") # tonumber() is used for a string token value
      max_size     = 4 # tonumber("<NODE_COUNT>") # tonumber() is used for a string token value

      taints = {
        # This Taint aims to keep just EKS Addons and Karpenter running on this MNG
        # The pods that do not tolerate this taint should run on nodes created by Karpenter
        addons = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        },
      }
    }
  }

  enable_cluster_creator_admin_permissions = true

  access_entries = {
    kube_admin = {
      principal_arn = aws_iam_role.kubernetes_admin.arn
      type          = "STANDARD"

      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }

    argocd = {
      principal_arn = "arn:aws:iam::<AWS_ACCOUNT_ID>:role/argocd-<CLUSTER_NAME>"
      type          = "STANDARD"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }

    atlantis = {
      principal_arn = "arn:aws:iam::<AWS_ACCOUNT_ID>:role/atlantis-<CLUSTER_NAME>"
      type          = "STANDARD"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = var.cluster_name
  })
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = var.cluster_name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 52)]

  enable_ipv6            = true
  create_egress_only_igw = true

  public_subnet_ipv6_prefixes  = [0, 1, 2]
  private_subnet_ipv6_prefixes = [3, 4, 5]
  intra_subnet_ipv6_prefixes   = [6, 7, 8]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "karpenter.sh/discovery"          = var.cluster_name
  }

  tags = local.tags
}

module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.1"

  role_name             = upper("VPC-CNI-IRSA-${var.cluster_name}")
  attach_vpc_cni_policy = true
  role_policy_arns = {
    AmazonEKS_CNI_Policy = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  }


  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }

  tags = local.tags
}

module "aws_ebs_csi_driver" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.1"

  role_name = upper("EBS-CSI-DRIVER-${var.cluster_name}")

  role_policy_arns = {
    admin = aws_iam_policy.aws_ebs_csi_driver.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node", "kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

resource "aws_iam_policy" "aws_ebs_csi_driver" {
  name        = "aws-ebs-csi-driver-${var.cluster_name}"
  path        = "/"
  description = "policy for aws ebs csi driver"

  policy = <<EOT
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateSnapshot",
        "ec2:AttachVolume",
        "ec2:DetachVolume",
        "ec2:ModifyVolume",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeInstances",
        "ec2:DescribeSnapshots",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DescribeVolumesModifications"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateTags"
      ],
      "Resource": [
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*:*:snapshot/*"
      ],
      "Condition": {
        "StringEquals": {
          "ec2:CreateAction": [
            "CreateVolume",
            "CreateSnapshot"
          ]
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteTags"
      ],
      "Resource": [
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*:*:snapshot/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVolume"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:RequestTag/ebs.csi.aws.com/cluster": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateVolume"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:RequestTag/CSIVolumeName": "*"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteVolume"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "ec2:ResourceTag/ebs.csi.aws.com/cluster": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteVolume"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "ec2:ResourceTag/CSIVolumeName": "*"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteVolume"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "ec2:ResourceTag/kubernetes.io/created-for/pvc/name": "*"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteSnapshot"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "ec2:ResourceTag/CSIVolumeSnapshotName": "*"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DeleteSnapshot"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "ec2:ResourceTag/ebs.csi.aws.com/cluster": "true"
        }
      }
    }
  ]
}
EOT
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name  = module.eks.cluster_name
  iam_role_name = "karpenter-${var.cluster_name}"

  # Attach additional IAM policies to the Karpenter node IAM role
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

module "cert_manager" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.1"

  role_name = "cert-manager-${var.cluster_name}"
  role_policy_arns = {
    cert_manager = aws_iam_policy.cert_manager.arn
  }
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["cert-manager:cert-manager"]
    }
  }

  tags = local.tags
}

resource "aws_iam_policy" "cert_manager" {
  name        = "cert-manager-${var.cluster_name}"
  path        = "/"
  description = "policy for external dns to access route53 resources"

  policy = <<EOT
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "route53:GetChange",
      "Resource": "arn:aws:route53:::change/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets",
        "route53:ListResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/*"
    },
    {
      "Effect": "Allow",
      "Action": "route53:ListHostedZonesByName",
      "Resource": "*"
    }
  ]
}
EOT
}

module "external_dns" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.1"

  role_name = "external-dns-${var.cluster_name}"
  role_policy_arns = {
    external_dns = aws_iam_policy.external_dns.arn
  }
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-dns:external-dns"]
    }
  }

  tags = local.tags
}

resource "aws_iam_policy" "external_dns" {
  name        = "external-dns-${var.cluster_name}"
  path        = "/"
  description = "policy for external dns to access route53 resources"

  policy = <<EOT
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
EOT
}

resource "vault_generic_secret" "clusters" {
  path = "secret/clusters/${var.cluster_name}"

  data_json = jsonencode(
    {
      cluster_ca_certificate = module.eks.cluster_certificate_authority_data
      host                   = module.eks.cluster_endpoint
      cluster_name           = var.cluster_name
      environment            = var.cluster_name
      argocd_role_arn        = "arn:aws:iam::<AWS_ACCOUNT_ID>:role/argocd-<CLUSTER_NAME>"
    }
  )
}
