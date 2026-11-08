# Monitoring and alerts

This page covers what docker-smtp-relay reports, how to get alerts from it and who tells you when it stops. Postfix logs every delivery attempt to the container log, and with `METRICS_PORT` set it also serves a Prometheus metrics page about its mail queue. Alert rules for Loki and for Prometheus ship in [`alerts/`](../alerts/).

## What you get

| You run | You get | You set up |
| --- | --- | --- |
| Prometheus, Mimir or VictoriaMetrics, with Alertmanager (the monitoring guide's starting stack adds Loki) | `SmtpRelayMailStuck` and `SmtpRelayDown` from the metrics page, a graph of each queue, and `SmtpRelayMailBounced` from Loki | `METRICS_PORT`, a scrape job named `smtp-relay`, `alerts/promql.yaml`, and the `smtp-relay-events` group of `alerts/logql.yaml` in Loki's ruler |
| Loki and Alertmanager, no metric store | `SmtpRelayMailStuck` and `SmtpRelayMailBounced`. No log rule sees a stopped relay. | All of `alerts/logql.yaml`, and an uptime prober that opens TCP port 25 and expects the `220` greeting |
| Grafana-managed alerting only | The same alerts, as Grafana rules | The rule files imported into Grafana, each with its data source |
| Docker or Unraid only | The container log and Docker's health status, which notify nobody | An uptime prober that opens TCP port 25 and expects the `220` greeting |

## Metrics

Set `METRICS_PORT` to a free port other than 25, such as `9154`, and publish it on the address your Prometheus reaches, such as `"192.0.2.10:9154:9154"`. Postfix then serves Prometheus metrics at `/metrics` on that port and answers any other path with 404. Left unset, the image opens no port beyond 25 and its Postfix configuration is unchanged. The page has no login, so keep the port on your network. It reports queue sizes and ages, never an address, a sender name or a queue id.

With `METRICS_PORT` set, the relay starts one background process, the queue reader, just before Postfix. Every 15 seconds it runs `postqueue -j` and writes a summary of the queue to a file. Each scrape returns that summary, so a scrape never walks the queue itself. A scrape interval shorter than 15 seconds only reads the same summary again.

The reader runs as the unprivileged `smtp-metrics` user with the `postdrop` group, the group `postqueue` needs to reach Postfix's queue service. Under no-new-privileges `postqueue` cannot gain that group on its own, so the reader holds it from its start. The page itself runs without `postdrop`, as [Security](hardening.md#privileges-and-the-hardened-compose-settings) explains.

| Series | Type | Labels | Meaning |
| --- | --- | --- | --- |
| `smtp_relay_queue_messages` | gauge | `queue`: `active`, `deferred`, `hold`, `incoming` or `maildrop` | Messages waiting in each Postfix queue |
| `smtp_relay_queue_oldest_message_age_seconds` | gauge | `queue`: always `deferred` | Seconds since the oldest deferred message arrived, 0 when none is deferred |
| `smtp_relay_queue_scrape_ok` | gauge | | 1 while the queue summary is at most 60 seconds old, else 0 |
| `smtp_relay_build_info` | gauge | `version`, `postfix_version` | Always 1, with labels that name the image version and the Postfix version |

The 60-second bound allows one failed read. Past it, `smtp_relay_queue_scrape_ok` is 0 and the page leaves out the two queue series, so an old count is never reported. Right after a start, `smtp_relay_queue_scrape_ok` is 0 and the queue series are missing until the first read, 15 seconds in. Nothing restarts a reader that stops, and a restart of the container starts a new one.

Postfix keeps no delivery counters, so the page reports the queue, not deliveries. If you want delivery counts on a dashboard, add a log-to-metric step in your log collector or a Postfix exporter.

No dashboard ships. These queries are a start in Grafana's Metrics Drilldown:

- Mail waiting for a retry: `smtp_relay_queue_messages{queue="deferred"}`
- Minutes the oldest deferred message has waited: `smtp_relay_queue_oldest_message_age_seconds / 60`

## Logs

All times in the container log are in UTC.

The startup steps write `level=... msg="..."` pairs. The last one before Postfix takes over is `msg="starting smtp-relay"`. It carries the relay host, the outbound and inbound TLS levels and the accepted networks. It also carries the queue depth left from the previous run, as `queue_active` and `queue_deferred`. `queue_scan_ok=false` means the queue could not be counted and the two numbers are not reliable. The depth makes a restart during a provider outage easy to spot.

The startup check, `STARTUP_PROBE`, opens a plain TCP connection to `RELAY_HOST` on `RELAY_PORT` and logs `upstream relay reachable` or `upstream relay unreachable at startup; continuing (mail will queue)`. It catches a wrong host name, a wrong port, a routing problem or a firewall at deploy time. It never tests the login or the TLS certificate, which only a real send can prove. A failure never stops the start.

Postfix then logs every delivery attempt with a `status=` field:

- `status=sent` means your provider accepted the message.
- `status=deferred` means delivery failed for now. The message stays in the queue and Postfix retries it. The line's `delay=` field is the number of seconds since the message arrived, which the log rule `SmtpRelayMailStuck` reads.
- `status=bounced` means your provider refused the message for good, which `SmtpRelayMailBounced` reads.

These fields are Postfix's own wording. The image's tests send mail through the Postfix version the image ships and check that each field appears as the rules expect.

Mail the relay refuses itself, because the sender is outside `ACCEPTED_NETWORKS` or the recipient fails `RECIPIENT_RESTRICTIONS`, logs as `NOQUEUE: reject` with no `status=` field.

With `METRICS_PORT` set, a queue reader that cannot read the queue logs `METRICS_PORT queue reader cannot read the queue` once, with a `status=` field. 124 or 137 means `postqueue` did not answer within 10 seconds. It logs `reads the queue again` when it recovers.

## Alerting

[`alerts/logql.yaml`](../alerts/logql.yaml) is for Loki's ruler and reads Postfix's own delivery lines. [`alerts/promql.yaml`](../alerts/promql.yaml) is for Prometheus, Mimir or vmalert and reads the metrics page, scraped as job `smtp-relay`. [Loading an app's alert rules](https://github.com/cplieger/docs/blob/main/docs/monitoring.md#loading-an-apps-alert-rules) and [Loading metric alert rules](https://github.com/cplieger/docs/blob/main/docs/monitoring.md#loading-metric-alert-rules) show how to load each file.

`alerts/logql.yaml` has two groups. `smtp-relay-state` holds `SmtpRelayMailStuck`, the alternative to `alerts/promql.yaml`. `smtp-relay-events` holds `SmtpRelayMailBounced`, which has no metric form, because Postfix keeps no counters. Load the `smtp-relay-events` group always. Load `smtp-relay-state` only if you do not load `alerts/promql.yaml`, or `SmtpRelayMailStuck` fires twice. With Prometheus, delete the `smtp-relay-state` group from your copy of `alerts/logql.yaml`.

`SmtpRelayDown` exists only in `alerts/promql.yaml`. With logs only, an outside probe of port 25 covers a stopped relay, as [Knowing the app is alive](#knowing-the-app-is-alive) explains.

| Alert | Fires when | Severity | File |
| --- | --- | --- | --- |
| `SmtpRelayMailStuck` | the oldest deferred message arrived more than 30 minutes ago | warning | both |
| `SmtpRelayMailBounced` | your provider refused a message for good in the last 15 minutes | warning | `logql.yaml`, group `smtp-relay-events` |
| `SmtpRelayDown` | the `smtp-relay` scrape has failed, or the page has not had a fresh queue summary, for 5 minutes | warning | `promql.yaml` |

Send these alerts to a receiver that is not email, such as a chat or push service. An email about a failing relay would travel through the relay that is failing.

Thresholds and the `severity` labels are starting points. Tune the 30-minute age to how long your mail may wait. Change the `container` selector to the label your log collector sets, and keep the scrape job name `smtp-relay` that `SmtpRelayDown` reads.

### Notes on each alert

`SmtpRelayMailStuck` fires however little mail the relay carries. In `alerts/logql.yaml` it reads the `delay=` field of each `status=deferred` line and fires on the first retry of a message older than 30 minutes. It stays firing for up to 90 minutes after the last deferral, because its window must outlast Postfix's longest wait between two retries. In `alerts/promql.yaml` it reads `smtp_relay_queue_oldest_message_age_seconds` and fires once that age has stayed over 30 minutes for 5 minutes. The common causes are a bad `RELAY_LOGIN` or `RELAY_PASSWORD`, a wrong `SMTP_TLS_SECURITY_LEVEL`, or your provider rejecting or throttling the sender. The deferred lines carry your provider's reply.

`SmtpRelayMailBounced` fires on any `status=bounced` line. A bounced message is not retried, and a sender with no mailbox, such as most apps and devices, never hears about it. The bounced line names the recipient and your provider's reply.

`SmtpRelayDown` fires when the scrape fails, when the target is missing, or when `smtp_relay_queue_scrape_ok` has stayed 0. A failed scrape means the container, Postfix or the network path is down. `smtp_relay_queue_scrape_ok` at 0 means the queue reader stopped or cannot read the queue. The container log then names a read failure, and a stopped reader logs nothing.

No rule reads `NOQUEUE: reject` lines. The relay refuses that mail while the sending app is still connected, so the app gets the error itself. Keep such a rule out of your defaults too, because `RECIPIENT_RESTRICTIONS` refuses mail on purpose.

## Knowing the app is alive

The relay serves no HTTP health page. The page on `METRICS_PORT` serves `/metrics` only and has no `/healthz`, because the program behind it cannot see whether Postfix answers mail on port 25. Port 25 itself is the health signal: Postfix greets each new connection with a line that starts with `220`.

**What healthy means.** Postfix accepts connections on port 25 and sends its `220` greeting. Your provider being unreachable never makes the relay unhealthy. It shows as `status=deferred` lines in the log and as a rising `smtp_relay_queue_oldest_message_age_seconds`, which `SmtpRelayMailStuck` reads.

**Docker health.** The image checks itself every 30 seconds by opening port 25 inside the container and reading the greeting. Docker marks the container unhealthy after 3 failures, and allows 15 seconds after a start. Docker's health status notifies nobody on its own, and Docker does not restart an unhealthy container. If Postfix stops, the container exits and your restart policy starts it again.

**Who is told.**

| You run | A dead app | A wedged app |
| --- | --- | --- |
| Prometheus with this app's rules | `SmtpRelayDown` | mail that waits: `SmtpRelayMailStuck`. Postfix not answering on port 25: an outside probe of port 25 |
| Loki only | an outside probe of port 25 | mail that waits: `SmtpRelayMailStuck`. Postfix not answering on port 25: an outside probe of port 25 |
| Docker or Unraid only | an uptime prober on port 25, or something that watches Docker health | the same |

`SmtpRelayDown` sees Postfix stop, but not a Postfix that still serves the metrics page while it no longer answers mail on port 25. An outside probe that expects `220` on port 25 sees both. Mail that Postfix accepts and keeps deferring leaves port 25 answering, so only `SmtpRelayMailStuck` sees it.

**Probing from outside.** Open a TCP connection to port 25 of the address your apps send mail to, and pass only when the first line it reads starts with `220`. A probe that only checks that the port opens still sees a stopped container, but not a Postfix that stopped greeting. Use a 5-second timeout, check every 60 seconds, alert after 3 failures, and wait 15 seconds after a first start. The probe sends no mail and needs no login, and `ACCEPTED_NETWORKS` does not apply to it, because Postfix greets every connection before any mail is sent.
