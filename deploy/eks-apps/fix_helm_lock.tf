# TEMP: clears a stuck helm release. Delete this file after one successful apply.
resource "kubernetes_service_account_v1" "helm_fixer" {
  metadata {
    name      = "helm-fixer"
    namespace = "tfe"
  }
}

resource "kubernetes_cluster_role_binding_v1" "helm_fixer" {
  metadata {
    name = "helm-fixer"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.helm_fixer.metadata[0].name
    namespace = "tfe"
  }
}

resource "kubernetes_job_v1" "helm_unlock" {
  metadata {
    name      = "helm-unlock-tfe-2"
    namespace = "tfe"
  }

  spec {
    backoff_limit = 1

    template {
      metadata {}

      spec {
        service_account_name = kubernetes_service_account_v1.helm_fixer.metadata[0].name
        restart_policy       = "Never"

        container {
          name  = "helm"
          image = "alpine/helm:3.16.3"
          command = [
            "sh", "-c",
            "helm status terraform-enterprise -n tfe | grep -q 'STATUS: pending' && helm rollback terraform-enterprise -n tfe || echo 'release not locked, nothing to do'"
          ]
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "5m"
  }

  depends_on = [kubernetes_cluster_role_binding_v1.helm_fixer]
}
