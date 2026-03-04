#!/bin/sh
set -eu

: "${ACCEPTED_NETWORKS:=192.168.0.0/16 172.16.0.0/12 10.0.0.0/8}"
: "${RELAY_HOST:=}"
: "${RELAY_PORT:=587}"
: "${RELAY_LOGIN:=}"
: "${RELAY_PASSWORD:=}"
: "${RECIPIENT_RESTRICTIONS:=}"
: "${SMTP_TLS_SECURITY_LEVEL:=encrypt}"
: "${MESSAGE_SIZE_LIMIT:=10240000}"

if [ -z "$RELAY_HOST" ]; then
    echo "Error: RELAY_HOST must be set" >&2
    exit 1
fi

if [ -z "$RELAY_LOGIN" ] || [ -z "$RELAY_PASSWORD" ]; then
    echo "Warning: RELAY_LOGIN/RELAY_PASSWORD not set — SASL auth disabled" >&2
fi

# Bracket relayhost to skip MX lookups and handle IPv6 safely
case "$RELAY_HOST" in
    \[*) RELAYHOST_BRACKETED="$RELAY_HOST" ;;
    *)   RELAYHOST_BRACKETED="[$RELAY_HOST]" ;;
esac
if [ -n "$RELAY_PORT" ]; then
    RELAYHOST_VALUE="${RELAYHOST_BRACKETED}:${RELAY_PORT}"
else
    RELAYHOST_VALUE="${RELAYHOST_BRACKETED}"
fi

# --- SASL authentication ---
RELAY_AUTH_ENABLE="no"
RELAY_AUTH_PASSWORD_MAPS=""

if [ -n "${RELAY_LOGIN}" ] && [ -n "${RELAY_PASSWORD}" ]; then
    RELAY_AUTH_ENABLE="yes"
    printf '%s %s:%s\n' "$RELAYHOST_VALUE" "$RELAY_LOGIN" "$RELAY_PASSWORD" \
        > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd
    RELAY_AUTH_PASSWORD_MAPS="hash:/etc/postfix/sasl_passwd"
fi

# --- Recipient filtering ---
SMTPD_RECIPIENT_RESTRICTIONS="permit_mynetworks, reject"

if [ -n "$RECIPIENT_RESTRICTIONS" ]; then
    RCPT_FILE="/etc/postfix/recipient_access"
    : > "$RCPT_FILE"
    for token in $RECIPIENT_RESTRICTIONS; do
        case "$token" in
            /*/)
                echo "$token OK" >> "$RCPT_FILE" ;;
            *@*)
                esc="$(printf '%s' "$token" | sed 's/[.[\^$*+?(){|\\]/\\&/g')"
                echo "/^${esc}$/ OK" >> "$RCPT_FILE" ;;
            *)
                esc="$(printf '%s' "$token" | sed 's/[.[\^$*+?(){|\\]/\\&/g')"
                echo "/@${esc}$/ OK" >> "$RCPT_FILE" ;;
        esac
    done
    echo "/.*/ REJECT" >> "$RCPT_FILE"
    SMTPD_RECIPIENT_RESTRICTIONS="check_recipient_access regexp:${RCPT_FILE}, reject"
fi

# --- Generate main.cf ---
cat > /etc/postfix/main.cf <<EOF
compatibility_level = 3.6

myhostname = $(hostname)
mydestination = localhost
mynetworks = 127.0.0.0/8 [::1]/128 ${ACCEPTED_NETWORKS}
inet_interfaces = all

relayhost = ${RELAYHOST_VALUE}

smtp_sasl_auth_enable = ${RELAY_AUTH_ENABLE}
smtp_sasl_password_maps = ${RELAY_AUTH_PASSWORD_MAPS}
smtp_sasl_security_options = noanonymous
smtp_sasl_mechanism_filter = plain, login

smtp_tls_security_level = ${SMTP_TLS_SECURITY_LEVEL}
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_tls_session_cache_database = btree:\${data_directory}/smtp_scache

message_size_limit = ${MESSAGE_SIZE_LIMIT}

smtpd_relay_restrictions = permit_mynetworks, reject
smtpd_recipient_restrictions = ${SMTPD_RECIPIENT_RESTRICTIONS}

maillog_file = /dev/stdout
EOF

newaliases || true
postfix check || true
postfix set-permissions || true

echo "smtp-relay: ${RELAYHOST_VALUE} (TLS=${SMTP_TLS_SECURITY_LEVEL})"
exec postfix start-fg
