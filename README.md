# DigiCert Trust Lifecycle Manager + Terraform

Short-lived TLS certificates for an nginx host, enrolled from a DigiCert
[Trust Lifecycle Manager](https://www.digicert.com/trust-lifecycle-manager) (TLM)
profile with the [`digicert/digicert`](https://registry.terraform.io/providers/digicert/digicert/latest)
Terraform provider, and renewed automatically. Tested with 5-day certificates,
works with any validity period.

The repository is a worked example, not a module. Read it, steal from it, adapt
it. It assumes you know Terraform and have admin access to a DigiCert ONE account.

## What happens on `terraform apply`

```
time_rotating.renew ──┐ (renewal clock, expires every renew_after_days)
                      ├─► tls_private_key.srv ─► tls_cert_request.srv ─► digicert_certificate.srv
terraform_data.cert_params ┘ (profile_id)                                        │
                                                                                 ▼
                      local_sensitive_file.key   local_file.crt   local_file.nginx_site   local_file.index_html
                                                        │
                                                        ▼
                                          terraform_data.nginx_reload  (nginx -t && systemctl reload nginx)
```

1. A 2048-bit RSA key and a CSR (CN = `domain`, O = `organization`) are generated locally. The key never leaves the host.
2. `digicert_certificate` POSTs the CSR to `/mpki/api/v1/certificate` on your DigiCert ONE instance and gets the PEM chain back.
3. Key, certificate, an nginx site for `domain` and the demo page from `www/` are written to disk; nginx is reloaded.
4. When the renewal clock expires, steps 1 to 3 run again with a fresh key. See [Renewal](#renewal).

## DigiCert configuration

This is the part that usually costs time. You need three things from DigiCert ONE:
the instance URL, an API key and a profile ID.

### 1. Instance URL (`digicert_url`)

DigiCert ONE is hosted per region. Use the base URL you log in to, without a path.
Examples: `https://one.digicert.com`, `https://one.ch.digicert.com`, `https://demo.one.digicert.com`.
A key from one instance does not work on another; a wrong URL shows up as HTTP 401.

### 2. TLM certificate profile (`profile_id`)

In DigiCert ONE open **Trust Lifecycle Manager → Policies → Certificate profiles**
and create a profile (or reuse one) with these properties:

| Setting | Required value | Why |
| --- | --- | --- |
| Enrollment method | **REST API** | The provider talks to the TLM REST API; profiles with browser, ACME or SCEP enrollment reject the call. |
| Authentication | API token | Lets a service user enroll with an `x-api-key` header. |
| CSR | Required / provided by requester | The CSR is generated on the host; TLM must accept it instead of generating the key itself. |
| Subject / SAN rules | CN taken from the CSR, SAN added by TLM or taken from CSR | The example sends only `common_name`. TLM profiles normally copy the CN into the SAN. If your profile insists on explicit SANs, add `dns_names = [var.domain]` to `digicert_certificate.srv`. |
| Validity | Anything, e.g. 5 days | `renew_after_days` must be shorter than this. |
| CA / template | Public TLS or private CA, server authentication | nginx serves it; browsers must trust the issuing CA. |
| Seat type and business unit | A seat pool with free seats | Each enrollment consumes a seat; TLM returns an error when the pool is exhausted. |

The profile ID is the UUID shown in the profile details (and in the URL when
the profile is open). Copy it into `configure.sh` when asked.

### 3. API key (`digicert_api_key`)

Create a dedicated service user rather than using a personal account:

1. **Account Manager → Users → Add user**, give it a role that includes
   *Trust Lifecycle Manager: enroll certificates* for the business unit the
   profile belongs to. Read-only roles produce HTTP 403.
2. Open the user, **API tokens → Create**, and copy the key. It is shown once.
3. Give the key an expiry that matches your rotation policy. An expired or
   revoked key fails with HTTP 401 at provider initialisation, before any plan
   is produced.

The key is stored in `terraform.tfvars` (mode 0600, git-ignored) and in the
Terraform state. Treat both as secrets.

### How the provider behaves (read this before relying on it)

The `digicert/digicert` provider (v0.1.x) is minimal. Things worth knowing:

* `digicert_certificate` has only `profile_id`, `common_name`, `csr`,
  `dns_names`, `tags` as inputs and `certificate`, `serial_number`,
  `request_id`, `delivery_format` as outputs. There is no validity, no
  renewal and no expiry handling in the provider.
* **Changing `csr`, `common_name` or `profile_id` is planned as an in-place
  update and does not enroll a new certificate.** This example forces
  replacement through `replace_triggered_by` instead. Without that, a key
  rotation would leave you with a new key and the old certificate.
* **Destroying the resource revokes the certificate in TLM.** Replacement is
  therefore done with `create_before_destroy`, so the new certificate is on
  disk and loaded by nginx before the old one is revoked.
* Revoking an already expired certificate can fail. If an expired certificate
  is stuck in your state, drop it with
  `terraform state rm digicert_certificate.srv` and apply again.
* `request_id` is empty for direct enrollments; the certificate dates come
  from parsing the PEM with the `tls_certificate` data source.

## Files

| File | Purpose |
| --- | --- |
| `install.sh` | Bootstraps an Ubuntu 24.04 host: HashiCorp apt repo, Terraform, nginx, placeholder certificate, `terraform init`, systemd timer |
| `configure.sh` | Interactive wizard, writes `terraform.tfvars` (API key entered without echo) |
| `renew.sh` | Non-interactive `terraform apply`; `--force` renews immediately |
| `main.tf` | Resources and lifecycle rules |
| `variables.tf` | Inputs with validation |
| `terraform.tfvars.example` | Shape of the generated configuration |
| `www/index.html` | Demo page written to `/var/www/html/index.html` |

`terraform.tfvars`, `terraform.tfstate*` and `.terraform/` are git-ignored.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `digicert_url` | `https://one.digicert.com` | Base URL of the DigiCert ONE instance |
| `digicert_api_key` | — | Sensitive |
| `profile_id` | — | UUID of the TLM profile |
| `domain` | — | FQDN; CN of the certificate and `server_name` in nginx |
| `organization` | — | O in the CSR subject |
| `tags` | `terraform` | Comma-separated, stored on the certificate in TLM |
| `renew_after_days` | `3` | Whole days; must be shorter than the profile validity |
| `cert_dir` | `/etc/certs` | Where `tls.key` and `tls.crt` are written |

## Quick start

```bash
git clone git@github.com:danielstroehmann/dc-tlm-example-terraform.git
cd dc-tlm-example-terraform
sudo ./install.sh      # packages, nginx with placeholder cert, terraform init, timer
./configure.sh         # URL, API key, profile ID, domain, renewal interval, ...
terraform plan
terraform apply        # or: ./renew.sh
```

`install.sh` is idempotent and does not touch an existing `terraform.tfvars` or
an nginx site that already references a certificate. Run it from the cloned
repository; it uses its own directory as the Terraform working directory.

## Renewal

Terraform has no notion of time, and the provider has no notion of expiry.
Renewal is built from three pieces:

1. **A clock in the state.** `time_rotating.renew` stores its creation
   timestamp plus `rotation_days`. Once that moment has passed, the next
   `terraform plan` marks the resource for replacement.
2. **Replacement that cascades.** `tls_private_key.srv` and
   `digicert_certificate.srv` carry
   `lifecycle { replace_triggered_by = [time_rotating.renew, ...] }`.
   Replacing the clock replaces the key, which changes the CSR, and the
   certificate is replaced explicitly as well. `create_before_destroy` on
   both makes Terraform enroll the new certificate first, rewrite the files,
   reload nginx and only then revoke the old certificate.
3. **Something that runs `terraform apply`.** `install.sh` installs
   `tlm-cert-renew.timer`, which calls `renew.sh` every 6 hours
   (`OnCalendar=*-*-* 00/6:00:00`, `Persistent=true`, 15 min jitter).
   `renew.sh` takes a lock, skips when no `terraform.tfvars` exists, and runs
   `terraform apply -auto-approve`. When the clock has not expired, that
   apply is a no-op.

Timing: with 5-day certificates and `renew_after_days = 3`, renewal happens
between day 3 and day 3.25, leaving well over a day of margin. The clock
starts at the time of the apply that created it, not at the certificate's
`notBefore`, so after `./renew.sh --force` the next renewal is again
`renew_after_days` later. Changing `renew_after_days` updates the clock in
place and triggers one immediate renewal.

Changing `domain` or `organization` changes the CSR and therefore re-enrolls;
changing `profile_id` re-enrolls through `terraform_data.cert_params`.
Changing `tags` only is an in-place update in TLM.

## Operations

```bash
terraform output                           # serial, notBefore/notAfter, next_renewal_after
systemctl list-timers tlm-cert-renew.timer # next scheduled run
journalctl -u tlm-cert-renew.service -n 50 # output of the last runs
./renew.sh --force                         # renew right now (new key + certificate)
./configure.sh                             # rotate the API key or change settings; existing values are offered as defaults
openssl s_client -connect localhost:443 -servername "$(terraform output -raw certificate_domain)" </dev/null 2>/dev/null | openssl x509 -noout -serial -dates
```

## Caveats

* **State contains secrets.** The private key and the API key are in
  `terraform.tfstate`. For anything beyond a demo use an encrypted remote
  backend and restrict access.
* **Short gap on disk during replacement.** `local_file` resources are
  replaced, not updated: the old `tls.crt`/`tls.key` are deleted a few seconds
  before the new ones are written. Running nginx workers keep the loaded
  certificate in memory, so traffic is unaffected, but an nginx restart in
  that window would fail. `create_before_destroy` cannot be used on
  `local_file` with a fixed filename because the deferred destroy would
  delete the freshly written file.
* **Revocation on every renewal.** Each renewal revokes the previous
  certificate. If your profile or CA charges per issuance or revocation, or
  if you prefer to let old certificates expire, remove the
  `digicert_certificate` resource from the state before replacing it, or
  change the lifecycle to your liking.
* **Single host.** Paths (`/etc/nginx/sites-available/default`,
  `/var/www/html`) and the `local-exec` reload assume Terraform runs on the
  nginx host as root.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `Unable to create Digicert client ... status code 401` during plan | API key expired or revoked, or `digicert_url` points at the wrong regional instance |
| HTTP 403 on apply | The API user's role lacks enroll permission on the profile's business unit |
| Enrollment error mentioning the profile or enrollment method | Profile is not set to REST API enrollment, does not accept a CSR, or the seat pool is empty |
| Plan shows `digicert_certificate.srv will be updated in-place` after changing the CSR | Expected provider behaviour; the `replace_triggered_by` rules in `main.tf` turn it into a replacement. Check that you did not remove them. |
| `nginx -t` fails in the `local-exec` step | Key and certificate on disk do not belong together, usually after a partially failed apply. Run `./renew.sh --force`. |
| Apply fails destroying an old, expired certificate | TLM refuses to revoke expired certificates. `terraform state rm digicert_certificate.srv`, then apply. |
