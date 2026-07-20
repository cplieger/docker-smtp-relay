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
  if [ "${#2}" -gt 18 ]; then
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
validate_range() {
  if [ "$2" -lt "$3" ] || [ "$2" -gt "$4" ]; then
    printf 'level=error msg="env var out of range" var=%s value="%s" min=%s max=%s\n' "$1" "$2" "$3" "$4" >&2
    return 1
  fi
}

validate_ipv6_cidr() {
  _net=$1
  _prefix=$2
  if [ "$_prefix" -gt 128 ]; then
    printf 'level=error msg="IPv6 prefix out of range" network="%s" prefix=%s\n' "$(sanitize_token "$_net")" "$_prefix" >&2
    return 1
  fi
}

validate_ipv4_cidr() {
  _net=$1
  _ip=$2
  _prefix=$3
  if [ "$_prefix" -gt 32 ]; then
    printf 'level=error msg="IPv4 prefix out of range" network="%s" prefix=%s\n' "$(sanitize_token "$_net")" "$_prefix" >&2
    return 1
  fi
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
    if [ "$_oct" -gt 255 ]; then
      printf 'level=error msg="IPv4 octet out of range" network="%s" octet=%s\n' "$(sanitize_token "$_net")" "$_oct" >&2
      return 1
    fi
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
    if [ "$_prefix" -lt 8 ]; then
      printf 'level=error msg="network CIDR too broad (min /8)" network="%s" prefix=%s\n' "$(sanitize_token "$_net")" "$_prefix" >&2
      return 1
    fi

    # IP shape validation: reject malformed entries the operator would not
    # notice -- wrong octet count (192.168.1/24), out-of-range octets
    # (192.168.1.300/24), or non-numeric octets -- that would silently exclude
    # the intended LAN from relaying. IPv4 requires four dotted octets each
    # 0-255. IPv6 is detected by `:`
    # and delegated to Postfix for per-group validation.
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
