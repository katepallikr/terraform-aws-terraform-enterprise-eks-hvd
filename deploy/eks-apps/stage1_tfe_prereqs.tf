resource "kubernetes_namespace" "tfe" {
  metadata {
    name = "tfe"
  }
}

resource "random_password" "tfe_encryption" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "tfe_secrets" {
  metadata {
    name      = "tfe-secrets"
    namespace = kubernetes_namespace.tfe.metadata[0].name
  }
  data = {
    TFE_LICENSE             = var.tfe_license
    TFE_ENCRYPTION_PASSWORD = random_password.tfe_encryption.result
    TFE_DATABASE_PASSWORD   = base64decode(local.infra.tfe_database_password_base64)
    TFE_REDIS_PASSWORD      = base64decode(local.infra.tfe_redis_password_base64)
  }
}

resource "kubernetes_secret" "tfe_image_pull" {
  metadata {
    name      = "terraform-enterprise"
    namespace = kubernetes_namespace.tfe.metadata[0].name
  }
  type = "kubernetes.io/dockerconfigjson"
  data = {
    ".dockerconfigjson" = jsonencode({
      auths = {
        "images.releases.hashicorp.com" = {
          username = "terraform"
          password = var.tfe_license
          auth     = base64encode("terraform:${var.tfe_license}")
        }
      }
    })
  }
}

# --- Sandbox TLS: private CA + server cert (swap for a real cert later) ---
resource "tls_private_key" "ca" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "tls_self_signed_cert" "ca" {
  private_key_pem       = tls_private_key.ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 8760
  allowed_uses          = ["cert_signing", "crl_signing", "digital_signature"]

  subject {
    common_name  = "sandbox-tfe-ca"
    organization = "sandbox"
  }
}

resource "tls_private_key" "tfe" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "tfe" {
  private_key_pem = tls_private_key.tfe.private_key_pem
  dns_names       = [var.tfe_fqdn]

  subject {
    common_name = var.tfe_fqdn
  }
}

resource "tls_locally_signed_cert" "tfe" {
  cert_request_pem      = tls_cert_request.tfe.cert_request_pem
  ca_private_key_pem    = tls_private_key.ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca.cert_pem
  validity_period_hours = 8760
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

resource "kubernetes_secret" "tfe_certs" {
  metadata {
    name      = "tfe-certs"
    namespace = kubernetes_namespace.tfe.metadata[0].name
  }
  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = "${tls_locally_signed_cert.tfe.cert_pem}${tls_self_signed_cert.ca.cert_pem}"
    "tls.key" = tls_private_key.tfe.private_key_pem
  }
}

output "tfe_ca_cert_pem" {
  value = tls_self_signed_cert.ca.cert_pem
}
