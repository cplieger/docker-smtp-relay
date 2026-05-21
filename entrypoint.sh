#!/bin/sh
# -f disables pathname expansion: ACCEPTED_NETWORKS and RECIPIENT_RESTRICTIONS
# are iterated via word-splitting on unquoted expansion, so glob metacharacters
# in entries must not expand to files in the CWD.
set -euf

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SASL_PASSWD_FILE="/etc/postfix/sasl_passwd"

# ---------------------------------------------------------------------------
# Exit codes: 2 = config-validation failure, 1 = runtime failure
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Config contract
# ---------------------------------------------------------------------------
# Env Var                  Type      Default              Constraints
# -------                  ----      -------              -----------
# ACCEPTED_NETWORKS        string    192.168.0.0/16 ...   space-separated CIDRs; min /8; no 0.0.0.0/0
# RELAY_HOST               string    (required)           no newlines/metacharacters; non-empty
# RELAY_PORT               integer   587                  1-65535
# RELAY_LOGIN              string    ""                   no whitespace or colons
# RELAY_PASSWORD           string    ""                   no whitespace
# RECIPIENT_RESTRICTIONS   string    ""                   space-separated; addresses or /regex/
# SMTP_TLS_SECURITY_LEVEL  enum      secure               one of $TLS_LEVELS (see validate.sh)
# MESSAGE_SIZE_LIMIT       integer   10240000             max 104857600 (100 MB)
# SMTP_HOSTNAME            string    smtp-relay.local     FQDN-shaped; no newlines/metacharacters
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Default configuration
# ---------------------------------------------------------------------------
: "${ACCEPTED_NETWORKS:=192.168.0.0/16 172.16.0.0/12 10.0.0.0/8}"
: "${RELAY_HOST:=}"
: "${RELAY_PORT:=587}"
: "${RELAY_LOGIN:=}"
: "${RELAY_PASSWORD:=}"
: "${RECIPIENT_RESTRICTIONS:=}"
# Default to `secure` (chain + hostname verification) so a deploy without the
# compose override does not silently fall back to cert-blind TLS.
: "${SMTP_TLS_SECURITY_LEVEL:=secure}"
: "${MESSAGE_SIZE_LIMIT:=10240000}"
# Use an FQDN-shaped default so Postfix does not emit `numeric hostname` warnings
# and receiving MTAs that validate HELO accept the relay. The compose service
# sets `hostname: smtp-relay.local` to keep container + Postfix identity aligned.
: "${SMTP_HOSTNAME:=smtp-relay.local}"

# ---------------------------------------------------------------------------
# Source validation helpers
# ---------------------------------------------------------------------------
# shellcheck source-path=SCRIPTDIR source=validate.sh
. "$(dirname "$0")/validate.sh"

# ---------------------------------------------------------------------------
# Input validation — data-driven spec table
# ---------------------------------------------------------------------------
# Format: VAR_NAME:check[,check...]
# Checks: nl=no_newlines, num=numeric, meta=no_metacharacters, range=MIN:MAX
VALIDATION_SPEC="
RELAY_HOST:nl,meta
RELAY_PORT:nl,num,range=1:65535
RELAY_LOGIN:nl
RELAY_PASSWORD:nl
ACCEPTED_NETWORKS:nl
RECIPIENT_RESTRICTIONS:nl
SMTP_TLS_SECURITY_LEVEL:nl
MESSAGE_SIZE_LIMIT:nl,num,range=0:104857600
SMTP_HOSTNAME:nl,meta
"

for _spec in $VALIDATION_SPEC; do
	_var="${_spec%%:*}"
	_checks="${_spec#*:}"
	case "$_var" in
	RELAY_HOST) _value="$RELAY_HOST" ;;
	RELAY_PORT) _value="$RELAY_PORT" ;;
	RELAY_LOGIN) _value="$RELAY_LOGIN" ;;
	RELAY_PASSWORD) _value="$RELAY_PASSWORD" ;;
	ACCEPTED_NETWORKS) _value="$ACCEPTED_NETWORKS" ;;
	RECIPIENT_RESTRICTIONS) _value="$RECIPIENT_RESTRICTIONS" ;;
	SMTP_TLS_SECURITY_LEVEL) _value="$SMTP_TLS_SECURITY_LEVEL" ;;
	MESSAGE_SIZE_LIMIT) _value="$MESSAGE_SIZE_LIMIT" ;;
	SMTP_HOSTNAME) _value="$SMTP_HOSTNAME" ;;
	*)
		printf 'level=error msg="unknown validation var" var=%s\n' "$_var" >&2
		exit 2
		;;
	esac
	_oldIFS=$IFS
	IFS=,
	for _chk in $_checks; do
		IFS=$_oldIFS
		case "$_chk" in
		nl) validate_no_newlines "$_var" "$_value" || exit 2 ;;
		num) validate_numeric "$_var" "$_value" || exit 2 ;;
		meta) validate_no_metacharacters "$_var" "$_value" || exit 2 ;;
		range=*)
			_range="${_chk#range=}"
			_min="${_range%%:*}"
			_max="${_range#*:}"
			validate_range "$_var" "$_value" "$_min" "$_max" || exit 2
			;;
		esac
	done
	IFS=$_oldIFS
done

# Field-specific validators not expressible in the generic table
validate_sasl_login "$RELAY_LOGIN" || exit 2
validate_sasl_password "$RELAY_PASSWORD" || exit 2
validate_tls_level "$SMTP_TLS_SECURITY_LEVEL" || exit 2

# ---------------------------------------------------------------------------
# Required variables
# ---------------------------------------------------------------------------
if [ -z "$RELAY_HOST" ]; then
	printf 'level=error msg="RELAY_HOST must be set"\n' >&2
	exit 2
fi

if [ -z "$RELAY_LOGIN" ] && [ -z "$RELAY_PASSWORD" ]; then
	printf 'level=info msg="SASL auth disabled; RELAY_LOGIN/RELAY_PASSWORD not set"\n' >&2
elif [ -z "$RELAY_LOGIN" ] || [ -z "$RELAY_PASSWORD" ]; then
	printf 'level=error msg="both RELAY_LOGIN and RELAY_PASSWORD must be set for SASL auth"\n' >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# ACCEPTED_NETWORKS: reject open-relay and overly broad configs
# ---------------------------------------------------------------------------
if [ -z "$ACCEPTED_NETWORKS" ]; then
	printf 'level=error msg="ACCEPTED_NETWORKS is empty"\n' >&2
	exit 2
fi

validate_no_open_relay "$ACCEPTED_NETWORKS" || exit 2

# Reject cleartext TLS when SASL credentials are configured — sending
# passwords over an unencrypted channel is a credential leak.
if [ -n "$RELAY_LOGIN" ] && [ -n "$RELAY_PASSWORD" ]; then
	case "$SMTP_TLS_SECURITY_LEVEL" in
	none | may)
		printf 'level=error msg="TLS must be encrypt or stronger when SASL credentials are set" tls_level=%s\n' \
			"$SMTP_TLS_SECURITY_LEVEL" >&2
		exit 2
		;;
	esac
fi

printf 'level=info msg="input validation passed"\n' >&2

# ---------------------------------------------------------------------------
# Bracket relayhost to skip MX lookups and handle IPv6 safely
# ---------------------------------------------------------------------------
case "$RELAY_HOST" in
\[*) RELAYHOST_BRACKETED="$RELAY_HOST" ;;
*) RELAYHOST_BRACKETED="[$RELAY_HOST]" ;;
esac
RELAYHOST_VALUE="${RELAYHOST_BRACKETED}:${RELAY_PORT}"

# ---------------------------------------------------------------------------
# SASL authentication
# ---------------------------------------------------------------------------
RELAY_AUTH_ENABLE="no"
RELAY_AUTH_PASSWORD_MAPS=""

cleanup_sasl_plaintext() { rm -f "$SASL_PASSWD_FILE"; }

if [ -n "$RELAY_LOGIN" ] && [ -n "$RELAY_PASSWORD" ]; then
	# Ensure the plaintext credentials file is removed even if postmap fails
	# under `set -e` before the explicit rm below runs.
	trap cleanup_sasl_plaintext EXIT INT TERM

	# Write credentials with restrictive permissions from the start (umask 077
	# in subshell avoids a brief world-readable window before chmod).
	(umask 077 && printf '%s %s:%s\n' "$RELAYHOST_VALUE" "$RELAY_LOGIN" "$RELAY_PASSWORD" \
		>"$SASL_PASSWD_FILE")
	# postmap inherits the process umask, not the source file mode; run it
	# inside a restrictive umask so the .db file is also 0600.
	if ! (umask 077 && postmap "$SASL_PASSWD_FILE"); then
		printf 'level=error msg="postmap failed"\n' >&2
		exit 1
	fi
	# Remove plaintext credentials; Postfix only reads the .db file.
	cleanup_sasl_plaintext
	trap - EXIT INT TERM

	RELAY_AUTH_ENABLE="yes"
	RELAY_AUTH_PASSWORD_MAPS="hash:${SASL_PASSWD_FILE}"
	printf 'level=info msg="SASL authentication configured"\n' >&2
fi

# ---------------------------------------------------------------------------
# Recipient filtering
# ---------------------------------------------------------------------------
# shellcheck source-path=SCRIPTDIR source=recipient-filter.sh
. "$(dirname "$0")/recipient-filter.sh"
build_recipient_filter

# ---------------------------------------------------------------------------
# Generate main.cf
# ---------------------------------------------------------------------------
cat >/etc/postfix/main.cf <<EOF
# Generated by /usr/local/bin/entrypoint.sh on container start.
# Do not edit; edits are discarded on restart.
compatibility_level = 3.6

myhostname = ${SMTP_HOSTNAME}
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
smtp_tls_protocols = >=TLSv1.2
smtp_tls_mandatory_protocols = >=TLSv1.2
smtp_tls_mandatory_ciphers = high
smtp_tls_ciphers = high

message_size_limit = ${MESSAGE_SIZE_LIMIT}

smtpd_relay_restrictions = permit_mynetworks, reject
smtpd_recipient_restrictions = ${SMTPD_RECIPIENT_RESTRICTIONS}

maillog_file = /dev/stdout
EOF

if ! newaliases; then
	printf 'level=warn msg="newaliases failed; continuing without alias database"\n' >&2
fi

if ! postfix check; then
	printf 'level=error msg="postfix config check failed"\n' >&2
	exit 1
fi

if ! postfix set-permissions; then
	printf 'level=error msg="postfix set-permissions failed; refusing to start"\n' >&2
	exit 1
fi

# Persisted queue depth at startup — helps correlate restart events with
# pre-existing backlogs in Loki/Grafana alerts (the spool is volume-mounted,
# so a restart during an upstream outage resumes with deferred mail). Raw
# find counts are more parseable than postqueue's summary string for Grafana
# stats() queries; both directories may be absent on a fresh spool, so 2>/dev/null.
queue_active=$(find /var/spool/postfix/active -type f 2>/dev/null | wc -l)
queue_deferred=$(find /var/spool/postfix/deferred -type f 2>/dev/null | wc -l)

printf 'level=info msg="starting smtp-relay" relay=%s tls=%s networks="%s" queue_active=%d queue_deferred=%d\n' \
	"$RELAYHOST_VALUE" "$SMTP_TLS_SECURITY_LEVEL" "$ACCEPTED_NETWORKS" \
	"$queue_active" "$queue_deferred" >&2
exec postfix start-fg
