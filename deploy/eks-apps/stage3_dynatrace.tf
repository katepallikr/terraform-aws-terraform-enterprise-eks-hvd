############################################
# Stage 3 - Dynatrace
#   Apply 1: deploy_dynakube = false  -> operator, secrets, OTel collector
#   Apply 2: deploy_dynakube = true   -> DynaKube (needs operator CRDs)
############################################

variable "dynatrace_env_url" {
  type        = string
  description = "e.g. https://abc12345.live.dynatrace.com (no trailing slash)"
}

variable "dynatrace_operator_token" {
  type      = string
  sensitive = true
}

variable "dynatrace_data_ingest_token" {
  type      = string
  sensitive = true
}

variable "deploy_dynakube" {
  type    = bool
  default = false
}

resource "kubernetes_namespace" "dynatrace" {
  metadata {
    name = "dynatrace"
  }
}

# --- Dynatrace Operator ---
resource "helm_release" "dynatrace_operator" {
  name       = "dynatrace-operator"
  repository = "oci://public.ecr.aws/dynatrace"
  chart      = "dynatrace-operator"
  namespace  = kubernetes_namespace.dynatrace.metadata[0].name
  wait       = true
  timeout    = 600
}

# Secret name must match the DynaKube name
resource "kubernetes_secret" "dynakube" {
  metadata {
    name      = "dynakube"
    namespace = kubernetes_namespace.dynatrace.metadata[0].name
  }
  data = {
    apiToken        = var.dynatrace_operator_token
    dataIngestToken = var.dynatrace_data_ingest_token
  }
}

# --- DynaKube: cluster, node and pod metrics ---
resource "kubernetes_manifest" "dynakube" {
  count = var.deploy_dynakube ? 1 : 0

  manifest = {
    apiVersion = "dynatrace.com/v1beta5"
    kind       = "DynaKube"
    metadata = {
      name      = "dynakube"
      namespace = "dynatrace"
    }
    spec = {
      apiUrl = "${var.dynatrace_env_url}/api"
      metadataEnrichment = {
        enabled = true
      }
      oneAgent = {
        hostMonitoring = {}
      }
      activeGate = {
        capabilities = ["routing", "kubernetes-monitoring"]
        resources = {
          requests = { cpu = "500m", memory = "512Mi" }
          limits   = { cpu = "1000m", memory = "1.5Gi" }
        }
      }
    }
  }

  depends_on = [
    helm_release.dynatrace_operator,
    kubernetes_secret.dynakube,
  ]
}

# --- OTel collector: TFE app metrics -> Dynatrace ---
resource "kubernetes_secret" "otel_dt" {
  metadata {
    name      = "otel-dynatrace"
    namespace = kubernetes_namespace.dynatrace.metadata[0].name
  }
  data = {
    token = var.dynatrace_data_ingest_token
  }
}

resource "helm_release" "otel_tfe" {
  name       = "otel-tfe-metrics"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  namespace  = kubernetes_namespace.dynatrace.metadata[0].name
  wait       = true
  timeout    = 600

  values = [yamlencode({
    mode = "deployment"

    image = {
      repository = "otel/opentelemetry-collector-contrib"
    }

    clusterRole = {
      create = true
      rules = [{
        apiGroups = [""]
        resources = ["pods", "endpoints", "services"]
        verbs     = ["get", "list", "watch"]
      }]
    }

    extraEnvs = [{
      name = "DT_TOKEN"
      valueFrom = {
        secretKeyRef = {
          name = kubernetes_secret.otel_dt.metadata[0].name
          key  = "token"
        }
      }
    }]

    config = {
      receivers = {
        prometheus = {
          config = {
            scrape_configs = [{
              job_name        = "terraform-enterprise"
              scrape_interval = "10s"
              metrics_path    = "/metrics"
              params = {
                format = ["prometheus"]
              }
              kubernetes_sd_configs = [{
                role = "pod"
                namespaces = {
                  names = ["tfe"]
                }
              }]
              relabel_configs = [
                # one target per TFE pod: anchor on the app's 8443 port
                {
                  source_labels = ["__meta_kubernetes_pod_container_port_number"]
                  regex         = "8443"
                  action        = "keep"
                },
                # scrape the metrics port instead
                {
                  source_labels = ["__meta_kubernetes_pod_ip"]
                  target_label  = "__address__"
                  replacement   = "$$1:9090"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_name"]
                  target_label  = "k8s_pod_name"
                },
              ]
            }]
          }
        }
      }

      processors = {
        cumulativetodelta = {}
        batch             = {}
      }

      exporters = {
        otlphttp = {
          endpoint = "${var.dynatrace_env_url}/api/v2/otlp"
          headers = {
            Authorization = "Bearer $${env:DT_TOKEN}"
          }
        }
      }

      service = {
        pipelines = {
          metrics = {
            receivers  = ["prometheus"]
            processors = ["cumulativetodelta", "batch"]
            exporters  = ["otlphttp"]
          }
        }
      }
    }
  })]
}

output "dynatrace_otel_endpoint" {
  value = "${var.dynatrace_env_url}/api/v2/otlp"
}
