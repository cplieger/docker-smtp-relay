#!/bin/sh
# Reads RECIPIENT_RESTRICTIONS (already validated) and sets
# SMTPD_RECIPIENT_RESTRICTIONS for main.cf generation.
#
# Token classification in emit_recipient_rule: leading / is regexp-family,
# an @ makes it a full address, anything else a domain. A mid-token slash
# WITHOUT a leading slash is legal RFC 5321 atext (john/doe@example.com),
# never regexp syntax.

# Escapes a recipient token for literal matching inside /^.../ or /@.../
# patterns. ] first (POSIX class requirement); / escaped as the Postfix
# regexp delimiter; # as the sed delimiter to avoid doubling slashes.
escape_postfix_regex() {
  printf '%s' "$1" | sed 's#[].[\\^$*+?(){}|/]#\\&#g'
}

# Appends one rule line to the recipient_access temp file; a write failure
# (ENOSPC, EROFS) becomes a structured error plus temp-file cleanup instead
# of a raw set -e diagnostic.
emit_rcpt_line() {
  if ! printf '%s\n' "$1" >>"$_rcpt_tmp"; then
    printf 'level=error msg="failed to write recipient_access (disk full or read-only?)" path="%s"\n' "$(sanitize_token "$_rcpt_tmp")" >&2
    rm -f "$_rcpt_tmp"
    exit 1
  fi
}

# emit_escaped_literal_rule ANCHOR TOKEN — escapes TOKEN and appends the
# anchored rule line ('/^' for the address arm, '/@' for the domain arm).
emit_escaped_literal_rule() {
  if ! _esc=$(escape_postfix_regex "$2"); then
    printf 'level=error msg="failed to escape recipient restriction for rendering"\n' >&2
    rm -f "$_rcpt_tmp"
    exit 1
  fi
  emit_rcpt_line "${1}${_esc}\$/ OK"
}

# parse_regexp_construct TOKEN — structure-parses a leading-/ token into /P/,
# /P/FLAGS, or /P1/[FLAGS]!/P2/[FLAGS] (dual: P1 AND NOT P2). Returns 1 on any
# other structure, which the caller warns and suppresses.
# Pattern scanning mirrors dict_regexp: each half ends at its first UNESCAPED /,
# a backslash escapes the next char, and escapes are preserved verbatim. Flags
# i/m/x were verified in-image against Postfix 3.11.5 via postmap -q; any other
# flag char makes postmap warn and drop the line, mirrored here as unparseable.
# One awk pass keeps parsing linear in token length: MAX_RECIPIENT_BYTES admits a
# single ~8 KiB construct, and a quadratic scan at that length would hold PID 1
# in pre-start validation. The heredoc read-back is safe because
# emit_recipient_rule rejects whitespace-bearing tokens fatally, so TOKEN can
# never contain a newline.
parse_regexp_construct() {
  _rx_fields=$(
    printf '%s\n' "$1" | awk '
      function add(c) { if (state == "p1") p1 = p1 c; else p2 = p2 c }
      {
        if (substr($0, 1, 1) != "/") exit 1
        state = "p1"; dual = closed1 = closed2 = 0
        for (i = 2; i <= length($0); i++) {
          c = substr($0, i, 1)
          if (state == "p1" || state == "p2") {
            if (c == "\\") {
              if (i == length($0)) exit 1
              add(c substr($0, ++i, 1))
            } else if (c == "/") {
              if (state == "p1") { state = "f1"; closed1 = 1 }
              else { state = "f2"; closed2 = 1 }
            } else add(c)
          } else if (state == "f1" && c == "!") {
            if (substr($0, i + 1, 1) != "/") exit 1
            dual = 1; state = "p2"; i++
          } else if (state == "f1") f1 = f1 c
          else f2 = f2 c
        }
        if (!closed1 || (dual && !closed2) || f1 ~ /[^imx]/ || f2 ~ /[^imx]/) exit 1
        print "dual:" dual; print "p1:" p1; print "f1:" f1
        print "p2:" p2; print "f2:" f2
      }'
  ) || return 1
  _rx_dual=0
  _rx_p1=''
  _rx_f1=''
  _rx_p2=''
  _rx_f2=''
  while IFS= read -r _rx_field; do
    case "$_rx_field" in
      dual:*) _rx_dual=${_rx_field#dual:} ;;
      p1:*) _rx_p1=${_rx_field#p1:} ;;
      f1:*) _rx_f1=${_rx_field#f1:} ;;
      p2:*) _rx_p2=${_rx_field#p2:} ;;
      f2:*) _rx_f2=${_rx_field#f2:} ;;
    esac
  done <<EOF
$_rx_fields
EOF
}

# half_flag_state FLAGS — folds one half's flags into its effective matcher state,
# mirroring dict_regexp: matching starts case-insensitive with ERE syntax, each i
# TOGGLES case sensitivity and each x TOGGLES extended-vs-basic (verified in-image
# with postmap -q on Postfix 3.11.5). m is accepted but not mirrored: it cannot
# change how a single-line recipient key matches.
half_flag_state() {
  _hf_ext=1
  _hf_icase=1
  _hf_rest=$1
  while [ -n "$_hf_rest" ]; do
    case "$_hf_rest" in
      i*) _hf_icase=$((1 - _hf_icase)) ;;
      x*) _hf_ext=$((1 - _hf_ext)) ;;
    esac
    _hf_rest=${_hf_rest#?}
  done
}

# regex_half_compiles PATTERN EXT — compile-probes one half with the grep syntax
# matching its effective flags. BusyBox grep links the same musl regcomp Postfix's
# regexp: tables use. A bad regex exits >=2 on both BusyBox 1.37 and GNU grep,
# valid-but-no-match exits 1; the prepended guaranteed-match alternation
# (^probe$|P) backstops a grep variant that reports a bad regex as exit 1.
# Prefixing rather than wrapping keeps capture/backreference numbering unchanged.
regex_half_compiles() {
  _rc_probe=0
  if [ "$2" -eq 1 ]; then
    printf 'probe\n' | grep -E -e "$1" >/dev/null 2>&1 || _rc_probe=$?
    [ "$_rc_probe" -ge 2 ] && return 1
    printf 'probe\n' | grep -E -e "^probe\$|$1" >/dev/null 2>&1 || return 1
  else
    printf 'probe\n' | grep -e "$1" >/dev/null 2>&1 || _rc_probe=$?
    [ "$_rc_probe" -ge 2 ] && return 1
    printf 'probe\n' | grep -e "^probe\$\\|$1" >/dev/null 2>&1 || return 1
  fi
}

# regex_half_matches PATTERN EXT ICASE STRING — match-probes one half with grep
# flags mirroring its effective regexp_table(5) state.
regex_half_matches() {
  _rm_opts=''
  [ "$2" -eq 1 ] && _rm_opts='E'
  [ "$3" -eq 1 ] && _rm_opts="${_rm_opts}i"
  if [ -n "$_rm_opts" ]; then
    printf '%s\n' "$4" | grep "-$_rm_opts" -e "$1" >/dev/null 2>&1
  else
    printf '%s\n' "$4" | grep -e "$1" >/dev/null 2>&1
  fi
}

# regexp_construct_matches PROBE — does the FULL parsed construct match PROBE the
# way Postfix will? Single form: P1 matches. Dual: P1 matches AND NOT P2.
regexp_construct_matches() {
  regex_half_matches "$_rx_p1" "$_rx_ext1" "$_rx_icase1" "$1" || return 1
  if [ "$_rx_dual" -eq 1 ] \
    && regex_half_matches "$_rx_p2" "$_rx_ext2" "$_rx_icase2" "$1"; then
    return 1
  fi
  return 0
}

# set_regexp_flag_states — folds the construct's flag strings into per-half
# matcher states, folding _rx_f2 only for the dual form.
set_regexp_flag_states() {
  half_flag_state "$_rx_f1"
  _rx_ext1=$_hf_ext
  _rx_icase1=$_hf_icase
  _rx_ext2=1
  _rx_icase2=1
  if [ "$_rx_dual" -eq 1 ]; then
    half_flag_state "$_rx_f2"
    _rx_ext2=$_hf_ext
    _rx_icase2=$_hf_icase
  fi
}

# Single source of the compile-warn log contract plus the shared
# ineffective-status bookkeeping.
warn_uncompilable_half() {
  printf 'level=warn msg="recipient restriction regex does not compile; Postfix skips an uncompilable rule at map load and matching recipients will be rejected" pattern="%s"\n' \
    "$(sanitize_token "$1")" >&2
  _rcpt_status=10
}

# classify_regexp_halves — compile-probes each parsed half. Sets _rcpt_status 10
# (ineffective) when either half draws the compile warn, excluding it from the
# effective count so an all-malformed list still trips the zero-rules guard.
classify_regexp_halves() {
  _rcpt_status=0
  regex_half_compiles "$_rx_p1" "$_rx_ext1" || warn_uncompilable_half "$_rx_p1"
  if [ "$_rx_dual" -eq 1 ]; then
    regex_half_compiles "$_rx_p2" "$_rx_ext2" || warn_uncompilable_half "$_rx_p2"
  fi
}

# reject_universal_construct ENTRY — possibly-allow-all guard on the FULL
# CONSTRUCT: fatal iff it matches BOTH of two fixed, dissimilar, valid-but-
# impossible probe addresses on reserved TLDs (RFC 2606/6761). An honest
# heuristic (possibly allow-all, not proof): it catches the empty-alternation typo
# class, nullable quantifiers and broad spellings (/./, /@/, /.+/, /.*/), while
# passing narrowing idioms like /.*@example\.com/!/^noreply@/. Only runs when
# every half compiled — an uncompilable half already means Postfix skips the line
# at map load. Tier 1 per validate.sh's policy.
reject_universal_construct() {
  _rcpt_probe_a='q7probe@nonce-a.invalid'
  _rcpt_probe_b='k2xrf@check-b.test'
  if [ "$_rcpt_status" -eq 0 ] \
    && regexp_construct_matches "$_rcpt_probe_a" \
    && regexp_construct_matches "$_rcpt_probe_b"; then
    printf 'level=error msg="recipient restriction regexp matches both universal-match safety probes and is treated as possibly allow-all; refusing to render it (split a narrow alternation into separate RECIPIENT_RESTRICTIONS entries; leave RECIPIENT_RESTRICTIONS empty only if allow-all is intended)" pattern="%s"\n' \
      "$(sanitize_token "$1")" >&2
    rm -f "$_rcpt_tmp"
    exit 2
  fi
}

# emit_regexp_recipient_rule ENTRY — emits structurally valid tokens VERBATIM
# (Postfix parses the dual/flags syntax natively). dict_regexp ignores an
# uncompilable line at map-open with only a maillog warning, so surface it at
# deploy time instead. Compile-warn arms still emit but return 10 (ineffective);
# the unparseable-structure arm returns 10 and does NOT emit.
emit_regexp_recipient_rule() {
  # dict_regexp ends the pattern at the FIRST unescaped /, so //, ///, //foo/
  # all have an EMPTY effective first pattern, which compiles as a POSIX
  # ERE matching every string — allow-all before the /.*/ REJECT terminator.
  # Fatal, matching the zero-rules guard's posture.
  case "$1" in
    //*)
      printf 'level=error msg="recipient restriction regex is empty (Postfix ends the pattern at the first unescaped /) and would match all recipients; refusing to allow all mail" entry="%s"\n' \
        "$(sanitize_token "$1")" >&2
      rm -f "$_rcpt_tmp"
      exit 2
      ;;
  esac
  # An unparseable leading-/ token is warned and SUPPRESSED, diverging from the
  # never-match arms' emit-anyway contract: those arms KNOW the rule is dead,
  # whereas an unparseable structure's behavior inside Postfix is unknown (probed
  # on 3.11.5: '/a@x/!/b/!/c/ OK' LOADS, silently absorbing '!/c/' into the lookup
  # result — semantics this validator never checked).
  if ! parse_regexp_construct "$1"; then
    printf 'level=warn msg="cannot parse regexp token structure; supported forms: /pattern/, /pattern/flags, /pattern1/!/pattern2/ (flags: i, m, x)" entry="%s"\n' \
      "$(sanitize_token "$1")" >&2
    return 10
  fi
  # An empty SECOND half (/x/!//) gets the same fatal posture as the //
  # arm above: an empty pattern matches every string.
  if [ "$_rx_dual" -eq 1 ] && [ -z "$_rx_p2" ]; then
    printf 'level=error msg="recipient restriction dual-form regexp has an empty pattern half (Postfix ends each pattern at the first unescaped /); an empty half matches every string, so the construct cannot mean what was configured; refusing to render it" entry="%s"\n' \
      "$(sanitize_token "$1")" >&2
    rm -f "$_rcpt_tmp"
    exit 2
  fi
  set_regexp_flag_states
  classify_regexp_halves
  reject_universal_construct "$1"
  emit_rcpt_line "$1 OK"
  return "$_rcpt_status"
}

# Single source of the never-match warn log contract plus the shared
# ineffective-status bookkeeping (the literal-arm counterpart of
# warn_uncompilable_half).
warn_never_match_rule() {
  printf 'level=warn msg="recipient restriction %s" entry="%s"\n' \
    "$1" "$(sanitize_token "$2")" >&2
  _rcpt_status=10
}

# emit_recipient_rule ENTRY — classifies one token (see the file header) and
# appends its rendered rule. Returns 0 for an effective rule, 10 otherwise. The
# address and domain arms return 10 for a deterministic never-match shape whose
# line is STILL emitted (Postfix loads it; no recipient can match). Address shapes
# are order-pinned: empty local part before empty domain, so a bare @ classifies
# as empty-local.
emit_recipient_rule() {
  case "$1" in
    *[[:space:]]*)
      # Word splitting already consumed spaces/tabs/line feeds, so residual
      # whitespace here is CR/FF/VT.
      printf 'level=error msg="recipient restriction contains invalid whitespace" entry="%s"\n' \
        "$(sanitize_token "$1")" >&2
      rm -f "$_rcpt_tmp"
      exit 2
      ;;
    /*)
      emit_regexp_recipient_rule "$1"
      ;;
    *@*)
      # Empty-local/empty-domain were probed live on Postfix 3.11.5 with
      # strict_rfc821_envelopes=no; re-probe on a major bump. Dot-after-@
      # needs no version caveat (DNS forbids an empty label).
      _rcpt_status=0
      _local="${1%@*}"
      _domain="${1##*@}"
      if [ -z "$_local" ]; then
        warn_never_match_rule "address has an empty local part; this anchored rule never matches a recipient smtpd presents" "$1"
      elif [ -z "$_domain" ]; then
        warn_never_match_rule "address has an empty domain; Postfix rejects domain-less recipients before the access-map lookup, so this rule will never match any recipient" "$1"
      else
        case "$_domain" in
          .*)
            warn_never_match_rule "address domain starts with a dot (no deliverable address contains @.); this rule will never match any recipient" "$1"
            ;;
        esac
      fi
      emit_escaped_literal_rule '/^' "$1"
      return "$_rcpt_status"
      ;;
    *)
      # A domain can never contain a slash (almost certainly a mis-typed
      # regexp literal) or start with a dot (no address contains @.).
      # Both are deterministic never-match shapes: warned, still emitted,
      # excluded from the effective count.
      _rcpt_status=0
      case "$1" in
        */*)
          warn_never_match_rule "looks like a mis-typed regexp (a domain cannot contain /); this rule will never match any recipient" "$1"
          ;;
        .*)
          warn_never_match_rule "domain starts with a dot (Postfix subdomain syntax is not supported by this regexp map; no address contains @.); this rule will never match any recipient" "$1"
          ;;
      esac
      emit_escaped_literal_rule '/@' "$1"
      return "$_rcpt_status"
      ;;
  esac
}

# Builds recipient_access from RECIPIENT_RESTRICTIONS and sets
# SMTPD_RECIPIENT_RESTRICTIONS. Must be called (not subshelled) so the variable is
# visible to the caller. Renders to a mktemp file in CONF_DIR and mv's atomically,
# so Postfix never sees a partial map.
build_recipient_filter() {
  # shellcheck disable=SC2034 # consumed by caller after sourcing
  SMTPD_RECIPIENT_RESTRICTIONS="permit_mynetworks, reject"

  if [ -n "$RECIPIENT_RESTRICTIONS" ]; then
    _rcpt_file="${CONF_DIR}/recipient_access"
    _rcpt_tmp=$(create_rendered_tmp "$_rcpt_file" recipient_access) || exit 1
    _rule_count=0
    for _entry in $RECIPIENT_RESTRICTIONS; do
      # Invoked as a condition: a bare call returning status 10 would abort
      # under set -e. The rule line is emitted either way; only effective
      # entries advance the count.
      if emit_recipient_rule "$_entry"; then
        _rule_count=$((_rule_count + 1))
      fi
    done
    # Refuse to proceed on zero EFFECTIVE rules: without this guard the map's only
    # live line is `/.*/ REJECT`, Postfix rejects 100% of mail, and the
    # healthcheck still reports green.
    if [ "$_rule_count" -eq 0 ]; then
      printf 'level=error msg="RECIPIENT_RESTRICTIONS is non-empty but parsed zero effective rules (whitespace only, or every entry malformed or never-matching?); refusing to reject all mail"\n' >&2
      rm -f "$_rcpt_tmp"
      exit 2
    fi
    emit_rcpt_line '/.*/ REJECT'
    promote_rendered_file "$_rcpt_tmp" "$_rcpt_file" recipient_access
    # shellcheck disable=SC2034 # consumed by caller after sourcing
    SMTPD_RECIPIENT_RESTRICTIONS="check_recipient_access regexp:${_rcpt_file}, reject"
    printf 'level=info msg="recipient filtering configured" rules=%d\n' \
      "$_rule_count" >&2
  else
    printf 'level=info msg="recipient filtering disabled; RECIPIENT_RESTRICTIONS is empty (all recipients from accepted networks are relayed)"\n' >&2
  fi
}
