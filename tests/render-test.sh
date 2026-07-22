#!/bin/sh
# ---------------------------------------------------------------------------
# render-test.sh — golden-file tests for the entrypoint's config generation.
#
# Runs `entrypoint.sh render` (which validates env and writes main.cf +
# recipient_access to $CONF_DIR without invoking Postfix or writing secrets)
# against a matrix of env inputs, and diffs the generated files against the
# committed fixtures in tests/golden/. Failure cases assert the validation
# exit code (2). Pure POSIX sh; needs only sh, sed, diff, mktemp.
#
# Run locally from the repo root:   sh tests/render-test.sh
# Regenerate fixtures after an intended change:  sh tests/render-test.sh --record
# The Docker build runs it via the `test` stage (see Dockerfile), pointing
# ENTRYPOINT_DIR at /usr/local/bin.
# ---------------------------------------------------------------------------
set -eu

CDPATH=''
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ENTRYPOINT_DIR="${ENTRYPOINT_DIR:-$(dirname -- "$SCRIPT_DIR")}"
ENTRYPOINT="$ENTRYPOINT_DIR/entrypoint.sh"
GOLDEN_DIR="$SCRIPT_DIR/golden"

RECORD=0
[ "${1:-}" = "--record" ] && RECORD=1
[ "$RECORD" = "1" ] && mkdir -p "$GOLDEN_DIR"

pass=0
fail=0

# check_ok NAME VAR=VAL...
# Render must exit 0; generated main.cf (and recipient_access, if produced) are
# normalized (the temp CONF_DIR path -> @CONF_DIR@) and compared to the golden.
check_ok() {
  _name=$1
  shift
  _tmp=$(mktemp -d)

  if env -i PATH="$PATH" CONF_DIR="$_tmp" "$@" sh "$ENTRYPOINT" render >/dev/null 2>&1; then
    :
  else
    _rc=$?
    printf 'FAIL %s: render exited %d, expected 0\n' "$_name" "$_rc" >&2
    fail=$((fail + 1))
    rm -rf "$_tmp"
    return
  fi

  _ok=1
  sed "s#${_tmp}#@CONF_DIR@#g" "$_tmp/main.cf" >"$_tmp/main.norm"
  if [ "$RECORD" = "1" ]; then
    cp "$_tmp/main.norm" "$GOLDEN_DIR/$_name.main.cf"
  elif ! diff -u "$GOLDEN_DIR/$_name.main.cf" "$_tmp/main.norm" >&2; then
    printf 'FAIL %s: main.cf differs from golden\n' "$_name" >&2
    _ok=0
  fi

  if [ -f "$_tmp/recipient_access" ]; then
    if [ "$RECORD" = "1" ]; then
      cp "$_tmp/recipient_access" "$GOLDEN_DIR/$_name.recipient_access"
    elif ! diff -u "$GOLDEN_DIR/$_name.recipient_access" "$_tmp/recipient_access" >&2; then
      printf 'FAIL %s: recipient_access differs from golden\n' "$_name" >&2
      _ok=0
    fi
  elif [ "$RECORD" = "1" ]; then
    # Keep regeneration symmetric: a golden case that no longer produces the
    # optional recipient_access artifact must have its obsolete fixture
    # removed, or the very next normal run fails on the stale file.
    rm -f "$GOLDEN_DIR/$_name.recipient_access"
  elif [ -f "$GOLDEN_DIR/$_name.recipient_access" ]; then
    printf 'FAIL %s: golden recipient_access exists but render produced none\n' "$_name" >&2
    _ok=0
  fi

  if [ "$_ok" = "1" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
  rm -rf "$_tmp"
}

# check_fail NAME EXPECTED_CODE VAR=VAL...
# Render must exit with EXPECTED_CODE (config failures are 2).
check_fail() {
  _name=$1
  _want=$2
  shift 2
  _tmp=$(mktemp -d)

  if env -i PATH="$PATH" CONF_DIR="$_tmp" "$@" sh "$ENTRYPOINT" render >/dev/null 2>&1; then
    _rc=0
  else
    _rc=$?
  fi

  if [ "$_rc" = "$_want" ]; then
    pass=$((pass + 1))
  else
    printf 'FAIL %s: render exited %d, expected %d\n' "$_name" "$_rc" "$_want" >&2
    fail=$((fail + 1))
  fi
  rm -rf "$_tmp"
}

# --- Valid configurations -------------------------------------------------
check_ok minimal \
  RELAY_HOST=email-smtp.us-east-1.amazonaws.com

check_ok sasl \
  RELAY_HOST=email-smtp.us-east-1.amazonaws.com \
  RELAY_LOGIN=AKIAEXAMPLE \
  RELAY_PASSWORD=secret-token

check_ok recipients \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=alerts@example.com example.org /^ops@example\.net$/"

check_ok ipv6-relay \
  RELAY_HOST=2001:db8::1

check_ok ipv6-networks \
  RELAY_HOST=smtp.example.com \
  "ACCEPTED_NETWORKS=192.168.0.0/16 fd00::/8"

check_ok custom-port-tls \
  RELAY_HOST=smtp.example.com \
  RELAY_PORT=465 \
  SMTP_TLS_SECURITY_LEVEL=encrypt \
  MESSAGE_SIZE_LIMIT=41943040 \
  ACCEPTED_NETWORKS=10.10.0.0/16 \
  SMTP_HOSTNAME=relay.example.com

# --- Rejected configurations (exit 2) -------------------------------------
check_fail no-relay-host 2 \
  RELAY_HOST=

check_fail open-relay 2 \
  RELAY_HOST=smtp.example.com \
  ACCEPTED_NETWORKS=0.0.0.0/0

check_fail bad-port 2 \
  RELAY_HOST=smtp.example.com \
  RELAY_PORT=70000

check_fail bad-network-trailing-dot 2 \
  RELAY_HOST=smtp.example.com \
  ACCEPTED_NETWORKS=192.168.1.2./24

check_fail ipv6-multi-slash 2 \
  RELAY_HOST=smtp.example.com \
  "ACCEPTED_NETWORKS=192.168.0.0/16 fd00::/8/9"

check_fail networks-whitespace 2 \
  RELAY_HOST=smtp.example.com \
  "ACCEPTED_NETWORKS= "

check_fail networks-empty 2 \
  RELAY_HOST=smtp.example.com \
  ACCEPTED_NETWORKS=

check_fail networks-leading-zero-octet 2 \
  RELAY_HOST=smtp.example.com \
  ACCEPTED_NETWORKS=192.168.010.0/24

check_fail sasl-cleartext 2 \
  RELAY_HOST=smtp.example.com \
  RELAY_LOGIN=user \
  RELAY_PASSWORD=pass \
  SMTP_TLS_SECURITY_LEVEL=none

check_fail partial-sasl 2 \
  RELAY_HOST=smtp.example.com \
  RELAY_LOGIN=user

check_fail recipients-whitespace 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=   "

check_fail recipients-carriage-return 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=$(printf '\r')"

check_fail recipients-empty-regex 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=//"

check_fail recipients-slash-leading-regex 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=///"

check_fail bad-tls-level 2 \
  RELAY_HOST=smtp.example.com \
  SMTP_TLS_SECURITY_LEVEL=bogus

# RELAY_PORT=465 is implicit TLS (wrappermode); a disabled or opportunistic
# TLS level contradicts that contract and must be rejected.
check_fail implicit-tls-none 2 \
  RELAY_HOST=smtp.example.com \
  RELAY_PORT=465 \
  SMTP_TLS_SECURITY_LEVEL=none

check_fail implicit-tls-may 2 \
  RELAY_HOST=smtp.example.com \
  RELAY_PORT=465 \
  SMTP_TLS_SECURITY_LEVEL=may

# dane is opportunistic-family: without usable TLSA records it degrades to
# may, which wrappermode cannot satisfy (Postfix requires encrypt or
# stronger for implicit TLS).
check_fail implicit-tls-dane 2 \
  RELAY_HOST=smtp.example.com \
  RELAY_PORT=465 \
  SMTP_TLS_SECURITY_LEVEL=dane

check_fail relay-host-bracket-port 2 \
  "RELAY_HOST=[2001:db8::1]:587"

check_fail relay-host-unbalanced-bracket 2 \
  "RELAY_HOST=[2001:db8::1"

check_fail relay-host-empty-brackets 2 \
  "RELAY_HOST=[]"

check_fail relay-host-inner-bracket 2 \
  "RELAY_HOST=[2001:db8::1]:587]"

# --- sanitize_token regression ---------------------------------------------
# The golden harness only diffs rendered files and asserts exit codes; there
# is no stderr-log assertion mechanism, so exercise the log-only sanitizer
# directly by sourcing validate.sh in a subshell.
# check_sanitize NAME INPUT EXPECTED
check_sanitize() {
  _name=$1
  _got=$(
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=../validate.sh
    . "$ENTRYPOINT_DIR/validate.sh"
    sanitize_token "$2"
  )
  if [ "$_got" = "$3" ]; then
    pass=$((pass + 1))
  else
    printf 'FAIL %s: sanitize_token produced "%s", expected "%s"\n' "$_name" "$_got" "$3" >&2
    fail=$((fail + 1))
  fi
}

# Control bytes (CR, VT) must be stripped so a rejection log line stays a
# single parseable logfmt record.
check_sanitize control-bytes "$(printf 'bad\r\vnet/24')" 'badnet/24'

# The 512-byte cap must truncate and append the literal [truncated] marker
# so a hostile oversized value cannot flood a single log line.
check_sanitize truncation "$(printf '%0600d' 0)" "$(printf '%0512d' 0)[truncated]"

# --- RELAY_HOST colon-shape warning ------------------------------------------
# The host:port warning is log-only (the value still renders), so like
# sanitize_token it is exercised by sourcing validate.sh and asserting on
# stderr directly.
# check_relay_host_warn NAME VALUE WANT_WARN(0|1)
check_relay_host_warn() {
  _name=$1
  # Capture stderr via a temp file so the validator's exit status survives
  # (a $(... || :) capture would erase it): a fatal validator result must
  # fail the assertion rather than pass as "no warning emitted".
  _stderr_file=$(mktemp)
  if (
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=../validate.sh
    . "$ENTRYPOINT_DIR/validate.sh"
    validate_relay_host_shape "$2" >/dev/null 2>"$_stderr_file"
  ); then
    _rc=0
  else
    _rc=$?
  fi
  _stderr=$(cat "$_stderr_file")
  rm -f "$_stderr_file"
  if [ "$_rc" -ne 0 ]; then
    printf 'FAIL %s: warning probe exited %d, expected 0 (stderr: %s)\n' "$_name" "$_rc" "$_stderr" >&2
    fail=$((fail + 1))
    return
  fi
  case "$_stderr" in
    *'contains a colon but is not an IPv6 address'*) _warned=1 ;;
    *) _warned=0 ;;
  esac
  if [ "$_warned" = "$3" ]; then
    pass=$((pass + 1))
  else
    printf 'FAIL %s: warning emitted=%d, expected %d (stderr: %s)\n' "$_name" "$_warned" "$3" "$_stderr" >&2
    fail=$((fail + 1))
  fi
}

# A bracketed host:port value must warn just like the unbracketed form:
# compute_relayhost appends :$RELAY_PORT, rendering [smtp.example.com:587]:587,
# a literal that never resolves.
check_relay_host_warn relay-host-bracketed-hostport '[smtp.example.com:587]' 1

# A well-formed bracketed IPv6 literal must stay warning-free.
check_relay_host_warn relay-host-bracketed-ipv6 '[2001:db8::1]' 0

# --- Summary --------------------------------------------------------------
printf 'render-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
