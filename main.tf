########################################################################
# DigiCert Trust Lifecycle Manager - TLS via Terraform
#
# Konfiguration liegt in terraform.tfvars (erzeugt durch ./configure.sh),
# die Variablen sind in variables.tf beschrieben:
#   - domain           -> CN des Zertifikats + nginx server_name
#   - cert_dir         -> Ablageort für Key/Cert
#   - digicert_url     -> DigiCert-ONE-Instanz
#   - digicert_api_key -> DigiCert ONE / TLM API-Key
#   - profile_id       -> TLM Profile-ID
#
# Ablauf:
#   1. tls_private_key      -> privater Schlüssel (bleibt auf der Maschine)
#   2. tls_cert_request     -> CSR aus dem lokalen Schlüssel
#   3. digicert_certificate -> Zertifikat vom TLM Profile ausstellen
#   4. local_(sensitive_)file -> Key + Cert-Kette nach cert_dir schreiben
#   5. local_file           -> nginx-Site mit server_name = domain schreiben
#   6. terraform_data       -> nginx reloaden, wenn Cert oder Site wechseln
########################################################################

terraform {
  required_providers {
    digicert = { source = "digicert/digicert", version = "~> 0.1" }
    tls      = { source = "hashicorp/tls", version = "~> 4.0" }
    local    = { source = "hashicorp/local", version = "~> 2.5" }
  }
}

# ── DigiCert ONE / TLM Zugang ───────────────────────────────────────────
provider "digicert" {
  url     = var.digicert_url
  api_key = var.digicert_api_key
}

# ── Lokal erzeugter Schlüssel + CSR ─────────────────────────────────────
resource "tls_private_key" "srv" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "srv" {
  private_key_pem = tls_private_key.srv.private_key_pem
  subject {
    common_name  = var.domain
    organization = var.organization
  }
}

# ── Zertifikat vom TLM Profile bestellen ────────────────────────────────
resource "digicert_certificate" "srv" {
  profile_id  = var.profile_id
  common_name = var.domain
  csr         = tls_cert_request.srv.cert_request_pem
  tags        = var.tags
}

# ── An nginx-Standort ablegen ───────────────────────────────────────────
resource "local_sensitive_file" "key" {
  filename        = "${var.cert_dir}/tls.key"
  content         = tls_private_key.srv.private_key_pem
  file_permission = "0600"
}

resource "local_file" "crt" {
  filename        = "${var.cert_dir}/tls.crt"
  content         = digicert_certificate.srv.certificate
  file_permission = "0644"
}

# ── nginx-Site aus der Domain generieren ────────────────────────────────
resource "local_file" "nginx_site" {
  filename        = "/etc/nginx/sites-available/default"
  file_permission = "0644"
  content         = <<-EOT
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name ${var.domain} _;
        return 301 https://$host$request_uri;
    }

    server {
        listen 443 ssl http2 default_server;
        listen [::]:443 ssl http2 default_server;

        server_name ${var.domain};

        ssl_certificate     ${var.cert_dir}/tls.crt;
        ssl_certificate_key ${var.cert_dir}/tls.key;

        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;

        root  /var/www/html;
        index index.html;

        location / {
            try_files $uri $uri/ =404;
        }
    }
  EOT
}

# ── nginx neu laden, sobald Cert oder Site wechseln ─────────────────────
resource "terraform_data" "nginx_reload" {
  triggers_replace = [
    digicert_certificate.srv.certificate,
    local_file.nginx_site.content,
  ]
  provisioner "local-exec" {
    command = "nginx -t && systemctl reload nginx"
  }
  depends_on = [local_file.crt, local_sensitive_file.key, local_file.nginx_site]
}

# ── Nützliche Ausgaben ──────────────────────────────────────────────────
# Ausgestelltes Zertifikat parsen (der Provider liefert außer PEM und
# Seriennummer nichts zurück; request_id bleibt bei Ausstellung leer)
data "tls_certificate" "srv" {
  content = digicert_certificate.srv.certificate
}

locals {
  leaf_cert = [for c in data.tls_certificate.srv.certificates : c if !c.is_ca][0]
}

output "certificate_serial" { value = digicert_certificate.srv.serial_number }
output "certificate_domain" { value = var.domain }
output "certificate_not_before" { value = local.leaf_cert.not_before }
output "certificate_not_after" { value = local.leaf_cert.not_after }
