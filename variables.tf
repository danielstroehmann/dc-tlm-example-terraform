########################################################################
# Configurable values
#
# Do NOT set values here. Put them in terraform.tfvars, which
# ./configure.sh generates interactively. terraform.tfvars is excluded
# from the repository via .gitignore because it contains the API key.
########################################################################

# ── DigiCert ONE / TLM access ───────────────────────────────────────────
variable "digicert_url" {
  description = "Base URL of your DigiCert ONE instance (region dependent, e.g. https://one.digicert.com)"
  type        = string
  default     = "https://one.digicert.com"

  validation {
    condition     = can(regex("^https://[^/]+$", var.digicert_url))
    error_message = "digicert_url must start with https:// and must not contain a path."
  }
}

variable "digicert_api_key" {
  description = "API key of a DigiCert ONE user who is allowed to enroll from the TLM profile"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.digicert_api_key) > 0
    error_message = "digicert_api_key must not be empty."
  }
}

variable "profile_id" {
  description = "ID (UUID) of the Trust Lifecycle Manager certificate profile to enroll from"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.profile_id))
    error_message = "profile_id must be a UUID."
  }
}

# ── Certificate ─────────────────────────────────────────────────────────
variable "domain" {
  description = "FQDN of the server; becomes the certificate's common name and the nginx server_name"
  type        = string

  validation {
    condition     = can(regex("^([a-zA-Z0-9-]+\\.)+[a-zA-Z]{2,}$", var.domain))
    error_message = "domain must be a valid FQDN (e.g. www.example.com)."
  }
}

variable "organization" {
  description = "Organization (O) in the CSR subject"
  type        = string
}

variable "tags" {
  description = "Comma-separated tags stored on the certificate in TLM"
  type        = string
  default     = "terraform"
}

# ── Renewal ─────────────────────────────────────────────────────────────
variable "renew_at_percent" {
  description = "Re-issue key and certificate once this percentage of the current certificate's validity period has elapsed. The validity is read from the certificate on disk, so this adapts to whatever the TLM profile issues."
  type        = number
  default     = 70

  validation {
    condition     = var.renew_at_percent >= 1 && var.renew_at_percent <= 99
    error_message = "renew_at_percent must be between 1 and 99."
  }
}

# ── Storage on the server ───────────────────────────────────────────────
variable "cert_dir" {
  description = "Directory the private key and certificate are written to"
  type        = string
  default     = "/etc/certs"

  validation {
    condition     = startswith(var.cert_dir, "/")
    error_message = "cert_dir must be an absolute path."
  }
}
