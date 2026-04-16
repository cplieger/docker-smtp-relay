# check=error=true

FROM alpine:3.23.4@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11

RUN apk add --no-cache \
        ca-certificates \
        cyrus-sasl \
        cyrus-sasl-login \
        postfix \
        tzdata

COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

EXPOSE 25
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
