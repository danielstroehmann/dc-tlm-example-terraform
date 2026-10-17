#!/usr/bin/env bash
#
# install.sh — bereitet eine frische Ubuntu-24.04-Maschine (Template-Clone) so vor,
# dass anschliessend nur noch ./configure.sh und terraform apply laufen muessen.
#
# Nutzung (aus dem geklonten Repo heraus):
#   git clone git@github.com:danielstroehmann/dc-tlm-example-terraform.git
#   cd dc-tlm-terraform && sudo ./install.sh
#
# Alles Entscheidende (Domain, API-Key, Profil-ID, cert_dir) wird NICHT hier,
# sondern per ./configure.sh in terraform.tfvars gesetzt. Das Skript
# bootstrappt nur die Maschine (Terraform, nginx, Platzhalter-Zertifikat).
#
# Das Skript ist idempotent: mehrfaches Ausfuehren aendert nichts kaputt.
#
set -euo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # das Repo-Verzeichnis
CERTDIR="/etc/certs" # nur Bootstrap; der endgueltige Pfad steht in terraform.tfvars (cert_dir)
export DEBIAN_FRONTEND=noninteractive

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fehler]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte als root ausfuehren (sudo ./install.sh)."

# ── 1. Grundpakete ──────────────────────────────────────────────────────
log "Grundpakete installieren"
apt-get update -y
apt-get install -y gnupg software-properties-common curl ca-certificates lsb-release

# ── 2. HashiCorp-APT-Repo eintragen ─────────────────────────────────────
KEYRING=/usr/share/keyrings/hashicorp-archive-keyring.gpg
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"

if [[ ! -s "$KEYRING" ]]; then
  log "HashiCorp-GPG-Key holen"
  curl -fsSL https://apt.releases.hashicorp.com/gpg |
    gpg --dearmor -o "$KEYRING"
  chmod 0644 "$KEYRING"
else
  log "HashiCorp-GPG-Key bereits vorhanden"
fi

REPO_LINE="deb [signed-by=${KEYRING}] https://apt.releases.hashicorp.com ${CODENAME} main"
if [[ "$(cat /etc/apt/sources.list.d/hashicorp.list 2>/dev/null || true)" != "$REPO_LINE" ]]; then
  log "HashiCorp-Repo eintragen (${CODENAME})"
  echo "$REPO_LINE" > /etc/apt/sources.list.d/hashicorp.list
  apt-get update -y
fi

# ── 3. Terraform + nginx + openssl ──────────────────────────────────────
log "Terraform, nginx und openssl installieren"
apt-get install -y terraform nginx openssl
terraform version

# ── 4. Cert-Verzeichnis + Bootstrap-Zertifikat ──────────────────────────
# nginx startet nicht ohne existierendes Zertifikat. Terraform ersetzt beide
# Dateien beim ersten `terraform apply` durch das echte DigiCert-Zertifikat.
log "Zertifikatsverzeichnis ${CERTDIR} vorbereiten"
install -d -m 0700 "$CERTDIR"

if [[ ! -s "${CERTDIR}/tls.crt" || ! -s "${CERTDIR}/tls.key" ]]; then
  log "Self-Signed-Platzhalter erzeugen (CN=bootstrap-snakeoil)"
  openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -subj "/CN=bootstrap-snakeoil" \
    -keyout "${CERTDIR}/tls.key" \
    -out    "${CERTDIR}/tls.crt" 2>/dev/null
  chmod 0600 "${CERTDIR}/tls.key"
  chmod 0644 "${CERTDIR}/tls.crt"
else
  log "Zertifikat in ${CERTDIR} existiert bereits — unveraendert"
fi

# ── 5. nginx-Bootstrap-Site ─────────────────────────────────────────────
# Bewusst OHNE Domain: die endgueltige Site (server_name = locals.domain)
# schreibt Terraform beim ersten `terraform apply` selbst.
if [[ ! -f /etc/nginx/sites-available/default ]] ||
   ! grep -q "ssl_certificate" /etc/nginx/sites-available/default; then
  log "nginx-Bootstrap-Site schreiben (wird spaeter von Terraform ersetzt)"
  cat > /etc/nginx/sites-available/default <<EOF
# Bootstrap-Konfiguration — wird beim ersten 'terraform apply' ersetzt.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;

    server_name _;

    ssl_certificate     ${CERTDIR}/tls.crt;
    ssl_certificate_key ${CERTDIR}/tls.key;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    root  /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
else
  log "nginx-Site existiert bereits (evtl. von Terraform verwaltet) — unveraendert"
fi

ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# ── 6. Terraform-Konfiguration pruefen ──────────────────────────────────
log "Terraform-Konfiguration in ${WORKDIR}"
[[ -f "${WORKDIR}/main.tf" && -f "${WORKDIR}/configure.sh" ]] ||
  die "main.tf / configure.sh fehlen in ${WORKDIR} — Skript bitte aus dem geklonten Repo starten."

# ── 7. terraform init ───────────────────────────────────────────────────
log "terraform init (laedt digicert-, tls- und local-Provider)"
if ! terraform -chdir="$WORKDIR" init -input=false -no-color; then
  warn "terraform init fehlgeschlagen — Netzwerk/Proxy pruefen und im Ordner ${WORKDIR} manuell 'terraform init' ausfuehren."
fi

# ── Fertig ──────────────────────────────────────────────────────────────
cat <<EOF

============================================================
 Fertig. Zustand der Maschine:
   terraform : $(terraform version | head -1)
   nginx     : $(nginx -v 2>&1) — aktiv, TLS aus ${CERTDIR}
   Zertifikat: $(openssl x509 -in "${CERTDIR}/tls.crt" -noout -subject | sed 's/^subject=//')
   Workdir   : ${WORKDIR}
   Konfig    : $([[ -f "${WORKDIR}/terraform.tfvars" ]] && echo "terraform.tfvars vorhanden" || echo "noch keine terraform.tfvars")

 Naechste Schritte:
   1. cd ${WORKDIR} && ./configure.sh
      -> fragt DigiCert-URL, API-Key, Profil-ID, Domain usw. ab
         und schreibt terraform.tfvars
   2. terraform plan
   3. terraform apply
      -> schreibt echtes Cert + nginx-Site und reloadet nginx
============================================================
EOF
