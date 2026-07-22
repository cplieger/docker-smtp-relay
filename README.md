# docker-smtp-relay

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-smtp-relay/badges/size.json)](https://github.com/cplieger/docker-smtp-relay/pkgs/container/docker-smtp-relay)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13210/badge)](https://www.bestpractices.dev/projects/13210)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-smtp-relay/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-smtp-relay)
[![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-smtp-relay/releases)

Point all your services at one container for outbound email — no per-app SMTP setup needed.

## What it does

Accepts email from services on your local network and forwards it through a real email provider (Gmail, AWS SES, Mailgun, etc.). Your apps just point at this container on port 25 — no per-service SMTP configuration needed.

**Example use cases:**

- **AWS SES**: Set `RELAY_HOST=email-smtp.us-east-1.amazonaws.com` with your IAM SMTP credentials. Services on your LAN send to port 25; the relay handles SES authentication and TLS.
- **Gmail**: Set `RELAY_HOST=smtp.gmail.com` with an App Password. Useful for sending alerts from devices that don't support OAuth2.
- **Mailgun / Sendgrid / Generic SMTP**: Any provider that accepts SMTP with STARTTLS on port 587 works out of the box.
- **Multi-service self-hosted**: NAS notifications, Grafana alerts, Paperless-ngx, Uptime Kuma, IoT devices; point them all at `<host-ip>:25` with no per-service SMTP configuration.

### Why this design

- **Env-var config, not Postfix config files** — set a few environment variables and go; no need to learn Postfix's configuration syntax or maintain `main.cf` templates.
- **Relay-only, not a full MTA** — no local delivery, no mailbox management, no inbound routing. Does one thing well: accept mail and forward it upstream.
- **Strict input validation** — every env var is validated before Postfix starts, so a bad value fails the container at boot instead of producing a misconfigured relay. See [Security](#security) for the specific checks.
- **Postfix as PID 1** — runs in foreground mode for proper signal handling; if it crashes, the container exits and Docker's restart policy recovers it cleanly.

## Quick start

Available from both GHCR (`ghcr.io/cplieger/docker-smtp-relay`) and Docker Hub (`docker.io/cplieger/docker-smtp-relay`).

```yaml
services:
  smtp-relay:
    image: ghcr.io/cplieger/docker-smtp-relay:latest
    container_name: smtp-relay
    restart: unless-stopped
    security_opt:
      - "no-new-privileges:true"  # block post-compromise setuid escalation

    environment:
      RELAY_HOST: "email-smtp.us-east-1.amazonaws.com"  # any SMTP provider hostname
      RELAY_LOGIN: "your-relay-login"
      RELAY_PASSWORD: "your-relay-password"
      RELAY_PORT: "587"  # 587 = STARTTLS, 465 = implicit TLS
      SMTP_TLS_SECURITY_LEVEL: "secure"  # secure (default), verify, or encrypt; full list in the configuration table (may/none are rejected when SASL credentials are set)
      MESSAGE_SIZE_LIMIT: "10240000"  # in bytes, default 10 MB
      ACCEPTED_NETWORKS: "192.168.0.0/16"  # CIDRs that can relay mail
      RECIPIENT_RESTRICTIONS: ""
      STARTUP_PROBE: "true"  # fail-soft upstream TCP reachability check at startup

    ports:
      - "25:25"

    volumes:
      - "/path/to/smtp-relay-spool:/var/spool/postfix"  # persistent mail queue (replace host path)
```

## Configuration reference

### Environment variables

| Variable                          | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Default                                   | Required |
|-----------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------|----------|
| `TZ`                              | Not configurable. The image omits `tzdata`, so all logs (Postfix maillog + the entrypoint's structured logs) are emitted in UTC — a single UTC timeline for Loki/Grafana ingestion. Setting `TZ` has no effect.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | `UTC`                                     | No       |
| `RELAY_HOST`                      | Upstream SMTP relay hostname; works with any provider (e.g. email-smtp.us-east-1.amazonaws.com for AWS SES, smtp.gmail.com for Gmail, smtp.mailgun.org for Mailgun)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | _none_                                    | Yes      |
| `RELAY_LOGIN`                     | SASL username for the upstream relay. Optional, but must be set together with RELAY_PASSWORD (set neither to relay without SASL, e.g. to an IP-authenticated smarthost). Most hosted providers (SES, Gmail, Mailgun) require both.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | -                                         | No       |
| `RELAY_PASSWORD`                  | SASL password for the upstream relay. Optional; see RELAY_LOGIN (both-or-neither).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | -                                         | No       |
| `RELAY_PORT`                      | Upstream relay port (587 for STARTTLS, 465 for implicit TLS). 465 requires a mandatory `SMTP_TLS_SECURITY_LEVEL` (`encrypt` or stronger, including `dane-only` and `fingerprint`; `none`, `may`, and `dane` — opportunistic without TLSA records — are rejected).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | `587`                                     | No       |
| `SMTP_TLS_SECURITY_LEVEL`         | Outbound TLS level: `secure` (default; chain + hostname verification), `verify`, `encrypt`, `dane`/`dane-only`/`fingerprint` (see [TLS security levels](#tls-security-levels)), `may`, or `none`. See the [Postfix TLS README](https://www.postfix.org/TLS_README.html). Prefer `secure`/`verify` when SASL (`RELAY_LOGIN`/`RELAY_PASSWORD`) is set; `encrypt` and weaker lack peer authentication.                                                                                                                                                                                                                                                                                                                                                                                | `secure`                                  | No       |
| `SMTP_TLS_FINGERPRINT_CERT_MATCH` | One or more space-separated certificate or public-key digests of the upstream, each formatted as colon-separated hex pairs (see [TLS security levels](#tls-security-levels)). Both-or-neither with `SMTP_TLS_SECURITY_LEVEL=fingerprint`: required at that level, rejected at any other (a silently ignored trust anchor is a misconfiguration).                                                                                                                                                                                                                                                                                                                                                                                                                                   | _none_                                    | No       |
| `SMTP_TLS_FINGERPRINT_DIGEST`     | Digest algorithm for fingerprint matching: `sha256` or `sha512` only (md5/sha1 are rejected as collision-weak). Only meaningful with `SMTP_TLS_SECURITY_LEVEL=fingerprint`; explicitly setting it at any other level is rejected (both-or-neither, like the cert match).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | `sha256`                                  | No       |
| `SMTPD_TLS_CERT_FILE`             | Server certificate for inbound STARTTLS on port 25 (PEM; may include the chain). Both-or-neither with `SMTPD_TLS_KEY_FILE`: mount and set both to offer STARTTLS to sending clients (see [Inbound TLS (STARTTLS)](#inbound-tls-starttls)); without the pair, inbound stays cleartext.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | _none_                                    | No       |
| `SMTPD_TLS_KEY_FILE`              | Private key for the inbound STARTTLS certificate (PEM). Both-or-neither with `SMTPD_TLS_CERT_FILE`. A group- or world-readable key file draws a startup warning.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | _none_                                    | No       |
| `SMTPD_TLS_SECURITY_LEVEL`        | Inbound TLS level: `may` (opportunistic — STARTTLS offered, cleartext still accepted) or `encrypt` (require TLS from every sender). Only meaningful with the cert/key pair set; setting it without the pair is rejected.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | `may` when certs set                      | No       |
| `MESSAGE_SIZE_LIMIT`              | Maximum message size in bytes (default 10240000 = 10 MB, AWS SES supports up to 40 MB with limit increase)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | `10240000`                                | No       |
| `ACCEPTED_NETWORKS`               | Space-separated CIDRs allowed to send mail through this relay. If unset, the entrypoint defaults to all RFC 1918 ranges (`192.168.0.0/16 172.16.0.0/12 10.0.0.0/8`); the shipped compose example deliberately narrows this to `192.168.0.0/16`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    | `192.168.0.0/16 172.16.0.0/12 10.0.0.0/8` | No       |
| `RECIPIENT_RESTRICTIONS`          | Optional recipient filter; space-separated list of allowed email addresses, domains, or regex patterns. Regex tokens use Postfix `/.../` delimiters (e.g. `/^alerts-.*@example\.com$/`); a literal `/` inside the pattern must be backslash-escaped, since Postfix ends the pattern at the first unescaped `/`. A malformed regex token, or a domain token that can never match a recipient (a leading dot — subdomain syntax is not supported — or an embedded `/`), is warned about and skipped (the valid remainder still applies); if every entry is malformed or never-matching the container refuses to start (exit 2) rather than silently rejecting all mail. If set, only matching recipients are accepted; all others are rejected. Leave empty to allow all recipients. | ``                                        | No       |
| `SMTP_HOSTNAME`                   | Postfix `myhostname` / HELO identity. Use an FQDN — some receiving MTAs reject non-FQDN HELO names. Validation rejects whitespace and shell metacharacters; it does not enforce FQDN shape.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | `smtp-relay.local`                        | No       |
| `STARTUP_PROBE`                   | Run a fail-soft TCP reachability check against the upstream relay at startup. Catches DNS/routing/port/firewall misconfiguration at deploy time; a failure logs a warning and the relay still starts (mail queues). Does not verify SASL credentials or the TLS chain. `true` or `false`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | `true`                                    | No       |
| `STARTUP_PROBE_TIMEOUT`           | Timeout in seconds for the startup reachability probe (1-10; kept under the 15s healthcheck start-period so a slow probe never delays readiness).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | `5`                                       | No       |
| `CONF_DIR`                        | Directory the generated Postfix files are rendered into. Test-harness knob for the golden-file render tests; leave unset in normal deployments. Must be an existing writable directory (no newlines or shell metacharacters). Overriding it at runtime logs a warning that live Postfix still reads `/etc/postfix`.                                                                                                                                                                                                                                                                                                                                                                                                                                                                | `/etc/postfix`                            | No       |

### TLS security levels

`secure` (the default) verifies the upstream's certificate chain and hostname
and suits every hosted provider (SES, Gmail, Mailgun). Three specialist levels
are fully supported for upstreams that warrant them:

- **`dane`** — opportunistic DANE per
  [RFC 7672](https://www.rfc-editor.org/rfc/rfc7672): TLS policy comes from
  DNSSEC-validated TLSA records, and the render adds
  `smtp_dns_support_level = dnssec` automatically. **Resolver requirement:**
  DANE only works when the container's entire resolver chain is
  DNSSEC-validating and trusted. Docker's embedded DNS forwards to the host's
  resolvers, so the host must point at a validating resolver you trust (for
  example a local `unbound`); with a non-validating resolver, TLSA records are
  never seen as secure. Fallback is Postfix-native, by design: when a
  destination has no usable (DNSSEC-validated) TLSA records, Postfix degrades
  `dane` to the documented weaker semantics per RFC 7672 — nothing
  defers just because TLSA is absent. Rejected on port 465
  (opportunistic-family; implicit TLS needs a mandatory level).
- **`dane-only`** — mandatory DANE: same mechanics, but no fallback by
  design — delivery defers until DNSSEC-validated TLSA records verify. Use
  only when the upstream publishes TLSA records and you want a hard fail
  otherwise. Allowed on port 465 (mandatory level).
- **`fingerprint`** — trust is pinned to specific certificate or public-key
  digests instead of a CA chain. Set `SMTP_TLS_FINGERPRINT_CERT_MATCH` to one
  or more space-separated digests of the upstream's certificate (or public
  key), each formatted as colon-separated hex pairs — the format printed by
  `openssl x509 -noout -fingerprint -sha256`. The digest algorithm is
  `SMTP_TLS_FINGERPRINT_DIGEST` (`sha256` default, `sha512` supported;
  md5/sha1 rejected as collision-weak). Both values are rendered into
  `main.cf` — the digest explicitly, even at its default — so the effective
  trust anchors stay auditable. Remember to update the pins when the upstream
  rotates its certificate. Allowed on port 465 (mandatory level).

### Inbound TLS (STARTTLS)

The levels above govern the upstream (outbound) connection. Inbound port 25
speaks cleartext SMTP by default — no STARTTLS is offered to sending clients.
`ACCEPTED_NETWORKS` is relay authorization (who may send mail through the
relay), not transport confidentiality: it does not encrypt anything. To offer
STARTTLS on port 25, mount a certificate/key pair and point the two env vars
at it:

```yaml
    environment:
      SMTPD_TLS_CERT_FILE: "/certs/smtpd.pem"  # PEM; may include the chain
      SMTPD_TLS_KEY_FILE: "/certs/smtpd.key"
    volumes:
      - "/path/to/certs:/certs:ro"
```

The default level, `may`, offers STARTTLS opportunistically and protects
against passive capture only: an active on-path attacker can strip the
STARTTLS offer, and clients that do not verify the certificate gain no
authentication from it. `encrypt` requires every sender to negotiate TLS
before mail is accepted — verify your senders actually support STARTTLS
first, or their mail is refused at the door.

### Volumes

| Mount                | Description                           |
| -------------------- | ------------------------------------- |
| `/var/spool/postfix` | Postfix mail spool (persistent queue) |

### Ports

| Port | Description                                  |
| ---- | -------------------------------------------- |
| `25` | SMTP relay (accepts mail from local network) |

## Healthcheck

The healthcheck verifies Postfix is accepting connections on port 25 and returning a valid SMTP 220 banner, confirming the relay process is running, the port is bound, and Postfix is ready to accept mail. Postfix runs as PID 1 via `start-fg`; if it dies, the container exits immediately and Docker's `restart: unless-stopped` brings it back — no supervisor or watchdog needed.

## Observability

The healthcheck above only confirms the inbound listener is up; it cannot tell
you whether mail is actually being delivered upstream (a bad `RELAY_*`
credential or wrong TLS level only surfaces when a send is attempted). Two
mechanisms cover that gap:

- **Startup probe** (`STARTUP_PROBE`, on by default) runs a fail-soft TCP
  reachability check against `RELAY_HOST:RELAY_PORT` at boot and logs the
  result, so DNS, routing, wrong-port, or firewall misconfiguration shows up in
  the logs immediately instead of silently deferring mail. It is deliberately a
  plain TCP connect: it does not verify SASL credentials or the TLS chain, since
  those are only provable by an actual send.
- **Delivery logging.** Postfix logs every delivery attempt to stdout with a
  `status=sent|deferred|bounced` field. In a Loki/Grafana stack, alert on a
  rising `deferred` rate with no `sent` deliveries; that is the unambiguous
  "upstream is broken" signal that the startup probe cannot give you. The
  entrypoint also logs the persisted `queue_active`/`queue_deferred` depth at
  startup so restarts during an outage are easy to correlate.

## Alerting

docker-smtp-relay has no metrics endpoint; its delivery state is in its logs.
Postfix writes every delivery attempt to the container log with a `status=sent`,
`status=deferred`, or `status=bounced` field (see [Observability](#observability)).
Ship the container's logs to Loki (Grafana Alloy's Docker log discovery does
this with no configuration) and evaluate this rule with
[Loki's ruler](https://grafana.com/docs/loki/latest/alert/); firing alerts
deliver through your Alertmanager exactly like Prometheus metric alerts.

```yaml
groups:
  - name: smtp-relay
    rules:
      - alert: SmtpRelayDeliveryFailing
        expr: |
          sum by (container) (count_over_time(
            {container="smtp-relay"} |~ `status=(deferred|bounced)` [15m]
          )) > 10
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "smtp-relay is failing to deliver mail upstream"
          description: >
            More than 10 delivery attempts logged status=deferred or
            status=bounced in the last 15m, so outbound mail is not reaching the
            upstream relay. Common causes are a bad RELAY_LOGIN / RELAY_PASSWORD,
            a wrong SMTP_TLS_SECURITY_LEVEL, or the provider rejecting or
            throttling the sender. Mail keeps queuing and retrying meanwhile;
            check the delivery lines for the SMTP reply text.
```

The threshold and the `severity` label are starting points; tune the count to
your mail volume and adjust the `container` selector (or `job` / `service`,
depending on your log collector) to your deployment, then route by whatever
labels your Alertmanager uses. No deadman is shipped: delivery lines appear only
when mail is sent, so quiet periods are normal and the container healthcheck
already covers the dead-process case. Note the rule keys on upstream delivery
status; mail refused at the door by recipient filtering logs as smtpd
`NOQUEUE: reject` lines (no `status=` field), so extend the pattern with
`NOQUEUE` if you want alerts on recipient-filter rejections too. The deferred and delivered counts can
alternatively be extracted into Prometheus metrics with an Alloy `loki.process`
`stage.metrics` block for dashboards, but this log-based rule needs no such setup.

## Security

**No vulnerabilities found.** Custom code is clean across all
tools.

| Tool                                             | Result                                                                          |
| ------------------------------------------------ | ------------------------------------------------------------------------------- |
| [shellcheck](https://www.shellcheck.net/)        | Clean                                                                           |
| [hadolint](https://github.com/hadolint/hadolint) | DL3018 (unpinned apk) + DL3002 (root USER) — both accepted by design            |
| [gitleaks](https://github.com/gitleaks/gitleaks) | No secrets detected                                                             |
| [trivy](https://trivy.dev/)                      | Clean                                                                           |
| [grype](https://github.com/anchore/grype)        | Clean                                                                           |
| [semgrep](https://semgrep.dev/)                  | 7 findings (ifs-tampering — deliberate IFS save/restore idiom, false positives) |

The entrypoint validates all env vars before generating Postfix
config: newline injection, numeric range, shell metacharacters,
open-relay CIDR rejection (`0.0.0.0/0` and `::/0` blocked, prefixes ≥/8 required),
TLS level allowlisting, and SASL credential field-format checks.
Outbound TLS pins `>=TLSv1.2` and `high` cipher grade; default
security level is `secure` (chain + hostname verification).
Inbound TLS is opt-in via `SMTPD_TLS_CERT_FILE`/`SMTPD_TLS_KEY_FILE`
(same protocol/cipher floor); without the pair, port 25 speaks
cleartext.
SASL credentials are written with umask 077 and the plaintext
file is removed after `postmap` (trap-guarded against partial
failure). Runs as root (required for port 25) with
`no-new-privileges:true` to block post-compromise setuid
escalation. Postfix drops privileges internally.

**Details for advanced users:** Recipient filtering uses properly
escaped regex patterns.

**Network exposure:** the example compose maps `25:25`, which binds
the SMTP listener on all host interfaces. `ACCEPTED_NETWORKS` is
relay authorization — it decides who may send mail through the relay,
not who can reach the listener — so it does not stop Internet
scanners from connecting to and exercising Postfix's SMTP parser. On
a host with a WAN-facing interface, bind a specific LAN address
instead (for example `ports: ["192.168.1.10:25:25"]`) and/or firewall
TCP/25 to trusted source subnets.

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate). The base image is pinned by SHA digest, and Postfix is pinned by version + SHA-256, its detached release signature verified at build with `gpgv` against the upstream signing key committed in this repo, and built from the upstream source tarball with feature parity to the Alpine `postfix` package (TLS, Cyrus SASL client auth, PCRE2, LMDB as the default map type, SMTPUTF8). The image embeds a CycloneDX component for the source-built Postfix so release SBOMs carry its name and version. The SASL runtime packages and shared libraries are installed unpinned so they track the digest-pinned base userland.

| Dependency                    | Source                                                          |
| ----------------------------- | --------------------------------------------------------------- |
| alpine                        | [Alpine](https://hub.docker.com/_/alpine)                       |
| postfix                       | [GitHub](https://github.com/vdukhovni/postfix)                  |
| cyrus-sasl / cyrus-sasl-login | [Alpine](https://pkgs.alpinelinux.org/packages?name=cyrus-sasl) |

Postfix version bumps arrive as Renovate PRs; each bump needs a one-command `POSTFIX_SHA256` refresh (the command is embedded in the Dockerfile comment and the PR body). Before merging a major or minor Postfix upgrade (e.g. 3.11 to 3.12), check the [upstream announcements](https://www.postfix.org/announcements.html) for behavior changes: the entrypoint pins `compatibility_level = 3.6`, so new upstream defaults are adopted deliberately rather than silently.

## Credits

This project packages [Postfix](https://github.com/vdukhovni/postfix) into a container image. All credit for the core functionality goes to the upstream maintainers.

## Contributing

Issues and pull requests are welcome. Please open an issue first for
larger changes so the approach can be discussed before implementation.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
