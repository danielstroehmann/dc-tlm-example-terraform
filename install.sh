#!/usr/bin/env bash
#
# install.sh — prepares a fresh Ubuntu 24.04 machine so that only
# ./configure.sh and `terraform apply` remain to be run.
#
# Usage (from the cloned repository):
#   git clone git@github.com:danielstroehmann/dc-tlm-example-terraform.git
#   cd dc-tlm-example-terraform && sudo ./install.sh
#
# What it does:
#   1. installs Terraform (HashiCorp apt repo), nginx and openssl
#   2. creates a self-signed placeholder certificate so nginx can start
#   3. writes a bootstrap nginx site (replaced by Terraform on first apply)
#   4. runs `terraform init`
#   5. installs a systemd timer that runs ./renew.sh every 6 hours so the
#      certificate is re-issued automatically (see renew_after_days)
#
# Everything that matters (domain, API key, profile ID, cert_dir, ...) is
# NOT set here but in terraform.tfvars via ./configure.sh.
#
# The script is idempotent: running it several times is safe.
#
set -euo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" # the repository directory
CERTDIR="/etc/certs" # bootstrap only; the final path is cert_dir in terraform.tfvars
TIMER_NAME="tlm-cert-renew"
export DEBIAN_FRONTEND=noninteractive

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Please run as root (sudo ./install.sh)."
[[ -f "${WORKDIR}/main.tf" && -f "${WORKDIR}/configure.sh" && -f "${WORKDIR}/renew.sh" ]] ||
  die "main.tf / configure.sh / renew.sh not found in ${WORKDIR} — run this script from the cloned repository."

# ── 1. Base packages ────────────────────────────────────────────────────
log "Installing base packages"
apt-get update -y
apt-get install -y gnupg software-properties-common curl ca-certificates lsb-release

# ── 2. HashiCorp apt repository ─────────────────────────────────────────
KEYRING=/usr/share/keyrings/hashicorp-archive-keyring.gpg
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}")"

if [[ ! -s "$KEYRING" ]]; then
  log "Fetching HashiCorp GPG key"
  curl -fsSL https://apt.releases.hashicorp.com/gpg |
    gpg --dearmor -o "$KEYRING"
  chmod 0644 "$KEYRING"
else
  log "HashiCorp GPG key already present"
fi

REPO_LINE="deb [signed-by=${KEYRING}] https://apt.releases.hashicorp.com ${CODENAME} main"
if [[ "$(cat /etc/apt/sources.list.d/hashicorp.list 2>/dev/null || true)" != "$REPO_LINE" ]]; then
  log "Adding HashiCorp repository (${CODENAME})"
  echo "$REPO_LINE" > /etc/apt/sources.list.d/hashicorp.list
  apt-get update -y
fi

# ── 3. Terraform + nginx + openssl ──────────────────────────────────────
log "Installing Terraform, nginx and openssl"
apt-get install -y terraform nginx openssl
terraform version

# ── 4. Certificate directory + bootstrap certificate ────────────────────
# nginx refuses to start without a certificate. Terraform replaces both
# files with the real DigiCert certificate on the first `terraform apply`.
log "Preparing certificate directory ${CERTDIR}"
install -d -m 0700 "$CERTDIR"

if [[ ! -s "${CERTDIR}/tls.crt" || ! -s "${CERTDIR}/tls.key" ]]; then
  log "Creating self-signed placeholder (CN=bootstrap-snakeoil)"
  openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -subj "/CN=bootstrap-snakeoil" \
    -keyout "${CERTDIR}/tls.key" \
    -out    "${CERTDIR}/tls.crt" 2>/dev/null
  chmod 0600 "${CERTDIR}/tls.key"
  chmod 0644 "${CERTDIR}/tls.crt"
else
  log "Certificate in ${CERTDIR} already exists — left untouched"
fi

# ── 5. nginx bootstrap site ─────────────────────────────────────────────
# Deliberately WITHOUT a domain: Terraform writes the final site
# (server_name = domain) on the first `terraform apply`.
if [[ ! -f /etc/nginx/sites-available/default ]] ||
   ! grep -q "ssl_certificate" /etc/nginx/sites-available/default; then
  log "Writing nginx bootstrap site (replaced by Terraform later)"
  cat > /etc/nginx/sites-available/default <<EOT
# Bootstrap configuration — replaced on the first 'terraform apply'.
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
EOT
else
  log "nginx site already exists (possibly managed by Terraform) — left untouched"
fi

ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# ── 6. terraform init ───────────────────────────────────────────────────
log "terraform init (downloads the digicert, tls, local and time providers)"
if ! terraform -chdir="$WORKDIR" init -input=false -no-color; then
  warn "terraform init failed — check network/proxy and run 'terraform init' in ${WORKDIR} manually."
fi

# ── 7. systemd timer for automatic renewal ──────────────────────────────
# Terraform only renews when `terraform apply` is actually run. The timer
# calls renew.sh every 6 hours; renew.sh is a no-op until terraform.tfvars
# exists and until the renewal clock (renew_after_days) has expired.
log "Installing systemd timer ${TIMER_NAME} (runs renew.sh every 6 hours)"
cat > "/etc/systemd/system/${TIMER_NAME}.service" <<EOT
[Unit]
Description=Renew DigiCert TLM certificate via Terraform
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${WORKDIR}
ExecStart=${WORKDIR}/renew.sh
EOT

cat > "/etc/systemd/system/${TIMER_NAME}.timer" <<EOT
[Unit]
Description=Check DigiCert TLM certificate renewal every 6 hours

[Timer]
OnCalendar=*-*-* 00/6:00:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOT

systemctl daemon-reload
systemctl enable --now "${TIMER_NAME}.timer"

# ── Done ────────────────────────────────────────────────────────────────
cat <<EOT

============================================================
 Done. State of the machine:
   terraform : $(terraform version | head -1)
   nginx     : $(nginx -v 2>&1) — running, TLS from ${CERTDIR}
   cert      : $(openssl x509 -in "${CERTDIR}/tls.crt" -noout -subject | sed 's/^subject=//')
   workdir   : ${WORKDIR}
   config    : $([[ -f "${WORKDIR}/terraform.tfvars" ]] && echo "terraform.tfvars present" || echo "no terraform.tfvars yet")
   renewal   : ${TIMER_NAME}.timer — $(systemctl is-active "${TIMER_NAME}.timer")

 Next steps:
   1. cd ${WORKDIR} && ./configure.sh
      -> asks for DigiCert URL, API key, profile ID, domain, renewal
         interval etc. and writes terraform.tfvars
   2. terraform plan
   3. terraform apply
      -> enrolls the certificate, writes the nginx site, reloads nginx
   Afterwards the timer keeps the certificate renewed:
      systemctl list-timers ${TIMER_NAME}.timer
      journalctl -u ${TIMER_NAME}.service
============================================================
EOT
