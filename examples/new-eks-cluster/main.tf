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
    cidr_allow_ingress_tfe_443 = concat(
    var.cidr_allow_ingress_tfe_443,
    ["${data.aws_nat_gateway.egress.public_ip}/32"],
  )
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
    "subnet-02be68d3a88bf6efb",        # private, 1a
    data.aws_subnet.eks_private_b.id,  # private, 1b (existing)
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

variable "tfc_agent_token" {
  type      = string
  sensitive = true
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "tfc_agent" {
  name_prefix = "${var.friendly_name_prefix}-tfc-agent-"
  vpc_id      = var.vpc_id
  description = "HCP Terraform agent - egress only"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# let the agent reach the private EKS API
resource "aws_security_group_rule" "eks_api_from_tfc_agent" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = module.tfe.eks_cluster_security_group_id
  source_security_group_id = aws_security_group.tfc_agent.id
  description              = "EKS API from HCP Terraform agent"
}

resource "aws_instance" "tfc_agent" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.medium"
  subnet_id                   = "subnet-02be68d3a88bf6efb" # private, NAT
  vpc_security_group_ids      = [aws_security_group.tfc_agent.id]
  associate_public_ip_address = false

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 30
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    dnf install -y docker
    systemctl enable --now docker
    docker run -d --restart always --name tfc-agent \
      -e TFC_AGENT_TOKEN='${var.tfc_agent_token}' \
      -e TFC_AGENT_NAME='eks-vpc-agent-1' \
      hashicorp/tfc-agent:latest
  EOF

  tags = {
    Name = "${var.friendly_name_prefix}-tfc-agent"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}
