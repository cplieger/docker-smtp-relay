# check=error=true

FROM alpine:3.23.4@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11

RUN apk add --no-cache \
        ca-certificates \
        cyrus-sasl \
        cyrus-sasl-login \
        postfix \
        tzdata

COPY --chmod=755 validate.sh /usr/local/bin/validate.sh
COPY --chmod=755 recipient-filter.sh /usr/local/bin/recipient-filter.sh
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 25

# trivy:ignore:DS-0002 — Postfix master must run as root to bind port 25 (a
# privileged port < 1024); smtpd workers drop to the postfix user internally
# via Postfix's chroot + setuid model. Adding USER non-root at the Dockerfile
# level would prevent the master from binding port 25 and break the relay.
# Capability-only alternatives (CAP_NET_BIND_SERVICE) don't apply because
# Postfix's privilege-separation model requires root for the master.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD nc -w 3 127.0.0.1 25 < /dev/null | grep -q '^220 ' || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
