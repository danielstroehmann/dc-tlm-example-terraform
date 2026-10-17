#!/usr/bin/env bash
#
# configure.sh — fragt die DigiCert-/Zertifikats-Konfiguration interaktiv ab
# und schreibt sie nach terraform.tfvars (Rechte 0600, per .gitignore vom
# Repo ausgeschlossen).
#
# Nutzung:
#   ./configure.sh                 # terraform.tfvars neben dem Skript
#   TFVARS=/pfad/zu/x.tfvars ./configure.sh
#
# Existiert bereits eine terraform.tfvars, werden deren Werte als Vorgabe
# angeboten; mit Enter wird die Vorgabe übernommen. Der API-Key wird
# verdeckt eingegeben und nie im Klartext angezeigt.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${TFVARS:-${SCRIPT_DIR}/terraform.tfvars}"

bold()  { printf '\033[1m%s\033[0m' "$*"; }
log()   { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
err()   { printf '\033[1;31m[fehler]\033[0m %s\n' "$*" >&2; }
die()   { err "$@"; exit 1; }

[[ -t 0 ]] || die "Dieses Skript braucht ein interaktives Terminal."

# ── Vorgaben: Standardwerte, überschrieben durch vorhandene tfvars ───────
digicert_url="https://one.digicert.com"
digicert_api_key=""
profile_id=""
domain=""
organization=""
tags="terraform"
cert_dir="/etc/certs"

read_existing() {
  # Liest einfache  key = "value"  Zeilen aus einer bestehenden tfvars ein.
  local key val
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*([a-z_]+)[[:space:]]*=[[:space:]]*\"(.*)\"[[:space:]]*$ ]] || continue
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    case "$key" in
      digicert_url|digicert_api_key|profile_id|domain|organization|tags|cert_dir)
        printf -v "$key" '%s' "$val" ;;
    esac
  done < "$1"
}

if [[ -f "$TFVARS" ]]; then
  log "Vorhandene Konfiguration gefunden: ${TFVARS}"
  echo "    Die bisherigen Werte werden als Vorgabe angeboten."
  read_existing "$TFVARS"
fi

# ── Eingabehilfen ───────────────────────────────────────────────────────
# ask VAR "Frage" "Vorgabe" validator-funktion
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
      err "Eingabe erforderlich."; continue
    fi
    if [[ -n "$validate" ]] && ! "$validate" "$input"; then
      continue
    fi
    printf -v "$var" '%s' "$input"
    return
  done
}

# ask_secret VAR "Frage" "bisheriger Wert"
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
      err "Eingabe erforderlich."; continue
    fi
    if [[ "$input" =~ [[:space:]\"] ]]; then
      err "Der API-Key darf keine Leerzeichen oder Anführungszeichen enthalten."; continue
    fi
    printf -v "$var" '%s' "$input"
    return
  done
}

mask() {
  local s="$1"
  if (( ${#s} <= 8 )); then printf '********'; else printf '%s…%s' "${s:0:4}" "${s: -4}"; fi
}

valid_url()     { [[ "$1" =~ ^https://[^/[:space:]]+$ ]] || { err "Muss mit https:// beginnen und darf keinen Pfad enthalten."; return 1; }; }
valid_uuid()    { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || { err "Muss eine UUID sein (z. B. 123e4567-e89b-12d3-a456-426614174000)."; return 1; }; }
valid_fqdn()    { [[ "$1" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] || { err "Muss ein FQDN sein (z. B. www.example.com)."; return 1; }; }
valid_abspath() { [[ "$1" == /* ]] || { err "Muss ein absoluter Pfad sein."; return 1; }; }
valid_text()    { [[ ! "$1" =~ [\"\\] ]] || { err "Anführungszeichen und Backslash sind nicht erlaubt."; return 1; }; }

# ── Fragen ──────────────────────────────────────────────────────────────
log "DigiCert ONE / Trust Lifecycle Manager"
echo "    Die DigiCert-ONE-URL hängt von der Region ab, z. B. https://one.digicert.com"
echo "    (global) oder https://one.ch.digicert.com (Schweiz). Den API-Key erzeugt"
echo "    ein Benutzer in DigiCert ONE unter Account > API-Tokens."
ask        digicert_url     "DigiCert-ONE-URL"             "$digicert_url"     valid_url
ask_secret digicert_api_key "API-Key (verdeckt)"           "$digicert_api_key"
ask        profile_id       "TLM-Profil-ID (UUID)"         "$profile_id"       valid_uuid

log "Zertifikat"
ask domain       "Domain / FQDN des Servers"       "$domain"       valid_fqdn
ask organization "Organisation (O im Subject)"     "$organization" valid_text
ask tags         "Tags in TLM (kommagetrennt)"     "$tags"         valid_text

log "Ablage auf dem Server"
ask cert_dir "Verzeichnis für Key und Zertifikat" "$cert_dir" valid_abspath

# ── Zusammenfassung + Bestätigung ───────────────────────────────────────
log "Zusammenfassung"
printf '    %-18s %s\n' \
  "DigiCert-URL:"  "$digicert_url" \
  "API-Key:"       "$(mask "$digicert_api_key")" \
  "Profil-ID:"     "$profile_id" \
  "Domain:"        "$domain" \
  "Organisation:"  "$organization" \
  "Tags:"          "$tags" \
  "Cert-Dir:"      "$cert_dir" \
  "Zieldatei:"     "$TFVARS"
echo
printf '%s [j/N]: ' "$(bold "Konfiguration schreiben?")"
IFS= read -r answer
[[ "$answer" =~ ^[jJyY]$ ]] || die "Abgebrochen, nichts geschrieben."

# ── Schreiben (atomar, 0600) ────────────────────────────────────────────
tmp="$(mktemp "${TFVARS}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
chmod 0600 "$tmp"
cat > "$tmp" <<TFV
# Erzeugt von configure.sh am $(date '+%Y-%m-%d %H:%M:%S').
# Enthält den DigiCert-API-Key — nicht ins Repo committen (.gitignore).

digicert_url     = "${digicert_url}"
digicert_api_key = "${digicert_api_key}"
profile_id       = "${profile_id}"

domain       = "${domain}"
organization = "${organization}"
tags         = "${tags}"

cert_dir = "${cert_dir}"
TFV
mv -f "$tmp" "$TFVARS"
trap - EXIT

log "Geschrieben: ${TFVARS} (Rechte 0600)"
cat <<EOT

 Nächste Schritte:
   cd ${SCRIPT_DIR}
   terraform init      # falls noch nicht geschehen
   terraform plan
   terraform apply     # stellt das Zertifikat aus und konfiguriert nginx
EOT
