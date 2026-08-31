# docker-smtp-relay

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-smtp-relay/badges/size.json)](https://github.com/cplieger/docker-smtp-relay/pkgs/container/docker-smtp-relay)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13210/badge)](https://www.bestpractices.dev/projects/13210)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-smtp-relay/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-smtp-relay)
[![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-smtp-relay/releases)

<!-- hub-overview BEGIN -->
Point all your services at one container for outbound email; no per-app SMTP setup needed.

## What it does

Accepts email from services on your local network and forwards it through a real email provider (Gmail, AWS SES, Mailgun, etc.). Your apps just point at this container on port 25.

**Example use cases:**

- **AWS SES**: Set `RELAY_HOST=email-smtp.us-east-1.amazonaws.com` with your IAM SMTP credentials. Services on your LAN send to port 25; the relay handles SES authentication and TLS.
- **Gmail**: Set `RELAY_HOST=smtp.gmail.com` with an App Password. Paste the password as Google issues it, spaces included (`wxyz abcd efgh aabb`); quote it in YAML. Useful for sending alerts from devices that don't support OAuth2.
- **Mailgun / Sendgrid / Generic SMTP**: Any provider that accepts SMTP with STARTTLS on port 587 works out of the box.
- **Multi-service self-hosted**: NAS notifications, Grafana alerts, Paperless-ngx, Uptime Kuma, IoT devices; point them all at `<host-ip>:25`.

### Why this design

- **Env-var config, not Postfix config files.** Set a few environment variables and go; no `main.cf` templates to learn or maintain.
- **Relay-only, not a full MTA.** No local delivery, no mailbox management, no inbound routing. Does one thing well: accept mail and forward it upstream.
- **Strict input validation.** Every env var is validated before Postfix starts, so a bad value fails the container at boot instead of producing a misconfigured relay. See [Security](#security) for the specific checks.
- **Postfix as PID 1.** Runs in foreground mode for proper signal handling; if it crashes, the container exits and Docker's restart policy recovers it cleanly.
<!-- hub-overview END -->

## Quick start

Available from both GHCR (`ghcr.io/cplieger/docker-smtp-relay`) and Docker Hub (`docker.io/cplieger/docker-smtp-relay`).

```yaml
services:
  smtp-relay:
    image: ghcr.io/cplieger/docker-smtp-relay:latest
    container_name: smtp-relay
    restart: unless-stopped

    environment:
      RELAY_HOST: "email-smtp.us-east-1.amazonaws.com"  # any SMTP provider hostname
      RELAY_LOGIN: "your-relay-login"
      RELAY_PASSWORD: "your-relay-password"
      RELAY_PORT: "587"  # 587 = STARTTLS, 465 = implicit TLS
      ACCEPTED_NETWORKS: "192.168.0.0/16"  # CIDRs that can relay mail

    ports:
      - "25:25"

    volumes:
      - "/path/to/smtp-relay-spool:/var/spool/postfix"  # persistent mail queue (replace host path)
```

## Configuration reference

### Environment variables

| Variable | Description | Default | Required |
| --- | --- | --- | --- |
| `RELAY_HOST` | Upstream SMTP relay hostname; works with any provider (e.g. email-smtp.us-east-1.amazonaws.com for AWS SES, smtp.gmail.com for Gmail, smtp.mailgun.org for Mailgun) | _none_ | Yes |
| `RELAY_LOGIN` | SASL username for the upstream relay. Optional, but must be set together with RELAY_PASSWORD (set neither to relay without SASL, e.g. to an IP-authenticated smarthost). Most hosted providers (SES, Gmail, Mailgun) require both. Must not contain a colon, must not start with whitespace, and must not end with a newline; whitespace inside or after the login is kept. | _(unset)_ | No |
| `RELAY_PASSWORD` | SASL password for the upstream relay. Optional; see RELAY_LOGIN (both-or-neither). Spaces inside the password are preserved, so a Gmail App Password can be pasted exactly as Google issues it (`wxyz abcd efgh aabb`). Only TRAILING whitespace is rejected, because the credential map trims it and the relay would then send a password that differs from the one configured. | _(unset)_ | No |
| `RELAY_PORT` | Upstream relay port: 587 for STARTTLS, 465 for implicit TLS. 465 requires a mandatory `SMTP_TLS_SECURITY_LEVEL` (`encrypt` or stronger, including `dane-only` and `fingerprint`); `none`, `may`, and `dane` are rejected with it. | `587` | No |
| `SMTP_TLS_SECURITY_LEVEL` | Outbound TLS level: `secure` (default; chain + hostname verification), `verify`, `encrypt`, `dane`/`dane-only`/`fingerprint` (see [TLS security levels](#tls-security-levels)), `may`, or `none`. See the [Postfix TLS README](https://www.postfix.org/TLS_README.html). Prefer `secure`/`verify` when SASL (`RELAY_LOGIN`/`RELAY_PASSWORD`) is set; `encrypt` and weaker lack peer authentication. | `secure` | No |
| `SMTP_TLS_FINGERPRINT_CERT_MATCH` | One or more space-separated certificate or public-key digests of the upstream, each formatted as colon-separated hex pairs (see [TLS security levels](#tls-security-levels)). Both-or-neither with `SMTP_TLS_SECURITY_LEVEL=fingerprint`: required at that level, rejected at any other (a silently ignored trust anchor is a misconfiguration). | _(unset)_ | No |
| `SMTP_TLS_FINGERPRINT_DIGEST` | Digest algorithm for fingerprint matching: `sha256` or `sha512` only (md5/sha1 are rejected as collision-weak). Only meaningful with `SMTP_TLS_SECURITY_LEVEL=fingerprint`; setting it to a digest name at any other level is rejected (both-or-neither, like the cert match), while an empty value counts as unset. | `sha256` | No |
| `SMTPD_TLS_CERT_FILE` | Server certificate for inbound STARTTLS on port 25 (PEM; may include the chain). Both-or-neither with `SMTPD_TLS_KEY_FILE`: mount and set both to offer STARTTLS to sending clients (see [Inbound TLS (STARTTLS)](#inbound-tls-starttls)); without the pair, inbound stays cleartext. | _(unset)_ | No |
| `SMTPD_TLS_KEY_FILE` | Private key for the inbound STARTTLS certificate (PEM). Both-or-neither with `SMTPD_TLS_CERT_FILE`. A group- or world-readable key file draws a startup warning. | _(unset)_ | No |
| `SMTPD_TLS_SECURITY_LEVEL` | Inbound TLS level: `may` (opportunistic; STARTTLS offered, cleartext still accepted) or `encrypt` (require TLS from every sender). Only meaningful with the cert/key pair set; setting it without the pair is rejected. | `may` when certs set | No |
| `MESSAGE_SIZE_LIMIT` | Maximum message size in bytes (default 10240000 = 10 MB, AWS SES supports up to 40 MB with limit increase) | `10240000` | No |
| `ACCEPTED_NETWORKS` | Space-separated CIDRs allowed to send mail through this relay. If unset, the entrypoint defaults to all RFC 1918 ranges (`192.168.0.0/16 172.16.0.0/12 10.0.0.0/8`); the shipped compose example deliberately narrows this to `192.168.0.0/16`. | `192.168.0.0/16 172.16.0.0/12 10.0.0.0/8` | No |
| `RECIPIENT_RESTRICTIONS` | Optional recipient allowlist: space-separated address, domain, and Postfix regexp tokens (including `/pattern/flags` and `/pattern1/!/pattern2/` forms). If set, only matching recipients are accepted; leave empty to allow all. Bounded at 256 rules and 16384 bytes; neither is tunable, and a bigger allowlist needs a Postfix deployment of your own with a `check_recipient_access` table or a policy service. Misconfigurations fail the boot loudly; see [Recipient filtering](#recipient-filtering) below. | _(unset)_ | No |
| `SMTP_HOSTNAME` | Postfix `myhostname` / HELO identity. Use an FQDN; some receiving MTAs reject non-FQDN HELO names. Validation rejects whitespace and shell metacharacters; it does not enforce FQDN shape. | `smtp-relay.local` | No |
| `STARTUP_PROBE` | Run a fail-soft TCP reachability check against the upstream relay at startup; see [Observability](#observability). `true` or `false`. | `true` | No |
| `STARTUP_PROBE_TIMEOUT` | Timeout in seconds for the startup reachability probe (1-10; kept under the 15s healthcheck start-period so a slow probe never delays readiness). | `5` | No |
| `CONF_DIR` | Directory the generated Postfix files are rendered into. Test-harness knob for the golden-file render tests; leave unset in normal deployments. Must be an existing writable directory (no newlines or shell metacharacters). Overriding it at runtime logs a warning that live Postfix still reads `/etc/postfix`. | `/etc/postfix` | No |

`TZ` is not configurable: the image omits `tzdata`, all logs (Postfix maillog
and the entrypoint's structured logs) are emitted in UTC, and setting `TZ` has
no effect.

### TLS security levels

`secure` (the default) verifies the upstream's certificate chain and hostname
and suits every hosted provider (SES, Gmail, Mailgun). Three specialist levels
are fully supported for upstreams that warrant them:

- **`dane`**: opportunistic DANE per
  [RFC 7672](https://www.rfc-editor.org/rfc/rfc7672). TLS policy comes from
  DNSSEC-validated TLSA records, and the render adds
  `smtp_dns_support_level = dnssec` automatically. **Resolver requirement:**
  DANE only works when the container's entire resolver chain is
  DNSSEC-validating and trusted. Docker's embedded DNS forwards to the host's
  resolvers, so the host must point at a validating resolver you trust (for
  example a local `unbound`); with a non-validating resolver, TLSA records are
  never seen as secure. When a destination has no usable TLSA records,
  Postfix falls back to its documented weaker semantics per RFC 7672;
  nothing defers just because TLSA is absent. Rejected on port 465
  (opportunistic-family; implicit TLS needs a mandatory level).
- **`dane-only`**: mandatory DANE. Same mechanics, but no fallback;
  delivery defers until DNSSEC-validated TLSA records verify. Use
  only when the upstream publishes TLSA records and you want a hard fail
  otherwise. Allowed on port 465 (mandatory level).
- **`fingerprint`**: trust is pinned to specific certificate or public-key
  digests instead of a CA chain. Set `SMTP_TLS_FINGERPRINT_CERT_MATCH` to one
  or more space-separated digests of the upstream's certificate (or public
  key), each formatted as colon-separated hex pairs, the format printed by
  `openssl x509 -noout -fingerprint -sha256`. The digest algorithm is
  `SMTP_TLS_FINGERPRINT_DIGEST` (`sha256` default, `sha512` supported;
  md5/sha1 rejected as collision-weak). Both values are rendered into
  `main.cf`, the digest explicitly even at its default, so the effective
  trust anchors stay auditable. Remember to update the pins when the upstream
  rotates its certificate. Allowed on port 465 (mandatory level).

### Inbound TLS (STARTTLS)

The levels above govern the upstream connection. Inbound port 25 speaks
cleartext SMTP by default; no STARTTLS is offered to sending clients.
`ACCEPTED_NETWORKS` decides who may relay mail through this container, not
whether the session is encrypted. To offer STARTTLS on port 25, mount a
certificate/key pair and set both env vars:

```yaml
    environment:
      SMTPD_TLS_CERT_FILE: "/certs/smtpd.pem"  # PEM; may include the chain
      SMTPD_TLS_KEY_FILE: "/certs/smtpd.key"
    volumes:
      - "/path/to/certs:/certs:ro"
```

The default level, `may`, offers STARTTLS opportunistically. That protects
against passive capture only: an on-path attacker can strip the offer, and a
client that skips certificate verification gains no authentication from it.
`encrypt` requires TLS from every sender, so confirm your senders speak
STARTTLS before setting it; their mail is refused at the door otherwise.

### Recipient filtering

`RECIPIENT_RESTRICTIONS` is an optional allowlist evaluated at the door: when
set, only matching recipients are accepted and everything else is refused with
an smtpd `NOQUEUE: reject`. Four space-separated token forms are supported in
the one variable:

- **Address**: `alerts@example.com`. Matched as an anchored, escaped literal,
  so a `/` in the local part (`john/doe@example.com`) matches literally.
- **Domain**: `example.org`. Matches every recipient at exactly that domain.
  Subdomain syntax (`.example.org`) is not supported and is warned as
  never-matching.
- **Regexp**: `/^ops-.*@example\.net$/`, emitted verbatim as a Postfix
  [regexp_table(5)](https://www.postfix.org/regexp_table.5.html) pattern;
  backslash-escape a literal `/` inside it. The flag suffix `/pattern/flags`
  accepts `i`, `m`, and `x` with regexp_table(5) semantics, where each
  occurrence toggles its property. Matching is case-insensitive by default, so
  `/^alerts@example\.com$/i` matches only the lowercase spelling.
- **Dual-pattern regexp**: `/pattern1/!/pattern2/`, either half optionally
  flagged. Matches `pattern1` AND NOT `pattern2`, for example
  `/.*@example\.com$/!/^noreply@/` for the whole domain except noreply.
  Anchor a domain half with `$`: patterns are substring matches, so the
  unanchored `/.*@example\.com/` would also accept
  `victim@example.com.attacker.net`.

Regexp tokens match against the full `user@domain` address smtpd presents.
They are not analyzed for reachability: an anchored pattern that can never
match, such as `/^@example\.com$/`, still counts as an effective rule.

Four checks run at boot, so a filter that would silently refuse or admit
every recipient (or hold up the boot) fails visibly instead. The
healthcheck cannot see any of these mistakes, since port 25 answers either
way.

- **Never-match warns.** A domain with a leading dot or an embedded `/`, an
  address with an empty local part or empty domain or a dot right after the
  `@`, and a regexp half that does not compile are each warned and excluded
  from the effective-rule count. They are still rendered; Postfix drops an
  uncompilable line when it opens the map. A leading-`/` token whose structure
  cannot be parsed at all (no closing delimiter, a dangling or doubled `!`, an
  unknown flag) is suppressed from the map instead, rather than loaded with
  semantics this image never validated.
- **Zero effective rules: exit 2.** When every token is malformed,
  unparseable, or never-matching, the only live line left would reject all
  mail, so the container refuses to start. A mixed list boots on its valid
  subset.
- **Possible allow-all: exit 2.** Every regexp construct is probed against two
  impossible addresses, with its own flags mirrored and the dual form
  evaluated as `P1 AND NOT P2`. A construct matching both probes is refused:
  `/.*/`, `/./`, an empty alternation branch like `/a@b\.c|/`, the
  near-allow-all `/.*/!/^noreply@/`, and any empty pattern (`//`, `/x/!//`).
  The probe is a heuristic, so it can over-refuse a pattern you consider
  narrow, such as one alternation spanning `\.invalid$` and `\.test$`. Split
  that into separate entries (`/\.invalid$/` and `/\.test$/`) and both pass.
  Leave `RECIPIENT_RESTRICTIONS` empty when allow-all is what you want.
- **Too large: exit 2.** At most 256 rules, and at most 16384 bytes in the
  whole value. Every rule is rendered and probed with external processes
  before Postfix binds port 25, so the count and length are capped at a fixed
  budget that keeps that work an order of magnitude inside the healthcheck's
  15s start-period; the caps bound the startup work, they are not the point
  where a boot actually misses the deadline. Neither limit is tunable, and
  this image renders `smtpd_recipient_restrictions` itself with no setting to
  point it elsewhere: a bigger allowlist needs a Postfix deployment of your
  own, with your table behind `check_recipient_access` or the decision moved
  to a [policy service](https://www.postfix.org/SMTPD_POLICY_README.html). A
  single regexp token of a few KiB is fine.

### Volumes

| Mount | Description |
| --- | --- |
| `/var/spool/postfix` | Postfix mail spool (persistent queue) |

### Ports

| Port | Description |
| --- | --- |
| `25` | SMTP relay (accepts mail from local network) |

## Healthcheck

The healthcheck verifies Postfix is accepting connections on port 25 and returning a valid SMTP 220 banner, confirming the relay process is running, the port is bound, and Postfix is ready to accept mail. Postfix runs as PID 1 via `start-fg`; if it dies, the container exits immediately and Docker's `restart: unless-stopped` brings it back.

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
  `status=sent|deferred|bounced` field; a rising `deferred` rate with no `sent`
  deliveries is the unambiguous "upstream is broken" signal the startup probe
  cannot give you, and [Alerting](#alerting) ships a ready-made rule on it. The
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
already covers the dead-process case. The rule keys on upstream delivery
status; mail refused at the door by recipient filtering logs as an smtpd
`NOQUEUE: reject` with no `status=` field, so add `NOQUEUE` to the pattern to
alert on those too. The deferred and delivered counts can
alternatively be extracted into Prometheus metrics with an Alloy `loki.process`
`stage.metrics` block for dashboards, but this log-based rule needs no such setup.

## Security

The entrypoint validates all env vars before generating Postfix
config: newline injection, numeric range, shell metacharacters,
open-relay CIDR rejection (`0.0.0.0/0` and `::/0` blocked, prefixes ≥/8
required, and a startup warning when an accepted range is not inside private
address space, since a mistyped prefix like `192.168.0.0/8` passes the floor
but covers ~16M public hosts), TLS level allowlisting, and SASL credential
field-format checks (the credential map is `<relayhost> <login>:<password>`, so a
colon in the login, leading whitespace in the login, a trailing newline in the
login, or trailing whitespace in the password would each be trimmed or split and
the relay would authenticate with a credential that differs from the configured
one; every position the map preserves is accepted, so a Gmail App Password works
with its spaces exactly as issued).
Recipient filter entries are regex-escaped before rendering.
Outbound TLS pins `>=TLSv1.2` and `high` cipher grade; default
security level is `secure` (chain + hostname verification).
Inbound TLS is opt-in via `SMTPD_TLS_CERT_FILE`/`SMTPD_TLS_KEY_FILE`
(same protocol/cipher floor); without the pair, port 25 speaks
cleartext.
SASL credentials are written with umask 077 and the plaintext
file is removed after `postmap` (trap-guarded against partial
failure). Runs as root (required for port 25); Postfix drops
privileges internally. Run the container with
`security_opt: ["no-new-privileges:true"]` to block
post-compromise setuid escalation.

Accepted scanner findings, each deliberate:

- hadolint `DL3018` (unpinned apk packages): the digest-pinned base image
  already fixes the package universe; version pins on top of it break on
  base-image bumps.
- hadolint `DL3002` and trivy `AVD-DS-0002` (image runs as root): required
  for the port 25 bind, as described above; suppressed with rationale in
  `.trivyignore`.
- semgrep `ifs-tampering` (7 findings): a deliberate IFS save/restore idiom
  in the entrypoint, flagged as false positives.

Live scan results are on the repository's Security tab.

**Network exposure:** the example compose maps `25:25`, which binds
the SMTP listener on all host interfaces. `ACCEPTED_NETWORKS` is
relay authorization (it decides who may send mail through the relay,
not who can reach the listener), so it does not stop Internet
scanners from connecting to and exercising Postfix's SMTP parser. On
a host with a WAN-facing interface, bind a specific LAN address
instead (for example `ports: ["192.168.1.10:25:25"]`) and/or firewall
TCP/25 to trusted source subnets.

## Dependencies

All dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate). The base image is pinned by SHA digest. Postfix is built from the upstream source tarball, pinned by version + SHA-256, with its detached release signature verified at build using `gpgv` against the upstream signing key committed in this repo. The build has feature parity with the Alpine `postfix` package (TLS, Cyrus SASL client auth, PCRE2, LMDB as the default map type, SMTPUTF8), and the image embeds a CycloneDX component for the source-built Postfix so release SBOMs carry its name and version. The SASL runtime packages and shared libraries are installed unpinned so they track the digest-pinned base userland.

| Dependency | Source |
| --- | --- |
| alpine | [Alpine](https://hub.docker.com/_/alpine) |
| postfix | [GitHub](https://github.com/vdukhovni/postfix) |
| cyrus-sasl / cyrus-sasl-login | [Alpine](https://pkgs.alpinelinux.org/packages?name=cyrus-sasl) |

The entrypoint pins `compatibility_level = 3.6`, so new Postfix defaults are adopted deliberately with version upgrades rather than silently at runtime.

## Credits

This project packages [Postfix](https://github.com/vdukhovni/postfix) into a container image. Postfix is dual-licensed: you can take it under either the Eclipse Public License 2.0 or the IBM Public License 1.0. All credit for the core functionality goes to the upstream maintainers.

## Contributing

Issues and pull requests are welcome. Please open an issue first for
larger changes so the approach can be discussed before implementation.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude](https://claude.com), [GPT](https://openai.com), and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

Apache-2.0. See [LICENSE](LICENSE).
