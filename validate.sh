#!/bin/sh
# ---------------------------------------------------------------------------
# validate.sh — input-validation helpers for smtp-relay entrypoint.
# Sourced at runtime by entrypoint.sh. Canonical copy; there is no shared
# validation library (the former lib/shell/validate.sh was removed).
# ---------------------------------------------------------------------------

# printf '%s' + trailing-newline strip lets a single trailing newline pass
# (harmless; env files and `$(...)` pipelines often preserve one), while
# still rejecting embedded newlines (the actual config-injection vector).
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

# Rejection logs must not interpolate the raw rejected token: an arbitrary
# value can carry a double quote (STARTUP_PROBE='bad"value' renders malformed
# logfmt that can make Alloy's parsing stage drop the fields precisely when
# startup fails). Log bounded context (var=NAME, valid="...") instead.
# Where the token itself must stay diagnosable (per-entry network validators:
# a multi-entry list needs to identify WHICH entry failed), route it through
# sanitize_token and emit it as a quoted logfmt field.

# sanitize_token -- strip logfmt delimiters (backslash, double quote) and
# control bytes (CR, VT, FF, ...), and bound the value to 512 bytes, so a
# rejected raw value can be logged as a bounded, parseable logfmt field.
# Values beyond the cap get a literal [truncated] marker appended.
sanitize_token() {
  printf '%.512s' "$1" | LC_ALL=C tr -d '\\"[:cntrl:]'
  if [ "${#1}" -gt 512 ]; then
    printf '[truncated]'
  fi
}
# Shell integers are compared with test(1), which aborts with "Illegal
# number" beyond LONG_MAX while an `if` swallows that error as "in range".
# 18 digits is the widest count that can never exceed LONG_MAX (2^63-1 has
# 19 digits). Single source of truth for the three length guards below.
readonly MAX_INT_DIGITS=18

# int_too_wide VALUE -- true when VALUE has more digits than test(1) can
# compare safely. Callers log their own site-specific context.
int_too_wide() { [ "${#1}" -gt "$MAX_INT_DIGITS" ]; }

validate_numeric() {
  case "$2" in
    '' | *[!0-9]*)
      printf 'level=error msg="env var must be a non-negative integer" var=%s\n' "$1" >&2
      return 1
      ;;
  esac
  # Reject values too long to compare as shell integers: test(1) aborts with
  # "Illegal number" beyond LONG_MAX, and validate_range's `if` silently
  # swallows that error and treats the value as in-range.
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

# Validate that a numeric value falls within [min, max].
# Usage: validate_range VAR_NAME VALUE MIN MAX
# Precondition: VALUE has already passed validate_numeric. The spec table in
# entrypoint.sh orders `num` before `range=` on every row, which is
# load-bearing twice: a non-numeric or >18-digit value would make both test(1)
# comparisons error out and the `if` would swallow that as "in range" (see the
# length-guard comment in validate_numeric), and the raw value="%s"
# interpolation below is exempt from the no-raw-token logging rule only
# because the value is guaranteed digits-only here.
validate_range() {
  if [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then
    printf 'level=error msg="env var out of range" var=%s value="%s" min=%s max=%s\n' "$1" "$2" "$3" "$4" >&2
    return 1
  fi
}

# validate_relay_host_shape VALUE -- shape check for RELAY_HOST. Two shape
# classes pass the metacharacter checks (a colon must be allowed for bare
# IPv6) but render a relayhost Postfix cannot use, deferring all mail at
# first send with only a maillog error:
#   - bracket defects ([host]:587, [host, [], [[host]], [host]:587]):
#     compute_relayhost trusts the leading bracket and appends :$RELAY_PORT
#     verbatim, rendering [host]:587:587, an unbalanced bracket, or a
#     malformed literal. No legitimate RELAY_HOST ever matches these
#     shapes, so they are fatal (return 1; the caller exits 2).
#   - a host:port value (smtp.example.com:587): the colon-bearing value is
#     bracketed whole, rendering [smtp.example.com:587]:587, an address
#     literal that never resolves (a hostname cannot contain a colon; only
#     an IPv6 address legitimately does). Warn-only: this arm is a
#     heuristic an exotic value could trip, so rejecting it would be a
#     config-acceptance change.
validate_relay_host_shape() {
  case "$1" in
    \[*\])
      # Outer brackets alone are not proof of a well-formed literal: strip
      # them and reject when the interior is empty or still contains a
      # bracket ([], [[host]], [host]:587] -- compute_relayhost trusts the
      # leading bracket, so the rendered relayhost is malformed).
      _rh_inner=${1#\[}
      _rh_inner=${_rh_inner%\]}
      case "$_rh_inner" in
        '' | *\[* | *\]*)
          printf 'level=error msg="RELAY_HOST has malformed brackets; the rendered relayhost would be malformed and Postfix would defer all mail (use a single [host] literal and put the port in RELAY_PORT)" relay_host="%s"\n' \
            "$(sanitize_token "$1")" >&2
          return 1
          ;;
      esac
      return 0
      ;;
    \[*)
      printf 'level=error msg="RELAY_HOST is bracketed but does not end with ]; the rendered relayhost would be malformed and Postfix would defer all mail (put the port in RELAY_PORT, not RELAY_HOST)" relay_host="%s"\n' \
        "$(sanitize_token "$1")" >&2
      return 1
      ;;
  esac
  case "$1" in
    *:*)
      case "${1#*:}" in
        *:*)
          # Two or more colons: plausibly IPv6; warn only on characters
          # invalid in an IPv6 address (also catches %zone ids).
          case "$1" in
            *[!0-9a-fA-F:.]*)
              printf 'level=warn msg="RELAY_HOST contains a colon but is not an IPv6 address (host:port?); the rendered relayhost will never resolve (put the port in RELAY_PORT)" relay_host="%s"\n' \
                "$(sanitize_token "$1")" >&2
              ;;
          esac
          ;;
        *)
          # Exactly one colon can never be IPv6 (even ::1 has two), so this
          # is host:port regardless of character set (192.0.2.10:587,
          # deadbeef:587 -- both all-hex, both silent under the old check).
          printf 'level=warn msg="RELAY_HOST contains a colon but is not an IPv6 address (host:port?); the rendered relayhost will never resolve (put the port in RELAY_PORT)" relay_host="%s"\n' \
            "$(sanitize_token "$1")" >&2
          ;;
      esac
      ;;
  esac
  return 0
}

validate_ipv6_cidr() {
  _net=$1
  _prefix=$2
  if [ "$_prefix" -gt 128 ]; then
    printf 'level=error msg="IPv6 prefix out of range" network="%s" prefix=%s\n' "$(sanitize_token "$_net")" "$_prefix" >&2
    return 1
  fi
  # A second / in the entry (fd00::/8/9) survives the prefix parse: the
  # trailing /9 becomes the prefix and the address part keeps /8, so
  # compute_mynetworks renders [fd00::/8]/9 -- Postfix logs a "bad
  # net/mask pattern" warning and the entry never matches, silently
  # excluding the operator's IPv6 LAN. Fatal, restoring parity with the
  # IPv4 arm, which rejects the same shape (the embedded / makes an
  # octet non-numeric).
  # Postfix mynetworks format allows an already-bracketed IPv6 entry
  # ([fd00::]/8, per postconf(5)); compute_mynetworks passes it through
  # verbatim, so it is a valid, matching shape. Strip the brackets before
  # the shape checks so the invalid-character arm does not false-warn
  # "never match" on it; the inner address still gets the check.
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
      # Postfix expands $name in main.cf parameter values (postconf(5)), so a
      # non-address character (e.g. $) is rewritten by config-parameter
      # expansion before the net/mask parse; either way the rendered entry is
      # a bad net/mask pattern that never matches, silently excluding the
      # intended LAN. Warn-only: rejecting it would be a config-acceptance
      # change (the multi-slash arm above is fatal by explicit user decision).
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
  # would split into four valid octets and pass; reject the trailing dot the
  # split cannot see (leading and doubled dots already yield an empty octet
  # the per-octet check catches).
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
    # Same LONG_MAX guard as validate_numeric; see int_too_wide.
    if int_too_wide "$_oct"; then
      printf 'level=error msg="IPv4 octet too large" network="%s" length=%d\n' "$(sanitize_token "$_net")" "${#_oct}" >&2
      return 1
    fi
    if [ "$_oct" -gt 255 ]; then
      printf 'level=error msg="IPv4 octet out of range" network="%s" octet=%s\n' "$(sanitize_token "$_net")" "$_oct" >&2
      return 1
    fi
    # Postfix's network parser (inet_pton-based) rejects leading-zero octets
    # at runtime ("bad network value ... skipping this rule", verified against
    # the shipped image), so the entry never matches and the intended LAN is
    # silently excluded while validation stays green. Fatal by explicit user
    # decision (same posture as the IPv6 multi-slash arm), restoring parity
    # with the other IPv4 shape rejections above.
    case "$_oct" in
      0[0-9]*)
        printf 'level=error msg="IPv4 octet has a leading zero; Postfix rejects this network entry at runtime (bad network value) and it would never match, silently excluding the intended LAN" network="%s" octet=%s\n' \
          "$(sanitize_token "$_net")" "$_oct" >&2
        return 1
        ;;
    esac
  done
}

validate_no_open_relay() {
  for _net in $1; do
    case "$_net" in
      0.0.0.0/0 | ::/0)
        # Exact-matched literal (0.0.0.0/0 or ::/0), sanitized for uniformity.
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
    # Same LONG_MAX guard as validate_numeric; see int_too_wide.
    if int_too_wide "$_prefix"; then
      printf 'level=error msg="network CIDR prefix too large" network="%s" length=%d\n' "$(sanitize_token "$_net")" "${#_prefix}" >&2
      return 1
    fi
    if [ "$_prefix" -lt 8 ]; then
      printf 'level=error msg="network CIDR too broad (min /8)" network="%s" prefix=%s\n' "$(sanitize_token "$_net")" "$_prefix" >&2
      return 1
    fi

    # IP shape validation: reject malformed entries the operator would not
    # notice -- wrong octet count (192.168.1/24), out-of-range octets
    # (192.168.1.300/24), or non-numeric octets -- that would silently exclude
    # the intended LAN from relaying. IPv4 requires four dotted octets each
    # 0-255. IPv6 is detected by `:`: validate_ipv6_cidr fatally rejects
    # multi-slash entries and warns on invalid address characters; per-group
    # (hextet) validation stays delegated to Postfix.
    _ip="${_net%/*}"
    case "$_ip" in
      *:*) validate_ipv6_cidr "$_net" "$_prefix" || return 1 ;;
      *.*.*.*) validate_ipv4_cidr "$_net" "$_ip" "$_prefix" || return 1 ;;
      *)
        printf 'level=error msg="unrecognized network format" network="%s"\n' "$(sanitize_token "$_net")" >&2
        return 1
        ;;
    esac
  done
}

# Valid TLS security levels (single source of truth).
readonly TLS_LEVELS="none may encrypt dane dane-only fingerprint verify secure"

validate_tls_level() {
  for _lvl in $TLS_LEVELS; do
    [ "$1" = "$_lvl" ] && return 0
  done
  # The rejected value is unvalidated input; do not interpolate it (logfmt
  # quoting) — the allowlist is enough context to fix the config.
  printf 'level=error msg="invalid TLS security level" var=SMTP_TLS_SECURITY_LEVEL valid="%s"\n' "$TLS_LEVELS" >&2
  return 1
}

# Reject SASL credentials that would break the sasl_passwd field format
# (`<host> <user>:<password>` parsed by splitting on first whitespace, then
# on first colon). Whitespace in either field, or a colon in the login,
# silently corrupts the hash map.
validate_sasl_login() {
  case "$1" in
    *[[:space:]]* | *:*)
      printf 'level=error msg="RELAY_LOGIN must not contain whitespace or colons"\n' >&2
      return 1
      ;;
  esac
}

validate_sasl_password() {
  case "$1" in
    *[[:space:]]*)
      printf 'level=error msg="RELAY_PASSWORD must not contain whitespace"\n' >&2
      return 1
      ;;
  esac
}
