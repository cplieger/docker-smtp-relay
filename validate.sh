#!/bin/sh
# Input-validation helpers for smtp-relay entrypoint.sh, sourced at runtime.
# Canonical copy; there is no shared validation library.

# Strips one trailing newline (env files and `$(...)` often carry one) before
# checking for embedded newlines, the actual config-injection vector.
validate_no_newlines() {
  _val=$(
    printf '%s' "$2"
    printf x
  )
  _val=${_val%x}
  _val=${_val%"
"}
  _line_count=$(printf '%s' "$_val" | wc -l)
  if [ "$_line_count" -gt 0 ]; then
    printf 'level=error msg="env var contains embedded newlines" var=%s\n' "$1" >&2
    return 1
  fi
}

# Rejection logs never interpolate the raw rejected token (a value can carry
# a double quote and break logfmt parsing) except through sanitize_token,
# which bounds and escapes it for per-entry diagnosability.
#
# Validation policy — which inputs are fatal, and which are the operator's:
#   Tier 1 (always fatal, security): injection into rendered config, the
#     open-relay CIDR rejection, credential exposure (SASL field format;
#     cleartext TLS with SASL), and any input that silently turns a
#     configured restriction into allow-all (the empty/slash-leading
#     recipient regex class and the universal-match guard in
#     recipient-filter.sh). Closed set; new entries require the same.
#   Tier 2 (fatal, documented contract): value combinations the app's own
#     contract says can never function — the implicit-TLS 465
#     mandatory-level gate, never-matching-shape escalations
#     (whitespace-only/leading-zero/multi-slash network entries,
#     leading-bracket RELAY_HOST defects), the fingerprint-family
#     both-or-neither and format checks, and the RECIPIENT_RESTRICTIONS
#     size bounds (rendering spawns external processes per rule before
#     Postfix binds port 25; hard-coded, no override — this image exposes
#     no access-map/policy-service setting for a larger allowlist).
#   Tier 3 (operator's responsibility): syntactically-plausible but
#     semantically-wrong values beyond those tiers. Existing warn arms are
#     final; no new shape arm without a Tier 1/2 justification — Postfix's
#     own runtime diagnostics are the source of truth beyond this point.

# Strips logfmt delimiters and control bytes, bounds to 512 bytes with a
# literal [truncated] marker, so a rejected value logs as one parseable field.
sanitize_token() {
  printf '%.512s' "$1" | LC_ALL=C tr -d '\\"[:cntrl:]'
  if [ "${#1}" -gt 512 ]; then
    printf '[truncated]'
  fi
}
# test(1) aborts with "Illegal number" beyond LONG_MAX while an `if` swallows
# that as "in range"; 18 digits is the widest count that can never exceed it
# (2^63-1 has 19). Single source of truth for the length guards below.
readonly MAX_INT_DIGITS=18

int_too_wide() { [ "${#1}" -gt "$MAX_INT_DIGITS" ]; }

validate_numeric() {
  case "$2" in
    '' | *[!0-9]*)
      printf 'level=error msg="env var must be a non-negative integer" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
  if int_too_wide "$2"; then
    printf 'level=error msg="env var numeric value too large" var=%s length=%d\n' "$1" "${#2}" >&2
    return 1
  fi
}

validate_no_metacharacters() {
  case "$2" in
    *[[:space:]]* | *\;* | *\&* | *\|* | *\`* | *\$*)
      printf 'level=error msg="env var contains invalid characters" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
}

# validate_range VAR VALUE MIN MAX. Precondition: VALUE already passed
# validate_numeric — entrypoint.sh's spec table orders `num` before `range=`
# on every row so a non-numeric or >18-digit value can never reach the `if`
# below, which would otherwise swallow "Illegal number" as in-range; the raw
# value="%s" interpolation is exempt from the no-raw-token rule for the same
# reason (guaranteed digits-only here).
validate_range() {
  if [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then
    printf 'level=error msg="env var out of range" var=%s value="%s" min=%s max=%s\n' "$1" "$2" "$3" "$4" >&2
    return 1
  fi
}

# RECIPIENT_RESTRICTIONS size bounds. Hard-coded with no env override: this
# image renders smtpd_recipient_restrictions itself with no access-map or
# policy-service setting, so a deployment needing more needs its own Postfix.
# Rendering spawns an external process per rule (sed/awk/grep) before Postfix
# binds port 25 with no deadline; measured ~1.4ms/plain rule, ~4.3ms/regexp
# rule on this host. 256 rules is ~1.1s, an order of magnitude inside the 15s
# healthcheck start-period.
readonly MAX_RECIPIENT_RULES=256
# The byte bound, against a shape a rule count cannot see (one pathological
# giant token). Wide enough to admit the ~8 KiB regexp construct
# tests/render-test.sh pins.
readonly MAX_RECIPIENT_BYTES=16384

# validate_recipient_rule_count VAR VALUE — upper bound on rule count
# (MAX_RECIPIENT_RULES). Counts whitespace-separated tokens the renderer
# itself will iterate (default-IFS splitting collapses whitespace runs, so
# padding cannot inflate the count); `set -f` premise matches
# validate_no_open_relay's loop. Upper bound only: a zero-token value is the
# zero-effective-rules guard's case (recipient-filter.sh), not this one's.
validate_recipient_rule_count() {
  _rr_var=$1
  # shellcheck disable=SC2086
  set -- $2
  if [ $# -gt "$MAX_RECIPIENT_RULES" ]; then
    printf 'level=error msg="RECIPIENT_RESTRICTIONS has more rules than this image renders at startup; every rule costs external processes (sed, awk, grep probes) before Postfix binds port 25, so the count is capped at a fixed budget deliberately set an order of magnitude inside the healthcheck start-period rather than measured per boot (this image renders smtpd_recipient_restrictions itself and exposes no access-map or policy-service setting, so a larger allowlist needs a Postfix deployment of your own configured with a check_recipient_access table or a policy service)" var=%s rules=%d max_rules=%d\n' \
      "$_rr_var" "$#" "$MAX_RECIPIENT_RULES" >&2
    return 1
  fi
}

# validate_recipient_byte_length VAR VALUE — upper bound on the whole
# value's byte length (MAX_RECIPIENT_BYTES). Ordered after the rule count in
# the spec table: a list breaking both is a rule-count problem, the
# actionable message.
# wc -c, not ${#VALUE}: BusyBox ash and dash disagree on what ${#} means for
# a multibyte value, and the bound is about bytes the renderer/Postfix
# handle.
validate_recipient_byte_length() {
  # A value that field-splits to zero tokens belongs to the
  # zero-effective-rules guard in recipient-filter.sh, not here.
  _rr_var=$1
  _rr_value=$2
  # shellcheck disable=SC2086
  set -- $_rr_value
  if [ $# -eq 0 ]; then
    return 0
  fi
  _rr_bytes=$(printf '%s' "$_rr_value" | wc -c)
  _rr_bytes=$((_rr_bytes))
  if [ "$_rr_bytes" -gt "$MAX_RECIPIENT_BYTES" ]; then
    printf 'level=error msg="RECIPIENT_RESTRICTIONS is longer than this image renders at startup; the whole value is parsed and probed before Postfix binds port 25, so its length is capped at a fixed budget rather than measured per boot (this image renders smtpd_recipient_restrictions itself and exposes no access-map or policy-service setting, so a larger allowlist needs a Postfix deployment of your own configured with a check_recipient_access table or a policy service)" var=%s bytes=%d max_bytes=%d\n' \
      "$_rr_var" "$_rr_bytes" "$MAX_RECIPIENT_BYTES" >&2
    return 1
  fi
}

# warn_relay_host_colon_shape CANDIDATE DISPLAY — warn when CANDIDATE looks
# like host:port rather than IPv6 (exactly one colon can never be IPv6, even
# ::1 has two; two+ colons is plausibly IPv6, warn only on invalid chars).
# DISPLAY is the original value to log; bracketed callers pass the bracket
# interior as CANDIDATE but the full value as DISPLAY.
warn_relay_host_colon_shape() {
  _rh_candidate=$1
  _rh_display=$2
  case "$_rh_candidate" in
    *:*)
      _rh_hostport=1
      case "${_rh_candidate#*:}" in
        *:*)
          case "$_rh_candidate" in
            *[!0-9a-fA-F:.]*) ;;
            *) _rh_hostport=0 ;;
          esac
          ;;
      esac
      if [ "$_rh_hostport" -eq 1 ]; then
        printf 'level=warn msg="RELAY_HOST contains a colon but is not an IPv6 address (host:port?); the rendered relayhost will never resolve (put the port in RELAY_PORT)" relay_host="%s"\n' \
          "$(sanitize_token "$_rh_display")" >&2
      fi
      ;;
  esac
}

# validate_relay_host_shape VALUE — shape check for RELAY_HOST. Two classes
# pass the metacharacter checks but render a relayhost Postfix can't use,
# deferring all mail with only a maillog error:
#   - bracket defects: compute_relayhost trusts the leading bracket and
#     appends :$RELAY_PORT verbatim, rendering a malformed literal. Fatal.
#   - host:port (smtp.example.com:587): bracketed whole, never resolves.
#     Warn-only — a heuristic an exotic value could trip.
validate_relay_host_shape() {
  case "$1" in
    \[*\])
      _rh_inner=${1#\[}
      _rh_inner=${_rh_inner%\]}
      case "$_rh_inner" in
        '' | *\[* | *\]*)
          printf 'level=error msg="RELAY_HOST has malformed brackets; the rendered relayhost would be malformed and Postfix would defer all mail (use a single [host] literal and put the port in RELAY_PORT)" relay_host="%s"\n' \
            "$(sanitize_token "$1")" >&2
          return 1
          ;;
      esac
      warn_relay_host_colon_shape "$_rh_inner" "$1"
      return 0
      ;;
    \[*)
      printf 'level=error msg="RELAY_HOST is bracketed but does not end with ]; the rendered relayhost would be malformed and Postfix would defer all mail (put the port in RELAY_PORT, not RELAY_HOST)" relay_host="%s"\n' \
        "$(sanitize_token "$1")" >&2
      return 1
      ;;
    *\[* | *\]*)
      printf 'level=warn msg="RELAY_HOST contains a stray bracket; the rendered relayhost will be malformed and Postfix will defer all mail" relay_host="%s"\n' \
        "$(sanitize_token "$1")" >&2
      ;;
  esac
  warn_relay_host_colon_shape "$1" "$1"
  return 0
}

validate_ipv6_cidr() {
  _net=$1
  _prefix=$2
  if [ "$_prefix" -gt 128 ]; then
    printf 'level=error msg="IPv6 prefix out of range" network="%s" prefix=%s\n' "$(sanitize_token "$_net")" "$_prefix" >&2
    return 1
  fi
  # A second / in the entry (fd00::/8/9) survives the prefix parse (the
  # trailing /9 becomes the prefix), rendering [fd00::/8]/9: Postfix logs a
  # bad net/mask pattern and the entry never matches, silently excluding the
  # LAN. Fatal, matching the IPv4 arm's parity below.
  # Postfix's mynetworks format allows an already-bracketed IPv6 entry
  # ([fd00::]/8, postconf(5)); strip brackets before the shape checks so a
  # legitimate value doesn't false-warn on the invalid-character arm.
  _v6_addr="${_net%/*}"
  case "$_v6_addr" in
    \[*\])
      _v6_addr="${_v6_addr#\[}"
      _v6_addr="${_v6_addr%\]}"
      ;;
  esac
  case "$_v6_addr" in
    */*)
      printf 'level=error msg="IPv6 network entry contains multiple / separators; Postfix would log a bad net/mask pattern and this network would never match, silently excluding the intended LAN" network="%s"\n' \
        "$(sanitize_token "$_net")" >&2
      return 1
      ;;
    *[!0-9a-fA-F:.]*)
      # Postfix expands $name in main.cf values (postconf(5)), so a
      # non-address character rewrites via config-parameter expansion; either
      # way the rendered entry never matches. Warn-only: rejecting would be a
      # config-acceptance change.
      printf 'level=warn msg="IPv6 network entry contains characters invalid in an IPv6 address; this network will never match (a $ is expanded as a Postfix config parameter)" network="%s"\n' \
        "$(sanitize_token "$_net")" >&2
      ;;
  esac
}

validate_ipv4_cidr() {
  _net=$1
  _ip=$2
  _prefix=$3
  if [ "$_prefix" -gt 32 ]; then
    printf 'level=error msg="IPv4 prefix out of range" network="%s" prefix=%s\n' "$(sanitize_token "$_net")" "$_prefix" >&2
    return 1
  fi
  # POSIX field splitting drops a trailing empty field, so "192.168.1.2./24"
  # would split into four valid octets and pass; reject the trailing dot
  # explicitly (leading/doubled dots already yield an empty octet caught below).
  case "$_ip" in
    *.)
      printf 'level=error msg="IPv4 address has a trailing dot" network="%s"\n' "$(sanitize_token "$_net")" >&2
      return 1
      ;;
  esac
  _oldIFS=$IFS
  IFS=.
  # shellcheck disable=SC2086
  set -- $_ip
  IFS=$_oldIFS
  if [ $# -ne 4 ]; then
    printf 'level=error msg="IPv4 address must have 4 octets" network="%s"\n' "$(sanitize_token "$_net")" >&2
    return 1
  fi
  for _oct; do
    case "$_oct" in
      '' | *[!0-9]*)
        printf 'level=error msg="IPv4 octet not numeric" network="%s" octet="%s"\n' "$(sanitize_token "$_net")" "$(sanitize_token "$_oct")" >&2
        return 1
        ;;
    esac
    if int_too_wide "$_oct"; then
      printf 'level=error msg="IPv4 octet too large" network="%s" length=%d\n' "$(sanitize_token "$_net")" "${#_oct}" >&2
      return 1
    fi
    if [ "$_oct" -gt 255 ]; then
      printf 'level=error msg="IPv4 octet out of range" network="%s" octet=%s\n' "$(sanitize_token "$_net")" "$_oct" >&2
      return 1
    fi
    # Postfix's inet_pton-based network parser rejects leading-zero octets at
    # runtime ("bad network value", verified in-image), silently excluding
    # the LAN while validation stays green. Fatal, matching the IPv6
    # multi-slash arm's posture.
    case "$_oct" in
      0[0-9]*)
        printf 'level=error msg="IPv4 octet has a leading zero; Postfix rejects this network entry at runtime (bad network value) and it would never match, silently excluding the intended LAN" network="%s" octet=%s\n' \
          "$(sanitize_token "$_net")" "$_oct" >&2
        return 1
        ;;
    esac
  done
}

# warn_public_network NET IP PREFIX — the open-relay guard below rejects the
# two all-address literals and any prefix under /8, but a /8 (or /16, /32 in
# IPv6) can still sit entirely inside PUBLIC address space (192.168.0.0/8
# masks to 192.0.0.0/8, authorizing ~16M Internet hosts). Postfix accepts
# both silently, so this warn is the only signal. Warn, not fatal: a
# deployment relaying for a public subnet it owns is legitimate.
# Containment is decided from the leading octets plus the prefix, exact for
# the RFC 1918/6598/3927/4193/4291 blocks.
warn_public_network() {
  _wpn_addr=$(printf '%s' "$2" | LC_ALL=C tr 'ABCDEF' 'abcdef')
  case "$_wpn_addr" in
    \[*)
      _wpn_addr="${_wpn_addr#\[}"
      _wpn_addr="${_wpn_addr%\]}"
      ;;
  esac
  case "$_wpn_addr" in
    10.*) [ "$3" -ge 8 ] && return 0 ;;
    127.*) [ "$3" -ge 8 ] && return 0 ;;
    192.168.*) [ "$3" -ge 16 ] && return 0 ;;
    169.254.*) [ "$3" -ge 16 ] && return 0 ;;
    172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) [ "$3" -ge 12 ] && return 0 ;;
    100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*)
      [ "$3" -ge 10 ] && return 0
      ;;
    # IPv6: fc00::/7 (ULA) and fe80::/10 (link-local). The first hextet must
    # be spelled in full (fc5:: is 0x0fc5, not inside fc00::/7).
    f[cd][0-9a-f][0-9a-f]:*) [ "$3" -ge 7 ] && return 0 ;;
    fe[89ab][0-9a-f]:*) [ "$3" -ge 10 ] && return 0 ;;
    ::1) [ "$3" -ge 128 ] && return 0 ;;
  esac
  printf 'level=warn msg="ACCEPTED_NETWORKS entry is not inside private address space; every host in that range may relay mail through this server (a mistyped prefix is how a relay accidentally becomes an open relay)" network="%s" prefix=%s\n' \
    "$(sanitize_token "$1")" "$3" >&2
}

validate_no_open_relay() {
  for _net in $1; do
    case "$_net" in
      0.0.0.0/0 | ::/0)
        printf 'level=error msg="network list contains open-relay CIDR" network="%s"\n' "$(sanitize_token "$_net")" >&2
        return 1
        ;;
    esac
    _prefix="${_net##*/}"
    if [ "$_prefix" = "$_net" ]; then
      printf 'level=error msg="network entry missing CIDR prefix" network="%s"\n' "$(sanitize_token "$_net")" >&2
      return 1
    fi
    case "$_prefix" in
      '' | *[!0-9]*)
        printf 'level=error msg="network entry has non-numeric prefix" network="%s"\n' "$(sanitize_token "$_net")" >&2
        return 1
        ;;
    esac
    if int_too_wide "$_prefix"; then
      printf 'level=error msg="network CIDR prefix too large" network="%s" length=%d\n' "$(sanitize_token "$_net")" "${#_prefix}" >&2
      return 1
    fi
    if [ "$_prefix" -lt 8 ]; then
      printf 'level=error msg="network CIDR too broad (min /8)" network="%s" prefix=%s\n' "$(sanitize_token "$_net")" "$_prefix" >&2
      return 1
    fi

    _ip="${_net%/*}"
    case "$_ip" in
      *:*) validate_ipv6_cidr "$_net" "$_prefix" || return 1 ;;
      *.*.*.*) validate_ipv4_cidr "$_net" "$_ip" "$_prefix" || return 1 ;;
      *)
        printf 'level=error msg="unrecognized network format" network="%s"\n' "$(sanitize_token "$_net")" >&2
        return 1
        ;;
    esac
    warn_public_network "$_net" "$_ip" "$_prefix"
  done
}

# Valid TLS security levels.
readonly TLS_LEVELS="none may encrypt dane dane-only fingerprint verify secure"

validate_tls_level() {
  for _lvl in $TLS_LEVELS; do
    [ "$1" = "$_lvl" ] && return 0
  done
  printf 'level=error msg="invalid TLS security level" var=SMTP_TLS_SECURITY_LEVEL valid="%s"\n' "$TLS_LEVELS" >&2
  return 1
}

# sha256/sha512 only; md5/sha1 are collision-weak and rejected as trust anchors.
validate_fingerprint_digest() {
  case "$1" in
    sha256 | sha512) return 0 ;;
  esac
  printf 'level=error msg="invalid fingerprint digest (md5/sha1 are rejected: collision-weak digests cannot anchor trust)" var=SMTP_TLS_FINGERPRINT_DIGEST valid="sha256 sha512"\n' >&2
  return 1
}

# validate_fingerprint_match MATCH DIGEST — format check for
# SMTP_TLS_FINGERPRINT_CERT_MATCH (Tier 2). Postfix compares each configured
# digest as colon-separated hex pairs (postconf(5)
# smtp_tls_fingerprint_cert_match); a token in any other shape can never
# match any peer, so a level=fingerprint relay would defer every delivery.
# Deterministic never-match => fatal.
validate_fingerprint_match() {
  _fm_match=$1
  _fm_digest=$2
  _fm_want_pairs=32
  [ "$_fm_digest" = sha512 ] && _fm_want_pairs=64
  for _fm_token in $_fm_match; do
    # A leading, trailing, or doubled colon yields an empty pair that POSIX
    # field splitting drops, which would otherwise fool the pair-count check.
    case "$_fm_token" in
      *[!0-9a-fA-F:]* | :* | *: | *::*)
        printf 'level=error msg="fingerprint match token is not colon-separated hex pairs; it can never match any peer and every delivery would defer" var=SMTP_TLS_FINGERPRINT_CERT_MATCH token="%s"\n' \
          "$(sanitize_token "$_fm_token")" >&2
        return 1
        ;;
    esac
    _oldIFS=$IFS
    IFS=:
    # shellcheck disable=SC2086
    set -- $_fm_token
    IFS=$_oldIFS
    if [ $# -ne "$_fm_want_pairs" ]; then
      printf 'level=error msg="fingerprint match token has wrong digest length; it can never match any peer and every delivery would defer" var=SMTP_TLS_FINGERPRINT_CERT_MATCH token="%s" pairs=%d want_pairs=%d digest=%s\n' \
        "$(sanitize_token "$_fm_token")" "$#" "$_fm_want_pairs" "$_fm_digest" >&2
      return 1
    fi
    for _fm_pair; do
      case "$_fm_pair" in
        [0-9a-fA-F][0-9a-fA-F]) ;;
        *)
          printf 'level=error msg="fingerprint match token has a malformed hex pair; it can never match any peer and every delivery would defer" var=SMTP_TLS_FINGERPRINT_CERT_MATCH token="%s"\n' \
            "$(sanitize_token "$_fm_token")" >&2
          return 1
          ;;
      esac
    done
  done
}

# Reject exactly the SASL credential shapes the sasl_passwd map cannot carry.
# Record is `<relayhost> <login>:<password>`: postmap(1) ends the key at the
# first whitespace, trims leading/trailing whitespace from the value, then
# smtp_sasl_passwd_lookup splits that value at the first colon. Only the
# value's two outer edges are trimmed; everything between — including the
# login's tail and password's head — is interior and survives verbatim.
# Measured against the pinned Postfix (postmap + postmap -q) and re-measured
# under BusyBox ash in the shipped image:
#   MANGLED (fatal): login leading whitespace (trimmed), password trailing
#     whitespace (trimmed), a colon anywhere in the login (first-colon
#     split), a login trailing newline (ends the record before the delimiter)
#   PRESERVED (accepted): password interior/leading whitespace (the Gmail
#     App Password shape), login interior/trailing whitespace, a colon
#     anywhere in the password (first-colon split takes only the login side)
# The fatal set is Tier 2: each is a documented never-works combination.
# "Whitespace" is ASCII whitespace only — Postfix's ISSPACE is ASCII-gated,
# so U+00A0 is ordinary content to both Postfix and these validators.
validate_sasl_login() {
  case "$1" in
    *:*)
      printf 'level=error msg="RELAY_LOGIN must not contain a colon; the sasl_passwd value is split at the first colon, so the login would be cut short and no delivery could authenticate"\n' >&2
      return 1
      ;;
    [[:space:]]*)
      printf 'level=error msg="RELAY_LOGIN must not start with whitespace; postmap trims it off the map value, so the login sent upstream would differ from the one configured (whitespace inside or after the login is kept)"\n' >&2
      return 1
      ;;
    # A trailing newline survives validate_no_newlines' one-newline
    # carve-out but ends the record line before the delimiter, leaving the
    # login with no password.
    *"
")
      printf 'level=error msg="RELAY_LOGIN must not end with a newline; it would end the credential record before the password and no delivery could authenticate"\n' >&2
      return 1
      ;;
  esac
}

validate_sasl_password() {
  case "$1" in
    *[[:space:]])
      printf 'level=error msg="RELAY_PASSWORD must not end with whitespace; postmap trims it off the map value, so the password sent upstream would differ from the one configured (whitespace INSIDE or BEFORE the password is kept, so a Gmail App Password works exactly as issued)"\n' >&2
      return 1
      ;;
  esac
}
