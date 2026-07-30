#!/bin/sh
# ---------------------------------------------------------------------------
# render-test.sh — golden-file tests for the entrypoint's config generation.
#
# Runs `entrypoint.sh render` (which validates env and writes main.cf +
# recipient_access to $CONF_DIR without invoking Postfix or writing secrets)
# against a matrix of env inputs, and diffs the generated files against the
# committed fixtures in tests/golden/. Failure cases assert the validation
# exit code (2). Pure POSIX sh; needs only sh, sed, diff, mktemp, head, stat,
# timeout (all present in the BusyBox test stage), plus a C compiler when run
# from a source checkout (see the renderer block below).
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
HELPER_SRC="$(dirname -- "$SCRIPT_DIR")/smtp-recipient-render.c"
HELPER_BIN=smtp-recipient-render

# --- the recipient map renderer -------------------------------------------
# recipient-filter.sh resolves the renderer on PATH, and every check below
# runs the entrypoint under `env -i PATH="$PATH"`, so an env-var override
# would be scrubbed: build the helper into a temp bin dir and PREPEND that to
# PATH. A source-checkout run then tests the binary built from the tree in
# front of it; the image `test` stage has neither the .c file nor a compiler
# and takes the already-installed binary instead. A run with neither is a
# harness fault, not a green run with the renderer missing -- that would fail
# every recipient case identically and bury the real cause.
HELPER_TMPDIR=''
# shellcheck disable=SC2064 # expand HELPER_TMPDIR at trap time, not at trap install
trap 'rm -rf "$HELPER_TMPDIR"' EXIT
HELPER_CC=''
if [ -f "$HELPER_SRC" ]; then
  HELPER_CC=$(command -v cc || command -v gcc || printf '')
fi
if [ -n "$HELPER_CC" ]; then
  HELPER_TMPDIR=$(mktemp -d)
  if ! "$HELPER_CC" -std=c17 -Os -Wall -Wextra -Werror \
    -fstack-protector-strong -fstack-clash-protection \
    -o "$HELPER_TMPDIR/$HELPER_BIN" "$HELPER_SRC"; then
    printf 'harness error: could not build %s from %s\n' "$HELPER_BIN" "$HELPER_SRC" >&2
    exit 1
  fi
  PATH="$HELPER_TMPDIR:$PATH"
  export PATH
elif ! command -v "$HELPER_BIN" >/dev/null 2>&1; then
  printf 'harness error: %s is neither buildable (no %s, or no C compiler) nor installed on PATH\n' \
    "$HELPER_BIN" "$HELPER_SRC" >&2
  exit 1
fi

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

# A well-formed entry that clears every fatal arm yet authorizes public hosts to
# relay (Postfix masks 192.168.0.0/8 to 192.0.0.0/8). Warn-only by design, so the
# render must still succeed -- the warn is the operator's only signal.
check_log networks-public-range 0 'not inside private address space' \
  RELAY_HOST=smtp.example.com \
  ACCEPTED_NETWORKS=192.168.0.0/8

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

# The split remediation the universal-guard error message and the README both
# promise: an alternation spanning both probe domains is refused, but the same
# intent written as SEPARATE entries passes, because each half matches only
# ONE probe. This is the assertion that pins the probes as DISSIMILAR -- give
# them a shared domain and one of these two starts matching both and turns
# fatal. (Their local parts are deliberately not pinned: a pattern keyed to a
# probe's nonce has no plausible authoring path in a recipient allowlist.)
check_log recipients-probe-split-invalid 0 'rules=1' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/\.invalid$/"

check_log recipients-probe-split-test 0 'rules=1' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/\.test$/"

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

# Escaped slash inside a regexp token stays inside the pattern (the parser
# preserves the \/ escape verbatim); the token boots as one effective rule.
check_log recipients-regexp-escaped-slash 0 'rules=1' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/a\/b@example\.com$/"

# ii restores default case-insensitive matching, so [A-Z] again matches
# both lowercase safety probes and must hit the universal-match guard.
check_log recipients-flags-repeated 2 'possibly allow-all' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/[A-Z]/ii"

# Under x/BRE, \( is an unmatched group opener and must fail compilation;
# under ERE it is a valid literal parenthesis, so this pins the x toggle.
check_log recipients-flags-basic-syntax 2 'does not compile' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/\(/x"

# Bare ( is a literal paren under BRE (compiles; matches neither guard
# probe) but an unmatched group opener under ERE -- flag-distinguishing
# coverage of regex_half_compiles' BRE compile-SUCCESS arm and its
# ^probe$\| backstop, which the failing /\(/x case above never reaches.
check_log recipients-flags-basic-syntax-valid 0 'rules=1' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/(/x"

# xx restores ERE, the symmetric partner of the ii case above: under ERE \(
# is a valid literal parenthesis that compiles and matches neither probe, so
# the token boots as one effective rule -- whereas the single-x /\(/x above is
# fatal. Pins that x TOGGLES rather than merely selecting BRE (one x and two
# x's are indistinguishable to any single-x case).
check_log recipients-flags-repeated-x 0 'rules=1' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/\(/xx"

# Unknown flag char: postmap (3.11.5) warns 'unknown regexp option' and
# skips the rule while the rest of the map loads; mirrored as unparseable
# structure — warn + suppressed + ineffective, so an all-such list trips
# the zero-effective-rules guard.
check_log recipients-unknown-flag 2 'cannot parse regexp token structure' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/alerts@example\.com/z"

# The flag allowlist applies to the SECOND half's flags too; a dual construct
# whose except-half carries an unknown flag is equally unparseable.
check_log recipients-unknown-flag-second-half 2 'cannot parse regexp token structure' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/.*@example\.com/!/^noreply@/z"

# Unparseable structure (mid-token unescaped delimiters — the round-4
# replacement for the old unescaped-delimiter heuristic and its inaccurate
# "Postfix will ignore this rule" wording): warn + suppressed; all-such
# exits 2 via the zero-effective-rules guard.
check_log recipients-unparseable-structure 2 'cannot parse regexp token structure' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/a/b/c/"

# The other two unparseable-structure causes the parser owns, each pinned by
# its own token shape because all three collapse to the same exit code:
#   - no closing delimiter (Postfix skips such a line at map load with a
#     'no closing regexp delimiter' warning), and
#   - a dual separator whose second half is not /-delimited. Without that
#     check the ! would silently swallow the next character and leave an EMPTY
#     second half, which is a different refusal with a different message.
check_log recipients-unterminated-regexp 2 'cannot parse regexp token structure' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/ops@example\.com"

# Same rule for the SECOND half of a dual construct: an unterminated except-half
# is unparseable, not a pattern of everything after the !.
check_log recipients-dual-unterminated-half 2 'cannot parse regexp token structure' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/alerts@example\.com/!/noreply"

check_log recipients-dual-bang-not-delimited 2 'cannot parse regexp token structure' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=/alerts@example\.com/!x/"

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

# The address arm splits the token on its LAST @, so a two-@ token is
# classified by what follows the last one: user@host@.example.com is a
# dot-after-@ never-match, not a valid address with an odd local part. Splitting
# on the FIRST @ instead would read the domain as host@.example.com and count
# the dead entry as effective.
check_log recipients-address-last-at 2 'address domain starts with a dot' \
  RELAY_HOST=smtp.example.com \
  RECIPIENT_RESTRICTIONS=user@host@.example.com

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

# --- RECIPIENT_RESTRICTIONS input bounds -----------------------------------
# These four checks replace the old parse-8kib-linearity regression. That test
# built an 8 KiB pattern and asserted the structure parser stayed linear under
# a 5s deadline, because the variable had NO length bound and a quadratic
# per-character shell parse held pre-start validation for ~100s on a 5 KiB
# pattern. Both halves of that premise are gone: the parse is one bounded C
# pass, and an 8 KiB value is now REFUSED rather than parsed, so an assertion
# that it parses fast could not even run. What still matters is asserted
# instead: the bound refuses an oversized value (fatally, at the entrypoint,
# with its own log line), a value at the cap still renders, and a near-cap
# pattern is rendered VERBATIM inside a hard deadline -- the same
# no-truncation, no-blowup property the old test pinned, observed at the
# rendered output instead of at an internal variable.

# repeat_char COUNT — print COUNT digits (a valid domain-token body needing no
# escaping), used to build values at exact byte lengths.
repeat_char() {
  printf "%0${1}d" 0
}

# A value one byte past the cap is fatal, and the bound reports itself.
check_log recipients-over-byte-cap 2 'exceeds its maximum length' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=$(repeat_char 4097)"

# A value AT the cap still renders as one effective rule: the bound refuses
# only what it says it refuses.
check_log recipients-at-byte-cap 0 'rules=1' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=$(repeat_char 4096)"

# The entry count is bounded independently of the byte length: 129 short
# tokens sit far inside the 4096-byte cap, so only the entry cap can refuse
# them.
build_entry_list() {
  _list=''
  _n=0
  while [ "$_n" -lt "$1" ]; do
    _list="${_list}d${_n}.test "
    _n=$((_n + 1))
  done
  printf '%s' "$_list"
}

check_log recipients-over-entry-cap 2 'too many entries' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=$(build_entry_list 129)"

check_log recipients-at-entry-cap 0 'rules=128' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=$(build_entry_list 128)"

# The renderer enforces BOTH bounds itself, so it is safe to run standalone
# (and so a future caller cannot hand it an unbounded value). The entrypoint
# refuses first in the shipped boot path, which means these two are the only
# assertions that reach the renderer's own limits — invoke it directly.
# check_helper_refusal NAME EXPECTED_CODE LOG_SNIPPET VALUE
check_helper_refusal() {
  _name=$1
  _want=$2
  _snippet=$3
  _tmp=$(mktemp -d)
  _stderr_file=$(mktemp)
  if "$HELPER_BIN" "$_tmp" "$4" >/dev/null 2>"$_stderr_file"; then
    _rc=0
  else
    _rc=$?
  fi
  _stderr=$(cat "$_stderr_file")
  rm -f "$_stderr_file"
  rm -rf "$_tmp"
  if [ "$_rc" != "$_want" ]; then
    printf 'FAIL %s: %s exited %d, expected %d (stderr: %s)\n' \
      "$_name" "$HELPER_BIN" "$_rc" "$_want" "$_stderr" >&2
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

check_helper_refusal helper-byte-cap 2 "renderer's input limit" \
  "$(repeat_char 4097)"

check_helper_refusal helper-entry-cap 2 "renderer's entry limit" \
  "$(build_entry_list 129)"

# Successor to the linearity regression: a near-cap regexp token must be
# rendered byte-identically (the parse preserves the whole pattern; nothing
# truncates it) and the whole render must finish well inside a hard deadline.
check_render_near_cap() {
  _name=$1
  _tok="/$(repeat_char 4000)@example\\.com\$/"
  _tmp=$(mktemp -d)
  if timeout 5 env -i PATH="$PATH" CONF_DIR="$_tmp" \
    RELAY_HOST=smtp.example.com "RECIPIENT_RESTRICTIONS=$_tok" \
    sh "$ENTRYPOINT" render >/dev/null 2>&1; then
    :
  else
    printf 'FAIL %s: render of a near-cap regexp token failed or exceeded 5s\n' "$_name" >&2
    fail=$((fail + 1))
    rm -rf "$_tmp"
    return
  fi
  if [ "$(head -n 1 "$_tmp/recipient_access")" = "$_tok OK" ]; then
    pass=$((pass + 1))
  else
    printf 'FAIL %s: near-cap regexp token was not rendered verbatim\n' "$_name" >&2
    fail=$((fail + 1))
  fi
  rm -rf "$_tmp"
}

check_render_near_cap recipients-near-cap-verbatim

# The rendered map must land world-readable (0644). The renderer writes it via
# mkstemp, which creates 0600, and the Postfix daemons read the map as an
# unprivileged user -- a mode regression breaks the deployed relay while the
# rendered CONTENT the golden fixtures diff stays byte-identical, so the mode
# needs its own assertion.
check_map_mode() {
  _name=$1
  _tmp=$(mktemp -d)
  if env -i PATH="$PATH" CONF_DIR="$_tmp" RELAY_HOST=smtp.example.com \
    RECIPIENT_RESTRICTIONS=alerts@example.com \
    sh "$ENTRYPOINT" render >/dev/null 2>&1; then
    # A missing map must report FAIL, not abort the suite: the promote step is
    # exactly what this case can catch failing.
    _mode=$(stat -c %a "$_tmp/recipient_access" 2>/dev/null) || _mode='(no map rendered)'
  else
    _mode='(render failed)'
  fi
  rm -rf "$_tmp"
  if [ "$_mode" = 644 ]; then
    pass=$((pass + 1))
  else
    printf 'FAIL %s: rendered recipient_access mode is %s, expected 644\n' "$_name" "$_mode" >&2
    fail=$((fail + 1))
  fi
}

check_map_mode recipients-map-mode

# An oversized token must not flood a single log line: the renderer's port of
# sanitize_token bounds a logged value to 512 bytes and marks the cut. A
# leading-dot domain that long is a never-match warn, so its entry= field is
# where the bound shows.
check_log recipients-oversized-token-truncated 2 '[truncated]' \
  RELAY_HOST=smtp.example.com \
  "RECIPIENT_RESTRICTIONS=.$(repeat_char 600)"

# Cross-file invariant: the two bounds are enforced in BOTH entrypoint.sh and
# the renderer (so the renderer is safe standalone), which means editing one
# side alone would silently split the contract. Read both at run time. The
# image test stage ships no .c file, so this check is source-checkout-only and
# says so rather than passing vacuously.
check_cap_parity() {
  if [ ! -f "$HELPER_SRC" ]; then
    printf 'render-test: note: %s absent, cap-parity check not run (image test stage)\n' \
      "$HELPER_SRC"
    return
  fi
  _sh_bytes=$(sed -n 's/^readonly RECIPIENT_RESTRICTIONS_MAX_BYTES=\([0-9]*\)$/\1/p' "$ENTRYPOINT")
  _sh_tokens=$(sed -n 's/^readonly RECIPIENT_RESTRICTIONS_MAX_TOKENS=\([0-9]*\)$/\1/p' "$ENTRYPOINT")
  _c_bytes=$(sed -n 's/^#define RCPT_MAX_INPUT_BYTES \([0-9]*\)$/\1/p' "$HELPER_SRC")
  _c_tokens=$(sed -n 's/^#define RCPT_MAX_TOKENS \([0-9]*\)$/\1/p' "$HELPER_SRC")
  if [ -z "$_sh_bytes" ] || [ -z "$_sh_tokens" ] || [ -z "$_c_bytes" ] || [ -z "$_c_tokens" ]; then
    printf 'FAIL cap-parity: could not read all four bounds (sh=%s/%s c=%s/%s)\n' \
      "$_sh_bytes" "$_sh_tokens" "$_c_bytes" "$_c_tokens" >&2
    fail=$((fail + 1))
    return
  fi
  if [ "$_sh_bytes" = "$_c_bytes" ] && [ "$_sh_tokens" = "$_c_tokens" ]; then
    pass=$((pass + 1))
  else
    printf 'FAIL cap-parity: entrypoint.sh bounds %s/%s do not match %s bounds %s/%s\n' \
      "$_sh_bytes" "$_sh_tokens" "$HELPER_BIN" "$_c_bytes" "$_c_tokens" >&2
    fail=$((fail + 1))
  fi
}

check_cap_parity

# --- Summary --------------------------------------------------------------
printf 'render-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
