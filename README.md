# DigiCert Trust Lifecycle Manager + Terraform example

Issues a TLS certificate for an nginx server from a [DigiCert Trust Lifecycle
Manager](https://www.digicert.com/trust-lifecycle-manager) (TLM) profile using
the [`digicert/digicert`](https://registry.terraform.io/providers/digicert/digicert)
Terraform provider, and keeps it renewed. Built for short-lived certificates
(a few days), but works with any profile.

## How it works

1. `tls_private_key` / `tls_cert_request` generate a key and CSR locally. The key never leaves the machine.
2. `digicert_certificate` enrolls the certificate from the TLM profile.
3. Key and certificate are written to `cert_dir`, an nginx site is generated and nginx is reloaded.
4. A `time_rotating` resource acts as a renewal clock. Once `renew_after_days` have passed, key, CSR and certificate are replaced. `create_before_destroy` makes sure the new certificate is on disk before the old one is revoked in TLM.
5. A systemd timer (`tlm-cert-renew.timer`) runs `renew.sh`, i.e. `terraform apply`, every 6 hours. Terraform decides whether a renewal is due.

## Files

| File | Purpose |
| --- | --- |
| `install.sh` | Bootstraps an Ubuntu 24.04 host: Terraform, nginx, placeholder cert, systemd timer |
| `configure.sh` | Interactive wizard that writes `terraform.tfvars` |
| `renew.sh` | Non-interactive `terraform apply`, used by the timer |
| `main.tf` | Resources |
| `variables.tf` | All configurable values with validation |
| `terraform.tfvars.example` | Template of the generated configuration |

`terraform.tfvars` and the Terraform state contain the API key and the private key. Both are git-ignored.

## Quick start

```bash
git clone git@github.com:danielstroehmann/dc-tlm-example-terraform.git
cd dc-tlm-example-terraform
sudo ./install.sh      # packages, nginx, terraform init, renewal timer
./configure.sh         # DigiCert URL, API key, profile ID, domain, ...
terraform plan
terraform apply
```

Check renewal status with:

```bash
terraform output                       # serial, validity, next renewal
systemctl list-timers tlm-cert-renew.timer
journalctl -u tlm-cert-renew.service
```

## Requirements

* DigiCert ONE account with a TLM certificate profile that accepts CSR enrollment via API
* API key of a user allowed to enroll from that profile
* Ubuntu 24.04 (or adapt `install.sh`), root access, port 80/443 reachable
