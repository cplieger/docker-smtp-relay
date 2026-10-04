# Security

This page is for readers who run docker-smtp-relay on a shared or internet-facing host. It covers network exposure, the checks run before Postfix starts, the provider login, privileges and what the image contains.

## Network exposure

The example compose file publishes `25:25`, which opens the SMTP listener on every host interface. `ACCEPTED_NETWORKS` is relay permission. It decides who may send mail through the relay, not who can connect, so it does not stop internet scanners from connecting and exercising Postfix's SMTP parser. On a host with an internet-facing interface, publish the port on a LAN address only, for example `ports: ["192.0.2.10:25:25"]`, or firewall TCP port 25 to your own networks, or both.

Senders never log in to the relay. It accepts mail only by the sender's network address, so every host inside `ACCEPTED_NETWORKS` can send through your provider account.

## Checks before Postfix starts

The relay checks every setting before it writes the Postfix configuration, and a failed check stops the start with exit code 2:

- A newline inside a setting is refused. One trailing newline, as an env file or a shell substitution often adds, is ignored by this check.
- Ports, sizes and timeouts must be whole numbers inside their range, and an over-long number is refused before the range check.
- Host names, file paths and `CONF_DIR` refuse shell metacharacters.
- `RELAY_HOST` refuses nested brackets and an opening bracket without a matching close. Any other stray bracket and a `host:port` value draw a warning, because the port belongs in `RELAY_PORT`.
- `ACCEPTED_NETWORKS` refuses `0.0.0.0/0`, `::/0`, entries without a prefix and prefixes wider than /8, so the relay cannot become an open relay by accident. An IPv4 entry with a leading-zero octet and an IPv6 entry with a second `/` are refused, because Postfix would never match them. An entry outside private address space draws a warning, because a mistyped prefix such as `192.168.0.0/8` passes the /8 floor and covers about 16 million public addresses.
- `SMTP_TLS_SECURITY_LEVEL` must be one of the listed levels, and the fingerprint, inbound TLS and port 465 settings must fit the level, as [Configuration](configuration.md) describes.
- `RELAY_LOGIN` and `RELAY_PASSWORD` must be set together or not at all. The login must not contain a colon, start with whitespace or end with a newline, and the password must not end with whitespace. Postfix stores the pair as `<relayhost> <login>:<password>` and trims or splits at those positions, so each of them would send a login that differs from the one you set. Every position the store keeps is accepted, so a Gmail App Password works with its spaces exactly as issued.

Recipient entries are escaped before they become Postfix patterns, and the recipient filter runs its own checks, described in [Recipient filtering](configuration.md#recipient-filtering).

## Your provider login

With a login set, the relay writes it to a file under a umask of 077, turns it into the Postfix lookup table that only root can read, and deletes the plaintext file. A trap removes the plaintext file too when a step fails or the container is stopped during that step. The relay then removes the login and password from its own environment before Postfix starts.

The values stay in the container's configuration, so anyone who can run `docker inspect` on the host can read them. The relay reads settings from environment variables only, with no file-based secret form.

## TLS

When the relay uses TLS to your provider, it uses TLS 1.2 or later with the `high` cipher grade. The default level, `secure`, checks the certificate chain and the host name. With a login set, the levels `none` and `may` are refused, and `encrypt` and `dane` draw a warning, because they do not prove who answers. Inbound STARTTLS on port 25 is off until you set `SMTPD_TLS_CERT_FILE` and `SMTPD_TLS_KEY_FILE`, and it uses the same protocol and cipher floor. Without them, port 25 speaks cleartext.

## Privileges and the hardened compose settings

The container runs as root, because Postfix's master process needs root to listen on port 25. Postfix runs its workers as the unprivileged `postfix` user. Add this to the service to stop a compromised process from gaining privileges through a setuid program:

```yaml
    security_opt:
      - "no-new-privileges:true"
```

## Accepted scanner findings

Each of these is deliberate:

- hadolint `DL3018`, unpinned apk packages. The packages come from the Alpine release of the digest-pinned base, and version pins on top of them break on base image updates.
- hadolint `DL3002` and Trivy `AVD-DS-0002`, the image runs as root. Root is needed to listen on port 25, as described above, and the Trivy finding is suppressed with its reason in `.trivyignore`.
- semgrep `ifs-tampering`, 7 findings. They flag a deliberate save-and-restore of `IFS` in the entrypoint.

Live scan results are on the repository's Security tab.

## What the image contains

The image is built on Alpine Linux, pinned by SHA digest. Postfix is built from the upstream release tarball, pinned by version and SHA-256, and the build checks the tarball's release signature with `gpgv` against the Postfix signing key committed in this repository. The build has the same features as Alpine's `postfix` package: TLS, Cyrus SASL client login, PCRE2, LMDB as the default map type and SMTPUTF8. The Cyrus SASL runtime packages and shared libraries are installed unpinned from the base image's Alpine release repository.

The image embeds a CycloneDX component for the source-built Postfix. Release SBOMs carry its name, its version, the mirror URL the build fetches from and the SHA-256 it checks.

| Component | Source |
| --- | --- |
| alpine | [Alpine](https://hub.docker.com/_/alpine) |
| postfix | [GitHub](https://github.com/vdukhovni/postfix) |
| cyrus-sasl, cyrus-sasl-login | [Alpine](https://pkgs.alpinelinux.org/packages?name=cyrus-sasl) |

[Renovate](https://github.com/renovatebot/renovate) updates every pinned dependency automatically. Image builds also run `apk upgrade`, so a package fix reaches the next build even before the base image changes.
