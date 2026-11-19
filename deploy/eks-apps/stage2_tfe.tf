variable "tfe_image_tag" {
  type = string
}

variable "tfe_lb_public_subnet_ids" {
  type    = list(string)
  default = ["subnet-03ec7bbcd68f0bb18", "subnet-0d900bf55d5c4c4d9"]
}

variable "create_dns_record" {
  type    = bool
  default = true
}

variable "dns_zone_name" {
  type    = string
  default = "kranthi-katepalli.sbx.hashidemos.io"
}

resource "helm_release" "tfe" {
  name       = "terraform-enterprise"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "terraform-enterprise"
  version    = "2.1.1"
  namespace  = kubernetes_namespace.tfe.metadata[0].name
  timeout    = 1200
  wait       = false

  values = [
    local.infra.helm_overrides_values,
    yamlencode({
      replicaCount = 1
      image = {
        tag = var.tfe_image_tag
      }
      tls = {
        certificateSecret = kubernetes_secret.tfe_certs.metadata[0].name
        caCertData        = base64encode(tls_self_signed_cert.ca.cert_pem)
      }
      tfe = {
        metrics = {
          enable    = true
          httpPort  = 9090
          httpsPort = 9091
        }
      }
      env = {
        secretRefs = [{ name = kubernetes_secret.tfe_secrets.metadata[0].name }]
        variables = {
          TFE_IACT_SUBNETS    = "10.0.0.0/16"
          TFE_IACT_TIME_LIMIT = "unlimited"
        }
      }
      service = {
        annotations = {
          "service.beta.kubernetes.io/aws-load-balancer-scheme"  = "internet-facing"
          "service.beta.kubernetes.io/aws-load-balancer-subnets" = join(",", var.tfe_lb_public_subnet_ids)
        }
      }
    })
  ]

  depends_on = [
    helm_release.aws_lb_controller,
    kubernetes_secret.tfe_image_pull,
    kubernetes_job_v1.helm_unlock,
  ]
}

data "kubernetes_service" "tfe" {
  metadata {
    name      = "terraform-enterprise"
    namespace = kubernetes_namespace.tfe.metadata[0].name
  }
  depends_on = [helm_release.tfe]
}

locals {
  tfe_nlb_hostname = try(data.kubernetes_service.tfe.status[0].load_balancer[0].ingress[0].hostname, "")
}

data "aws_route53_zone" "this" {
  count = var.create_dns_record ? 1 : 0
  name  = var.dns_zone_name
}

resource "aws_route53_record" "tfe" {
  count   = var.create_dns_record ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = var.tfe_fqdn
  type    = "CNAME"
  ttl     = 60
  records = [local.tfe_nlb_hostname]
}

output "tfe_nlb_hostname" {
  value = local.tfe_nlb_hostname
}

output "tfe_url" {
  value = "https://${var.tfe_fqdn}"
}

data "kubernetes_resources" "tfe_deploy" {
  api_version    = "apps/v1"
  kind           = "Deployment"
  namespace      = "tfe"
  field_selector = "metadata.name=terraform-enterprise"
}

output "debug_tfe_iact_env" {
  value = [
    for e in try(data.kubernetes_resources.tfe_deploy.objects[0].spec.template.spec.containers[0].env, []) :
    e if can(regex("IACT", e.name))
  ]
}
