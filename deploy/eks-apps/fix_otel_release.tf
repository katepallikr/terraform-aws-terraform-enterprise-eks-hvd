# TEMP: removes the broken otel release so Terraform can install it cleanly.
resource "kubernetes_service_account_v1" "helm_fixer_dt" {
  metadata {
    name      = "helm-fixer"
    namespace = "dynatrace"
  }
}

resource "kubernetes_cluster_role_binding_v1" "helm_fixer_dt" {
  metadata {
    name = "helm-fixer-dt"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.helm_fixer_dt.metadata[0].name
    namespace = "dynatrace"
  }
}

resource "kubernetes_job_v1" "otel_uninstall" {
  metadata {
    name      = "helm-uninstall-otel"
    namespace = "dynatrace"
  }

  spec {
    backoff_limit = 1

    template {
      metadata {}

      spec {
        service_account_name = kubernetes_service_account_v1.helm_fixer_dt.metadata[0].name
        restart_policy       = "Never"

        container {
          name  = "helm"
          image = "alpine/helm:3.16.3"
          command = [
            "sh", "-c",
            "helm uninstall otel-tfe-metrics -n dynatrace --wait || echo 'nothing to uninstall'"
          ]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
  }

  depends_on = [kubernetes_cluster_role_binding_v1.helm_fixer_dt]
}
