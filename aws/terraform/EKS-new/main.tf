### VPC ###

locals {
  azs = [for zone in var.zones : "${var.region}${zone}"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = var.network_name != "" ? var.network_name : "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform   = "true"
    Environment = "dev"
    Owner       = "Vlad"
  }
}

### EKS ###

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.11.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access = true

  cluster_addons = {
    aws-ebs-csi-driver = {
      most_recent = true
    },
    aws-efs-csi-driver = {
      most_recent = true
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    initial = {
      min_size     = 1
      max_size     = 5
      desired_size = 2

      instance_types = var.instance_types
      capacity_type  = "ON_DEMAND"
    }
  }

  # Cluster access entry
  # To add the current caller identity as an administrator
  enable_cluster_creator_admin_permissions = true

  tags = {
    Environment = "dev"
    Terraform   = "true"
    Owner       = "Vlad"
  }
}

### DNS + Ingress ###
module "dns-hosted-zone" {
  source       = "./modules/dns/dns-hosted-zone"
  count        = var.domain != "" ? 1 : 0
  cluster_name = var.cluster_name
  domain       = var.domain
  owner        = var.owner
  project      = var.project
  env          = var.env
}

module "ingress" {
  depends_on   = [module.eks]
  source       = "./modules/ingress"
  domain       = var.domain
  aws_cert_arn = module.dns-hosted-zone[0].cert_arn
  aws_vpc_cidr = var.vpc_cidr
  enable_private_lb = true
}

data "kubernetes_service" "nginx_lb" {
  depends_on = [module.ingress]
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }
}

data "aws_lb" "nginx-nlb" {
  name       = regex("^(?P<name>.+)-.+\\.elb\\..+\\.amazonaws\\.com", data.kubernetes_service.nginx_lb.status.0.load_balancer.0.ingress.0.hostname)["name"]
  depends_on = [data.kubernetes_service.nginx_lb]
}

module "dns-a-record" {
  source       = "./modules/dns/dns-a-record"
  count        = var.domain != "" ? 1 : 0
  domain       = var.domain
  zone_id      = module.dns-hosted-zone[0].hz_zone_id
  nlb_dns_name = data.aws_lb.nginx-nlb.dns_name
  nlb_zone_id  = data.aws_lb.nginx-nlb.zone_id

  depends_on = [
    data.aws_lb.nginx-nlb,
  ]
}

### K2V Agent ###
module "k2v_agent" {
  depends_on     = [module.eks]
  count          = var.mailbox_id != "" ? 1 : 0
  source         = "./modules/k2v_agent"
  mailbox_id     = var.mailbox_id
  mailbox_url    = var.mailbox_url
  cloud_provider = "AWS"
  region         = var.region
  namespace      = var.k2view_agent_namespace
}

### Storage Classes ###
module "ebs" {
  depends_on          = [module.eks]
  source              = "./modules/storage-classes/ebs"
  encrypted           = true
  node_group_iam_role = module.eks.eks_managed_node_groups["initial"].iam_role_name
}

### EFS ###
module "efs" {
  count                = var.efs_enabled ? 1 : 0
  source               = "./modules/storage-classes/efs"
  cluster_name         = var.cluster_name
  aws_region           = var.region
  owner                = var.owner
  project              = var.project
  env                  = var.env
  vpc_subnets          = module.vpc.private_subnets
  vpc_cidr             = var.vpc_cidr
  node_group_role_name = module.eks.eks_managed_node_groups.initial.iam_role_name

  providers = {
    aws = aws
  }

  depends_on = [
    module.eks, module.vpc
  ]
}

### IRSA ###
module "irsa" {
  source       = "./modules/irsa"
  aws_region   = var.region
  cluster_name = var.cluster_name
  owner        = var.owner
  project      = var.project
  env          = var.env

  providers = {
    aws = aws
  }

  depends_on = [
    module.eks
  ]
}