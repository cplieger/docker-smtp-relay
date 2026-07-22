#!/bin/sh
# recipient-filter.sh — recipient-filtering logic sourced by entrypoint.sh.
# Reads RECIPIENT_RESTRICTIONS (already validated) and sets
# SMTPD_RECIPIENT_RESTRICTIONS for main.cf generation.

# Escape user-supplied recipient tokens so they are matched literally (not as
# regex) when rendered inside /^.../ or /@.../ patterns below. The character
# class uses ] first (POSIX requirement), escapes / because it is the Postfix
# regexp delimiter, and uses # as the sed delimiter to avoid doubling slashes.
# Both { and } are escaped together so the class stays symmetric and obviously
# covers every metacharacter of the POSIX regular expressions that Postfix
# regexp: tables use (the class would also cover pcre: if the map type ever
# changed).
escape_postfix_regex() {
  printf '%s' "$1" | sed 's#[].[\\^$*+?(){}|/]#\\&#g'
}

# emit_rcpt_line LINE — append one rule line to the recipient_access temp
# file, converting a write failure (ENOSPC, EROFS) into a structured
# level=error plus temp-file cleanup instead of a raw set -e diagnostic.
emit_rcpt_line() {
  if ! printf '%s\n' "$1" >>"$_rcpt_tmp"; then
    printf 'level=error msg="failed to write recipient_access (disk full or read-only?)" path="%s"\n' "$(sanitize_token "$_rcpt_tmp")" >&2
    rm -f "$_rcpt_tmp"
    exit 1
  fi
}

# emit_regexp_recipient_rule ENTRY — render one /.../ regexp-literal token.
# Test-compiles the pattern with grep -E (BusyBox grep links the same musl
# regcomp Postfix's regexp: tables use in this image). dict_regexp ignores an
# uncompilable line at map-open time with only a maillog warning, so the
# intended allow rule silently vanishes and the /.*/ REJECT terminator rejects
# that mail; surface it at deploy time. A bad ERE exits 2 on both BusyBox
# (v1.37, the pinned base) and GNU grep, while valid-but-no-match exits 1,
# so the standalone probe classifies exit >= 2 as uncompilable; the
# alternation probe "(P)|^probe$" (matches whenever P compiles) backstops
# any grep variant that reports a bad ERE as a silent exit 1. Warn arms
# still warn and emit the line unchanged, but return 10 (ineffective) so the
# entry no longer satisfies the zero-rules guard — an all-malformed list is
# now fatal there (2026-07 decision).
emit_regexp_recipient_rule() {
  _rcpt_pat=${1#/}
  _rcpt_pat=${_rcpt_pat%/}
  _rcpt_status=0
  # Postfix's dict_regexp ends the pattern at the FIRST unescaped /, so any
  # entry beginning with // (//, ///, //foo/) has an EMPTY effective pattern
  # even when the shell strip above leaves text. An empty pattern compiles as
  # a POSIX ERE that matches every string, so the rendered rule would allow
  # ALL recipients before the /.*/ REJECT terminator (or dict_regexp drops
  # the line as bad flags and matching mail is rejected) — the operator
  # configured a restriction and silently got allow-all or reject-all. Fatal,
  # matching the zero-rules guard's posture of refusing to render a map that
  # allows or rejects all mail.
  case "$1" in
    //*)
      printf 'level=error msg="recipient restriction regex is empty (Postfix ends the pattern at the first unescaped /) and would match all recipients; refusing to allow all mail" entry="%s"\n' \
        "$(sanitize_token "$1")" >&2
      rm -f "$_rcpt_tmp"
      exit 2
      ;;
  esac
  # Two probes: the alternation probe alone is healed by an unbalanced-paren
  # pattern (P='a)|(b' wraps to '(a)|(b)|^probe$', a valid ERE), so also
  # compile P standalone and treat exit >= 2 as a regcomp failure (BusyBox
  # v1.37 and GNU grep both exit 2 on a bad ERE; exit 1 is valid-but-no-
  # match). Either probe failing marks the entry ineffective.
  _rcpt_compile=0
  printf 'probe\n' | grep -E -e "${_rcpt_pat}" >/dev/null 2>&1 || _rcpt_compile=$?
  if [ "$_rcpt_compile" -ge 2 ] \
    || ! printf 'probe\n' | grep -E -e "(${_rcpt_pat})|^probe\$" >/dev/null 2>&1; then
    printf 'level=warn msg="recipient restriction regex does not compile; Postfix will ignore this rule and matching recipients will be rejected" pattern="%s"\n' \
      "$(sanitize_token "$_rcpt_pat")" >&2
    _rcpt_status=10
  fi
  # The grep compile check cannot see the delimiter contract: an unescaped /
  # inside the pattern (e.g. /a/b/) is a valid ERE but terminates the Postfix
  # regexp-table pattern early, so dict_regexp drops the whole line at
  # map-open with only a maillog warning. Strip backslash escapes first; any
  # / left is an unescaped delimiter (escape_postfix_regex escapes / for
  # exactly this reason in the literal arms).
  case "$(printf '%s' "$_rcpt_pat" | sed 's#\\.##g')" in
    */*)
      printf 'level=warn msg="recipient restriction regex contains an unescaped /; Postfix parses / as the pattern delimiter and will ignore this rule" pattern="%s"\n' \
        "$(sanitize_token "$_rcpt_pat")" >&2
      _rcpt_status=10
      ;;
  esac
  emit_rcpt_line "$1 OK"
  return "$_rcpt_status"
}

# emit_recipient_rule ENTRY — classify one RECIPIENT_RESTRICTIONS token
# (regexp literal, full address, or domain) and append its rendered rule via
# emit_rcpt_line. Shares the _rcpt_tmp contract with build_recipient_filter:
# fatal branches remove the temp file and exit 2. Returns 0 for an effective
# rule; the regexp arm is its case arm's last command, so it propagates
# emit_regexp_recipient_rule's ineffective status (10). The address/domain
# arms end in emit_rcpt_line and keep returning 0 (their warns are shape
# hints, not load failures).
emit_recipient_rule() {
  case "$1" in
    *[[:space:]]*)
      # Word splitting already consumed spaces, tabs, and line feeds, so
      # residual whitespace here is CR/FF/VT — it would render a rule no
      # real recipient matches, silently rejecting all mail.
      printf 'level=error msg="recipient restriction contains invalid whitespace" entry="%s"\n' \
        "$(sanitize_token "$1")" >&2
      rm -f "$_rcpt_tmp"
      exit 2
      ;;
    /*/) # already a Postfix regexp literal
      emit_regexp_recipient_rule "$1"
      ;;
    *@*) # full address: anchor both ends
      _esc=$(escape_postfix_regex "$1")
      emit_rcpt_line "/^${_esc}\$/ OK"
      ;;
    *) # domain-only: anchor the @-suffix
      # A domain can never contain a slash, so a slash-bearing token here
      # is almost certainly a mis-typed regexp literal (e.g. `/foo`
      # missing its closing delimiter). The escaped rule compiles but can
      # never match a real recipient; surface that at deploy time.
      # Warn-only: rejecting it would be a config-acceptance change.
      case "$1" in
        */*)
          printf 'level=warn msg="recipient restriction looks like a mis-typed regexp (a domain cannot contain /); this rule will never match any recipient" entry="%s"\n' \
            "$(sanitize_token "$1")" >&2
          ;;
        .*)
          printf 'level=warn msg="recipient restriction domain starts with a dot (Postfix subdomain syntax is not supported by this regexp map; no address contains @.); this rule will never match any recipient" entry="%s"\n' \
            "$(sanitize_token "$1")" >&2
          ;;
      esac
      _esc=$(escape_postfix_regex "$1")
      emit_rcpt_line "/@${_esc}\$/ OK"
      ;;
  esac
}

# build_recipient_filter — builds /etc/postfix/recipient_access from
# RECIPIENT_RESTRICTIONS tokens and sets SMTPD_RECIPIENT_RESTRICTIONS.
# Must be called (not subshelled) so the variable is visible to the caller.
# The file is rendered to a mktemp file in CONF_DIR and mv'd into place
# atomically only once the complete artifact is written, so Postfix never
# sees a partial map and every failure path is a structured level=error.
build_recipient_filter() {
  # shellcheck disable=SC2034 # consumed by caller after sourcing
  SMTPD_RECIPIENT_RESTRICTIONS="permit_mynetworks, reject"

  if [ -n "$RECIPIENT_RESTRICTIONS" ]; then
    _rcpt_file="${CONF_DIR}/recipient_access"
    _rcpt_tmp=$(create_rendered_tmp "$_rcpt_file" recipient_access) || exit 1
    _rule_count=0
    for _entry in $RECIPIENT_RESTRICTIONS; do
      # Invoked as a condition: a bare call returning the ineffective status
      # (10) would abort the script under set -e. The rule line is emitted
      # either way; only effective entries advance the count.
      if emit_recipient_rule "$_entry"; then
        _rule_count=$((_rule_count + 1))
      fi
    done
    # Refuse to proceed if a non-empty RECIPIENT_RESTRICTIONS parses to zero
    # EFFECTIVE rules: whitespace-only value (quoting bug, empty-var
    # expansion) or every entry malformed (warned above; Postfix drops each
    # at map-open). Without this guard the map's only live line is
    # `/.*/ REJECT`, Postfix rejects 100% of mail, and the healthcheck still
    # reports green.
    if [ "$_rule_count" -eq 0 ]; then
      printf 'level=error msg="RECIPIENT_RESTRICTIONS is non-empty but parsed zero effective rules (whitespace only, or every entry malformed?); refusing to reject all mail"\n' >&2
      rm -f "$_rcpt_tmp"
      exit 2
    fi
    emit_rcpt_line '/.*/ REJECT'
    promote_rendered_file "$_rcpt_tmp" "$_rcpt_file" recipient_access
    # shellcheck disable=SC2034 # consumed by caller after sourcing
    SMTPD_RECIPIENT_RESTRICTIONS="check_recipient_access regexp:${_rcpt_file}, reject"
    # Count only EFFECTIVE operator-supplied allow rules (entries Postfix
    # will actually load; warned-ineffective ones are excluded), never the
    # trailing /.*/ REJECT terminator — an internal implementation detail
    # that would confuse operators reading Loki.
    printf 'level=info msg="recipient filtering configured" rules=%d\n' \
      "$_rule_count" >&2
  fi
}
