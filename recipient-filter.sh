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
    printf 'level=error msg="failed to write recipient_access (disk full or read-only?)" path=%s\n' "$_rcpt_tmp" >&2
    rm -f "$_rcpt_tmp"
    exit 1
  fi
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
    if ! _rcpt_tmp=$(mktemp "${_rcpt_file}.XXXXXX"); then
      printf 'level=error msg="failed to create temporary file for recipient_access" conf_dir=%s\n' "$CONF_DIR" >&2
      exit 1
    fi
    _rule_count=0
    for _entry in $RECIPIENT_RESTRICTIONS; do
      case "$_entry" in
        *[[:space:]]*)
          # Word splitting already consumed spaces, tabs, and line feeds, so
          # residual whitespace here is CR/FF/VT — it would render a rule no
          # real recipient matches, silently rejecting all mail.
          printf 'level=error msg="recipient restriction contains invalid whitespace"\n' >&2
          rm -f "$_rcpt_tmp"
          exit 2
          ;;
        /*/) # already a Postfix regexp literal
          emit_rcpt_line "$_entry OK"
          ;;
        *@*) # full address: anchor both ends
          _esc=$(escape_postfix_regex "$_entry")
          emit_rcpt_line "/^${_esc}\$/ OK"
          ;;
        *) # domain-only: anchor the @-suffix
          _esc=$(escape_postfix_regex "$_entry")
          emit_rcpt_line "/@${_esc}\$/ OK"
          ;;
      esac
      _rule_count=$((_rule_count + 1))
    done
    # Refuse to proceed if a non-empty RECIPIENT_RESTRICTIONS parses to zero
    # rules (whitespace-only value from a quoting bug or empty-var expansion).
    # Without this guard the file ends up containing only `/.*/ REJECT`, Postfix
    # rejects 100% of mail, and the healthcheck still reports green.
    if [ "$_rule_count" -eq 0 ]; then
      printf 'level=error msg="RECIPIENT_RESTRICTIONS is non-empty but parsed zero rules (whitespace only?); refusing to reject all mail"\n' >&2
      rm -f "$_rcpt_tmp"
      exit 2
    fi
    emit_rcpt_line '/.*/ REJECT'
    # mktemp creates 0600; the map must stay world-readable (smtpd runs as
    # the postfix user), matching the previous umask-derived 0644.
    if ! chmod 644 "$_rcpt_tmp" || ! mv "$_rcpt_tmp" "$_rcpt_file"; then
      printf 'level=error msg="failed to move rendered recipient_access into place" path=%s\n' "$_rcpt_file" >&2
      rm -f "$_rcpt_tmp"
      exit 1
    fi
    # shellcheck disable=SC2034 # consumed by caller after sourcing
    SMTPD_RECIPIENT_RESTRICTIONS="check_recipient_access regexp:${_rcpt_file}, reject"
    # Count only operator-supplied allow rules; the trailing /.*/ REJECT terminator
    # is an internal implementation detail and would confuse operators reading Loki.
    printf 'level=info msg="recipient filtering configured" rules=%d\n' \
      "$_rule_count" >&2
  fi
}
