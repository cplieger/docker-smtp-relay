#!/bin/sh
# -f: ACCEPTED_NETWORKS and RECIPIENT_RESTRICTIONS are iterated by word-splitting
# an unquoted expansion, so glob metacharacters must not expand against the CWD.
set -euf

MODE="${1:-run}"

: "${CONF_DIR:=/etc/postfix}"
readonly CONF_DIR
readonly SASL_PASSWD_FILE="${CONF_DIR}/sasl_passwd"
readonly MAIN_CF="${CONF_DIR}/main.cf"

# Exit codes: 2 = config-validation failure, 1 = runtime failure.

# shellcheck source-path=SCRIPTDIR source=validate.sh
. "$(dirname "$0")/validate.sh"
# shellcheck source-path=SCRIPTDIR source=recipient-filter.sh
. "$(dirname "$0")/recipient-filter.sh"

apply_defaults() {
  # Unset gets the RFC1918 default; explicitly empty is left for validate_config
  # to reject, so an empty value cannot silently broaden relay acceptance.
  if [ "${ACCEPTED_NETWORKS+x}" != x ]; then
    ACCEPTED_NETWORKS="192.168.0.0/16 172.16.0.0/12 10.0.0.0/8"
  fi
  : "${RELAY_HOST:=}"
  : "${RELAY_PORT:=587}"
  : "${RELAY_LOGIN:=}"
  : "${RELAY_PASSWORD:=}"
  : "${RECIPIENT_RESTRICTIONS:=}"
  # Default to `secure` (chain + hostname verification) so a deploy without
  # the compose override does not silently fall back to cert-blind TLS.
  : "${SMTP_TLS_SECURITY_LEVEL:=secure}"
  : "${SMTP_TLS_FINGERPRINT_CERT_MATCH:=}"
  # Tracked separately because the sha256 default must not trip the
  # fingerprint-family both-or-neither check, while an operator-set digest at a
  # non-fingerprint level must. Blank counts as unset: never a valid digest.
  if [ -n "${SMTP_TLS_FINGERPRINT_DIGEST:-}" ]; then
    FINGERPRINT_DIGEST_EXPLICIT=true
  else
    FINGERPRINT_DIGEST_EXPLICIT=false
    SMTP_TLS_FINGERPRINT_DIGEST=sha256
  fi
  : "${SMTPD_TLS_CERT_FILE:=}"
  : "${SMTPD_TLS_KEY_FILE:=}"
  : "${SMTPD_TLS_SECURITY_LEVEL:=}"
  : "${MESSAGE_SIZE_LIMIT:=10240000}"
  # FQDN-shaped to avoid Postfix's `numeric hostname` warning. Rendered as
  # myhostname; the container hostname is never read.
  : "${SMTP_HOSTNAME:=smtp-relay.local}"
  : "${STARTUP_PROBE:=true}"
  : "${STARTUP_PROBE_TIMEOUT:=5}"
}

# Exit-2 precedence is load-bearing across these helpers: the RELAY_HOST
# required check must fire before the SASL both-or-neither check, and the
# cleartext-TLS guard after the ACCEPTED_NETWORKS checks.

# validate_field_check VAR VALUE CHECK — one spec-table check. An unknown token
# is a spec-table typo: fail loudly rather than skip the field's validation.
validate_field_check() {
  case "$3" in
    nl) validate_no_newlines "$1" "$2" ;;
    num) validate_numeric "$1" "$2" ;;
    meta) validate_no_metacharacters "$1" "$2" ;;
    range=*)
      _vfc_range="${3#range=}"
      validate_range "$1" "$2" "${_vfc_range%%:*}" "${_vfc_range#*:}"
      ;;
    rcptrules) validate_recipient_rule_count "$1" "$2" ;;
    rcptbytes) validate_recipient_byte_length "$1" "$2" ;;
    *)
      printf 'level=error msg="unknown validation check" var=%s check=%s\n' "$1" "$3" >&2
      return 1
      ;;
  esac
}

# Format: VAR_NAME:check[,check...]
# Checks: nl=no_newlines, num=numeric, meta=no_metacharacters, range=MIN:MAX,
# rcptrules/rcptbytes=the RECIPIENT_RESTRICTIONS size bounds (see validate.sh)
validate_declared_fields() {
  _spec_table="
CONF_DIR:nl,meta
RELAY_HOST:nl,meta
RELAY_PORT:nl,num,range=1:65535
RELAY_LOGIN:nl
RELAY_PASSWORD:nl
ACCEPTED_NETWORKS:nl
RECIPIENT_RESTRICTIONS:nl,rcptrules,rcptbytes
SMTP_TLS_SECURITY_LEVEL:nl
SMTP_TLS_FINGERPRINT_CERT_MATCH:nl
SMTP_TLS_FINGERPRINT_DIGEST:nl
SMTPD_TLS_CERT_FILE:nl,meta
SMTPD_TLS_KEY_FILE:nl,meta
SMTPD_TLS_SECURITY_LEVEL:nl
MESSAGE_SIZE_LIMIT:nl,num,range=1:104857600
SMTP_HOSTNAME:nl,meta
STARTUP_PROBE:nl
STARTUP_PROBE_TIMEOUT:nl,num,range=1:10
"
  for _spec in $_spec_table; do
    _var="${_spec%%:*}"
    _checks="${_spec#*:}"
    # apply_defaults sets every var in the table, so an unset name is a
    # spec-table typo. `${var+x}` is unset-safe under `set -u`.
    if ! eval "[ \"\${${_var}+x}\" = x ]"; then
      printf 'level=error msg="unknown validation var" var=%s\n' "$_var" >&2
      exit 2
    fi
    # eval is confined to this bare parameter expansion; $_value then runs the
    # same checks as every other value, so nothing unsanitized reaches a command.
    _value=''
    eval "_value=\${$_var}"
    _oldIFS=$IFS
    IFS=,
    # The for-list is split ONCE with IFS=, so restoring IFS inside the body is
    # load-bearing: rcptrules/rcptbytes re-split their value with `set -- $2` and
    # need the default IFS, or the 256-rule cap never fires.
    for _chk in $_checks; do
      IFS=$_oldIFS
      validate_field_check "$_var" "$_value" "$_chk" || exit 2
    done
    IFS=$_oldIFS
  done

  validate_sasl_login "$RELAY_LOGIN" || exit 2
  validate_sasl_password "$RELAY_PASSWORD" || exit 2
  validate_tls_level "$SMTP_TLS_SECURITY_LEVEL" || exit 2

  # Kept here, before the SASL pairing check, so exit-2 precedence is unchanged.
  if [ -z "$RELAY_HOST" ]; then
    printf 'level=error msg="RELAY_HOST must be set"\n' >&2
    exit 2
  fi
  validate_relay_host_shape "$RELAY_HOST" || exit 2
}

validate_sasl_config() {
  if [ -z "$RELAY_LOGIN" ] && [ -z "$RELAY_PASSWORD" ]; then
    printf 'level=info msg="SASL auth disabled; RELAY_LOGIN/RELAY_PASSWORD not set"\n' >&2
  elif [ -z "$RELAY_LOGIN" ] || [ -z "$RELAY_PASSWORD" ]; then
    printf 'level=error msg="both RELAY_LOGIN and RELAY_PASSWORD must be set for SASL auth"\n' >&2
    exit 2
  fi
}

# level=fingerprint without a cert match can never verify a peer (every delivery
# defers); a cert match or explicit digest at any other level is silently
# ignored by Postfix. Both are rejected at boot.
validate_fingerprint_config() {
  if [ "$SMTP_TLS_SECURITY_LEVEL" = fingerprint ]; then
    # Whitespace-only bypasses -z but word-splits to zero tokens, rendering an
    # empty smtp_tls_fingerprint_cert_match that no peer can satisfy.
    case "$SMTP_TLS_FINGERPRINT_CERT_MATCH" in
      '')
        printf 'level=error msg="SMTP_TLS_SECURITY_LEVEL=fingerprint requires SMTP_TLS_FINGERPRINT_CERT_MATCH; without a match no peer can ever verify and every delivery defers"\n' >&2
        exit 2
        ;;
      *[![:space:]]*) ;;
      *)
        printf 'level=error msg="SMTP_TLS_FINGERPRINT_CERT_MATCH is non-empty but contains no tokens (whitespace only?); without a match no peer can ever verify and every delivery defers"\n' >&2
        exit 2
        ;;
    esac
    validate_fingerprint_digest "$SMTP_TLS_FINGERPRINT_DIGEST" || exit 2
    validate_fingerprint_match "$SMTP_TLS_FINGERPRINT_CERT_MATCH" "$SMTP_TLS_FINGERPRINT_DIGEST" || exit 2
  else
    if [ -n "$SMTP_TLS_FINGERPRINT_CERT_MATCH" ]; then
      printf 'level=error msg="SMTP_TLS_FINGERPRINT_CERT_MATCH is set but SMTP_TLS_SECURITY_LEVEL is not fingerprint; refusing to silently ignore a configured trust anchor" tls_level=%s\n' \
        "$SMTP_TLS_SECURITY_LEVEL" >&2
      exit 2
    fi
    if [ "$FINGERPRINT_DIGEST_EXPLICIT" = true ]; then
      printf 'level=error msg="SMTP_TLS_FINGERPRINT_DIGEST is set but SMTP_TLS_SECURITY_LEVEL is not fingerprint; the digest only applies to the fingerprint level" tls_level=%s\n' \
        "$SMTP_TLS_SECURITY_LEVEL" >&2
      exit 2
    fi
  fi
}

# Half a cert/key pair can never negotiate STARTTLS, and a level without the
# pair renders no smtpd_tls_* lines at all. The level is allowlisted to
# may|encrypt; cleartext is expressed by leaving the pair unset. The
# filesystem contract is run-mode-only, in validate_smtpd_tls_files.
validate_smtpd_tls_config() {
  if [ -z "$SMTPD_TLS_CERT_FILE" ] && [ -z "$SMTPD_TLS_KEY_FILE" ]; then
    if [ -n "$SMTPD_TLS_SECURITY_LEVEL" ]; then
      printf 'level=error msg="SMTPD_TLS_SECURITY_LEVEL is set but SMTPD_TLS_CERT_FILE/SMTPD_TLS_KEY_FILE are not; without the cert/key pair no inbound TLS is rendered, and a trust config that silently does nothing is a misconfiguration"\n' >&2
      exit 2
    fi
    return 0
  fi
  if [ -z "$SMTPD_TLS_CERT_FILE" ] || [ -z "$SMTPD_TLS_KEY_FILE" ]; then
    printf 'level=error msg="both SMTPD_TLS_CERT_FILE and SMTPD_TLS_KEY_FILE must be set for inbound TLS"\n' >&2
    exit 2
  fi
  # The empty value takes the may default in compute_smtpd_tls_lines.
  case "${SMTPD_TLS_SECURITY_LEVEL:-may}" in
    may | encrypt) ;;
    *)
      printf 'level=error msg="invalid inbound TLS security level (cleartext is expressed by leaving the cert/key pair unset, not by a level value)" var=SMTPD_TLS_SECURITY_LEVEL valid="may encrypt"\n' >&2
      exit 2
      ;;
  esac
}

validate_relay_acceptance() {
  # Whitespace-only parses to zero entries: the loop below succeeds and
  # mynetworks renders loopback only, silently excluding every intended LAN.
  # An UNSET value never reaches here (apply_defaults gives it the default).
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

  if sasl_enabled && tls_level_cleartext; then
    printf 'level=error msg="TLS must be encrypt or stronger when SASL credentials are set" tls_level=%s\n' \
      "$SMTP_TLS_SECURITY_LEVEL" >&2
    exit 2
  fi
  # encrypt never authenticates the peer, and dane degrades to unauthenticated
  # opportunistic TLS without usable TLSA records (the normal case for hosted
  # providers), so an on-path attacker can harvest credentials. Warn only:
  # noplaintext already blocks credentials on a fully cleartext channel.
  if sasl_enabled; then
    case "$SMTP_TLS_SECURITY_LEVEL" in
      encrypt | dane)
        printf 'level=warn msg="TLS level does not guarantee upstream peer authentication; SASL credentials are exposed to an on-path TLS interceptor (prefer secure or verify)" tls_level=%s\n' \
          "$SMTP_TLS_SECURITY_LEVEL" >&2
        ;;
    esac
  fi

  # RELAY_PORT=465 is implicit TLS (compute_tls_wrappermode sets
  # smtp_tls_wrappermode), so a non-mandatory level could never deliver mail.
  if [ "$RELAY_PORT" -eq 465 ] && tls_level_wrapper_incompatible; then
    printf 'level=error msg="RELAY_PORT=465 is implicit TLS; SMTP_TLS_SECURITY_LEVEL must be mandatory (encrypt or stronger; dane is opportunistic and degrades to may without TLSA records)" tls_level=%s\n' \
      "$SMTP_TLS_SECURITY_LEVEL" >&2
    exit 2
  fi
}

# Run mode only: render mode must stay side-effect-free and runnable without
# the operator's mounted files.
validate_smtpd_tls_files() {
  if [ "$MODE" != run ] || [ -z "$SMTPD_TLS_CERT_FILE" ]; then
    return 0
  fi
  for _tls_file in "$SMTPD_TLS_CERT_FILE" "$SMTPD_TLS_KEY_FILE"; do
    if [ ! -f "$_tls_file" ] || [ ! -r "$_tls_file" ]; then
      printf 'level=error msg="inbound TLS cert/key must be an existing readable file (is the volume mounted?)" path="%s"\n' "$(sanitize_token "$_tls_file")" >&2
      exit 2
    fi
  done
  # Warn-only: a swapped pair passes the readable-file loop above and then fails
  # every handshake with maillog-only errors while the TCP-220 healthcheck stays
  # green. A combined cert+key PEM carries both markers and passes both greps.
  if ! grep -q 'BEGIN CERTIFICATE' -- "$SMTPD_TLS_CERT_FILE" 2>/dev/null; then
    printf 'level=warn msg="inbound TLS cert file does not contain a PEM CERTIFICATE block (cert and key swapped, or not PEM?)" path="%s"\n' \
      "$(sanitize_token "$SMTPD_TLS_CERT_FILE")" >&2
  fi
  if ! grep -q 'PRIVATE KEY' -- "$SMTPD_TLS_KEY_FILE" 2>/dev/null; then
    printf 'level=warn msg="inbound TLS key file does not contain a PEM PRIVATE KEY block (cert and key swapped, or not PEM?)" path="%s"\n' \
      "$(sanitize_token "$SMTPD_TLS_KEY_FILE")" >&2
  fi
  # A group- or world-readable key stays a warning: the operator may have
  # deliberate group-read semantics (e.g. a cert-renewal sidecar's group).
  if ! _key_mode=$(stat -c %a -- "$SMTPD_TLS_KEY_FILE" 2>/dev/null); then
    _key_mode=''
    printf 'level=warn msg="could not read inbound TLS key file mode; the group/world-readable check was skipped" path="%s"\n' \
      "$(sanitize_token "$SMTPD_TLS_KEY_FILE")" >&2
  fi
  case "$_key_mode" in
    *[4-7]? | *[4-7])
      printf 'level=warn msg="inbound TLS key file is group- or world-readable" path="%s" mode=%s\n' \
        "$(sanitize_token "$SMTPD_TLS_KEY_FILE")" "$_key_mode" >&2
      ;;
  esac
}

validate_runtime_config() {
  case "$STARTUP_PROBE" in
    true | false) ;;
    *)
      printf 'level=error msg="STARTUP_PROBE must be true or false" var=STARTUP_PROBE valid="true false"\n' >&2
      exit 2
      ;;
  esac

  # Caught here with a structured error rather than as a raw shell diagnostic
  # from a later redirection failing under set -e.
  if [ ! -d "$CONF_DIR" ] || [ ! -w "$CONF_DIR" ]; then
    printf 'level=error msg="CONF_DIR must be an existing writable directory" conf_dir="%s"\n' "$(sanitize_token "$CONF_DIR")" >&2
    exit 2
  fi

  validate_smtpd_tls_files
}

validate_config() {
  validate_declared_fields
  validate_sasl_config
  validate_fingerprint_config
  validate_smtpd_tls_config
  validate_relay_acceptance
  validate_runtime_config

  printf 'level=info msg="input validation passed"\n' >&2
}

# Bracketing the relay host skips MX lookups and makes IPv6 unambiguous.
compute_relayhost() {
  case "$RELAY_HOST" in
    \[*) RELAYHOST_BRACKETED="$RELAY_HOST" ;;
    *) RELAYHOST_BRACKETED="[$RELAY_HOST]" ;;
  esac
  RELAYHOST_VALUE="${RELAYHOST_BRACKETED}:${RELAY_PORT}"
}

# Port 465 is implicit TLS (RFC 8314): Postfix must open with a TLS handshake
# instead of plaintext SMTP/STARTTLS, or the upstream never answers and every
# message defers while the inbound healthcheck stays green.
compute_tls_wrappermode() {
  if [ "$RELAY_PORT" -eq 465 ]; then
    SMTP_TLS_WRAPPERMODE="yes"
  else
    SMTP_TLS_WRAPPERMODE="no"
  fi
}

# Extra main.cf lines the selected TLS level needs. An empty value renders
# nothing, so every other level stays byte-identical.
#   dane/dane-only: DANE takes policy from DNSSEC-validated TLSA records, which
#     requires smtp_dns_support_level = dnssec (postconf(5): DANE is disabled at
#     the default level). Fallback is Postfix-native per RFC 7672, not
#     reimplemented here.
#   fingerprint: render the cert match and digest explicitly, even at the
#     sha256 default, so the effective trust anchor is auditable in main.cf.
compute_tls_policy_lines() {
  TLS_POLICY_LINES=''
  case "$SMTP_TLS_SECURITY_LEVEL" in
    dane | dane-only)
      TLS_POLICY_LINES="
smtp_dns_support_level = dnssec"
      ;;
    fingerprint)
      TLS_POLICY_LINES="
smtp_tls_fingerprint_cert_match = ${SMTP_TLS_FINGERPRINT_CERT_MATCH}
smtp_tls_fingerprint_digest = ${SMTP_TLS_FINGERPRINT_DIGEST}"
      ;;
  esac
}

# Opt-in: rendered only when the operator mounts a cert/key pair, so every
# certless render stays byte-identical and port 25 keeps speaking cleartext.
# SMTPD_TLS_LEVEL_VALUE carries the effective level (off when unset) for the log.
compute_smtpd_tls_lines() {
  # validate_smtpd_tls_config enforced both-or-neither, so testing the cert
  # alone is testing the pair.
  if [ -n "$SMTPD_TLS_CERT_FILE" ]; then
    SMTPD_TLS_LEVEL_VALUE="${SMTPD_TLS_SECURITY_LEVEL:-may}"
    SMTPD_TLS_LINES="

smtpd_tls_security_level = ${SMTPD_TLS_LEVEL_VALUE}
smtpd_tls_cert_file = ${SMTPD_TLS_CERT_FILE}
smtpd_tls_key_file = ${SMTPD_TLS_KEY_FILE}
smtpd_tls_protocols = >=TLSv1.2
smtpd_tls_mandatory_protocols = >=TLSv1.2
smtpd_tls_ciphers = high
smtpd_tls_mandatory_ciphers = high"
  else
    SMTPD_TLS_LEVEL_VALUE="off"
    SMTPD_TLS_LINES=''
  fi
}

# Postfix requires IPv6 entries in mynetworks bracketed ([fd00::]/8, per
# postconf(5)); an unbracketed IPv6 CIDR draws a "bad net/mask pattern" warning
# and never matches, silently denying the operator's IPv6 LAN. IPv4 passes
# through verbatim, so IPv4-only output is byte-identical.
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

# Single source of truth for "SASL is on", keeping the cleartext-TLS guard and
# the RELAY_AUTH_ENABLE derivation in lockstep.
sasl_enabled() {
  [ -n "$RELAY_LOGIN" ] && [ -n "$RELAY_PASSWORD" ]
}

# True when the TLS level allows a cleartext (none) or opportunistic (may)
# channel. The SASL credential-leak predicate; the port-465 gate uses the
# stricter sibling below.
tls_level_cleartext() {
  case "$SMTP_TLS_SECURITY_LEVEL" in
    none | may) return 0 ;;
  esac
  return 1
}

# True when the level cannot satisfy implicit TLS on RELAY_PORT=465. Postfix
# documents smtp_tls_wrappermode as requiring encrypt or stronger (postconf(5)).
# dane is opportunistic-family: without usable TLSA records it degrades to may.
tls_level_wrapper_incompatible() {
  case "$SMTP_TLS_SECURITY_LEVEL" in
    none | may | dane) return 0 ;;
  esac
  return 1
}

# Pure: writes no secret to disk, so it is safe in render mode. The sasl_passwd
# map itself is written by write_sasl_secret.
compute_sasl_state() {
  # SASL_MAPS_LINE is the whole main.cf line so the disabled case renders
  # `smtp_sasl_password_maps =` with no trailing space (a templated empty var
  # would leave whitespace; Postfix reads an empty value as "no map").
  # The map type must be lmdb:, not hash:. This image builds Postfix with
  # -DNO_DB and -DDEF_DB_TYPE="lmdb", so hash: asks for the one backend that is
  # compiled out. `postconf -m` still LISTS hash, so no compile-time check sees
  # it, but every lookup is fatal at runtime and every message defers with
  # dsn=4.3.0 while the TCP-220 healthcheck stays green.
  if sasl_enabled; then
    RELAY_AUTH_ENABLE="yes"
    SASL_MAPS_LINE="smtp_sasl_password_maps = lmdb:${SASL_PASSWD_FILE}"
  else
    RELAY_AUTH_ENABLE="no"
    SASL_MAPS_LINE="smtp_sasl_password_maps ="
  fi
}

# promote_rendered_file TMP DEST LABEL -- chmod the temp file to the 0644 the
# Postfix daemons need (mktemp creates 0600), then mv it into place. Shared with
# recipient-filter.sh, which resolves it at call time from the sourced shell.
promote_rendered_file() {
  if ! chmod 644 "$1" || ! mv "$1" "$2"; then
    printf 'level=error msg="failed to move rendered %s into place" path="%s"\n' "$3" "$(sanitize_token "$2")" >&2
    rm -f "$1"
    exit 1
  fi
}

# create_rendered_tmp DEST LABEL -- mktemp DEST.XXXXXX in CONF_DIR and print the
# path. Returns 1 rather than exiting: callers `|| exit 1`, because a helper in a
# command substitution runs in a subshell and cannot exit the script.
create_rendered_tmp() {
  if ! mktemp "$1.XXXXXX"; then
    printf 'level=error msg="failed to create temporary file for %s" conf_dir="%s"\n' "$2" "$(sanitize_token "$CONF_DIR")" >&2
    return 1
  fi
}

# Deliberately not inside render_main_cf's `if`: shfmt prints a heredoc left
# pending at a `then` one way before v3.14.0 and the other way after
# (mvdan/sh#1047), so that construct drifts on a shfmt bump.
emit_main_cf_body() {
  cat <<EOF
# Generated by /usr/local/bin/entrypoint.sh on container start.
# Do not edit; edits are discarded on restart.
compatibility_level = 3.6

myhostname = ${SMTP_HOSTNAME}
mydestination = localhost
# local(8) delivery is disabled (local_transport below); localhost stays in
# mydestination so an unknown localhost recipient is still rejected at RCPT
# rather than silently forwarded upstream.
local_transport = error: local mail delivery is disabled
mynetworks = ${MYNETWORKS_VALUE}
inet_interfaces = all

relayhost = ${RELAYHOST_VALUE}

smtp_sasl_auth_enable = ${RELAY_AUTH_ENABLE}
${SASL_MAPS_LINE}
smtp_sasl_security_options = noanonymous, noplaintext
smtp_sasl_tls_security_options = noanonymous
smtp_sasl_mechanism_filter = plain, login

smtp_tls_security_level = ${SMTP_TLS_SECURITY_LEVEL}${TLS_POLICY_LINES}
smtp_tls_wrappermode = ${SMTP_TLS_WRAPPERMODE}
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt
smtp_tls_session_cache_database = lmdb:\${data_directory}/smtp_scache
smtp_tls_protocols = >=TLSv1.2
smtp_tls_mandatory_protocols = >=TLSv1.2
smtp_tls_mandatory_ciphers = high
smtp_tls_ciphers = high${SMTPD_TLS_LINES}

message_size_limit = ${MESSAGE_SIZE_LIMIT}
# mailbox_size_limit must be >= message_size_limit or Postfix's default
# (51200000) makes local(8) fatal on mail to \$mydestination once
# MESSAGE_SIZE_LIMIT exceeds it (relayed mail is unaffected).
mailbox_size_limit = ${MESSAGE_SIZE_LIMIT}

smtpd_relay_restrictions = permit_mynetworks, reject
smtpd_recipient_restrictions = ${SMTPD_RECIPIENT_RESTRICTIONS}

maillog_file = /dev/stdout
EOF
}

# Renders to a mktemp file in CONF_DIR and mv's atomically, so a write failure
# (ENOSPC, EROFS) never leaves a partial main.cf for Postfix to read.
render_main_cf() {
  _main_tmp=$(create_rendered_tmp "$MAIN_CF" main.cf) || exit 1
  if ! emit_main_cf_body >"$_main_tmp"; then
    printf 'level=error msg="failed to write main.cf (disk full or read-only?)" path="%s"\n' "$(sanitize_token "$_main_tmp")" >&2
    rm -f "$_main_tmp"
    exit 1
  fi
  promote_rendered_file "$_main_tmp" "$MAIN_CF" main.cf
}

render_config() {
  apply_defaults
  validate_config
  compute_relayhost
  compute_tls_wrappermode
  compute_tls_policy_lines
  compute_smtpd_tls_lines
  compute_mynetworks
  compute_sasl_state
  # Called, not subshelled, so SMTPD_RECIPIENT_RESTRICTIONS reaches render_main_cf.
  build_recipient_filter
  render_main_cf
}

# As PID 1 under Alpine ash a trapped signal is only handled once the current
# foreground command returns, so a TERM arriving while startup blocks in postmap,
# newaliases, postfix check, the probe or a queue scan stays pending until that
# child exits — the probe alone can block 12s, past Docker's 10s stop grace,
# drawing SIGKILL before any abort line is logged. run_interruptible backgrounds
# the operation and blocks in `wait`, which IS interruptible. Bounded operations
# record the timeout supervisor as the child; its own TERM handling terminates
# its command, so the TERM still stops the real operation.
STARTUP_CHILD_PID=''

run_interruptible() {
  "$@" &
  STARTUP_CHILD_PID=$!
  _ri_status=0
  wait "$STARTUP_CHILD_PID" || _ri_status=$?
  STARTUP_CHILD_PID=''
  return "$_ri_status"
}

# TERM and reap the recorded child so the container exits without an orphan.
# BusyBox kill needs the numeric signal form (-15).
terminate_startup_child() {
  if [ -n "$STARTUP_CHILD_PID" ]; then
    kill -15 "$STARTUP_CHILD_PID" 2>/dev/null || true
    wait "$STARTUP_CHILD_PID" 2>/dev/null || true
    STARTUP_CHILD_PID=''
  fi
}

# run_interruptible makes signal delivery prompt but has no deadline of its own;
# without one a wedged spool/config filesystem holds PID 1 in startup forever.
# timeout KILLs 5s after its TERM if the command ignores it.
readonly STARTUP_CMD_TIMEOUT=30

# Separate from STARTUP_CMD_TIMEOUT because a spool walk is bounded much tighter,
# and the log must report the budget that actually applied.
readonly QUEUE_SCAN_TIMEOUT=5

# The recorded startup child is the timeout supervisor, whose own TERM handling
# terminates its command. BusyBox timeout reports an elapsed budget as 143 (TERM)
# or 137 (KILL after the -k grace).
run_bounded() {
  run_interruptible timeout -k 5 "$STARTUP_CMD_TIMEOUT" "$@"
}

# timeout_log_fields STATUS [BUDGET] — the structured timeout fields when STATUS
# indicates the elapsed budget; empty otherwise. BUDGET defaults to
# STARTUP_CMD_TIMEOUT so a caller with its own deadline reports the budget that
# applied. BusyBox timeout (the only one in the runtime image) exits 143 on
# expiry, or 137 when the command ignored the TERM and the -k grace elapsed;
# coreutils' 124 is accepted for portability.
timeout_log_fields() {
  case "$1" in
    124 | 137 | 143) printf ' reason=timeout timeout_seconds=%d' "${2:-$STARTUP_CMD_TIMEOUT}" ;;
  esac
}

cleanup_sasl_plaintext() {
  if rm -f "$SASL_PASSWD_FILE"; then
    return 0
  fi
  # Unlink failed (e.g. a directory-level restriction): truncate the 0600 file
  # so the credential bytes are gone even if the entry cannot be removed.
  : >"$SASL_PASSWD_FILE" 2>/dev/null || return 1
  chmod 600 "$SASL_PASSWD_FILE" 2>/dev/null || true
  rm -f "$SASL_PASSWD_FILE"
}

# Shared by every cleanup caller so a retained plaintext credential is always
# surfaced as a structured error instead of silently ignored.
cleanup_sasl_plaintext_or_log() {
  cleanup_sasl_plaintext && return 0
  printf 'level=error msg="failed to remove plaintext SASL credentials file; credentials may remain on disk" path="%s"\n' \
    "$(sanitize_token "$SASL_PASSWD_FILE")" >&2
  return 1
}

# postmap under a restrictive umask so a newly created map is 0600. Runs as a
# run_interruptible child, which is a subshell, so the umask never leaks into the
# main shell. exec replaces the wrapper with the timeout supervisor, so the
# recorded PID names the supervisor, whose TERM handling also stops postmap.
postmap_restricted() {
  umask 077
  exec timeout -k 5 "$STARTUP_CMD_TIMEOUT" postmap "$1"
}

# Must EXIT, not just clean up: returning control would let the script resume
# into Postfix startup after the signal, so PID 1 would ignore the stop request
# until Docker escalated to SIGKILL.
abort_sasl_secret() {
  # Disarm first, matching startup_abort: a second signal must not re-enter the
  # handler mid-cleanup.
  trap - EXIT INT TERM HUP QUIT
  terminate_startup_child
  if cleanup_sasl_plaintext_or_log; then
    printf 'level=info msg="received termination signal during SASL setup; cleaned up and aborting startup"\n' >&2
  else
    printf 'level=error msg="received termination signal during SASL setup; aborting startup with plaintext cleanup failure"\n' >&2
  fi
  exit 1
}

write_sasl_secret() {
  sasl_enabled || return 0

  # EXIT does best-effort removal even if postmap fails under `set -e` before the
  # explicit rm below. A terminating signal both cleans up AND aborts, so a stop
  # request mid-write is not swallowed.
  trap 'cleanup_sasl_plaintext_or_log || true' EXIT
  trap abort_sasl_secret INT TERM HUP QUIT

  # Remove any pre-existing plaintext first: redirection to an existing file
  # truncates but preserves its mode, so only the create path honors the umask.
  if ! rm -f "$SASL_PASSWD_FILE"; then
    printf 'level=error msg="failed to remove pre-existing SASL credentials file" path="%s"\n' "$(sanitize_token "$SASL_PASSWD_FILE")" >&2
    exit 1
  fi
  if ! (umask 077 && printf '%s %s:%s\n' "$RELAYHOST_VALUE" "$RELAY_LOGIN" "$RELAY_PASSWORD" \
    >"$SASL_PASSWD_FILE"); then
    printf 'level=error msg="failed to write SASL credentials file" path="%s"\n' "$(sanitize_token "$SASL_PASSWD_FILE")" >&2
    exit 1
  fi
  # postmap inherits the process umask, not the source file mode, but it rewrites
  # a PRE-EXISTING map in place and preserves its mode — so a leftover permissive
  # map would keep exposing credentials, which the map stores verbatim. Remove it
  # first so the umask controls the recreated file. .lmdb is what this image
  # writes; .db covers a map left by an older image.
  if ! rm -f "${SASL_PASSWD_FILE}.db" "${SASL_PASSWD_FILE}.lmdb"; then
    printf 'level=error msg="failed to remove pre-existing SASL map; refusing to let postmap reuse a possibly permissive map file" path="%s"\n' "$(sanitize_token "$SASL_PASSWD_FILE")" >&2
    exit 1
  fi
  _postmap_status=0
  run_interruptible postmap_restricted "$SASL_PASSWD_FILE" || _postmap_status=$?
  if [ "$_postmap_status" -ne 0 ]; then
    printf 'level=error msg="postmap failed"%s\n' "$(timeout_log_fields "$_postmap_status")" >&2
    exit 1
  fi
  # Tighten the regenerated map regardless of the suffix Postfix chose.
  chmod 600 "${SASL_PASSWD_FILE}.db" "${SASL_PASSWD_FILE}.lmdb" 2>/dev/null || true
  # Drop the EXIT trap before the explicit removal so a failure here is reported
  # exactly once; with it armed, exit 1 re-enters the cleanup and double-logs.
  # abort_sasl_secret stays armed, so a signal here still cleans up.
  trap - EXIT
  cleanup_sasl_plaintext_or_log || exit 1
  # Re-arm: clearing all traps would leave the rest of startup without signal
  # handling as PID 1.
  trap startup_abort INT TERM HUP QUIT

  printf 'level=info msg="SASL authentication configured"\n' >&2
}

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

# Fail-soft: a failure warns and returns 0 so mail still queues (the relay may be
# transiently down at boot). A plain TCP connect is deliberate — it catches the
# common deploy-time faults (DNS, routing, wrong port, firewall) for both
# STARTTLS and implicit TLS. It does NOT verify SASL or the TLS chain; those are
# only provable by a real send and surface via deferred-queue alerting.
# The outer timeout gets a margin over nc's own -w so that for an implicit-TLS
# upstream (465, no plaintext greeting) nc's idle-close (success) wins the race
# instead of being SIGTERM-killed into a spurious "unreachable" warn. QUIT lets a
# plaintext-greeting server close promptly. Total stays under the 15s healthcheck
# start-period (max 10 + 2 = 12s; a TERM-ignoring nc is KILLed 2s later).
probe_relay_tcp() {
  # STARTUP_PROBE_TIMEOUT is range-validated (1-10) but not canonicalized: a
  # leading-zero value (08, 09) is read as octal by shell arithmetic and errors
  # out, which would make the fail-soft wrapper report a false "unreachable".
  # validate_range's min of 1 rejects every all-zero spelling, so stripping
  # leading zeroes can never empty the value.
  _probe_timeout=$STARTUP_PROBE_TIMEOUT
  while [ "${_probe_timeout#0}" != "$_probe_timeout" ]; do
    _probe_timeout=${_probe_timeout#0}
  done
  printf 'QUIT\r\n' | timeout -k 2 "$((_probe_timeout + 2))" nc -w "$_probe_timeout" "$1" "$2" >/dev/null 2>&1
}

probe_upstream() {
  if [ "$STARTUP_PROBE" != "true" ]; then
    printf 'level=info msg="startup probe disabled" var=STARTUP_PROBE\n' >&2
    return 0
  fi

  _probe_host="${RELAY_HOST#\[}"
  _probe_host="${_probe_host%\]}"

  # Never let the host land in nc's argv as an option: a dash-leading value
  # passes the metacharacter checks but parses as a flag. Fail-soft by contract,
  # so skip-with-warn instead of rejecting.
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

# Scans through a temp file so a find failure cannot be masked by wc or reported
# as an authoritative zero. Sets _queue_count and _queue_ok.
scan_queue_files() {
  exec timeout -k 5 "$QUEUE_SCAN_TIMEOUT" find "$1" -type f >"$2" 2>/dev/null
}

count_queue() {
  _cq_name=$1
  _cq_dir=$2
  _queue_count=0
  _queue_ok=true
  # An absent directory is a fresh spool, not a scan failure. An `if` rather than
  # a bare AND-list so that path exits 0 instead of tripping set -e in the caller.
  if [ -d "$_cq_dir" ]; then
    _cq_tmp=''
    # Every step stays fail-soft — a mktemp failure, a failed or timed-out scan,
    # and a failed wc read all report the depth as unavailable rather than
    # aborting PID 1 before Postfix starts. Each records its own reason so the
    # warn names the failing step.
    _cq_reason=''
    if ! _cq_tmp=$(mktemp); then
      _cq_tmp=''
      _cq_reason=' reason=tmpfile'
    else
      _cq_scan_status=0
      run_interruptible scan_queue_files "$_cq_dir" "$_cq_tmp" || _cq_scan_status=$?
      if [ "$_cq_scan_status" -ne 0 ]; then
        _cq_reason=$(timeout_log_fields "$_cq_scan_status" "$QUEUE_SCAN_TIMEOUT")
        [ -n "$_cq_reason" ] || _cq_reason=" reason=scan_failed status=$_cq_scan_status"
      elif ! _queue_count=$(wc -l <"$_cq_tmp"); then
        _cq_reason=' reason=count_failed'
      fi
    fi
    if [ -n "$_cq_reason" ]; then
      _queue_count=0
      _queue_ok=false
      printf 'level=warn msg="queue depth unavailable" queue=%s%s\n' "$_cq_name" "$_cq_reason" >&2
    fi
    if [ -n "$_cq_tmp" ]; then
      # Warn-and-continue: a stray temp file must never abort startup under set -e.
      if ! rm -f "$_cq_tmp"; then
        printf 'level=warn msg="queue temp cleanup failed" queue=%s\n' "$_cq_name" >&2
      fi
    fi
  fi
}

# Records persisted queue depth for correlating restarts with pre-existing
# backlogs. queue_scan_ok=false marks the counts as non-authoritative.
log_startup() {
  count_queue active /var/spool/postfix/active
  _queue_active=$_queue_count
  _queue_scan_ok=$_queue_ok
  count_queue deferred /var/spool/postfix/deferred
  _queue_deferred=$_queue_count
  [ "$_queue_ok" = true ] || _queue_scan_ok=false
  printf 'level=info msg="starting smtp-relay" relay="%s" tls=%s smtpd_tls=%s networks="%s" queue_active=%d queue_deferred=%d queue_scan_ok=%s\n' \
    "$(sanitize_token "$RELAYHOST_VALUE")" "$SMTP_TLS_SECURITY_LEVEL" "$SMTPD_TLS_LEVEL_VALUE" "$(sanitize_token "$ACCEPTED_NETWORKS")" \
    "$_queue_active" "$_queue_deferred" "$_queue_scan_ok" >&2
}

# As PID 1 the shell ignores SIGTERM/SIGINT by default, so without this a docker
# stop during startup is ignored until Docker escalates to SIGKILL.
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
    # commands below read the compiled-in /etc/postfix regardless, so an
    # overridden CONF_DIR would boot Postfix on the stock unrendered config.
    if [ "$CONF_DIR" != /etc/postfix ]; then
      printf 'level=warn msg="CONF_DIR overridden in run mode; Postfix reads /etc/postfix and will NOT use the rendered config" conf_dir="%s"\n' \
        "$(sanitize_token "$CONF_DIR")" >&2
    fi
    write_sasl_secret
    # Credentials are persisted in the 0600 indexed map; drop the env copies so
    # they do not linger in /proc/1/environ. One-way door: under set -u any
    # startup step added below that reads them aborts PID 1.
    unset RELAY_PASSWORD RELAY_LOGIN
    run_postfix_checks
    probe_upstream
    log_startup
    # The startup trap stays armed through exec: clearing it here would open a
    # TERM-loss window, and exec resets signal dispositions for Postfix anyway.
    exec postfix start-fg
    ;;
  *)
    # MODE bypasses env validation and may contain a newline, so route it through
    # sanitize_token to keep the log line a single parseable record.
    printf 'level=error msg="unknown mode" mode_invalid=true mode="%s" valid="run render"\n' \
      "$(sanitize_token "$MODE")" >&2
    exit 2
    ;;
esac
