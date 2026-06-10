# check=error=true

FROM alpine:3.24.0@sha256:a2d49ea686c2adfe3c992e47dc3b5e7fa6e6b5055609400dc2acaeb241c829f4

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

# Note: this image runs as root by design — Postfix master needs root to bind
# port 25; smtpd workers drop to the postfix user internally via setuid+chroot.
# AVD-DS-0002 is suppressed via .trivyignore at the repo root; see the rationale
# there.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD nc -w 3 127.0.0.1 25 < /dev/null | grep -q '^220 ' || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
