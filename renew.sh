#!/usr/bin/env bash
#
# renew.sh — applies the Terraform configuration non-interactively.
#
# Called by the systemd timer that install.sh sets up (tlm-cert-renew.timer),
# but can also be run by hand. Terraform itself decides whether anything
# needs to happen: once the renewal clock (time_rotating) has expired, key
# and certificate are re-issued and nginx is reloaded; otherwise this is a
# no-op.
#
# Usage:
#   ./renew.sh           # renew only if the renewal clock has expired
#   ./renew.sh --force   # renew now: restarts the clock, re-issues key + cert
#
set -euo pipefail

FORCE=()
case "${1:-}" in
  --force) FORCE=(-replace=time_rotating.renew) ;;
  "") ;;
  *) echo "Usage: $0 [--force]" >&2; exit 2 ;;
esac

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="/run/lock/tlm-cert-renew.lock"

if [[ ! -f "${DIR}/terraform.tfvars" ]]; then
  echo "No terraform.tfvars in ${DIR} yet — run ./configure.sh first. Nothing to do."
  exit 0
fi

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Another renewal run is still in progress. Skipping."
  exit 0
fi

if [[ ! -d "${DIR}/.terraform" ]]; then
  terraform -chdir="$DIR" init -input=false -no-color
fi

terraform -chdir="$DIR" apply -auto-approve -input=false -no-color "${FORCE[@]}"
