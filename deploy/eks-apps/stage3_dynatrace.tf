############################################
# Stage 3 - Observability via OpenTelemetry only
#   otel_tfe  (Deployment): TFE /metrics scrape, k8s_cluster, agent OTLP
#   otel_node (DaemonSet):  kubeletstats per node
#   Both: memory_limiter + self-monitoring (scrape of own :8888)
############################################

variable "dynatrace_env_url" {
  type        = string
  description = "e.g. https://abc12345.live.dynatrace.com (no trailing slash)"
}

variable "dynatrace_data_ingest_token" {
  type      = string
  sensitive = true
}

variable "cluster_collector_replicas" {
  type    = number
  default = 1 # set 0 only for the failure test
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

  memory_limiter = {
    check_interval         = "1s"
    limit_percentage       = 80
    spike_limit_percentage = 25
  }

  # Collector scrapes its own internal metrics endpoint
  self_scrape_job = {
    job_name        = "otelcol-contrib"
    scrape_interval = "30s"
    static_configs  = [{ targets = ["$${env:MY_POD_IP}:8888"] }]
  }
}

# ---------------------------------------------------------------
# Cluster collector
# ---------------------------------------------------------------
resource "helm_release" "otel_tfe" {
  name            = "otel-tfe-metrics"
  repository      = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart           = "opentelemetry-collector"
  version         = "0.183.0"
  namespace       = kubernetes_namespace.dynatrace.metadata[0].name
  wait            = var.cluster_collector_replicas > 0
  timeout         = 300
  atomic          = var.cluster_collector_replicas > 0
  cleanup_on_fail = true

  values = [yamlencode({
    image        = { repository = "otel/opentelemetry-collector-contrib" }
    mode         = "deployment"
    replicaCount = max(var.cluster_collector_replicas, 1)
    nodeSelector = var.cluster_collector_replicas == 0 ? { "failure-test" = "no-such-node" } : {}
    rollout      = { strategy = "Recreate" }

    resources = {
      requests = { cpu = "100m", memory = "256Mi" }
      limits   = { memory = "512Mi" }
    }

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
            scrape_configs = [
              {
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
              },
              local.self_scrape_job,
            ]
          }
        }

        k8s_cluster = {
          auth_type                   = "serviceAccount"
          collection_interval         = "30s"
          node_conditions_to_report   = ["Ready", "MemoryPressure", "DiskPressure"]
          allocatable_types_to_report = ["cpu", "memory"]
        }
      }

      processors = {
        memory_limiter = local.memory_limiter
        k8sattributes = {
          auth_type   = "serviceAccount"
          passthrough = false
          extract = {
            metadata = ["k8s.namespace.name", "k8s.pod.name", "k8s.deployment.name", "k8s.node.name"]
          }
          pod_association = [
            { sources = [{ from = "connection" }] },
          ]
        }
        cumulativetodelta = {}
        batch             = {}
      }

      exporters = local.dt_exporter

      service = {
        pipelines = {
          metrics = {
            receivers  = ["prometheus", "k8s_cluster"] # TFE /metrics + own :8888 + cluster state
            processors = ["memory_limiter", "cumulativetodelta", "batch"]
            exporters  = ["otlphttp"]
          }
          "metrics/agents" = {
            receivers  = ["otlp"] # tfc-agents
            processors = ["memory_limiter", "k8sattributes", "cumulativetodelta", "batch"]
            exporters  = ["otlphttp"]
          }
        }
      }
    }
  })]

  depends_on = [kubernetes_secret.otel_dt]
}

# ---------------------------------------------------------------
# Node collector
# ---------------------------------------------------------------
resource "helm_release" "otel_node" {
  name            = "otel-node-metrics"
  repository      = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart           = "opentelemetry-collector"
  version         = "0.183.0"
  namespace       = kubernetes_namespace.dynatrace.metadata[0].name
  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode({
    mode  = "daemonset"
    image = { repository = "otel/opentelemetry-collector-contrib" }

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "512Mi" }
    }

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

        prometheus = {
          config = {
            scrape_configs = [local.self_scrape_job]
          }
        }
      }

      processors = {
        memory_limiter = local.memory_limiter
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
            processors = ["memory_limiter", "k8sattributes", "cumulativetodelta", "batch"]
            exporters  = ["otlphttp"]
          }
          "metrics/self" = {
            receivers  = ["prometheus"] # own :8888
            processors = ["memory_limiter", "cumulativetodelta", "batch"]
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
      phase     = try(p.status.phase, null)
      ready     = try(alltrue([for c in p.status.containerStatuses : c.ready]), false)
      restarts  = try(sum([for c in p.status.containerStatuses : c.restartCount]), 0)
      waiting   = try([for c in p.status.containerStatuses : "${c.state.waiting.reason}: ${try(c.state.waiting.message, "")}"][0], null)
      last_term = try([for c in p.status.containerStatuses : "${c.lastState.terminated.reason} exit=${c.lastState.terminated.exitCode} ${try(c.lastState.terminated.message, "")}"][0], null)
    }
  }
}

output "dynatrace_otel_endpoint" {
  value = "${var.dynatrace_env_url}/api/v2/otlp"
}
