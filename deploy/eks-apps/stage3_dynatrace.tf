############################################
# Stage 3 - Observability via OpenTelemetry only (no OneAgent / ActiveGate)
#   otel_tfe  (Deployment, 1 replica): TFE /metrics scrape + k8s_cluster
#   otel_node (DaemonSet, per node):   kubeletstats + k8sattributes
############################################

variable "dynatrace_env_url" {
  type        = string
  description = "e.g. https://abc12345.live.dynatrace.com (no trailing slash)"
}

variable "dynatrace_data_ingest_token" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "dynatrace" {
  metadata {
    name = "dynatrace"
  }
}

resource "kubernetes_secret" "otel_dt" {
  metadata {
    name      = "otel-dynatrace"
    namespace = kubernetes_namespace.dynatrace.metadata[0].name
  }
  data = {
    token = var.dynatrace_data_ingest_token
  }
}

locals {
  dt_exporter = {
    otlphttp = {
      endpoint = "${var.dynatrace_env_url}/api/v2/otlp"
      headers  = { Authorization = "Bearer $${env:DT_TOKEN}" }
    }
  }

  dt_token_env = {
    name = "DT_TOKEN"
    valueFrom = {
      secretKeyRef = { name = "otel-dynatrace", key = "token" }
    }
  }
}

# ---------------------------------------------------------------
# Cluster collector: TFE app metrics + Kubernetes object state
# ---------------------------------------------------------------
resource "helm_release" "otel_tfe" {
  name            = "otel-tfe-metrics"
  repository      = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart           = "opentelemetry-collector"
  namespace       = kubernetes_namespace.dynatrace.metadata[0].name
  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    mode         = "deployment"
    replicaCount = 1 # k8s_cluster must run as a single instance
    image        = { repository = "otel/opentelemetry-collector-contrib" }

    clusterRole = {
      create = true
      rules = [
        {
          apiGroups = [""]
          resources = ["events", "namespaces", "namespaces/status", "nodes", "nodes/spec", "pods", "pods/status", "replicationcontrollers", "replicationcontrollers/status", "resourcequotas", "services", "endpoints"]
          verbs     = ["get", "list", "watch"]
        },
        {
          apiGroups = ["apps"]
          resources = ["daemonsets", "deployments", "replicasets", "statefulsets"]
          verbs     = ["get", "list", "watch"]
        },
        {
          apiGroups = ["batch"]
          resources = ["jobs", "cronjobs"]
          verbs     = ["get", "list", "watch"]
        },
        {
          apiGroups = ["autoscaling"]
          resources = ["horizontalpodautoscalers"]
          verbs     = ["get", "list", "watch"]
        },
      ]
    }

    extraEnvs = [local.dt_token_env]

    config = {
      receivers = {
        prometheus = {
          config = {
            scrape_configs = [{
              job_name        = "terraform-enterprise"
              scrape_interval = "10s"
              metrics_path    = "/metrics"
              params          = { format = ["prometheus"] }
              kubernetes_sd_configs = [{
                role       = "pod"
                namespaces = { names = ["tfe"] }
              }]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_container_port_number"]
                  regex         = "8443"
                  action        = "keep"
                },
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

        k8s_cluster = {
          auth_type                  = "serviceAccount"
          collection_interval        = "30s"
          node_conditions_to_report  = ["Ready", "MemoryPressure", "DiskPressure"]
          allocatable_types_to_report = ["cpu", "memory"]
        }
      }

      processors = {
        cumulativetodelta = {}
        batch             = {}
      }

      exporters = local.dt_exporter

      service = {
        pipelines = {
          metrics = {
            receivers  = ["prometheus", "k8s_cluster"]
            processors = ["cumulativetodelta", "batch"]
            exporters  = ["otlphttp"]
          }
        }
      }
    }
  })]

  depends_on = [kubernetes_secret.otel_dt]
}

# ---------------------------------------------------------------
# Node collector: per-node kubelet stats (CPU/memory/net/fs)
# ---------------------------------------------------------------
resource "helm_release" "otel_node" {
  name            = "otel-node-metrics"
  repository      = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart           = "opentelemetry-collector"
  namespace       = kubernetes_namespace.dynatrace.metadata[0].name
  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    mode  = "daemonset"
    image = { repository = "otel/opentelemetry-collector-contrib" }

    clusterRole = {
      create = true
      rules = [
        {
          apiGroups = [""]
          resources = ["nodes", "nodes/stats", "nodes/proxy", "pods", "namespaces"]
          verbs     = ["get", "list", "watch"]
        },
        {
          apiGroups = ["apps"]
          resources = ["replicasets", "deployments"]
          verbs     = ["get", "list", "watch"]
        },
      ]
    }

    extraEnvs = [
      local.dt_token_env,
      { name = "K8S_NODE_NAME", valueFrom = { fieldRef = { fieldPath = "spec.nodeName" } } },
      { name = "K8S_NODE_IP", valueFrom = { fieldRef = { fieldPath = "status.hostIP" } } },
    ]

    config = {
      receivers = {
        kubeletstats = {
          auth_type            = "serviceAccount"
          collection_interval  = "30s"
          endpoint             = "https://$${env:K8S_NODE_IP}:10250"
          insecure_skip_verify = true
          metric_groups        = ["node", "pod", "container"]
        }
      }

      processors = {
        k8sattributes = {
          auth_type   = "serviceAccount"
          passthrough = false
          filter      = { node_from_env_var = "K8S_NODE_NAME" }
          extract = {
            metadata = ["k8s.namespace.name", "k8s.pod.name", "k8s.pod.uid", "k8s.deployment.name", "k8s.node.name"]
          }
          pod_association = [
            { sources = [{ from = "resource_attribute", name = "k8s.pod.uid" }] },
            { sources = [{ from = "resource_attribute", name = "k8s.pod.ip" }] },
          ]
        }
        cumulativetodelta = {}
        batch             = {}
      }

      exporters = local.dt_exporter

      service = {
        pipelines = {
          metrics = {
            receivers  = ["kubeletstats"]
            processors = ["k8sattributes", "cumulativetodelta", "batch"]
            exporters  = ["otlphttp"]
          }
        }
      }
    }
  })]

  depends_on = [kubernetes_secret.otel_dt]
}

# --- TEMP: pod status in the dynatrace namespace ---
data "kubernetes_resources" "obs_pods" {
  api_version = "v1"
  kind        = "Pod"
  namespace   = "dynatrace"
}

output "debug_obs_pods" {
  value = {
    for p in data.kubernetes_resources.obs_pods.objects :
    p.metadata.name => {
      phase    = try(p.status.phase, null)
      ready    = try(alltrue([for c in p.status.containerStatuses : c.ready]), false)
      restarts = try(sum([for c in p.status.containerStatuses : c.restartCount]), 0)
      waiting  = try([for c in p.status.containerStatuses : c.state.waiting.reason][0], null)
    }
  }
}

output "dynatrace_otel_endpoint" {
  value = "${var.dynatrace_env_url}/api/v2/otlp"
}
