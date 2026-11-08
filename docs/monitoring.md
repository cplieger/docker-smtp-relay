# Monitoring and alerts

This page explains what docker-smtp-relay writes to its log and how to alert when mail stops reaching your provider, for readers who collect container logs.

## What the relay logs

All times in the container log are in UTC.

The startup steps write `level=... msg="..."` pairs. The last one before Postfix takes over is `msg="starting smtp-relay"`. It carries the relay host, the outbound and inbound TLS levels and the accepted networks. It also carries the queue depth left from the previous run, as `queue_active` and `queue_deferred`. `queue_scan_ok=false` means the queue could not be counted and the two numbers are not reliable. The depth makes a restart during a provider outage easy to spot.

Postfix then logs every delivery attempt with a `status=` field:

- `status=sent` means your provider accepted the message.
- `status=deferred` means delivery failed for now. The message stays in the queue and Postfix retries it.
- `status=bounced` means your provider refused the message for good.

Mail the relay refuses itself, because the sender is outside `ACCEPTED_NETWORKS` or the recipient fails `RECIPIENT_RESTRICTIONS`, logs as `NOQUEUE: reject` with no `status=` field.

## What the healthcheck and the startup check cover

The healthcheck only shows that Postfix answers on port 25. A wrong login or TLS level appears only when a message is sent, as a delivery line.

The startup check, `STARTUP_PROBE`, opens a plain TCP connection to `RELAY_HOST` on `RELAY_PORT` and logs `upstream relay reachable` or `upstream relay unreachable at startup; continuing (mail will queue)`. It catches a wrong host name, a wrong port, a routing problem or a firewall at deploy time. It never tests the login or the TLS certificate, which only a real send can prove, and a failure never stops the start.

## What `METRICS_PORT` serves

With `METRICS_PORT` set, the relay starts one background process, the queue reader, just before Postfix. Every 15 seconds it runs `postqueue -j` and writes a summary of the queue to a file: how many messages wait in each queue and how long the oldest deferred one has waited. The page Postfix serves on `METRICS_PORT` returns that summary, so a scrape never walks the queue itself. A scrape interval shorter than 15 seconds only reads the same summary again.

The reader runs as the unprivileged `smtp-metrics` user with the `postdrop` group, the group `postqueue` needs to reach Postfix's queue service. Under no-new-privileges `postqueue` cannot gain that group on its own, so the reader holds it from its start. The page itself runs without `postdrop`, as [Security](hardening.md#privileges-and-the-hardened-compose-settings) explains.

`smtp_relay_queue_scrape_ok` is 1 while the summary is at most 60 seconds old, which allows one failed read. Otherwise it is 0 and the page leaves out the queue series, so an old count is never reported. Nothing restarts a reader that stops; `SmtpRelayDown` fires once `smtp_relay_queue_scrape_ok` has stayed 0 for 5 minutes, and a restart of the container starts a new reader. A reader that cannot read the queue logs `METRICS_PORT queue reader cannot read the queue` once, with `postqueue`'s exit status, and `reads the queue again` when it recovers. Right after a start the page reports 0 until the first read, 15 seconds in.

## Alerting

The rules are in [`alerts/`](../alerts/). [`alerts/logql.yaml`](../alerts/logql.yaml) is for Loki's ruler and reads Postfix's own delivery lines. [`alerts/promql.yaml`](../alerts/promql.yaml) is for Prometheus, Mimir or vmalert and reads the page `METRICS_PORT` serves, scraped as job `smtp-relay`. Load them as [Loading an app's alert rules](https://github.com/cplieger/docs/blob/main/docs/monitoring.md#loading-an-apps-alert-rules) shows.

| Alert | Fires when | Severity | File |
| --- | --- | --- | --- |
| `SmtpRelayMailStuck` | the oldest deferred message arrived more than 30 minutes ago | warning | both |
| `SmtpRelayMailBounced` | your provider refused a message for good in the last 15 minutes | warning | `logql.yaml`, group `smtp-relay-events` |
| `SmtpRelayDown` | the `smtp-relay` scrape has failed, or the page has not had a fresh queue summary, for 5 minutes | warning | `promql.yaml` |

`alerts/logql.yaml` has two groups. `smtp-relay-state` holds `SmtpRelayMailStuck`, and `smtp-relay-events` holds `SmtpRelayMailBounced`. Load the `smtp-relay-events` group always, because a bounce has no metric. Load `smtp-relay-state` only if you do not load `alerts/promql.yaml`, or `SmtpRelayMailStuck` fires twice.

In `alerts/logql.yaml`, `SmtpRelayMailStuck` reads the `delay=` field of each `status=deferred` line, which is how long the message has waited since it arrived. It fires on the first retry of a message older than 30 minutes. It stays firing for up to 90 minutes after the last deferral, because its window must outlast Postfix's longest wait between two retries. In `alerts/promql.yaml` it reads `smtp_relay_queue_oldest_message_age_seconds` and fires once that age has stayed over 30 minutes for 5 minutes. Either way it fires however little mail the relay carries. When it fires, the common causes are a bad `RELAY_LOGIN` or `RELAY_PASSWORD`, a wrong `SMTP_TLS_SECURITY_LEVEL`, or your provider rejecting or throttling the sender. The deferred lines carry your provider's reply.

`SmtpRelayMailBounced` fires on any `status=bounced` line. A bounced message is not retried, and a sender with no mailbox, such as most apps and devices, never hears about it.

Send these alerts to a receiver that is not email, such as a chat or push service. An email about a failing relay would travel through the relay that is failing.

No rule reads `NOQUEUE: reject` lines: the relay refuses that mail while the sending app is still connected, so the app gets the error itself. If you want delivery counts on a dashboard, add a log-to-metric step in your log collector or a Postfix exporter.

Thresholds and the `severity` label are starting points. Tune the 30-minute age to how long your mail may wait, and change the `container` selector to the label your log collector sets, such as `job` or `service`. Route by whatever labels your Alertmanager uses.
