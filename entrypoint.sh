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
# ACCEPTED_NETWORKS        string    192.168.0.0/16 ...   space-separated CIDRs; min /8; no 0.0.0.0/0 or ::/0
# CONF_DIR                 string    /etc/postfix         no newlines/metacharacters (rendered into main.cf paths)
# RELAY_HOST               string    (required)           no newlines/metacharacters; non-empty; well-formed [brackets] (host:port warned)
# RELAY_PORT               integer   587                  1-65535
# RELAY_LOGIN              string    ""                   no whitespace or colons
# RELAY_PASSWORD           string    ""                   no whitespace
# RECIPIENT_RESTRICTIONS   string    ""                   space-separated; addresses, domains, or /regex/
# SMTP_TLS_SECURITY_LEVEL  enum      secure               one of $TLS_LEVELS (see validate.sh); not none/may with RELAY_PORT=465
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
# Split into one helper per validation concern; validate_config (defined
# after the helpers) orchestrates them in the original check order, so exit-2
# precedence is unchanged. Two blocks deliberately live outside their tidiest
# home to preserve that order: the RELAY_HOST required check ends
# validate_declared_fields (it must fire before the SASL both-or-neither
# check), and the cleartext-TLS guard ends validate_relay_acceptance (it must
# fire after the ACCEPTED_NETWORKS checks).
# ---------------------------------------------------------------------------

# validate_field_check VAR VALUE CHECK — run one spec-table check. An unknown
# check token is a spec-table typo: fail loudly (the caller exits 2), matching
# the unknown-var guard in validate_declared_fields, instead of silently
# skipping the intended validation. The token comes from the hardcoded
# _spec_table, never from user input, so interpolating it is safe.
validate_field_check() {
  case "$3" in
    nl) validate_no_newlines "$1" "$2" ;;
    num) validate_numeric "$1" "$2" ;;
    meta) validate_no_metacharacters "$1" "$2" ;;
    range=*)
      _vfc_range="${3#range=}"
      validate_range "$1" "$2" "${_vfc_range%%:*}" "${_vfc_range#*:}"
      ;;
    *)
      printf 'level=error msg="unknown validation check" var=%s check=%s\n' "$1" "$3" >&2
      return 1
      ;;
  esac
}

# validate_declared_fields — the generic spec-table interpreter, the
# field-specific validators not expressible in the table, and the
# required-variable check.
# Format: VAR_NAME:check[,check...]
# Checks: nl=no_newlines, num=numeric, meta=no_metacharacters, range=MIN:MAX
validate_declared_fields() {
  _spec_table="
CONF_DIR:nl,meta
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
      validate_field_check "$_var" "$_value" "$_chk" || exit 2
    done
    IFS=$_oldIFS
  done

  # Field-specific validators not expressible in the generic table
  validate_sasl_login "$RELAY_LOGIN" || exit 2
  validate_sasl_password "$RELAY_PASSWORD" || exit 2
  validate_tls_level "$SMTP_TLS_SECURITY_LEVEL" || exit 2

  # Required variables (kept here, before the SASL pairing check, so the
  # exit-2 precedence between the two errors is unchanged)
  if [ -z "$RELAY_HOST" ]; then
    printf 'level=error msg="RELAY_HOST must be set"\n' >&2
    exit 2
  fi
  validate_relay_host_shape "$RELAY_HOST" || exit 2
}

# validate_sasl_config — SASL credentials are both-or-neither.
validate_sasl_config() {
  if [ -z "$RELAY_LOGIN" ] && [ -z "$RELAY_PASSWORD" ]; then
    printf 'level=info msg="SASL auth disabled; RELAY_LOGIN/RELAY_PASSWORD not set"\n' >&2
  elif [ -z "$RELAY_LOGIN" ] || [ -z "$RELAY_PASSWORD" ]; then
    printf 'level=error msg="both RELAY_LOGIN and RELAY_PASSWORD must be set for SASL auth"\n' >&2
    exit 2
  fi
}

# validate_relay_acceptance — relay-acceptance policy: who we accept mail
# from, and that credentials never travel a cleartext upstream channel.
validate_relay_acceptance() {
  # ACCEPTED_NETWORKS: reject open-relay and overly broad configs. One case
  # covers both degenerate shapes: explicitly empty, and non-empty but
  # whitespace-only. The whitespace-only value parses to zero entries:
  # validate_no_open_relay iterates nothing and succeeds, and the rendered
  # mynetworks contains only 127.0.0.0/8 and [::1]/128 -- silently excluding
  # every intended LAN while validation and the healthcheck stay green.
  # Fatal, mirroring the RECIPIENT_RESTRICTIONS zero-token rejection. (An
  # UNSET ACCEPTED_NETWORKS never reaches here: apply_defaults gives it the
  # RFC 1918 default.)
  case "$ACCEPTED_NETWORKS" in
    '')
      printf 'level=error msg="ACCEPTED_NETWORKS is empty"\n' >&2
      exit 2
      ;;
    *[![:space:]]*) ;;
    *)
      printf 'level=error msg="ACCEPTED_NETWORKS is non-empty but contains no network entries (whitespace only?); refusing to render a localhost-only mynetworks"\n' >&2
      exit 2
      ;;
  esac
  validate_no_open_relay "$ACCEPTED_NETWORKS" || exit 2

  # Reject cleartext TLS when SASL credentials are configured — sending
  # passwords over an unencrypted channel is a credential leak. (Kept here,
  # after the ACCEPTED_NETWORKS checks, so exit-2 precedence is unchanged.)
  if sasl_enabled && tls_level_cleartext; then
    printf 'level=error msg="TLS must be encrypt or stronger when SASL credentials are set" tls_level=%s\n' \
      "$SMTP_TLS_SECURITY_LEVEL" >&2
    exit 2
  fi

  # RELAY_PORT=465 is the documented implicit-TLS port (the render turns on
  # smtp_tls_wrappermode, see compute_tls_wrappermode): the upstream opens
  # with a TLS handshake, so a disabled (none) or opportunistic (may) TLS
  # level contradicts the contract — the wrapped connection is mandatory TLS
  # and such a config could never have delivered mail. Reject it instead of
  # rendering a dead relay. (Numeric -eq: RELAY_PORT is already validated
  # numeric and in range, and -eq also matches a leading-zero spelling.)
  if [ "$RELAY_PORT" -eq 465 ] && tls_level_cleartext; then
    printf 'level=error msg="RELAY_PORT=465 is implicit TLS; SMTP_TLS_SECURITY_LEVEL must be encrypt or stronger" tls_level=%s\n' \
      "$SMTP_TLS_SECURITY_LEVEL" >&2
    exit 2
  fi
}

# validate_runtime_config — runtime toggles and the filesystem contract.
validate_runtime_config() {
  # STARTUP_PROBE is a plain boolean toggle; anything other than true/false is
  # a config typo worth surfacing rather than silently treating as disabled.
  case "$STARTUP_PROBE" in
    true | false) ;;
    *)
      # Do not interpolate the rejected raw value (it can carry a double
      # quote and break logfmt parsing); the var name + allowlist suffice.
      printf 'level=error msg="STARTUP_PROBE must be true or false" var=STARTUP_PROBE valid="true false"\n' >&2
      exit 2
      ;;
  esac

  # CONF_DIR is where every generated file lands. A syntactically valid but
  # missing or unwritable directory is a config-contract failure: catch it
  # here with a structured error and exit 2, instead of letting a later
  # redirection fail under set -e with only a raw shell diagnostic after
  # "input validation passed" was already logged (which misclassifies the
  # bad config as a runtime failure and blinds level=error-based alerts).
  if [ ! -d "$CONF_DIR" ] || [ ! -w "$CONF_DIR" ]; then
    printf 'level=error msg="CONF_DIR must be an existing writable directory" conf_dir="%s"\n' "$(sanitize_token "$CONF_DIR")" >&2
    exit 2
  fi
}

validate_config() {
  validate_declared_fields
  validate_sasl_config
  validate_relay_acceptance
  validate_runtime_config

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
# compute_tls_wrappermode — derive smtp_tls_wrappermode from RELAY_PORT.
# Port 465 is implicit TLS (RFC 8314): Postfix must open the connection with
# a TLS handshake instead of the plaintext SMTP/STARTTLS exchange, or the
# upstream never answers and every message sits deferred while the inbound
# healthcheck stays green. Any other port keeps the STARTTLS default (no).
# Numeric -eq, matching the 465 guard in validate_relay_acceptance.
# ---------------------------------------------------------------------------
compute_tls_wrappermode() {
  if [ "$RELAY_PORT" -eq 465 ]; then
    SMTP_TLS_WRAPPERMODE="yes"
  else
    SMTP_TLS_WRAPPERMODE="no"
  fi
}

# ---------------------------------------------------------------------------
# compute_mynetworks — build the mynetworks value Postfix consumes. Postfix
# requires IPv6 addresses in mynetworks to be bracketed ([fd00::]/8, per
# postconf(5)); an unbracketed IPv6 CIDR draws a runtime "bad net/mask
# pattern" warning and never matches, silently denying the operator's IPv6
# LAN. Bracket bare IPv6 entries here; IPv4 entries pass through verbatim, so
# output is byte-identical for IPv4-only inputs. validate_no_open_relay has
# already guaranteed every entry carries a /prefix.
# ---------------------------------------------------------------------------
compute_mynetworks() {
  MYNETWORKS_VALUE="127.0.0.0/8 [::1]/128"
  for _net in $ACCEPTED_NETWORKS; do
    case "$_net" in
      \[*) ;;                                 # already bracketed IPv6 - Postfix format
      *:*) _net="[${_net%/*}]/${_net##*/}" ;; # bare IPv6: bracket address for mynetworks
    esac
    MYNETWORKS_VALUE="$MYNETWORKS_VALUE $_net"
  done
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
# tls_level_cleartext -- true when the configured TLS level allows a cleartext
# (none) or opportunistic (may) upstream channel. Single source of truth for
# the two validate_relay_acceptance guards that must reject such a level
# (credential leak with SASL; dead relay with implicit-TLS port 465).
# ---------------------------------------------------------------------------
tls_level_cleartext() {
  case "$SMTP_TLS_SECURITY_LEVEL" in
    none | may) return 0 ;;
  esac
  return 1
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
# promote_rendered_file TMP DEST LABEL -- finish an atomic render: chmod the
# temp file to the world-readable 0644 the Postfix daemons need (mktemp
# creates 0600), then mv it into place. On failure emit a structured
# level=error naming LABEL, remove the temp file, and exit 1. Shared by
# render_main_cf and build_recipient_filter (all three scripts are sourced
# into one shell, so the caller in recipient-filter.sh resolves this at call
# time, exactly like its existing sanitize_token calls into validate.sh).
# ---------------------------------------------------------------------------
promote_rendered_file() {
  if ! chmod 644 "$1" || ! mv "$1" "$2"; then
    printf 'level=error msg="failed to move rendered %s into place" path="%s"\n' "$3" "$(sanitize_token "$2")" >&2
    rm -f "$1"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# create_rendered_tmp DEST LABEL -- start an atomic render: mktemp DEST.XXXXXX
# in CONF_DIR and print the path. On failure emit a structured level=error
# naming LABEL and return 1 (callers `|| exit 1`; a helper in a command
# substitution runs in a subshell, so it cannot exit the script itself).
# The counterpart of promote_rendered_file, shared the same sourced-shell way
# by render_main_cf and build_recipient_filter.
# ---------------------------------------------------------------------------
create_rendered_tmp() {
  if ! mktemp "$1.XXXXXX"; then
    printf 'level=error msg="failed to create temporary file for %s" conf_dir="%s"\n' "$2" "$(sanitize_token "$CONF_DIR")" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# render_main_cf — generate $CONF_DIR/main.cf from the computed values.
# Deterministic text generation only; no side effects beyond the file write.
# Renders to a mktemp file in CONF_DIR and mv's atomically so a write failure
# (ENOSPC, EROFS) surfaces as a structured level=error instead of a raw shell
# diagnostic, and a partial main.cf is never left for Postfix to read.
# ---------------------------------------------------------------------------
render_main_cf() {
  _main_tmp=$(create_rendered_tmp "$MAIN_CF" main.cf) || exit 1
  if ! cat >"$_main_tmp" <<EOF; then
# Generated by /usr/local/bin/entrypoint.sh on container start.
# Do not edit; edits are discarded on restart.
compatibility_level = 3.6

myhostname = ${SMTP_HOSTNAME}
mydestination = localhost
mynetworks = ${MYNETWORKS_VALUE}
inet_interfaces = all

relayhost = ${RELAYHOST_VALUE}

smtp_sasl_auth_enable = ${RELAY_AUTH_ENABLE}
${SASL_MAPS_LINE}
smtp_sasl_security_options = noanonymous, noplaintext
smtp_sasl_tls_security_options = noanonymous
smtp_sasl_mechanism_filter = plain, login

smtp_tls_security_level = ${SMTP_TLS_SECURITY_LEVEL}
smtp_tls_wrappermode = ${SMTP_TLS_WRAPPERMODE}
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
    printf 'level=error msg="failed to write main.cf (disk full or read-only?)" path="%s"\n' "$(sanitize_token "$_main_tmp")" >&2
    rm -f "$_main_tmp"
    exit 1
  fi
  promote_rendered_file "$_main_tmp" "$MAIN_CF" main.cf
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
  compute_tls_wrappermode
  compute_mynetworks
  compute_sasl_state
  # Sets SMTPD_RECIPIENT_RESTRICTIONS and writes $CONF_DIR/recipient_access.
  # Called (not subshelled) so the variable is visible to render_main_cf.
  build_recipient_filter
  render_main_cf
}

# ---------------------------------------------------------------------------
# Interruptible startup — as PID 1 under Alpine ash, a trapped signal is only
# handled once the current foreground command returns, so a TERM delivered
# while startup blocks in postmap, newaliases, postfix check/set-permissions,
# the upstream probe, or a queue scan stays pending until that child exits —
# the probe alone can block up to 12 seconds, past Docker's default 10-second
# stop grace, drawing a SIGKILL before any abort line is logged.
# run_interruptible backgrounds the operation and blocks in `wait`, which IS
# interruptible: the signal handler runs immediately, TERMs and reaps the
# recorded child via terminate_startup_child, and exits promptly. Bounded
# operations (run_bounded, postmap_restricted, scan_queue_files) record the
# timeout supervisor as the child; its own TERM handling also terminates its
# command, so the TERM still stops the real operation. The probe wrapper
# deliberately keeps its QUIT pipeline (see probe_relay_tcp), so there the
# TERM lands on the wrapper shell and the timeout-bounded pipeline children
# exit on their own deadline.
# ---------------------------------------------------------------------------
STARTUP_CHILD_PID=''

# run_interruptible CMD [ARGS...] — run a potentially blocking startup
# operation as a background child, record its PID for the signal handlers,
# and wait for it, preserving its exit status for the caller.
run_interruptible() {
  "$@" &
  STARTUP_CHILD_PID=$!
  _ri_status=0
  wait "$STARTUP_CHILD_PID" || _ri_status=$?
  STARTUP_CHILD_PID=''
  return "$_ri_status"
}

# terminate_startup_child — called from the terminating-signal handlers to
# TERM and reap the recorded background child so the container exits without
# leaving an orphan. BusyBox kill needs the numeric signal form (-15).
terminate_startup_child() {
  if [ -n "$STARTUP_CHILD_PID" ]; then
    kill -15 "$STARTUP_CHILD_PID" 2>/dev/null || true
    wait "$STARTUP_CHILD_PID" 2>/dev/null || true
    STARTUP_CHILD_PID=''
  fi
}

# Elapsed-time budget for the finite external startup operations (postmap,
# newaliases, postfix check, postfix set-permissions). run_interruptible
# makes signal delivery prompt but has no deadline of its own; without one, a
# wedged or persistently slow spool/config filesystem would hold PID 1 in
# startup forever and the container would never reach Postfix. 30s is
# generous for a healthy system while keeping startup bounded on a
# pathological one; timeout KILLs 5s after its TERM if the command ignores it.
readonly STARTUP_CMD_TIMEOUT=30

# run_bounded CMD [ARGS...] — run a finite external startup operation through
# run_interruptible under the elapsed-time budget above. The recorded startup
# child is the timeout supervisor, whose own TERM handling also terminates
# its command, so terminate_startup_child still stops the real operation.
# The exit status is preserved for the caller; BusyBox timeout reports an
# elapsed budget as 143 (TERM) or 137 (KILL after the -k grace).
run_bounded() {
  run_interruptible timeout -k 5 "$STARTUP_CMD_TIMEOUT" "$@"
}

# timeout_log_fields STATUS — emit the structured timeout log fields when
# STATUS indicates the elapsed budget; empty otherwise. BusyBox timeout (the
# only timeout in the runtime image) exits 143 (128+TERM) on expiry, or 137
# (128+KILL) when the command ignored the TERM and the -k grace elapsed;
# coreutils' 124 is accepted too for portability. Lets a caller's failure
# log distinguish a timed-out operation from a plain failure without
# duplicating the fields at every call site.
timeout_log_fields() {
  case "$1" in
    124 | 137 | 143) printf ' reason=timeout timeout_seconds=%d' "$STARTUP_CMD_TIMEOUT" ;;
  esac
}

# ---------------------------------------------------------------------------
# write_sasl_secret — write the plaintext sasl_passwd, hash it with postmap,
# then remove the plaintext. Run-mode only (writes a secret to disk).
# ---------------------------------------------------------------------------
cleanup_sasl_plaintext() { rm -f "$SASL_PASSWD_FILE"; }

# postmap_restricted — postmap under a restrictive umask so the newly created
# map file is 0600. Runs as a run_interruptible background child, which is a
# subshell, so the umask never leaks into the main shell. exec replaces the
# wrapper with the timeout supervisor bounding postmap (run_bounded's budget;
# the umask must be set in this subshell, so the timeout cannot come from
# run_bounded itself), so the recorded PID names the supervisor, whose TERM
# handling also terminates postmap itself.
postmap_restricted() {
  umask 077
  exec timeout -k 5 "$STARTUP_CMD_TIMEOUT" postmap "$1"
}

# On a terminating signal (e.g. Docker sending SIGTERM during a stop), remove
# the plaintext secret, disarm the traps, and exit non-zero. A plain
# cleanup-only handler would return control to the run path and let the script
# resume into Postfix startup after the signal, so PID 1 would ignore the stop
# request until Docker escalated to SIGKILL. Exiting here honors shutdown.
abort_sasl_secret() {
  # Disarm first, matching startup_abort: a second signal arriving while the
  # handler runs must not re-enter it mid-cleanup.
  trap - EXIT INT TERM HUP QUIT
  terminate_startup_child
  cleanup_sasl_plaintext
  printf 'level=info msg="received termination signal during SASL setup; cleaned up and aborting startup"\n' >&2
  exit 1
}

write_sasl_secret() {
  sasl_enabled || return 0

  # EXIT does best-effort plaintext removal even if postmap fails under
  # `set -e` before the explicit rm below runs. A terminating signal both
  # cleans up AND aborts (abort_sasl_secret exits non-zero) so a stop request
  # mid-write is not swallowed.
  trap cleanup_sasl_plaintext EXIT
  trap abort_sasl_secret INT TERM HUP QUIT

  # Write credentials with restrictive permissions from the start (umask 077
  # in subshell avoids a brief world-readable window before chmod). Remove any
  # pre-existing plaintext first: redirection to an existing file truncates
  # but preserves its mode, so only the create path honors the umask — same
  # guard the hashed map gets before postmap below.
  rm -f "$SASL_PASSWD_FILE"
  if ! (umask 077 && printf '%s %s:%s\n' "$RELAYHOST_VALUE" "$RELAY_LOGIN" "$RELAY_PASSWORD" \
    >"$SASL_PASSWD_FILE"); then
    printf 'level=error msg="failed to write SASL credentials file" path="%s"\n' "$(sanitize_token "$SASL_PASSWD_FILE")" >&2
    exit 1
  fi
  # postmap inherits the process umask, not the source file mode; run it
  # inside a restrictive umask so a newly created .db file is 0600. But
  # postmap rewrites a PRE-EXISTING map in place and preserves its current
  # mode, so a leftover permissive sasl_passwd.db/.lmdb (e.g. 0644 from a
  # prior image build) would keep exposing the credentials -- 'hash:' names
  # the table format, not a digest; the map stores login and password
  # verbatim. Remove any pre-existing map first so the umask controls the
  # recreated file.
  rm -f "${SASL_PASSWD_FILE}.db" "${SASL_PASSWD_FILE}.lmdb"
  _postmap_status=0
  run_interruptible postmap_restricted "$SASL_PASSWD_FILE" || _postmap_status=$?
  if [ "$_postmap_status" -ne 0 ]; then
    printf 'level=error msg="postmap failed"%s\n' "$(timeout_log_fields "$_postmap_status")" >&2
    exit 1
  fi
  # Belt-and-suspenders: tighten the regenerated map to 0600 regardless of
  # the database suffix Postfix chose (ignore a missing suffix).
  chmod 600 "${SASL_PASSWD_FILE}.db" "${SASL_PASSWD_FILE}.lmdb" 2>/dev/null || true
  # Remove plaintext credentials; Postfix only reads the .db file.
  cleanup_sasl_plaintext
  # Drop only the EXIT cleanup trap and re-arm the startup handler: clearing
  # all traps here would leave the rest of startup (postfix checks, upstream
  # probe) without signal handling as PID 1.
  trap - EXIT
  trap startup_abort INT TERM HUP QUIT

  printf 'level=info msg="SASL authentication configured"\n' >&2
}

# ---------------------------------------------------------------------------
# run_postfix_checks — alias DB, config check, and permission fixup.
# ---------------------------------------------------------------------------
run_postfix_checks() {
  _rpc_status=0
  run_bounded newaliases || _rpc_status=$?
  if [ "$_rpc_status" -ne 0 ]; then
    printf 'level=warn msg="newaliases failed; continuing without alias database"%s\n' \
      "$(timeout_log_fields "$_rpc_status")" >&2
  fi
  _rpc_status=0
  run_bounded postfix check || _rpc_status=$?
  if [ "$_rpc_status" -ne 0 ]; then
    printf 'level=error msg="postfix config check failed"%s\n' \
      "$(timeout_log_fields "$_rpc_status")" >&2
    exit 1
  fi
  _rpc_status=0
  run_bounded postfix set-permissions || _rpc_status=$?
  if [ "$_rpc_status" -ne 0 ]; then
    printf 'level=error msg="postfix set-permissions failed; refusing to start"%s\n' \
      "$(timeout_log_fields "$_rpc_status")" >&2
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
# probe_relay_tcp HOST PORT — the bounded TCP connect pipeline, wrapped so
# run_interruptible can background it as a single child. The outer timeout
# gets a small margin over nc's own -w idle timeout so that for an
# implicit-TLS upstream (465, no plaintext greeting) nc's own idle-close
# (success) wins the race instead of being SIGTERM-killed (a spurious
# "unreachable" warn). Total stays bounded under the 15s healthcheck
# start-period (max 10 + 2 = 12s; a TERM-ignoring nc is KILLed 2s
# later, still under 15s).
probe_relay_tcp() {
  # STARTUP_PROBE_TIMEOUT is range-validated (1-10) but the validation does
  # not canonicalize the representation: a leading-zero value (08, 09) is
  # read as octal by POSIX shell arithmetic and errors out, which would make
  # the fail-soft wrapper report a false "unreachable". Strip leading zeroes
  # before the value enters $((...)). The validated range makes an all-zero
  # value impossible; the :-0 fallback is purely defensive.
  _probe_timeout=$STARTUP_PROBE_TIMEOUT
  while [ "${_probe_timeout#0}" != "$_probe_timeout" ]; do
    _probe_timeout=${_probe_timeout#0}
  done
  _probe_timeout=${_probe_timeout:-0}
  printf 'QUIT\r\n' | timeout -k 2 "$((_probe_timeout + 2))" nc -w "$_probe_timeout" "$1" "$2" >/dev/null 2>&1
}

probe_upstream() {
  [ "$STARTUP_PROBE" = "true" ] || return 0

  # nc needs the bare host; strip the IPv6/skip-MX brackets the relay host
  # may carry.
  _probe_host="${RELAY_HOST#\[}"
  _probe_host="${_probe_host%\]}"

  # Never let the host land in nc's argv as an option: a dash-leading value
  # passes the metacharacter checks but would be parsed as an nc flag. The
  # probe is fail-soft by contract, so skip-with-warn instead of rejecting.
  case "$_probe_host" in
    -*)
      printf 'level=warn msg="startup probe skipped: relay host looks like an option" relay="%s"\n' \
        "$(sanitize_token "$RELAYHOST_VALUE")" >&2
      return 0
      ;;
  esac

  if run_interruptible probe_relay_tcp "$_probe_host" "$RELAY_PORT"; then
    printf 'level=info msg="upstream relay reachable" relay="%s"\n' "$(sanitize_token "$RELAYHOST_VALUE")" >&2
  else
    printf 'level=warn msg="upstream relay unreachable at startup; continuing (mail will queue)" relay="%s"\n' \
      "$(sanitize_token "$RELAYHOST_VALUE")" >&2
  fi
}

# ---------------------------------------------------------------------------
# count_queue — bounded, error-checked count of files in one spool queue
# directory. The old inline pipeline suppressed find errors and took the
# pipeline status from wc, so an unreadable, corrupt, or disappearing spool
# was reported as an authoritative 0 with no warning, and an unbounded find
# over a pathological volume could hold startup indefinitely. Run the find
# under a short timeout via run_interruptible (a docker stop mid-scan is
# honored), check the scan status before counting, and report availability
# instead of presenting a failed scan as a real zero.
# Usage: count_queue NAME DIR — sets _queue_count and _queue_ok (true|false);
# emits level=warn when the scan fails.
# ---------------------------------------------------------------------------
# scan_queue_files DIR OUTFILE — the bounded find, wrapped so
# run_interruptible can background it as a single child. 5s is generous for
# a healthy spool while keeping startup bounded on a pathological one. exec
# replaces the wrapper so the recorded PID names the timeout-supervised find
# (terminate_startup_child TERMs the operation, not an intermediate shell).
scan_queue_files() {
  exec timeout -k 5 5 find "$1" -type f >"$2" 2>/dev/null
}

count_queue() {
  _cq_name=$1
  _cq_dir=$2
  _queue_count=0
  _queue_ok=true
  # An absent directory is a fresh spool with nothing queued (the volume may
  # not carry the full layout yet), not a scan failure. An if (not a bare
  # AND-list) so the absent-dir path completes with status 0 instead of
  # tripping set -e in the caller.
  if [ -d "$_cq_dir" ]; then
    _cq_tmp=''
    # Every step of the telemetry pipeline stays fail-soft: a mktemp failure
    # (e.g. full /tmp), a failed or timed-out scan, and a failed wc read (an
    # I/O error or a disappearing temp file) all report the depth as
    # unavailable instead of aborting PID 1 under set -e before Postfix
    # starts. The && chain short-circuits exactly like the old nested ifs:
    # a failed step skips the rest, and any failure lands in the one warn.
    if ! { _cq_tmp=$(mktemp) && run_interruptible scan_queue_files "$_cq_dir" "$_cq_tmp" \
      && _queue_count=$(wc -l <"$_cq_tmp"); }; then
      _queue_count=0
      _queue_ok=false
      printf 'level=warn msg="queue depth unavailable" queue=%s\n' "$_cq_name" >&2
    fi
    if [ -n "$_cq_tmp" ]; then
      # Cleanup failure is warn-and-continue: the telemetry path is optional
      # and a stray temp file must never abort startup under set -e.
      if ! rm -f "$_cq_tmp"; then
        printf 'level=warn msg="queue temp cleanup failed" queue=%s\n' "$_cq_name" >&2
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# log_startup — record persisted queue depth at startup. Helps correlate
# restart events with pre-existing backlogs in Loki/Grafana alerts (the spool
# is volume-mounted, so a restart during an upstream outage resumes with
# deferred mail). Raw find counts are more parseable than postqueue's summary
# string for Grafana stats() queries. queue_scan_ok=false marks the counts as
# non-authoritative when either scan failed (details in the paired warn).
# ---------------------------------------------------------------------------
log_startup() {
  count_queue active /var/spool/postfix/active
  _queue_active=$_queue_count
  _queue_scan_ok=$_queue_ok
  count_queue deferred /var/spool/postfix/deferred
  _queue_deferred=$_queue_count
  [ "$_queue_ok" = true ] || _queue_scan_ok=false
  printf 'level=info msg="starting smtp-relay" relay="%s" tls=%s networks="%s" queue_active=%d queue_deferred=%d queue_scan_ok=%s\n' \
    "$(sanitize_token "$RELAYHOST_VALUE")" "$SMTP_TLS_SECURITY_LEVEL" "$(sanitize_token "$ACCEPTED_NETWORKS")" \
    "$_queue_active" "$_queue_deferred" "$_queue_scan_ok" >&2
}

# ---------------------------------------------------------------------------
# startup_abort — terminating-signal handler for the whole pre-exec startup
# path. As PID 1 the shell ignores SIGTERM/SIGINT with default disposition,
# so without an explicit handler a `docker stop` during startup (notably
# probe_upstream, which blocks up to STARTUP_PROBE_TIMEOUT+2 seconds, or
# postfix set-permissions over a large spool) is silently ignored until
# Docker escalates to SIGKILL. Blocking startup ops run via run_interruptible
# so the shell is in an interruptible `wait` when the signal lands; TERM and
# reap the recorded child, then exit non-zero so the stop is honored.
# ---------------------------------------------------------------------------
startup_abort() {
  trap - INT TERM HUP QUIT
  terminate_startup_child
  printf 'level=info msg="received termination signal during startup; aborting"\n' >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "$MODE" in
  render)
    render_config
    printf 'level=info msg="config rendered" conf_dir="%s"\n' "$(sanitize_token "$CONF_DIR")" >&2
    ;;
  run)
    trap startup_abort INT TERM HUP QUIT
    render_config
    # CONF_DIR scopes only where the generated files are written; the Postfix
    # commands below (newaliases, check, set-permissions, start-fg) read the
    # compiled-in /etc/postfix. An overridden CONF_DIR in run mode therefore
    # boots Postfix on the stock unrendered config while startup logs claim
    # the validated values are live. Warn loudly; the override is a test-
    # harness knob (see the Constants comment), not a supported run-mode path.
    if [ "$CONF_DIR" != /etc/postfix ]; then
      printf 'level=warn msg="CONF_DIR overridden in run mode; Postfix reads /etc/postfix and will NOT use the rendered config" conf_dir="%s"\n' \
        "$(sanitize_token "$CONF_DIR")" >&2
    fi
    write_sasl_secret
    # Credentials are persisted in the 0600 hashed map; drop the env copies so
    # they do not linger in /proc/1/environ for the container's lifetime.
    unset RELAY_PASSWORD RELAY_LOGIN
    run_postfix_checks
    probe_upstream
    log_startup
    # The startup trap deliberately stays armed through exec: clearing it
    # here would open a TERM-loss window between the reset and exec, and
    # exec itself resets caught signal dispositions to default for Postfix.
    exec postfix start-fg
    ;;
  *)
    # MODE is a raw CLI argument that bypasses env validation (it may even
    # contain a newline); flag the rejection without interpolating it.
    printf 'level=error msg="unknown mode" mode_invalid=true valid="run render"\n' >&2
    exit 2
    ;;
esac
