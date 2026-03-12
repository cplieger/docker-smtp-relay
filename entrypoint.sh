#!/bin/sh
set -eu

# ---------------------------------------------------------------------------
# Default configuration
# ---------------------------------------------------------------------------
: "${ACCEPTED_NETWORKS:=192.168.0.0/16 172.16.0.0/12 10.0.0.0/8}"
: "${RELAY_HOST:=}"
: "${RELAY_PORT:=587}"
: "${RELAY_LOGIN:=}"
: "${RELAY_PASSWORD:=}"
: "${RECIPIENT_RESTRICTIONS:=}"
: "${SMTP_TLS_SECURITY_LEVEL:=encrypt}"
: "${MESSAGE_SIZE_LIMIT:=10240000}"

# ---------------------------------------------------------------------------
# Input validation — reject values that could inject Postfix config directives
# ---------------------------------------------------------------------------

# Reject env vars containing newlines — a newline in a Postfix config value
# would inject additional directives. printf '%s' strips trailing newline;
# wc -l counts remaining embedded newlines (0 = clean, 1+ = injected).
validate_no_newlines() {
    line_count=$(printf '%s' "$2" | wc -l)
    if [ "$line_count" -gt 0 ]; then
        printf 'level=error msg="env var contains newlines" var=%s\n' "$1" >&2
        exit 1
    fi
}

validate_numeric() {
    case "$2" in
        ''|*[!0-9]*)
            printf 'level=error msg="env var must be a positive integer" var=%s value="%s"\n' "$1" "$2" >&2
            exit 1
            ;;
    esac
}

validate_no_newlines "RELAY_HOST" "$RELAY_HOST"
validate_no_newlines "RELAY_PORT" "$RELAY_PORT"
validate_no_newlines "RELAY_LOGIN" "$RELAY_LOGIN"
validate_no_newlines "RELAY_PASSWORD" "$RELAY_PASSWORD"
validate_no_newlines "ACCEPTED_NETWORKS" "$ACCEPTED_NETWORKS"
validate_no_newlines "RECIPIENT_RESTRICTIONS" "$RECIPIENT_RESTRICTIONS"
validate_no_newlines "SMTP_TLS_SECURITY_LEVEL" "$SMTP_TLS_SECURITY_LEVEL"
validate_no_newlines "MESSAGE_SIZE_LIMIT" "$MESSAGE_SIZE_LIMIT"

validate_numeric "RELAY_PORT" "$RELAY_PORT"
validate_numeric "MESSAGE_SIZE_LIMIT" "$MESSAGE_SIZE_LIMIT"

# ---------------------------------------------------------------------------
# Required variables
# ---------------------------------------------------------------------------
if [ -z "$RELAY_HOST" ]; then
    printf 'level=error msg="RELAY_HOST must be set"\n' >&2
    exit 1
fi

if [ -z "$RELAY_LOGIN" ] && [ -z "$RELAY_PASSWORD" ]; then
    printf 'level=info msg="SASL auth disabled — RELAY_LOGIN/RELAY_PASSWORD not set"\n' >&2
elif [ -z "$RELAY_LOGIN" ] || [ -z "$RELAY_PASSWORD" ]; then
    printf 'level=error msg="both RELAY_LOGIN and RELAY_PASSWORD must be set for SASL auth"\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Validate ACCEPTED_NETWORKS — reject open-relay configs
# ---------------------------------------------------------------------------
for net in $ACCEPTED_NETWORKS; do
    case "$net" in
        0.0.0.0/0|::/0)
            printf 'level=error msg="ACCEPTED_NETWORKS contains open-relay CIDR" network=%s\n' "$net" >&2
            exit 1
            ;;
    esac
done

# Validate TLS level against known Postfix values
case "$SMTP_TLS_SECURITY_LEVEL" in
    none|may|encrypt|dane|dane-only|fingerprint|verify|secure) ;;
    *)
        printf 'level=error msg="invalid SMTP_TLS_SECURITY_LEVEL" value="%s"\n' "$SMTP_TLS_SECURITY_LEVEL" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# Bracket relayhost to skip MX lookups and handle IPv6 safely
# ---------------------------------------------------------------------------
case "$RELAY_HOST" in
    \[*) RELAYHOST_BRACKETED="$RELAY_HOST" ;;
    *)   RELAYHOST_BRACKETED="[$RELAY_HOST]" ;;
esac
RELAYHOST_VALUE="${RELAYHOST_BRACKETED}:${RELAY_PORT}"

# ---------------------------------------------------------------------------
# SASL authentication
# ---------------------------------------------------------------------------
RELAY_AUTH_ENABLE="no"
RELAY_AUTH_PASSWORD_MAPS=""

if [ -n "$RELAY_LOGIN" ] && [ -n "$RELAY_PASSWORD" ]; then
    RELAY_AUTH_ENABLE="yes"
    # Write credentials with restrictive permissions from the start (umask 077
    # in subshell avoids a brief world-readable window before chmod).
    (umask 077 && printf '%s %s:%s\n' "$RELAYHOST_VALUE" "$RELAY_LOGIN" "$RELAY_PASSWORD" \
        > /etc/postfix/sasl_passwd)
    # postmap inherits the process umask, not the source file mode — run it
    # inside a restrictive umask so the .db file is also 0600.
    (umask 077 && postmap /etc/postfix/sasl_passwd)
    # Remove plaintext credentials — Postfix only reads the .db file.
    rm -f /etc/postfix/sasl_passwd
    RELAY_AUTH_PASSWORD_MAPS="hash:/etc/postfix/sasl_passwd"
    printf 'level=info msg="SASL authentication configured"\n' >&2
fi

# ---------------------------------------------------------------------------
# Recipient filtering
# ---------------------------------------------------------------------------
SMTPD_RECIPIENT_RESTRICTIONS="permit_mynetworks, reject"

if [ -n "$RECIPIENT_RESTRICTIONS" ]; then
    RCPT_FILE="/etc/postfix/recipient_access"
    : > "$RCPT_FILE"
    for token in $RECIPIENT_RESTRICTIONS; do
        case "$token" in
            /*/)
                printf '%s OK\n' "$token" >> "$RCPT_FILE" ;;
            *@*)
                # Escape regex metacharacters and the / delimiter used by
                # Postfix regexp tables. ] must be first in the character class
                # per POSIX; # delimiter avoids conflict with literal /.
                esc=$(printf '%s' "$token" | sed 's#[].[\\^$*+?(){|/]#\\&#g')
                printf '/^%s$/ OK\n' "$esc" >> "$RCPT_FILE" ;;
            *)
                # Domain match — same escaping as above
                esc=$(printf '%s' "$token" | sed 's#[].[\\^$*+?(){|/]#\\&#g')
                printf '/@%s$/ OK\n' "$esc" >> "$RCPT_FILE" ;;
        esac
    done
    printf '/.*/ REJECT\n' >> "$RCPT_FILE"
    SMTPD_RECIPIENT_RESTRICTIONS="check_recipient_access regexp:${RCPT_FILE}, reject"
    printf 'level=info msg="recipient filtering configured" rules=%d\n' \
        "$(wc -l < "$RCPT_FILE")" >&2
fi

# ---------------------------------------------------------------------------
# Generate main.cf
# ---------------------------------------------------------------------------
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

if ! newaliases; then
    printf 'level=warn msg="newaliases failed — continuing without alias database"\n' >&2
fi

if ! postfix check; then
    printf 'level=error msg="postfix config check failed"\n' >&2
    exit 1
fi

if ! postfix set-permissions; then
    printf 'level=warn msg="postfix set-permissions failed — continuing"\n' >&2
fi

printf 'level=info msg="starting smtp-relay" relay=%s tls=%s networks="%s"\n' \
    "$RELAYHOST_VALUE" "$SMTP_TLS_SECURITY_LEVEL" "$ACCEPTED_NETWORKS" >&2
exec postfix start-fg
