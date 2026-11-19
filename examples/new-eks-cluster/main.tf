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

  # --- Database --- #
  tfe_database_password_secret_arn = var.tfe_database_password_secret_arn
  rds_skip_final_snapshot          = var.rds_skip_final_snapshot

  # --- Redis --- #
  tfe_redis_password_secret_arn = var.tfe_redis_password_secret_arn
}
resource "aws_subnet" "eks_private_b" {
  vpc_id                  = var.vpc_id
  cidr_block              = "10.0.11.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = false

  tags = {
    Name                              = "${var.friendly_name_prefix}-eks-private-b"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table_association" "eks_private_b" {
  subnet_id      = aws_subnet.eks_private_b.id
  route_table_id = "rtb-09550ce556deb4936" # existing private RT -> nat-0c712752f8650d05e
}
