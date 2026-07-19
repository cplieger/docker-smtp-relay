#!/bin/sh
# -f disables pathname expansion: ACCEPTED_NETWORKS and RECIPIENT_RESTRICTIONS
# are iterated via word-splitting on unquoted expansion, so glob metacharacters
# in entries must not expand to files in the CWD.
set -euf

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
# run    (default) Validate env, render config, configure SASL, probe the
#                  upstream relay, then exec Postfix in the foreground as PID 1.
# render           Validate env and render the Postfix config files only — no
#                  secrets written, no postmap/postfix invoked, no root needed.
#                  Used by the golden-file tests (tests/render-test.sh) to
#                  exercise config generation in isolation.
MODE="${1:-run}"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# CONF_DIR is the directory the generated Postfix files are written to. It
# defaults to the real Postfix config dir; the test harness overrides it to a
# temp dir so config generation runs without root or a Postfix install. Only
# the three generated files are scoped to it — CA bundle, TLS scache, and the
# stdout maillog path are left at their absolute locations.
: "${CONF_DIR:=/etc/postfix}"
readonly CONF_DIR
readonly SASL_PASSWD_FILE="${CONF_DIR}/sasl_passwd"
readonly MAIN_CF="${CONF_DIR}/main.cf"

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
# SMTP_HOSTNAME            string    smtp-relay.local     FQDN recommended (shape not enforced); no newlines/metacharacters
# STARTUP_PROBE            enum      true                 true|false; fail-soft upstream TCP check
# STARTUP_PROBE_TIMEOUT    integer   5                    1-10; seconds (kept under healthcheck start-period)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Source validation and recipient-filter helpers
# ---------------------------------------------------------------------------
# shellcheck source-path=SCRIPTDIR source=validate.sh
. "$(dirname "$0")/validate.sh"
# shellcheck source-path=SCRIPTDIR source=recipient-filter.sh
. "$(dirname "$0")/recipient-filter.sh"

# ---------------------------------------------------------------------------
# apply_defaults — populate unset env vars with their documented defaults.
# ---------------------------------------------------------------------------
apply_defaults() {
  # Distinguish unset from explicitly empty: an unset ACCEPTED_NETWORKS gets
  # the RFC1918 default, but an explicitly empty value is left as-is so the
  # empty-value guard in validate_config can reject it (exit 2) rather than
  # silently broadening relay acceptance to the default private ranges.
  if [ "${ACCEPTED_NETWORKS+x}" != x ]; then
    ACCEPTED_NETWORKS="192.168.0.0/16 172.16.0.0/12 10.0.0.0/8"
  fi
  : "${RELAY_HOST:=}"
  : "${RELAY_PORT:=587}"
  : "${RELAY_LOGIN:=}"
  : "${RELAY_PASSWORD:=}"
  : "${RECIPIENT_RESTRICTIONS:=}"
  # Default to `secure` (chain + hostname verification) so a deploy without the
  # compose override does not silently fall back to cert-blind TLS.
  : "${SMTP_TLS_SECURITY_LEVEL:=secure}"
  : "${MESSAGE_SIZE_LIMIT:=10240000}"
  # Use an FQDN-shaped default so Postfix does not emit `numeric hostname`
  # warnings and receiving MTAs that validate HELO accept the relay. Set a
  # matching `hostname: smtp-relay.local` on the compose service to keep the
  # container and Postfix identity aligned.
  : "${SMTP_HOSTNAME:=smtp-relay.local}"
  : "${STARTUP_PROBE:=true}"
  : "${STARTUP_PROBE_TIMEOUT:=5}"
}

# ---------------------------------------------------------------------------
# validate_config — run every input check, exit 2 on the first failure.
# ---------------------------------------------------------------------------
# Format: VAR_NAME:check[,check...]
# Checks: nl=no_newlines, num=numeric, meta=no_metacharacters, range=MIN:MAX
validate_config() {
  _spec_table="
RELAY_HOST:nl,meta
RELAY_PORT:nl,num,range=1:65535
RELAY_LOGIN:nl
RELAY_PASSWORD:nl
ACCEPTED_NETWORKS:nl
RECIPIENT_RESTRICTIONS:nl
SMTP_TLS_SECURITY_LEVEL:nl
MESSAGE_SIZE_LIMIT:nl,num,range=1:104857600
SMTP_HOSTNAME:nl,meta
STARTUP_PROBE:nl
STARTUP_PROBE_TIMEOUT:nl,num,range=1:10
"
  for _spec in $_spec_table; do
    _var="${_spec%%:*}"
    _checks="${_spec#*:}"
    # A spec row names its env var exactly once; the value is fetched
    # indirectly so the name lives in one place ($_spec_table) instead of
    # being duplicated in a per-var case. apply_defaults sets every var in
    # the table, so an unset name here is a spec-table typo — surface it the
    # way the old `*)` arm did (exit 2) rather than letting `set -u` abort
    # with a vaguer message. `${var+x}` is unset-safe (yields empty, never
    # trips `set -u`); the eval is needed only for the indirect name.
    if ! eval "[ \"\${${_var}+x}\" = x ]"; then
      printf 'level=error msg="unknown validation var" var=%s\n' "$_var" >&2
      exit 2
    fi
    # eval is confined to this bare parameter expansion; $_value is then run
    # through the same newline/metacharacter checks as before, so no
    # unsanitized value ever reaches a command. The empty seed makes the
    # indirect assignment visible to ShellCheck (SC2154).
    _value=''
    eval "_value=\${$_var}"
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

  # Required variables
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

  # ACCEPTED_NETWORKS: reject open-relay and overly broad configs
  if [ -z "$ACCEPTED_NETWORKS" ]; then
    printf 'level=error msg="ACCEPTED_NETWORKS is empty"\n' >&2
    exit 2
  fi
  validate_no_open_relay "$ACCEPTED_NETWORKS" || exit 2

  # Reject cleartext TLS when SASL credentials are configured — sending
  # passwords over an unencrypted channel is a credential leak.
  if sasl_enabled; then
    case "$SMTP_TLS_SECURITY_LEVEL" in
      none | may)
        printf 'level=error msg="TLS must be encrypt or stronger when SASL credentials are set" tls_level=%s\n' \
          "$SMTP_TLS_SECURITY_LEVEL" >&2
        exit 2
        ;;
    esac
  fi

  # STARTUP_PROBE is a plain boolean toggle; anything other than true/false is
  # a config typo worth surfacing rather than silently treating as disabled.
  case "$STARTUP_PROBE" in
    true | false) ;;
    *)
      printf 'level=error msg="STARTUP_PROBE must be true or false" value="%s"\n' "$STARTUP_PROBE" >&2
      exit 2
      ;;
  esac

  printf 'level=info msg="input validation passed"\n' >&2
}

# ---------------------------------------------------------------------------
# compute_relayhost — bracket the relay host to skip MX lookups and handle
# IPv6 safely, then build the relayhost value Postfix consumes.
# ---------------------------------------------------------------------------
compute_relayhost() {
  case "$RELAY_HOST" in
    \[*) RELAYHOST_BRACKETED="$RELAY_HOST" ;;
    *) RELAYHOST_BRACKETED="[$RELAY_HOST]" ;;
  esac
  RELAYHOST_VALUE="${RELAYHOST_BRACKETED}:${RELAY_PORT}"
}

# ---------------------------------------------------------------------------
# sasl_enabled — true when both SASL credentials are configured (the single
# source of truth for "SASL is on"). Keeps the cleartext-TLS guard in
# validate_config and the RELAY_AUTH_ENABLE derivation below in lockstep.
# ---------------------------------------------------------------------------
sasl_enabled() {
  [ -n "$RELAY_LOGIN" ] && [ -n "$RELAY_PASSWORD" ]
}

# ---------------------------------------------------------------------------
# compute_sasl_state — derive the SASL-related main.cf values from whether
# credentials are present. Pure: writes no secret to disk, so it is safe in
# render mode. The actual sasl_passwd .db is written by write_sasl_secret.
# ---------------------------------------------------------------------------
compute_sasl_state() {
  # SASL_MAPS_LINE is the full main.cf line so the disabled case renders
  # `smtp_sasl_password_maps =` without a trailing space (Postfix reads an
  # empty value as "no map"; a templated empty var would leave whitespace).
  if sasl_enabled; then
    RELAY_AUTH_ENABLE="yes"
    SASL_MAPS_LINE="smtp_sasl_password_maps = hash:${SASL_PASSWD_FILE}"
  else
    RELAY_AUTH_ENABLE="no"
    SASL_MAPS_LINE="smtp_sasl_password_maps ="
  fi
}

# ---------------------------------------------------------------------------
# render_main_cf — generate $CONF_DIR/main.cf from the computed values.
# Deterministic text generation only; no side effects beyond the file write.
# ---------------------------------------------------------------------------
render_main_cf() {
  cat >"$MAIN_CF" <<EOF
# Generated by /usr/local/bin/entrypoint.sh on container start.
# Do not edit; edits are discarded on restart.
compatibility_level = 3.6

myhostname = ${SMTP_HOSTNAME}
mydestination = localhost
mynetworks = 127.0.0.0/8 [::1]/128 ${ACCEPTED_NETWORKS}
inet_interfaces = all

relayhost = ${RELAYHOST_VALUE}

smtp_sasl_auth_enable = ${RELAY_AUTH_ENABLE}
${SASL_MAPS_LINE}
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
# Postfix requires mailbox_size_limit >= message_size_limit. With the Postfix
# default (51200000) a larger MESSAGE_SIZE_LIMIT makes the local(8) delivery
# agent fatal on mail addressed to \$mydestination (verified by live repro);
# relayed mail is unaffected. Track the message limit so the whole validated
# 1-100 MB range works on every delivery path.
mailbox_size_limit = ${MESSAGE_SIZE_LIMIT}

smtpd_relay_restrictions = permit_mynetworks, reject
smtpd_recipient_restrictions = ${SMTPD_RECIPIENT_RESTRICTIONS}

maillog_file = /dev/stdout
EOF
}

# ---------------------------------------------------------------------------
# render_config — the shared pipeline: defaults, validation, and config-file
# generation. Used by both modes; produces no side effects beyond the
# generated files under $CONF_DIR.
# ---------------------------------------------------------------------------
render_config() {
  apply_defaults
  validate_config
  compute_relayhost
  compute_sasl_state
  # Sets SMTPD_RECIPIENT_RESTRICTIONS and writes $CONF_DIR/recipient_access.
  # Called (not subshelled) so the variable is visible to render_main_cf.
  build_recipient_filter
  render_main_cf
}

# ---------------------------------------------------------------------------
# write_sasl_secret — write the plaintext sasl_passwd, hash it with postmap,
# then remove the plaintext. Run-mode only (writes a secret to disk).
# ---------------------------------------------------------------------------
cleanup_sasl_plaintext() { rm -f "$SASL_PASSWD_FILE"; }

# On a terminating signal (e.g. Docker sending SIGTERM during a stop), remove
# the plaintext secret, disarm the traps, and exit non-zero. A plain
# cleanup-only handler would return control to the run path and let the script
# resume into Postfix startup after the signal, so PID 1 would ignore the stop
# request until Docker escalated to SIGKILL. Exiting here honors shutdown.
abort_sasl_secret() {
  cleanup_sasl_plaintext
  trap - EXIT INT TERM HUP QUIT
  printf 'level=info msg="received termination signal during SASL setup; cleaned up and aborting startup"\n' >&2
  exit 1
}

write_sasl_secret() {
  [ "$RELAY_AUTH_ENABLE" = "yes" ] || return 0

  # EXIT does best-effort plaintext removal even if postmap fails under
  # `set -e` before the explicit rm below runs. A terminating signal both
  # cleans up AND aborts (abort_sasl_secret exits non-zero) so a stop request
  # mid-write is not swallowed.
  trap cleanup_sasl_plaintext EXIT
  trap abort_sasl_secret INT TERM HUP QUIT

  # Write credentials with restrictive permissions from the start (umask 077
  # in subshell avoids a brief world-readable window before chmod).
  if ! (umask 077 && printf '%s %s:%s\n' "$RELAYHOST_VALUE" "$RELAY_LOGIN" "$RELAY_PASSWORD" \
    >"$SASL_PASSWD_FILE"); then
    printf 'level=error msg="failed to write SASL credentials file" path=%s\n' "$SASL_PASSWD_FILE" >&2
    exit 1
  fi
  # postmap inherits the process umask, not the source file mode; run it
  # inside a restrictive umask so a newly created .db file is 0600. But
  # postmap rewrites a PRE-EXISTING map in place and preserves its current
  # mode, so a leftover permissive sasl_passwd.db/.lmdb (e.g. 0644 from a
  # prior image build) would keep leaking the hashed credentials. Remove any
  # pre-existing hashed map first so the umask controls the recreated file.
  rm -f "${SASL_PASSWD_FILE}.db" "${SASL_PASSWD_FILE}.lmdb"
  if ! (umask 077 && postmap "$SASL_PASSWD_FILE"); then
    printf 'level=error msg="postmap failed"\n' >&2
    exit 1
  fi
  # Belt-and-suspenders: tighten the regenerated map to 0600 regardless of
  # the database suffix Postfix chose (ignore a missing suffix).
  chmod 600 "${SASL_PASSWD_FILE}.db" "${SASL_PASSWD_FILE}.lmdb" 2>/dev/null || true
  # Remove plaintext credentials; Postfix only reads the .db file.
  cleanup_sasl_plaintext
  trap - EXIT INT TERM HUP QUIT

  printf 'level=info msg="SASL authentication configured"\n' >&2
}

# ---------------------------------------------------------------------------
# run_postfix_checks — alias DB, config check, and permission fixup.
# ---------------------------------------------------------------------------
run_postfix_checks() {
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
}

# ---------------------------------------------------------------------------
# probe_upstream — best-effort TCP reachability check against the upstream
# relay. Fail-soft: a failure logs a warning and returns 0 so mail still
# queues (the relay may be transiently down at boot). A plain TCP connect is
# deliberate — it catches the common deploy-time faults (DNS, routing, wrong
# port, firewall) for both STARTTLS (587) and implicit-TLS (465) without a
# TLS handshake. It does NOT verify SASL credentials or the TLS chain; those
# are only provable by an actual send and surface via the deferred-queue /
# delivery-log alerting, not here. Sending QUIT lets a plaintext-greeting
# server (587/25) close promptly instead of holding the socket open until the
# timeout.
# ---------------------------------------------------------------------------
probe_upstream() {
  [ "$STARTUP_PROBE" = "true" ] || return 0

  # nc needs the bare host; strip the IPv6/skip-MX brackets the relay host
  # may carry.
  _probe_host="${RELAY_HOST#\[}"
  _probe_host="${_probe_host%\]}"

  # The outer timeout gets a small margin over nc's own -w idle timeout so
  # that for an implicit-TLS upstream (465, no plaintext greeting) nc's own
  # idle-close (success) wins the race instead of being SIGTERM-killed (a
  # spurious "unreachable" warn). Total stays bounded under the 15s
  # healthcheck start-period (max 10 + 2 = 12s).
  if printf 'QUIT\r\n' | timeout "$((STARTUP_PROBE_TIMEOUT + 2))" nc -w "$STARTUP_PROBE_TIMEOUT" "$_probe_host" "$RELAY_PORT" >/dev/null 2>&1; then
    printf 'level=info msg="upstream relay reachable" relay=%s\n' "$RELAYHOST_VALUE" >&2
  else
    printf 'level=warn msg="upstream relay unreachable at startup; continuing (mail will queue)" relay=%s\n' \
      "$RELAYHOST_VALUE" >&2
  fi
}

# ---------------------------------------------------------------------------
# log_startup — record persisted queue depth at startup. Helps correlate
# restart events with pre-existing backlogs in Loki/Grafana alerts (the spool
# is volume-mounted, so a restart during an upstream outage resumes with
# deferred mail). Raw find counts are more parseable than postqueue's summary
# string for Grafana stats() queries; both directories may be absent on a
# fresh spool, so 2>/dev/null.
# ---------------------------------------------------------------------------
log_startup() {
  _queue_active=$(find /var/spool/postfix/active -type f 2>/dev/null | wc -l)
  _queue_deferred=$(find /var/spool/postfix/deferred -type f 2>/dev/null | wc -l)
  printf 'level=info msg="starting smtp-relay" relay=%s tls=%s networks="%s" queue_active=%d queue_deferred=%d\n' \
    "$RELAYHOST_VALUE" "$SMTP_TLS_SECURITY_LEVEL" "$ACCEPTED_NETWORKS" \
    "$_queue_active" "$_queue_deferred" >&2
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "$MODE" in
  render)
    render_config
    printf 'level=info msg="config rendered" conf_dir=%s\n' "$CONF_DIR" >&2
    ;;
  run)
    render_config
    write_sasl_secret
    run_postfix_checks
    probe_upstream
    log_startup
    exec postfix start-fg
    ;;
  *)
    printf 'level=error msg="unknown mode" mode="%s" valid="run render"\n' "$MODE" >&2
    exit 2
    ;;
esac
