# Configuration

This page lists every setting of docker-smtp-relay and explains the TLS levels, inbound TLS and recipient filtering, for readers who want to change more than the quick start sets.

## Where settings live

Every setting is an environment variable in the compose file. The container reads and checks them each time it starts, then writes the Postfix configuration from them, so you never edit a Postfix file. After a change, run `docker compose up -d` to recreate the container with the new values. A setting that fails its check stops the start with exit code 2 and a `level=error` line that names it.

## Every setting

| Variable | Description | Default |
| --- | --- | --- |
| `RELAY_HOST` | Your provider's SMTP server, such as `email-smtp.us-east-1.amazonaws.com`, `smtp.gmail.com` or `smtp.mailgun.org` | required |
| `RELAY_LOGIN` | SMTP username. Set it together with `RELAY_PASSWORD`, or leave both unset, and delete both lines from the compose file, for a server that needs no login | _(unset)_ |
| `RELAY_PASSWORD` | SMTP password. Spaces inside it are kept, so a Gmail App Password works as issued. It must not end with whitespace | _(unset)_ |
| `RELAY_PORT` | `587` for STARTTLS, `465` for implicit TLS. With `465`, `SMTP_TLS_SECURITY_LEVEL` cannot be `none`, `may` or `dane` | `587` |
| `SMTP_TLS_SECURITY_LEVEL` | How the relay checks your provider's certificate. `secure` checks the chain and the host name | `secure` |
| `SMTP_TLS_FINGERPRINT_CERT_MATCH` | Space-separated certificate or public-key digests of your provider's server, as colon-separated hex pairs. Required at level `fingerprint`, refused at any other | _(unset)_ |
| `SMTP_TLS_FINGERPRINT_DIGEST` | Digest used at level `fingerprint`, `sha256` or `sha512`. Setting it at any other level is refused, and an empty value counts as unset | `sha256` |
| `ACCEPTED_NETWORKS` | Space-separated networks, in CIDR form, allowed to send through the relay. `0.0.0.0/0`, `::/0` and ranges wider than /8 are refused | `192.168.0.0/16 172.16.0.0/12 10.0.0.0/8` |
| `RECIPIENT_RESTRICTIONS` | Space-separated addresses, domains or patterns the relay may send to. Empty sends to anyone | _(unset)_ |
| `MESSAGE_SIZE_LIMIT` | Largest message accepted, in bytes, from 1 to 104857600 | `10240000` |
| `SMTP_HOSTNAME` | The name the relay gives when it connects to your provider. Use a full domain name, because some servers refuse a short one | `smtp-relay.local` |
| `SMTPD_TLS_CERT_FILE` | Certificate file in PEM form, to offer STARTTLS to your apps on port 25. Set it with `SMTPD_TLS_KEY_FILE` | _(unset)_ |
| `SMTPD_TLS_KEY_FILE` | Private key file in PEM form for that certificate | _(unset)_ |
| `SMTPD_TLS_SECURITY_LEVEL` | Inbound TLS level, `may` or `encrypt`. Setting it without the certificate and key is refused | `may` when the certificate is set |
| `STARTUP_PROBE` | `true` checks at start that your provider's server answers on its port, and logs the result | `true` |
| `STARTUP_PROBE_TIMEOUT` | Seconds the startup check waits for an answer, from 1 to 10 | `5` |
| `CONF_DIR` | Folder the generated Postfix files are written to, used by the tests. Leave it unset, because Postfix always reads `/etc/postfix` | `/etc/postfix` |

`ACCEPTED_NETWORKS` takes its default only when the variable is absent. The shipped compose file sets it to `192.168.0.0/16`, and an empty value is refused. IPv6 networks work in either `fd00::/8` or `[fd00::]/8` form. An entry outside private address space draws a startup warning, because a mistyped prefix such as `192.168.0.0/8` passes the /8 floor and covers about 16 million public addresses.

`RELAY_LOGIN` must not contain a colon, start with whitespace or end with a newline, and `RELAY_PASSWORD` must not end with whitespace. Each of those would change the login the relay sends. Every other character is kept as you typed it.

`SMTP_HOSTNAME` refuses whitespace and shell metacharacters, and it does not check that the value is a full domain name.

`CONF_DIR` must be an existing writable folder. Setting it in a normal start logs a warning, because Postfix then runs on a configuration the relay did not write.

The image ships no time zone data and logs in UTC, so `TZ` has no effect.

## Provider examples

- For AWS SES, set `RELAY_HOST` to your region's SMTP endpoint, such as `email-smtp.us-east-1.amazonaws.com`, and the login to the SMTP credentials SES gives you.
- For Gmail, set `RELAY_HOST` to `smtp.gmail.com` and `RELAY_PASSWORD` to an App Password. Paste it as Google shows it, spaces included, such as `'wxyz abcd efgh aabb'`, and keep the quotes in `.env`.
- Mailgun, SendGrid and any other provider that accepts SMTP with STARTTLS on port 587 work with the defaults.

The relay passes each message's sender address through unchanged. Set each app's sender to an address your provider accepts for your account.

With a login set, the relay offers it with the `PLAIN` or `LOGIN` method only, and never over a connection without TLS.

## TLS security levels

`SMTP_TLS_SECURITY_LEVEL` sets how the relay protects the connection to your provider. When a level uses TLS, the connection uses TLS 1.2 or later with the `high` cipher grade. See the [Postfix TLS README](https://www.postfix.org/TLS_README.html) for the full meaning of each level.

| Level | What it does |
| --- | --- |
| `secure` | Requires TLS and checks the certificate chain and the host name. The default, and right for every hosted provider |
| `verify` | Requires TLS and checks the certificate chain and the server name. The Postfix TLS README explains how it differs from `secure` |
| `encrypt` | Requires TLS without checking who answers. Warns with a login set |
| `dane` | Takes the TLS policy from DNSSEC-validated TLSA records, with Postfix's weaker fallback for a server that has none. Warns with a login set |
| `dane-only` | Requires DNSSEC-validated TLSA records, and mail waits until they verify |
| `fingerprint` | Trusts only the certificate or public-key digests in `SMTP_TLS_FINGERPRINT_CERT_MATCH` |
| `may` | Uses TLS when offered and sends in cleartext otherwise. Refused with a login set |
| `none` | Never uses TLS. Refused with a login set |

With `RELAY_PORT` `465`, the relay opens the connection with TLS and accepts `encrypt`, `verify`, `secure`, `dane-only` or `fingerprint` only.

For `dane` and `dane-only`, the relay adds `smtp_dns_support_level = dnssec` itself. DANE works only when the container's whole resolver chain checks DNSSEC. Docker's built-in DNS forwards to the host's resolvers, so point the host at a validating resolver you trust, such as a local `unbound`. With a resolver that does not validate, TLSA records never count as secure. Use `dane-only` only when your provider publishes TLSA records and you want delivery to stop otherwise.

For `fingerprint`, set `SMTP_TLS_FINGERPRINT_CERT_MATCH` to one or more digests in the format `openssl x509 -noout -fingerprint -sha256` prints. `SMTP_TLS_FINGERPRINT_DIGEST` is `sha256` unless you set `sha512`, and md5 and sha1 are refused because they are open to collisions. A digest of the wrong length or with a malformed hex pair stops the start. Both values are written into `main.cf`, the digest even at its default, so the trust anchors stay visible there. Update the digests when your provider changes its certificate.

## Inbound TLS

The TLS levels above cover the connection to your provider. On port 25 the relay speaks cleartext SMTP by default and offers no STARTTLS to your apps. `ACCEPTED_NETWORKS` decides who may send mail through the relay, not whether the connection is encrypted.

To offer STARTTLS on port 25, mount a certificate and key and set both variables:

```yaml
    environment:
      SMTPD_TLS_CERT_FILE: "/certs/smtpd.pem"  # PEM, may include the chain
      SMTPD_TLS_KEY_FILE: "/certs/smtpd.key"
    volumes:
      - "/path/to/certs:/certs:ro"
```

Both files must exist and be readable, or the start stops. The relay warns when the certificate file holds no PEM certificate, when the key file holds no PEM private key, and when the key is readable by its group or by everyone.

The default level, `may`, offers STARTTLS and still accepts cleartext. That protects against passive capture only, because an attacker on the network path can remove the offer, and a client that skips certificate checks gains no proof of who it talks to. `encrypt` requires TLS from every sender, so confirm your apps support STARTTLS before you set it. Mail from an app that does not is refused.

## Recipient filtering

`RECIPIENT_RESTRICTIONS` is an optional allowlist of recipients. When it is set, the relay accepts mail only for matching recipients and refuses everything else with `NOQUEUE: reject` in the log. One variable takes four kinds of space-separated entries:

- An address, such as `alerts@example.com`, matches that address exactly. A `/` in the local part, as in `john/doe@example.com`, matches literally.
- A domain, such as `example.org`, matches every recipient at exactly that domain. Subdomain syntax, `.example.org`, is not supported and draws a warning that it never matches.
- A pattern, such as `/^ops-.*@example\.net$/`, is passed to Postfix as a [regexp_table(5)](https://www.postfix.org/regexp_table.5.html) pattern. Escape a literal `/` inside it with a backslash.
- A pair of patterns, such as `/.*@example\.com$/!/^noreply@/`, matches the first pattern and not the second. This example accepts the whole domain except noreply.

A pattern may end with the flags `i`, `m` and `x`, with regexp_table(5) meanings, and each occurrence of a flag switches its setting. Patterns ignore case unless you add `i`, so `/^alerts@example\.com$/i` matches only the lowercase spelling. Patterns match anywhere in the `user@domain` address, so anchor a domain with `$`. Without it, `/.*@example\.com/` also accepts `victim@example.com.attacker.net`. The relay does not check whether a pattern can ever match, so `/^@example\.com$/` still counts as a working rule.

Four checks run at start, so a filter that would refuse or accept every recipient fails visibly. The healthcheck cannot see these mistakes, because port 25 answers either way.

- An entry that can never match draws a warning and does not count as a rule. That covers a domain with a leading dot or a `/`, an address with an empty local part, an empty domain or a dot right after the `@`, and a pattern that does not compile. A pattern entry whose structure cannot be read, such as one with no closing `/`, a dangling or doubled `!` or an unknown flag, draws a warning and is left out of the filter.
- When no entry counts as a rule, the start stops with exit code 2, because the filter would refuse all mail. A list with some good entries starts on those.
- A pattern that matches two made-up test addresses counts as possibly accepting everyone, and the start stops with exit code 2. That catches `/.*/`, `/./`, an empty alternative such as `/a@b\.c|/`, `/.*/!/^noreply@/` and every empty pattern, such as `//` and `/x/!//`. The check can refuse a pattern you meant narrowly, such as one alternation spanning `\.invalid$` and `\.test$`. Split it into `/\.invalid$/` and `/\.test$/` and both pass. Leave `RECIPIENT_RESTRICTIONS` empty when you want to send to anyone.
- The list holds at most 256 rules and 16384 bytes, and a longer one stops the start with exit code 2. Both limits are fixed. They keep the startup checks well inside the healthcheck's 15-second start period. A single pattern of a few KiB is fine. A bigger allowlist needs a Postfix setup of your own, with a `check_recipient_access` table or a [policy service](https://www.postfix.org/SMTPD_POLICY_README.html).
