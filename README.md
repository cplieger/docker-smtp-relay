# docker-smtp-relay

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-smtp-relay/badges/size.json)](https://github.com/cplieger/docker-smtp-relay/pkgs/container/docker-smtp-relay) [![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)](https://github.com/cplieger/docker-smtp-relay/pkgs/container/docker-smtp-relay) [![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)](https://github.com/cplieger/docker-smtp-relay/blob/main/Dockerfile) [![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-smtp-relay/releases)

<!-- hub-overview BEGIN -->
docker-smtp-relay gives the apps and devices on your network one place to send email, and forwards it through your provider, such as AWS SES, Gmail or Mailgun. It only sends mail and holds no mailboxes.

## What it does

docker-smtp-relay lets every app on your network send email through one provider account:

- Your apps send to port 25 on your Docker host, with no login to set up in each app.
- Your provider login lives in one container, and by default mail leaves over TLS with certificate checks.
- Mail is queued and retried while your provider is unreachable.
- It checks each setting's format before it starts and names a wrong one in the log.
- It can limit which addresses your apps may send to.

## Who it is for

docker-smtp-relay is built for a home lab where a NAS, Grafana, Paperless-ngx, Uptime Kuma or IoT devices send alerts by email. Devices that cannot use your provider's login or TLS can still send.

You need an email provider account that accepts SMTP, with its server name, port and login. For Gmail, the login is an App Password. Keep port 25 on your own network.

Other projects suit other needs:

- Consider [docker-mailserver](https://docker-mailserver.github.io/docker-mailserver/latest/) if you want your own mailboxes. It is a full mail server with SMTP, IMAP, anti-spam and anti-virus.
- Consider [Apprise](https://github.com/caronc/apprise) if you want alerts in Telegram, Discord, Slack or Gotify. It sends to most popular notification services with one syntax.

docker-smtp-relay is free software under the Apache-2.0 license.
<!-- hub-overview END -->

## Quick start

The image is on GitHub Container Registry and Docker Hub, for `amd64` and `arm64`. This is the [`compose.yaml`](compose.yaml) in this repository.

```yaml
services:
  smtp-relay:
    image: ghcr.io/cplieger/docker-smtp-relay:latest
    container_name: smtp-relay
    restart: unless-stopped

    environment:
      RELAY_HOST: "email-smtp.us-east-1.amazonaws.com"  # your provider's SMTP server name
      RELAY_LOGIN: "your-relay-login"  # the SMTP username your provider gives you
      RELAY_PASSWORD: "your-relay-password"  # for Gmail, paste the App Password with its spaces
      RELAY_PORT: "587"  # 587 = STARTTLS, 465 = implicit TLS
      # For apps in other containers, add their Docker network range from "docker network inspect".
      ACCEPTED_NETWORKS: "192.168.0.0/16"  # the networks your apps send mail from

    ports:
      - "25:25"

    volumes:
      # Replace /path/to/smtp-relay-spool with a folder on your host before the first start.
      - "/path/to/smtp-relay-spool:/var/spool/postfix"  # keeps queued mail across restarts
```

1. Replace `/path/to/smtp-relay-spool` with a folder on your host, such as `/opt/smtp-relay/spool`.
2. Set `RELAY_HOST`, `RELAY_LOGIN` and `RELAY_PASSWORD` to your provider's SMTP server and login. For Gmail, use `smtp.gmail.com` and paste the App Password as Google shows it, spaces included.
3. Set `ACCEPTED_NETWORKS` to the networks your apps send from. For apps in other containers, add their Docker network's range, which `docker network inspect <network>` shows.
4. Run `docker compose up -d`.
5. In each app's email settings, enter your Docker host's address as the SMTP server, port 25, with no login and no encryption.

Run `docker logs smtp-relay`. You should see `msg="starting smtp-relay"`. If you see `upstream relay unreachable at startup`, check `RELAY_HOST`, `RELAY_PORT` and your firewall. Mail queues until the relay reaches your provider.

## Configuration reference

Every setting is an environment variable, checked each time the container starts. After a change, run `docker compose up -d` to recreate the container with the new values. A setting that fails its check stops the start with exit code 2 and a `level=error` line that names it.

| Variable | Description | Default |
| --- | --- | --- |
| `RELAY_HOST` | Your provider's SMTP server, such as `email-smtp.us-east-1.amazonaws.com`, `smtp.gmail.com` or `smtp.mailgun.org` | required |
| `RELAY_LOGIN` | SMTP username. Set it together with `RELAY_PASSWORD`, or leave both unset for a server that needs no login | _(unset)_ |
| `RELAY_PASSWORD` | SMTP password. Spaces inside it are kept, so a Gmail App Password works as issued. It must not end with whitespace | _(unset)_ |
| `RELAY_PORT` | `587` for STARTTLS, `465` for implicit TLS. With `465`, `SMTP_TLS_SECURITY_LEVEL` cannot be `none`, `may` or `dane` | `587` |
| `SMTP_TLS_SECURITY_LEVEL` | How the relay checks your provider's certificate. `secure` checks the chain and the host name | `secure` |
| `ACCEPTED_NETWORKS` | Space-separated networks, in CIDR form, allowed to send through the relay. `0.0.0.0/0`, `::/0` and ranges wider than /8 are refused | `192.168.0.0/16 172.16.0.0/12 10.0.0.0/8` |
| `RECIPIENT_RESTRICTIONS` | Space-separated addresses, domains or patterns the relay may send to. Empty sends to anyone | _(unset)_ |
| `MESSAGE_SIZE_LIMIT` | Largest message accepted, in bytes, from 1 to 104857600 | `10240000` |
| `SMTP_HOSTNAME` | The name the relay gives when it connects to your provider. Use a full domain name, because some servers refuse a short one | `smtp-relay.local` |
| `SMTPD_TLS_CERT_FILE` | Certificate file in PEM form, to offer STARTTLS to your apps on port 25. Set it with `SMTPD_TLS_KEY_FILE` | _(unset)_ |
| `SMTPD_TLS_KEY_FILE` | Private key file in PEM form for that certificate | _(unset)_ |
| `STARTUP_PROBE` | `true` checks at start that your provider's server answers on its port, and logs the result | `true` |

The image logs in UTC, and `TZ` has no effect. [Configuration](docs/configuration.md) lists every other setting and covers the TLS levels, inbound TLS, recipient filtering and provider examples.

| Mount | Description |
| --- | --- |
| `/var/spool/postfix` | Postfix mail queue, kept across restarts |

| Port | Description |
| --- | --- |
| `25` | SMTP, where your apps send mail |

## Security

Keep port 25 on your own network. The example publishes it on every host interface, and `ACCEPTED_NETWORKS` decides who may send mail, not who can connect. On a host with an internet-facing interface, publish it on a LAN address only, such as `"192.0.2.10:25:25"`, or firewall port 25.

Your apps send to the relay without encryption unless you set `SMTPD_TLS_CERT_FILE` and `SMTPD_TLS_KEY_FILE`. When the relay uses TLS to your provider, it uses TLS 1.2 or later. With a login set, the TLS levels `none` and `may` are refused.

The relay keeps the provider login in a file only root can read. Settings are environment variables only, so anyone who can run `docker inspect` on the host can read the password. The container starts as root to listen on port 25, and Postfix runs its workers as an unprivileged user. [Security](docs/hardening.md) covers hardening, every check the relay runs and what the image contains.

## Troubleshooting

Every 30 seconds, the healthcheck checks that Postfix answers on port 25 with its `220` greeting. Unhealthy means Postfix is not answering. The check never contacts your provider, so a healthy relay can still fail to deliver mail. If Postfix stops, the container exits and Docker's restart policy starts it again. Queued mail stays on the spool volume and is retried.

- The container exits at start. The `level=error` line names the setting to fix.
- The log shows `upstream relay unreachable at startup`. `RELAY_HOST` or `RELAY_PORT` is wrong, or a firewall blocks the connection.
- An app reports `Access denied` when it sends. Its address is outside `ACCEPTED_NETWORKS`.
- Delivery lines show `status=deferred`. Your provider could not be reached, or it refused the login or the TLS check. The line carries the reason.

## Monitoring

The relay has no metrics endpoint. Postfix logs every delivery attempt to the container log with `status=sent`, `status=deferred` or `status=bounced`, and the startup lines are `level=... msg=...` pairs. [Monitoring and alerts](docs/monitoring.md) explains the lines and has a Loki alert rule for failing delivery.

## Documentation

- [Configuration](docs/configuration.md) lists every setting, with the TLS levels, inbound TLS and recipient filtering.
- [Security](docs/hardening.md) covers network exposure, the hardened compose settings and what the image contains.
- [Monitoring and alerts](docs/monitoring.md) explains the log lines and the alert rule.
- [How docker-smtp-relay works](docs/how-it-works.md) describes the design and what happens at each start.

## Credits

docker-smtp-relay packages [Postfix](https://github.com/vdukhovni/postfix), which does all the mail handling, and all credit for it goes to its maintainers. You may take Postfix under either the Eclipse Public License 2.0 or the IBM Public License 1.0.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude](https://claude.com), [GPT](https://openai.com), and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

Apache-2.0. See [LICENSE](LICENSE).

The image carries the license text of every bundled component under `/usr/share/licenses/`. The Alpine packages in the image ship no license file upstream, so their license texts are kept under `licenses/` in this repository and copied in.

It packages Postfix, which you may take under either the Eclipse Public License 2.0 or the IBM Public License 1.0, and Postfix's own `LICENSE` and `TLS_LICENSE` ship under `/usr/share/licenses/postfix/`. The exact version is pinned in the Dockerfile as `POSTFIX_VERSION`, with `POSTFIX_SHA256` pinning the tarball the build fetches from `https://high5.nl/mirrors/postfix-release/official/postfix-<version>.tar.gz` (the fallback mirror serves the same path on `http://ftp.porcupine.org`); the upstream source repository is [vdukhovni/postfix](https://github.com/vdukhovni/postfix). The build applies no patch files, and the only changes it makes to that source are the `sed` commands in the Dockerfile, so this repository at the commit that produced an image plus the pinned tarball are the complete build recipe for it.
