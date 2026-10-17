########################################################################
# Konfigurierbare Werte
#
# Werte werden NICHT hier gesetzt, sondern in terraform.tfvars.
# Diese Datei erzeugt ./configure.sh interaktiv; sie ist per .gitignore
# vom Repo ausgeschlossen, weil sie den API-Key enthält.
########################################################################

# ── DigiCert ONE / TLM Zugang ───────────────────────────────────────────
variable "digicert_url" {
  description = "Basis-URL der DigiCert-ONE-Instanz (je nach Region, z. B. https://one.digicert.com oder https://one.ch.digicert.com)"
  type        = string
  default     = "https://one.digicert.com"

  validation {
    condition     = can(regex("^https://[^/]+$", var.digicert_url))
    error_message = "digicert_url muss mit https:// beginnen und darf keinen Pfad enthalten."
  }
}

variable "digicert_api_key" {
  description = "API-Key eines DigiCert-ONE-Benutzers mit Berechtigung auf das TLM-Profil"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.digicert_api_key) > 0
    error_message = "digicert_api_key darf nicht leer sein."
  }
}

variable "profile_id" {
  description = "ID des TLM-Zertifikatsprofils (UUID), aus dem ausgestellt wird"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.profile_id))
    error_message = "profile_id muss eine UUID sein."
  }
}

# ── Zertifikat ──────────────────────────────────────────────────────────
variable "domain" {
  description = "FQDN des Servers; wird Common Name des Zertifikats und server_name in nginx"
  type        = string

  validation {
    condition     = can(regex("^([a-zA-Z0-9-]+\\.)+[a-zA-Z]{2,}$", var.domain))
    error_message = "domain muss ein gültiger FQDN sein (z. B. www.example.com)."
  }
}

variable "organization" {
  description = "Organisation (O) im Subject des CSR"
  type        = string
}

variable "tags" {
  description = "Kommagetrennte Tags, die TLM am Zertifikat speichert"
  type        = string
  default     = "terraform"
}

# ── Ablage auf dem Server ───────────────────────────────────────────────
variable "cert_dir" {
  description = "Verzeichnis, in das Key und Zertifikat geschrieben werden"
  type        = string
  default     = "/etc/certs"

  validation {
    condition     = startswith(var.cert_dir, "/")
    error_message = "cert_dir muss ein absoluter Pfad sein."
  }
}
