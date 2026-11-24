############################################
# Stage 4 - HCP Terraform Operator + per-org agent pools (KP layout)
#   Apply 1: deploy_agentpools = false -> operator, namespaces, secrets, CA
#   Apply 2: deploy_agentpools = true  -> AgentPool resources
############################################

variable "org_token_dev02" {
  type      = string
  sensitive = true
}

variable "org_token_prod03" {
  type      = string
  sensitive = true
}

variable "org_token_cdocas" {
  type      = string
  sensitive = true
}

variable "deploy_agentpools" {
  type    = bool
  default = false
}

locals {
  orgs = {
    "az-services-kp-azure-dev-02"  = var.org_token_dev02
    "az-services-kp-azure-prod-03" = var.org_token_prod03
    "cdocas-azure"                 = var.org_token_cdocas
  }

  pool_ns = { for org, _ in local.orgs : org => "kp-cis-aks-agentpool-${org}-prod" }

  otlp_address = "otel-tfe-metrics-opentelemetry-collector.dynatrace.svc.cluster.local:4317"
}

# --- Operator ---
resource "helm_release" "tfc_operator" {
  name             = "hcp-terraform-operator"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "hcp-terraform-operator"
  namespace        = "tfc-operator"
  create_namespace = true
  wait             = true
  timeout          = 600
  atomic           = true
  cleanup_on_fail  = true

  values = [yamlencode({
    operator = {
      tfeAddress = "https://${var.tfe_fqdn}"
    }
    customCAcertificates = base64encode(tls_self_signed_cert.ca.cert_pem)
  })]

  depends_on = [helm_release.tfe]
}

# --- Per-org namespace, org token, CA ---
resource "kubernetes_namespace" "pool" {
  for_each = local.pool_ns
  metadata {
    name = each.value
  }
}

resource "kubernetes_secret" "org_token" {
  for_each = local.pool_ns
  metadata {
    name      = "tfe-org-token"
    namespace = kubernetes_namespace.pool[each.key].metadata[0].name
  }
  data = {
    token = local.orgs[each.key]
  }
}

resource "kubernetes_config_map" "sandbox_ca" {
  for_each = local.pool_ns
  metadata {
    name      = "sandbox-ca"
    namespace = kubernetes_namespace.pool[each.key].metadata[0].name
  }
  data = {
    "sandbox-ca.pem" = tls_self_signed_cert.ca.cert_pem
  }
}

# --- Agent pools (apply 2) ---
resource "kubernetes_manifest" "agentpool" {
  for_each = var.deploy_agentpools ? local.pool_ns : {}

  manifest = {
    apiVersion = "app.terraform.io/v1alpha2"
    kind       = "AgentPool"
    metadata = {
      name      = each.key # deployment becomes agents-of-<org>
      namespace = each.value
    }
    spec = {
      organization = each.key
      name         = "${each.key}-pool"
      token = {
        secretKeyRef = { name = "tfe-org-token", key = "token" }
      }
      agentTokens = [{ name = "k8s" }]
      agentDeployment = {
        replicas = 2
        spec = {
          containers = [{
            name  = "tfc-agent"
            image = "hashicorp/tfc-agent:latest"
            env = [
              { name = "TFC_AGENT_OTLP_ADDRESS", value = local.otlp_address },
            ]
            resources = {
              requests = { cpu = "250m", memory = "512Mi" }
              limits   = { memory = "2Gi" }
            }
            volumeMounts = [{
              name      = "sandbox-ca"
              mountPath = "/etc/ssl/certs/sandbox-ca.pem"
              subPath   = "sandbox-ca.pem"
              readOnly  = true
            }]
          }]
          volumes = [{
            name      = "sandbox-ca"
            configMap = { name = "sandbox-ca" }
          }]
        }
      }
    }
  }

  depends_on = [
    helm_release.tfc_operator,
    kubernetes_secret.org_token,
    kubernetes_config_map.sandbox_ca,
  ]
}

# --- TEMP: what the operator created in each pool namespace ---
data "kubernetes_resources" "pool_pods" {
  for_each    = local.pool_ns
  api_version = "v1"
  kind        = "Pod"
  namespace   = each.value
}

output "debug_pool_pods" {
  value = {
    for org, d in data.kubernetes_resources.pool_pods : org => [
      for p in d.objects : {
        pod   = p.metadata.name
        phase = try(p.status.phase, null)
        ready = try(alltrue([for c in p.status.containerStatuses : c.ready]), false)
        env   = [for e in try(p.spec.containers[0].env, []) : e.name]
      }
    ]
  }
}
