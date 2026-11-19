variable "region"      { default = "us-east-1" }
variable "tfe_fqdn"    { default = "tfe.kranthi-katepalli.sbx.hashidemos.io" }
variable "tfe_license" {
  type      = string
  sensitive = true
}

provider "aws" {
  region = var.region
}

data "terraform_remote_state" "infra" {
  backend = "remote"
  config = {
    organization = "kate"
    workspaces   = { name = "terraform-aws-terraform-enterprise-eks-hvd" }
  }
}

locals {
  infra        = data.terraform_remote_state.infra.outputs
  cluster_name = local.infra.tfe_eks_cluster_name
}

data "aws_eks_cluster" "this" {
  name = local.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = local.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
