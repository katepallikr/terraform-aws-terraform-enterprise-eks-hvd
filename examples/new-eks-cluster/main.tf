# Copyright IBM Corp. 2024, 2026
# SPDX-License-Identifier: MPL-2.0

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region
}

module "tfe" {
  source = "../.."

  # --- Common --- #
  friendly_name_prefix = var.friendly_name_prefix
  common_tags          = var.common_tags

  # --- TFE configuration settings --- #
  tfe_fqdn                   = var.tfe_fqdn
  create_helm_overrides_file = var.create_helm_overrides_file

  # --- Networking --- #
  vpc_id                               = var.vpc_id
  eks_subnet_ids                       = var.eks_subnet_ids
  rds_subnet_ids                       = var.rds_subnet_ids
  redis_subnet_ids                     = var.redis_subnet_ids
  cidr_allow_ingress_tfe_443           = var.cidr_allow_ingress_tfe_443
  cidr_allow_ingress_tfe_metrics_http  = var.cidr_allow_ingress_tfe_metrics_http
  cidr_allow_ingress_tfe_metrics_https = var.cidr_allow_ingress_tfe_metrics_https

  # --- IAM --- #
  create_eks_oidc_provider      = var.create_eks_oidc_provider
  create_aws_lb_controller_irsa = var.create_aws_lb_controller_irsa
  create_tfe_eks_irsa           = var.create_tfe_eks_irsa

  # --- EKS --- #
  create_eks_cluster                 = var.create_eks_cluster
  eks_cluster_endpoint_public_access = var.eks_cluster_endpoint_public_access
  eks_cluster_public_access_cidrs    = var.eks_cluster_public_access_cidrs
  eks_cluster_version      = "1.35"
  eks_cluster_support_type = "STANDARD"
 eks_nodegroup_subnet_ids = [
    "subnet-02be68d3a88bf6efb",  # existing private, 1a
    aws_subnet.eks_private_b.id, # new private, 1b
  ]

  # --- Database --- #
  tfe_database_password_secret_arn = var.tfe_database_password_secret_arn
  rds_skip_final_snapshot          = var.rds_skip_final_snapshot

  # --- Redis --- #
  tfe_redis_password_secret_arn = var.tfe_redis_password_secret_arn
}
data "aws_subnet" "eks_private_b" {
  vpc_id     = var.vpc_id
  cidr_block = "10.0.11.0/24"
}

data "aws_route_table" "eks_private_b" {
  subnet_id = data.aws_subnet.eks_private_b.id
}

output "check_private_b" {
  value = {
    id        = data.aws_subnet.eks_private_b.id
    az        = data.aws_subnet.eks_private_b.availability_zone
    public_ip = data.aws_subnet.eks_private_b.map_public_ip_on_launch
    default   = [for r in data.aws_route_table.eks_private_b.routes : { nat = r.nat_gateway_id, igw = r.gateway_id } if r.cidr_block == "0.0.0.0/0"]
  }
}
