# check=error=true

FROM alpine:3.23.3@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659

RUN apk add --no-cache \
        ca-certificates \
        cyrus-sasl \
        cyrus-sasl-login \
        postfix \
        tzdata

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 25
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
