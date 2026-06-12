# docker-smtp-relay

[![CI](https://github.com/cplieger/docker-smtp-relay/actions/workflows/ci.yaml/badge.svg)](https://github.com/cplieger/docker-smtp-relay/actions/workflows/ci.yaml)
[![GitHub release](https://img.shields.io/github/v/release/cplieger/docker-smtp-relay)](https://github.com/cplieger/docker-smtp-relay/releases)
[![Image Size](https://ghcr-badge.egpl.dev/cplieger/docker-smtp-relay/size)](https://github.com/cplieger/docker-smtp-relay/pkgs/container/smtp-relay)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-smtp-relay/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-smtp-relay)

Point all your services at one container for outbound email — no per-app SMTP setup needed.

## What it does

Accepts email from services on your local network and forwards it through a real email provider (Gmail, AWS SES, Mailgun, etc.). Your apps just point at this container on port 25 — no per-service SMTP configuration needed.

**Example use cases:**

- **AWS SES**: Set `RELAY_HOST=email-smtp.us-east-1.amazonaws.com` with your IAM SMTP credentials. Services on your LAN send to port 25; the relay handles SES authentication and TLS.
- **Gmail**: Set `RELAY_HOST=smtp.gmail.com` with an App Password. Useful for sending alerts from devices that don't support OAuth2.
- **Mailgun / Sendgrid / Generic SMTP**: Any provider that accepts SMTP with STARTTLS on port 587 works out of the box.
- **Multi-service homelab**: NAS notifications, Grafana alerts, Paperless-ngx, Uptime Kuma, IoT devices; point them all at `<host-ip>:25` with no per-service SMTP configuration.

### Why this design

- **Env-var config, not Postfix config files** — set a few environment variables and go; no need to learn Postfix's configuration syntax or maintain `main.cf` templates.
- **Relay-only, not a full MTA** — no local delivery, no mailbox management, no inbound routing. Does one thing well: accept mail and forward it upstream.
- **Strict input validation** — newline injection prevention, numeric range assertions, shell-metacharacter rejection, open-relay CIDR blocking, TLS level allowlisting, and SASL credential format checks all run before Postfix starts.
- **Postfix as PID 1** — runs in foreground mode for proper signal handling; if it crashes, the container exits and Docker's restart policy recovers it cleanly.

## Quick start

Available from both GHCR (`ghcr.io/cplieger/docker-smtp-relay`) and Docker Hub (`docker.io/cplieger/docker-smtp-relay`).

```yaml
services:
  smtp-relay:
    image: ghcr.io/cplieger/docker-smtp-relay:latest
    container_name: smtp-relay
    restart: unless-stopped
    user: "0:0"  # required for config file permissions

    environment:
      TZ: "Europe/Paris"
      RELAY_HOST: "email-smtp.us-east-1.amazonaws.com"  # any SMTP provider hostname
      RELAY_LOGIN: "your-relay-login"
      RELAY_PASSWORD: "your-relay-password"
      RELAY_PORT: "587"  # 587 = STARTTLS, 465 = implicit TLS
      SMTP_TLS_SECURITY_LEVEL: "secure"  # secure (default), verify, encrypt, may, or none
      MESSAGE_SIZE_LIMIT: "10240000"  # in bytes, default 10 MB
      ACCEPTED_NETWORKS: "192.168.0.0/16"  # CIDRs that can relay mail
      RECIPIENT_RESTRICTIONS: ""

    ports:
      - "25:25"

    volumes:
      - "/opt/appdata/smtp-relay:/var/spool/postfix"  # persistent mail queue
```

## Configuration reference

### Environment variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `TZ` | Container timezone | `Europe/Paris` | No |
| `RELAY_HOST` | Upstream SMTP relay hostname; works with any provider (e.g. email-smtp.us-east-1.amazonaws.com for AWS SES, smtp.gmail.com for Gmail, smtp.mailgun.org for Mailgun) | `email-smtp.us-east-1.amazonaws.com` | Yes |
| `RELAY_LOGIN` | SASL username for authenticating with the upstream relay | - | Yes |
| `RELAY_PASSWORD` | SASL password for authenticating with the upstream relay | - | Yes |
| `RELAY_PORT` | Upstream relay port (587 for STARTTLS, 465 for implicit TLS) | `587` | No |
| `SMTP_TLS_SECURITY_LEVEL` | Outbound TLS level. Default: secure (TLS required, certificate chain + hostname verification against smtp_tls_CAfile). Also supported: verify (chain only, no hostname match), encrypt (TLS required, no cert verification), dane / dane-only / fingerprint (advanced), may (opportunistic TLS), none (plaintext, credentials exposed). | `secure` | No |
| `MESSAGE_SIZE_LIMIT` | Maximum message size in bytes (default 10240000 = 10 MB, AWS SES supports up to 40 MB with limit increase) | `10240000` | No |
| `ACCEPTED_NETWORKS` | Space-separated CIDRs allowed to send mail through this relay (default: 192.168.0.0/16). The entrypoint falls back to all RFC 1918 ranges if unset, but the shipped compose defaults to 192.168.0.0/16. | `192.168.0.0/16` | No |
| `RECIPIENT_RESTRICTIONS` | Optional recipient filter; space-separated list of allowed email addresses, domains, or regex patterns. If set, only matching recipients are accepted; all others are rejected. Leave empty to allow all recipients. | `` | No |

### Volumes

| Mount | Description |
|-------|-------------|
| `/var/spool/postfix` | Postfix mail spool (persistent queue) |

### Ports

| Port | Description |
|------|-------------|
| `25` | SMTP relay (accepts mail from local network) |

## Healthcheck

The healthcheck verifies Postfix is accepting connections on port 25 and returning a valid SMTP 220 banner, confirming the relay process is running, the port is bound, and Postfix is ready to accept mail. Postfix runs as PID 1 via `start-fg`; if it dies, the container exits immediately and Docker's `restart: unless-stopped` brings it back — no supervisor or watchdog needed.

## Security

**No vulnerabilities found.** Custom code is clean across all
tools.

| Tool | Result |
|------|--------|
| [shellcheck](https://www.shellcheck.net/) | Clean |
| [hadolint](https://github.com/hadolint/hadolint) | DL3018 (unpinned apk, accepted) |
| [gitleaks](https://github.com/gitleaks/gitleaks) | No secrets detected |
| [trivy](https://trivy.dev/) | Clean |
| [grype](https://github.com/anchore/grype) | Clean |
| [semgrep](https://semgrep.dev/) | 1 info (missing USER, expected) |

The entrypoint validates all env vars before generating Postfix
config: newline injection, numeric range, shell metacharacters,
open-relay CIDR rejection (`0.0.0.0/0` blocked, prefixes ≥/8 required),
TLS level allowlisting, and SASL credential field-format checks.
Outbound TLS pins `>=TLSv1.2` and `high` cipher grade; default
security level is `secure` (chain + hostname verification).
SASL credentials are written with umask 077 and the plaintext
file is removed after `postmap` (trap-guarded against partial
failure). Runs as root (required for port 25) with
`no-new-privileges:true` to block post-compromise setuid
escalation. Postfix drops privileges internally.

**Details for advanced users:** Recipient filtering uses properly
escaped regex patterns. The container runs relay-only with no
local delivery. Postfix runs as PID 1 via `start-fg` for proper
signal handling.

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate) and pinned by digest or version for reproducibility.

| Dependency | Version | Source |
|------------|---------|--------|
| alpine | `3.23.4` | [Alpine](https://hub.docker.com/_/alpine) |

## Credits

This project packages [Postfix](https://github.com/vdukhovni/postfix) into a container image. All credit for the core functionality goes to the upstream maintainers.

## Contributing

Issues and pull requests are welcome. Please open an issue first for
larger changes so the approach can be discussed before implementation.

## Disclaimer

These images are built with care and follow security best practices, but they are intended for **homelab use**. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
