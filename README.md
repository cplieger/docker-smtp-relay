# docker-smtp-relay

![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)
[![GitHub release](https://img.shields.io/github/v/release/cplieger/docker-smtp-relay)](https://github.com/cplieger/docker-smtp-relay/releases)
[![Image Size](https://ghcr-badge.egpl.dev/cplieger/smtp-relay/size)](https://github.com/cplieger/docker-smtp-relay/pkgs/container/smtp-relay)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Alpine 3.23.3](https://img.shields.io/badge/base-Alpine_3.23.3-0D597F?logo=alpinelinux)

Postfix SMTP relay with env-var-driven configuration

## Overview

Runs a Postfix SMTP relay in a minimal Alpine container. Accepts mail on
port 25 from your local network and relays it through any configurable
upstream SMTP server. Postfix runs as PID 1 in foreground mode — if it
crashes, the container exits and Docker's restart policy recovers it.
Supports SASL authentication, TLS encryption, and optional recipient
filtering, all configured via environment variables at startup.

**Example use cases:**

- **AWS SES**: Set `RELAY_HOST=email-smtp.us-east-1.amazonaws.com` with your IAM SMTP credentials. Services on your LAN send to port 25 — the relay handles SES authentication and TLS.
- **Gmail**: Set `RELAY_HOST=smtp.gmail.com` with an App Password. Useful for sending alerts from devices that don't support OAuth2.
- **Mailgun / Sendgrid / Generic SMTP**: Any provider that accepts SMTP with STARTTLS on port 587 works out of the box.
- **Multi-service homelab**: NAS notifications, Grafana alerts, Paperless-ngx, Uptime Kuma, IoT devices — point them all at `<host-ip>:25` with no per-service SMTP configuration.

This is an Alpine-based container that runs as root — Postfix requires
root for port 25 binding and config file permissions.


### How It Differs From Postfix

The upstream [Postfix](https://www.postfix.org/) is a full MTA that
requires significant configuration. This image is pre-configured as a
relay-only setup with environment-variable-driven configuration —
no config files to write, just set env vars and go.

## Container Registries

This image is published to both GHCR and Docker Hub:

| Registry | Image |
|----------|-------|
| GHCR | `ghcr.io/cplieger/smtp-relay` |
| Docker Hub | `docker.io/cplieger/smtp-relay` |

```bash
# Pull from GHCR
docker pull ghcr.io/cplieger/smtp-relay:latest

# Pull from Docker Hub
docker pull cplieger/smtp-relay:latest
```

Both registries receive identical images and tags. Use whichever you prefer.

## Quick Start

```yaml
services:
  smtp-relay:
    image: ghcr.io/cplieger/smtp-relay:latest
    container_name: smtp-relay
    restart: unless-stopped
    user: "0:0"  # required for config file permissions
    mem_limit: 128m

    environment:
      TZ: "Europe/Paris"
      RELAY_HOST: "email-smtp.us-east-1.amazonaws.com"  # any SMTP provider hostname
      RELAY_LOGIN: "your-relay-login"
      RELAY_PASSWORD: "your-relay-password"
      RELAY_PORT: "587"  # 587 = STARTTLS, 465 = implicit TLS
      SMTP_TLS_SECURITY_LEVEL: "encrypt"  # encrypt, may, or none
      MESSAGE_SIZE_LIMIT: "10240000"  # in bytes, default 10 MB
      ACCEPTED_NETWORKS: "192.168.0.0/16"  # CIDRs that can relay mail
      RECIPIENT_RESTRICTIONS: ""

    ports:
      - "25:25"

    volumes:
      - "/opt/appdata/smtp-relay:/var/spool/postfix"  # persistent mail queue

    healthcheck:
      test:
        - CMD-SHELL
        - nc -z 127.0.0.1 25
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
```

## Deployment

1. Set `RELAY_HOST` to your SMTP provider's hostname.
2. Set `RELAY_LOGIN` and `RELAY_PASSWORD` with your SMTP credentials.
3. Set `ACCEPTED_NETWORKS` to the CIDRs allowed to relay mail (default: RFC 1918 ranges).
4. Mount a persistent volume to `/var/spool/postfix` so queued mail survives container restarts.
5. Port 25 requires root — this container runs as root.
6. Point your services at `<host-ip>:25` as their SMTP server. No authentication is needed from accepted networks.

For additional configuration options not covered by this image's environment variables, refer to the [Postfix documentation](https://www.postfix.org/documentation.html).

## Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `TZ` | Container timezone | `Europe/Paris` | No |
| `RELAY_HOST` | Upstream SMTP relay hostname — works with any provider (e.g. email-smtp.us-east-1.amazonaws.com for AWS SES, smtp.gmail.com for Gmail, smtp.mailgun.org for Mailgun) | `email-smtp.us-east-1.amazonaws.com` | Yes |
| `RELAY_LOGIN` | SASL username for authenticating with the upstream relay | - | Yes |
| `RELAY_PASSWORD` | SASL password for authenticating with the upstream relay | - | Yes |
| `RELAY_PORT` | Upstream relay port (587 for STARTTLS, 465 for implicit TLS) | `587` | No |
| `SMTP_TLS_SECURITY_LEVEL` | Outbound TLS level — encrypt (require TLS, default), may (opportunistic), or none (plaintext) | `encrypt` | No |
| `MESSAGE_SIZE_LIMIT` | Maximum message size in bytes (default 10240000 = 10 MB, AWS SES supports up to 40 MB with limit increase) | `10240000` | No |
| `ACCEPTED_NETWORKS` | Space-separated CIDRs allowed to send mail through this relay (default: 192.168.0.0/16 172.16.0.0/12 10.0.0.0/8) | `192.168.0.0/16` | No |
| `RECIPIENT_RESTRICTIONS` | Optional recipient filter — space-separated list of allowed email addresses, domains, or regex patterns. If set, only matching recipients are accepted; all others are rejected. Leave empty to allow all recipients. | `` | No |


## Volumes

| Mount | Description |
|-------|-------------|
| `/var/spool/postfix` | Postfix mail spool (persistent queue) |

## Ports

| Port | Description |
|------|-------------|
| `25` | SMTP relay (accepts mail from local network) |


## Docker Healthcheck

The healthcheck verifies Postfix is accepting TCP connections on port 25.
This confirms the relay process is running and the port is bound.

**When it becomes unhealthy:**
- Postfix hasn't finished starting yet (during `start_period`)
- Postfix is running but not accepting connections (config error, port binding failure)
- Postfix crashed — the container exits entirely and Docker restarts it

**When it recovers:**
- Postfix starts accepting connections on port 25. Recovery is automatic after a restart.

**Process model:** Postfix runs as PID 1 via `start-fg`. If Postfix
dies, the container exits immediately — Docker's `restart: unless-stopped`
brings it back. There is no supervisor or watchdog process.

To check health manually:
```bash
docker inspect --format='{{json .State.Health.Log}}' smtp-relay | python3 -m json.tool
```

| Type | Command | Meaning |
|------|---------|---------|
| TCP port check | `nc -z 127.0.0.1 25` | Postfix is accepting connections on port 25 |


## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate) and pinned by digest or version for reproducibility.

| Dependency | Version | Source |
|------------|---------|--------|
| alpine | `3.23.3` | [Alpine](https://hub.docker.com/_/alpine) |

## Design Principles

- **Always up to date**: Base images, packages, and libraries are updated automatically via Renovate. Unlike many community Docker images that ship outdated or abandoned dependencies, these images receive continuous updates.
- **Minimal attack surface**: When possible, pure Go apps use `gcr.io/distroless/static:nonroot` (no shell, no package manager, runs as non-root). Apps requiring system packages use Alpine with the minimum necessary privileges.
- **Digest-pinned**: Every `FROM` instruction pins a SHA256 digest. All GitHub Actions are digest-pinned.
- **Multi-platform**: Built for `linux/amd64` and `linux/arm64`.
- **Healthchecks**: Every container includes a Docker healthcheck.
- **Provenance**: Build provenance is attested via GitHub Actions, verifiable with `gh attestation verify`.

## Contributing

Issues, suggestions, and pull requests are welcome.

## Credits

This project packages [Postfix](https://github.com/vdukhovni/postfix) into a container image. All credit for the core functionality goes to the upstream maintainers.

## Disclaimer

These images are built with care and follow security best practices, but they are intended for **homelab use**. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
