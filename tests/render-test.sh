#!/bin/sh
# ---------------------------------------------------------------------------
# render-test.sh — golden-file tests for the entrypoint's config generation.
#
# Runs `entrypoint.sh render` (which validates env and writes main.cf +
# recipient_access to $CONF_DIR without invoking Postfix or writing secrets)
# against a matrix of env inputs, and diffs the generated files against the
# committed fixtures in tests/golden/. Failure cases assert the validation
# exit code (2). Pure POSIX sh; needs only sh, sed, diff, mktemp, awk,
# timeout (all present in the BusyBox test stage).
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

# check_log NAME EXPECTED_CODE LOG_SNIPPET VAR=VAL...
# Render must exit EXPECTED_CODE AND its stderr must contain LOG_SNIPPET
# (fixed string). check_ok/check_fail discard stderr, so structured
# level=error/warn log contracts are pinned through this helper instead.
check_log() {
  _name=$1
  _want=$2
  _snippet=$3
  shift 3
  _tmp=$(mktemp -d)
  _stderr_file=$(mktemp)
  if env -i PATH="$PATH" CONF_DIR="$_tmp" "$@" sh "$ENTRYPOINT" render >/dev/null 2>"$_stderr_file"; then
    _rc=0
  else
    _rc=$?
  fi
  _stderr=$(cat "$_stderr_file")
  rm -f "$_stderr_file"
  rm -rf "$_tmp"
  if [ "$_rc" != "$_want" ]; then
    printf 'FAIL %s: render exited %d, expected %d (stderr: %s)\n' "$_name" "$_rc" "$_want" "$_stderr" >&2
    fail=$((fail + 1))
    return
  fi
  case "$_stderr" in
    *"$_snippet"*) pass=$((pass + 1)) ;;
    *)
      printf 'FAIL %s: stderr missing "%s" (stderr: %s)\n' "$_name" "$_snippet" "$_stderr" >&2
      fail=$((fail + 1))
      ;;
  esac
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

# Mixed valid + malformed: the container still starts on the valid subset.
# The malformed regexp is warned, still rendered (a dead line Postfix drops
# at map-open), and excluded from the effective-rule count.
check_ok recipients-mixed-malformed \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=user@example.com /[/"

# Mixed valid + deterministic never-match domain: the container still starts
# on the valid subset. The leading-dot domain is warned, still rendered (a
# dead line no recipient can ever match), and excluded from the
# effective-rule count (2026-07 decision).
check_ok recipients-mixed-never-match \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=user@example.com .example.com"

# Mixed valid + deterministic never-match ADDRESS shape (dot right after
# the @): same contract as the domain shape above — the dead entry is
# warned, still rendered (the map carries both lines + /.*/ REJECT), and
# excluded from the effective-rule count (2026-07 round-3 decision).
check_ok recipients-mixed-never-match-address \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=user@.example.com valid@example.com"

# The dead address entry must be excluded from the effective count
# (rules=1, not 2) and its never-match warn must be present.
check_log recipients-mixed-never-match-address-rules 0 'rules=1' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=user@.example.com valid@example.com"

check_log recipients-mixed-never-match-address-warn 0 'address domain starts with a dot' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=user@.example.com valid@example.com"

# Valid ERE with a backreference: the alternation compile probe must prepend
# its guaranteed-match alternative rather than wrap the pattern in a capture
# group ('(P)|^probe$' renumbers \1 to the still-open outer group and
# false-fails on GNU grep). Must render exit 0 under both GNU grep and the
# pinned BusyBox 1.37 image.
check_ok recipients-backreference \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/(a)\1/"

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

# dane obtains TLS policy from DNSSEC-validated TLSA records; the render must
# add smtp_dns_support_level = dnssec (postconf(5): DANE is disabled at the
# default dns support level) while keeping STARTTLS wrappermode off.
check_ok dane-relay \
  RELAY_HOST=smtp.example.com \
  SMTP_TLS_SECURITY_LEVEL=dane

# dane-only is a mandatory level, so it satisfies implicit TLS on 465:
# dnssec support line plus wrappermode = yes.
check_ok dane-only-465 \
  RELAY_HOST=smtp.example.com \
  RELAY_PORT=465 \
  SMTP_TLS_SECURITY_LEVEL=dane-only

# fingerprint renders the operator's trust anchors (space-separated tokens of
# colon-separated hex pairs) and the digest — explicit even at the sha256
# default, for auditability. No dnssec line.
check_ok fingerprint-relay \
  RELAY_HOST=smtp.example.com \
  SMTP_TLS_SECURITY_LEVEL=fingerprint \
  "SMTP_TLS_FINGERPRINT_CERT_MATCH=00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"

# Inbound STARTTLS is opt-in: a mounted cert/key pair renders the smtpd_tls_*
# block with the level defaulting to may (opportunistic). The paths are
# illustrative — render mode deliberately does not require the files to
# exist (that filesystem contract is run-mode-only).
check_ok smtpd-tls \
  RELAY_HOST=smtp.example.com \
  SMTPD_TLS_CERT_FILE=/certs/smtpd.pem \
  SMTPD_TLS_KEY_FILE=/certs/smtpd.key

# encrypt requires TLS from every inbound sender.
check_ok smtpd-tls-encrypt \
  RELAY_HOST=smtp.example.com \
  SMTPD_TLS_CERT_FILE=/certs/smtpd.pem \
  SMTPD_TLS_KEY_FILE=/certs/smtpd.key \
  SMTPD_TLS_SECURITY_LEVEL=encrypt

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

# Universal-match safety heuristic: a construct matching BOTH fixed
# impossible probes is treated as possibly allow-all, so rendering is
# refused with exit 2. The empty-alternation typo class (trailing,
# leading, doubled |, empty group) and the broad spellings (/./, /@/,
# /.+/, /.*/) must all trip it.
check_fail recipients-universal-trailing-alternation 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/alerts@example\.com|/"

check_fail recipients-universal-leading-alternation 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/|alerts@example\.com/"

check_fail recipients-universal-doubled-alternation 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/a||b/"

check_fail recipients-universal-empty-group 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/()/"

check_fail recipients-universal-dot 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/./"

check_fail recipients-universal-at 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/@/"

check_fail recipients-universal-dot-plus 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/.+/"

check_fail recipients-universal-dot-star 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/.*/"

# Default-insensitive /[A-Z]/ matches both lowercase safety probes and is
# therefore rejected by the possibly-allow-all heuristic; the probes run
# grep -i to mirror Postfix.
check_fail recipients-universal-case-insensitive 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/[A-Z]/"

# The structured error line for the universal-pattern rejection is a log
# contract (names the honest possibly-allow-all heuristic and the split /
# leave-empty remediations; round-4 wording — it must never claim "matches
# every recipient"); pin it for one case.
check_log recipients-universal-error-log 2 'matches both universal-match safety probes' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/.*/"

# MUST-PASS controls for the universal guard: a dead anchored-empty branch
# beside a real branch is restrictive (never-match patterns are not this
# guard's class), and a working optional-suffix group has an empty
# alternation branch that is NOT universal. Both must boot exit 0 with the
# rule emitted and counted.
check_ok recipients-anchored-empty-branch \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/^$|^alerts@example\.com$/"

check_ok recipients-optional-suffix-group \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/alerts(|-dev)@example\.com/"

# --- regexp_table(5) dual-pattern and flags forms (round-4) -----------------
# The dual form /pattern1/!/pattern2/ (matches P1 AND NOT P2) is emitted
# verbatim and counted effective: Postfix parses it natively (verified
# in-image with postmap -q on the pinned 3.11.5).
check_ok recipients-dual-form \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/.*@example\.com/!/^noreply@/"

# Construct-level universal guard: a universal P1 with a narrow except
# matches both safety probes (the except excludes neither probe), so the
# FULL construct is possibly allow-all and is refused — near-allow-all must
# be spelled as the empty var. The supported narrowing idiom above matches
# neither probe and passes.
check_log recipients-dual-universal 2 'matches both universal-match safety probes' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/.*/!/^noreply@/"

# Dual tokens mix with address and domain tokens; the effective count stays
# truthful (all three load and can match).
check_ok recipients-dual-mixed \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=alerts@example.com example.org /.*@example\.net/!/^noreply@/"

check_log recipients-dual-mixed-rules 0 'rules=3' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=alerts@example.com example.org /.*@example\.net/!/^noreply@/"

# An empty pattern half in a dual construct is fatal, same posture as the
# landed // empty-pattern arm: an empty half matches every string, so the
# construct cannot mean what was configured.
check_fail recipients-dual-empty-first-half 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=//!/x/"

check_fail recipients-dual-empty-second-half 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/x/!//"

# Flag-suffixed pattern (regexp_table(5) flags, verified set i/m/x): the
# c11 finding's exact spelling boots as an effective rule emitted verbatim
# (it used to fall through to the address arm as a silent never-match
# escaped literal).
check_ok recipients-flags-case-sensitive \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/^alerts@example\.com$/i"

# Probe flag-mirroring, both toggle directions (verified in-image on
# 3.11.5: matching is case-insensitive by DEFAULT and i toggles it OFF):
# /[A-Z]/i is case-SENSITIVE — it matches neither all-lowercase safety
# probe (restrictive: matches only uppercase-bearing recipients) and must
# boot, while plain /[A-Z]/ (default-insensitive, universal) stays fatal
# per recipients-universal-case-insensitive above.
check_ok recipients-flags-case-sensitive-class \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/[A-Z]/i"

# Unknown flag char: postmap (3.11.5) warns 'unknown regexp option' and
# skips the rule while the rest of the map loads; mirrored as unparseable
# structure — warn + suppressed + ineffective, so an all-such list trips
# the zero-effective-rules guard.
check_log recipients-unknown-flag 2 'cannot parse regexp token structure' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/alerts@example\.com/z"

# Unparseable structure (mid-token unescaped delimiters — the round-4
# replacement for the old unescaped-delimiter heuristic and its inaccurate
# "Postfix will ignore this rule" wording): warn + suppressed; all-such
# exits 2 via the zero-effective-rules guard.
check_log recipients-unparseable-structure 2 'cannot parse regexp token structure' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/a/b/c/"

# Mixed valid + unparseable structure: the container boots on the valid
# subset and the unparseable token is SUPPRESSED from the rendered map
# (the golden pins the absence — unlike never-match warns, an unvalidated
# structure is never emitted).
check_ok recipients-mixed-unparseable \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=user@example.com /a/b/c/"

# A mid-token slash WITHOUT a leading slash is legal RFC 5321 atext, not
# regexp syntax: john/doe@example.com boots silently as an escaped
# address-arm literal (the golden pins the escaped \/ rendering).
check_ok recipients-address-literal-slash \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=john/doe@example.com"

# Every entry malformed (the ERE does not compile): zero EFFECTIVE rules must
# trip the zero-rules guard instead of rendering a map whose only live line
# is /.*/ REJECT.
check_fail recipients-all-malformed 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/[/"

# Unbalanced-paren ERE: the standalone compile probe must catch it (the
# prepended '^probe$|' alternative leaves the parens unmatched, but a grep
# variant could heal them); zero effective rules trips the zero-rules guard.
check_fail recipients-all-malformed-parens 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/a)|(b/"

# Every entry a deterministic never-match domain shape: a leading-dot domain
# renders a rule Postfix loads but no recipient can ever match (no address
# contains @.), so zero EFFECTIVE rules must trip the zero-rules guard —
# the same operator outcome as the all-malformed list, reached through
# rules Postfix loads-but-never-matches (2026-07 decision).
check_fail recipients-all-never-match 2 \
  RELAY_HOST=smtp.example.com \
  RECIPIENT_RESTRICTIONS=.example.com

# Slash-bearing domain token (a domain cannot contain /; almost certainly a
# mis-typed regexp literal): the other deterministic never-match shape, same
# zero-effective-rules outcome.
check_fail recipients-all-never-match-slash 2 \
  RELAY_HOST=smtp.example.com \
  RECIPIENT_RESTRICTIONS=foo/bar

# Every entry a deterministic never-match ADDRESS shape (dot-after-@,
# empty local part, empty domain): zero EFFECTIVE rules must trip the
# zero-rules guard, same as the domain shapes (2026-07 round-3 decision).
check_fail recipients-all-never-match-address 2 \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=user@.example.com @example.com user@"

# A bare @ is both empty-local and empty-domain; the classification order
# is pinned to empty-local. The all-@ list trips the zero-rules guard AND
# the warn text must carry the empty-local classification.
check_log recipients-never-match-bare-at 2 'empty local part' \
  RELAY_HOST=smtp.example.com \
  RECIPIENT_RESTRICTIONS=@

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

# The fingerprint-family vars are both-or-neither with level=fingerprint
# (mirrors the RELAY_LOGIN/RELAY_PASSWORD contract): a fingerprint level
# without a match can never deliver; a match or an explicit digest at any
# other level is a silently-ignored trust anchor.
check_fail fingerprint-no-match 2 \
  RELAY_HOST=smtp.example.com \
  SMTP_TLS_SECURITY_LEVEL=fingerprint

check_fail fingerprint-whitespace-match 2 \
  RELAY_HOST=smtp.example.com \
  SMTP_TLS_SECURITY_LEVEL=fingerprint \
  "SMTP_TLS_FINGERPRINT_CERT_MATCH= "

check_fail fingerprint-match-wrong-level 2 \
  RELAY_HOST=smtp.example.com \
  SMTP_TLS_SECURITY_LEVEL=secure \
  "SMTP_TLS_FINGERPRINT_CERT_MATCH=00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff"

# Explicit digest at a non-fingerprint level (the level defaults to secure).
check_fail fingerprint-digest-wrong-level 2 \
  RELAY_HOST=smtp.example.com \
  SMTP_TLS_FINGERPRINT_DIGEST=sha256

# Wrong pair count for sha256 (32 pairs required): a deterministic
# never-match token is fatal, not a warn.
check_fail fingerprint-bad-token 2 \
  RELAY_HOST=smtp.example.com \
  SMTP_TLS_SECURITY_LEVEL=fingerprint \
  SMTP_TLS_FINGERPRINT_CERT_MATCH=de:ad:be:ef

# md5/sha1 digests are rejected (collision-weak; sha256/sha512 only).
check_fail fingerprint-md5-digest 2 \
  RELAY_HOST=smtp.example.com \
  SMTP_TLS_SECURITY_LEVEL=fingerprint \
  SMTP_TLS_FINGERPRINT_CERT_MATCH=00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff \
  SMTP_TLS_FINGERPRINT_DIGEST=md5

# The inbound cert/key pair is both-or-neither (mirrors the RELAY_LOGIN/
# RELAY_PASSWORD contract): half a pair can never negotiate STARTTLS.
check_fail smtpd-tls-key-only 2 \
  RELAY_HOST=smtp.example.com \
  SMTPD_TLS_KEY_FILE=/certs/smtpd.key

# An inbound level without the cert pair renders no smtpd_tls_* lines at
# all — a trust config that silently does nothing is a misconfiguration
# (same posture as SMTP_TLS_FINGERPRINT_DIGEST at a non-fingerprint level).
check_fail smtpd-tls-level-without-certs 2 \
  RELAY_HOST=smtp.example.com \
  SMTPD_TLS_SECURITY_LEVEL=may

# The inbound level is allowlisted to may/encrypt; cleartext is expressed
# by leaving the pair unset, not by a level value.
check_fail smtpd-tls-bad-level 2 \
  RELAY_HOST=smtp.example.com \
  SMTPD_TLS_CERT_FILE=/certs/smtpd.pem \
  SMTPD_TLS_KEY_FILE=/certs/smtpd.key \
  SMTPD_TLS_SECURITY_LEVEL=secure

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

# --- parse_regexp_construct linearity regression ---------------------------
# The structured parser must stay linear in the token length: the earlier
# per-character shell loop copied both the shrinking suffix and the growing
# prefix on every character, so a 5 KiB pattern held pre-start validation
# for ~100s in the built image (RECIPIENT_RESTRICTIONS has no length
# bound). Build an 8 KiB literal pattern, parse it under a hard 5s
# deadline, and assert the extracted first half is byte-identical.
check_parse_linear() {
  _name=$1
  _pat=''
  _i=0
  while [ "$_i" -lt 512 ]; do
    _pat="${_pat}abcdefghijklmnop"
    _i=$((_i + 1))
  done
  if _got=$(
    timeout 5 sh -c '
      . "$1/recipient-filter.sh"
      parse_regexp_construct "/$2/" || exit 1
      printf %s "$_rx_p1"
    ' parse-probe "$ENTRYPOINT_DIR" "$_pat"
  ); then
    :
  else
    printf 'FAIL %s: parser failed or exceeded 5s on an 8 KiB pattern\n' "$_name" >&2
    fail=$((fail + 1))
    return
  fi
  if [ "$_got" = "$_pat" ]; then
    pass=$((pass + 1))
  else
    printf 'FAIL %s: _rx_p1 is not byte-identical to the 8 KiB input pattern\n' "$_name" >&2
    fail=$((fail + 1))
  fi
}

check_parse_linear parse-8kib-linear

# --- Summary --------------------------------------------------------------
printf 'render-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
