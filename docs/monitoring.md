# Monitoring and alerts

This page explains what docker-smtp-relay writes to its log and how to alert when mail stops reaching your provider, for readers who collect container logs.

## What the relay logs

The relay has no metrics endpoint, so its state is in the container log. All times are in UTC.

The startup steps write `level=... msg="..."` pairs. The last one before Postfix takes over is `msg="starting smtp-relay"`. It carries the relay host, the outbound and inbound TLS levels and the accepted networks. It also carries the queue depth left from the previous run, as `queue_active` and `queue_deferred`. `queue_scan_ok=false` means the queue could not be counted and the two numbers are not reliable. The depth makes a restart during a provider outage easy to spot.

Postfix then logs every delivery attempt with a `status=` field:

- `status=sent` means your provider accepted the message.
- `status=deferred` means delivery failed for now. The message stays in the queue and Postfix retries it.
- `status=bounced` means your provider refused the message for good.

Mail the relay refuses itself, because the sender is outside `ACCEPTED_NETWORKS` or the recipient fails `RECIPIENT_RESTRICTIONS`, logs as `NOQUEUE: reject` with no `status=` field.

## What the healthcheck and the startup check cover

The healthcheck only shows that Postfix answers on port 25. A wrong login or TLS level appears only when a message is sent, as a delivery line.

The startup check, `STARTUP_PROBE`, opens a plain TCP connection to `RELAY_HOST` on `RELAY_PORT` and logs `upstream relay reachable` or `upstream relay unreachable at startup; continuing (mail will queue)`. It catches a wrong host name, a wrong port, a routing problem or a firewall at deploy time. It never tests the login or the TLS certificate, which only a real send can prove, and a failure never stops the start.

A rising count of `status=deferred` lines with no `status=sent` lines means that your provider is unreachable or refusing the relay.

## Alerting

Ship the container's logs to Loki and evaluate this rule with [Loki's ruler](https://grafana.com/docs/loki/latest/alert/). Grafana Alloy's Docker log discovery ships them with no extra configuration. Firing alerts go through your Alertmanager like any Prometheus alert.

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
            status=bounced in 15m, so outbound mail is not reaching the upstream
            relay. Mail keeps queuing and retrying. Check the delivery lines for
            the SMTP reply text.
```

When `SmtpRelayDeliveryFailing` fires, the common causes are a bad `RELAY_LOGIN` or `RELAY_PASSWORD`, a wrong `SMTP_TLS_SECURITY_LEVEL`, or your provider rejecting or throttling the sender.

The rule ships with no stall alert, because delivery lines appear only when mail is sent and quiet periods are normal. The healthcheck covers a stopped Postfix. To alert on mail the relay refuses itself, add `NOQUEUE` to the pattern.

You can also turn the delivery lines into Prometheus metrics with an Alloy `loki.process` block and a `stage.metrics` stage, for dashboards. The rule above needs no such setup.

Thresholds and the `severity` label are starting points. Tune the count to your mail volume, and change the `container` selector to the label your log collector sets, such as `job` or `service`. Route by whatever labels your Alertmanager uses.
