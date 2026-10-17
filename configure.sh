#!/usr/bin/env bash
#
# configure.sh — interactively collects the DigiCert / certificate settings
# and writes them to terraform.tfvars (mode 0600, excluded from the
# repository via .gitignore).
#
# Usage:
#   ./configure.sh                    # writes terraform.tfvars next to this script
#   TFVARS=/path/to/x.tfvars ./configure.sh
#
# If a terraform.tfvars already exists, its values are offered as defaults;
# pressing Enter keeps the default. The API key is entered without echo and
# is never shown in clear text.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${TFVARS:-${SCRIPT_DIR}/terraform.tfvars}"

bold()  { printf '\033[1m%s\033[0m' "$*"; }
log()   { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }
die()   { err "$@"; exit 1; }

[[ -t 0 ]] || die "This script needs an interactive terminal."

# ── Defaults, overridden by an existing tfvars file ─────────────────────
digicert_url="https://one.digicert.com"
digicert_api_key=""
profile_id=""
domain=""
organization=""
tags="terraform"
renew_after_days="3"
cert_dir="/etc/certs"

read_existing() {
  # Reads simple  key = "value"  and  key = number  lines from an existing tfvars file.
  local key val
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=[[:space:]]*\"(.*)\"[[:space:]]*$ ]] ||
       [[ "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
      key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
      case "$key" in
        digicert_url|digicert_api_key|profile_id|domain|organization|tags|renew_after_days|cert_dir)
          printf -v "$key" '%s' "$val" ;;
      esac
    fi
  done < "$1"
}

if [[ -f "$TFVARS" ]]; then
  log "Existing configuration found: ${TFVARS}"
  echo "    Its values are offered as defaults."
  read_existing "$TFVARS"
fi

# ── Input helpers ───────────────────────────────────────────────────────
# ask VAR "Question" "default" validator-function
ask() {
  local var="$1" prompt="$2" default="$3" validate="${4:-}" input
  while true; do
    if [[ -n "$default" ]]; then
      printf '%s [%s]: ' "$(bold "$prompt")" "$default"
    else
      printf '%s: ' "$(bold "$prompt")"
    fi
    IFS= read -r input
    input="${input:-$default}"
    if [[ -z "$input" ]]; then
      err "A value is required."; continue
    fi
    if [[ -n "$validate" ]] && ! "$validate" "$input"; then
      continue
    fi
    printf -v "$var" '%s' "$input"
    return
  done
}

# ask_secret VAR "Question" "existing value"
ask_secret() {
  local var="$1" prompt="$2" existing="$3" input
  while true; do
    if [[ -n "$existing" ]]; then
      printf '%s [%s]: ' "$(bold "$prompt")" "$(mask "$existing")"
    else
      printf '%s: ' "$(bold "$prompt")"
    fi
    IFS= read -rs input; echo
    input="${input:-$existing}"
    if [[ -z "$input" ]]; then
      err "A value is required."; continue
    fi
    if [[ "$input" =~ [[:space:]\"] ]]; then
      err "The API key must not contain whitespace or quotes."; continue
    fi
    printf -v "$var" '%s' "$input"
    return
  done
}

mask() {
  local s="$1"
  if (( ${#s} <= 8 )); then printf '********'; else printf '%s…%s' "${s:0:4}" "${s: -4}"; fi
}

valid_url()     { [[ "$1" =~ ^https://[^/[:space:]]+$ ]] || { err "Must start with https:// and must not contain a path."; return 1; }; }
valid_uuid()    { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { err "Must be a UUID (e.g. 123e4567-e89b-12d3-a456-426614174000)."; return 1; }; }
valid_fqdn()    { [[ "$1" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] || { err "Must be an FQDN (e.g. www.example.com)."; return 1; }; }
valid_abspath() { [[ "$1" == /* ]] || { err "Must be an absolute path."; return 1; }; }
valid_text()    { [[ ! "$1" =~ [\"\\] ]] || { err "Quotes and backslashes are not allowed."; return 1; }; }
valid_days()    { [[ "$1" =~ ^[1-9][0-9]*$ ]] || { err "Must be a whole number of days, at least 1."; return 1; }; }

# ── Questions ───────────────────────────────────────────────────────────
log "DigiCert ONE / Trust Lifecycle Manager"
echo "    The DigiCert ONE URL depends on your region (e.g. https://one.digicert.com)."
echo "    API keys are created in DigiCert ONE under Account > API Tokens."
ask        digicert_url     "DigiCert ONE URL"            "$digicert_url"     valid_url
ask_secret digicert_api_key "API key (hidden)"            "$digicert_api_key"
ask        profile_id       "TLM profile ID (UUID)"       "$profile_id"       valid_uuid

log "Certificate"
ask domain       "Domain / FQDN of the server"     "$domain"       valid_fqdn
ask organization "Organization (O in the subject)" "$organization" valid_text
ask tags         "Tags in TLM (comma-separated)"   "$tags"         valid_text

log "Renewal"
echo "    Key and certificate are re-issued after this many days. The value must be"
echo "    shorter than the validity period of the TLM profile, e.g. 3 for 5-day"
echo "    certificates. A systemd timer (installed by install.sh) runs the check."
ask renew_after_days "Renew after (days)" "$renew_after_days" valid_days

log "Storage on the server"
ask cert_dir "Directory for key and certificate" "$cert_dir" valid_abspath

# ── Summary + confirmation ──────────────────────────────────────────────
log "Summary"
printf '    %-18s %s\n' \
  "DigiCert URL:"   "$digicert_url" \
  "API key:"        "$(mask "$digicert_api_key")" \
  "Profile ID:"     "$profile_id" \
  "Domain:"         "$domain" \
  "Organization:"   "$organization" \
  "Tags:"           "$tags" \
  "Renew after:"    "${renew_after_days} days" \
  "Cert directory:" "$cert_dir" \
  "Target file:"    "$TFVARS"
echo
printf '%s [y/N]: ' "$(bold "Write configuration?")"
IFS= read -r answer
[[ "$answer" =~ ^[yY]$ ]] || die "Aborted, nothing written."

# ── Write atomically with mode 0600 ─────────────────────────────────────
tmp="$(mktemp "${TFVARS}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
chmod 0600 "$tmp"
cat > "$tmp" <<TFV
# Generated by configure.sh on $(date '+%Y-%m-%d %H:%M:%S').
# Contains the DigiCert API key — never commit this file (.gitignore).

digicert_url     = "${digicert_url}"
digicert_api_key = "${digicert_api_key}"
profile_id       = "${profile_id}"

domain       = "${domain}"
organization = "${organization}"
tags         = "${tags}"

renew_after_days = ${renew_after_days}

cert_dir = "${cert_dir}"
TFV
mv -f "$tmp" "$TFVARS"
trap - EXIT

log "Written: ${TFVARS} (mode 0600)"
cat <<EOT

 Next steps:
   cd ${SCRIPT_DIR}
   terraform init      # if not done yet
   terraform plan
   terraform apply     # enrolls the certificate and configures nginx
EOT
