#!/bin/sh
# recipient-filter.sh — recipient-filtering logic sourced by entrypoint.sh.
# Reads RECIPIENT_RESTRICTIONS (already validated) and sets
# SMTPD_RECIPIENT_RESTRICTIONS for main.cf generation.
#
# Token classification (emit_recipient_rule): any token STARTING with /
# is regexp-family and gets the full regexp_table(5) structure parse
# (/pattern/, flag-suffixed /pattern/flags, and the dual-pattern form
# /pattern1/[flags]!/pattern2/[flags]); a token containing @ is a full
# address rendered as an anchored escaped literal; anything else is a
# domain rendered as an anchored @-suffix literal. A mid-token slash
# WITHOUT a leading slash is not regexp syntax: / is legal RFC 5321 atext,
# so john/doe@example.com is a correct address-arm literal (escaped,
# matched literally, never warned), while a slash-bearing domain token
# still draws its arm's mis-typed-regexp warn (a domain can never
# contain /).

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

# emit_escaped_literal_rule ANCHOR TOKEN -- escape TOKEN for literal matching
# and append the anchored rule line (ANCHOR is '/^' for the address arm,
# '/@' for the domain arm). A sed failure is a runtime error: structured
# level=error, temp-file cleanup, exit 1 -- the contract both literal arms
# previously duplicated inline.
emit_escaped_literal_rule() {
  if ! _esc=$(escape_postfix_regex "$2"); then
    printf 'level=error msg="failed to escape recipient restriction for rendering"\n' >&2
    rm -f "$_rcpt_tmp"
    exit 1
  fi
  emit_rcpt_line "${1}${_esc}\$/ OK"
}

# parse_regexp_construct TOKEN — structure-parse a leading-/ token into the
# regexp_table(5) forms this image supports:
#   /P/                        plain pattern
#   /P/FLAGS                   flag-suffixed (FLAGS: one or more of i m x)
#   /P1/[FLAGS]!/P2/[FLAGS]    dual-pattern: matches P1 AND NOT P2
# Sets _rx_p1/_rx_f1 (first half + flags), _rx_dual (0|1), _rx_p2/_rx_f2.
# Returns 1 on any other leading-/ structure: no closing delimiter (Postfix
# skips such a line at map load with a 'no closing regexp delimiter'
# warning — probed in-image with postmap -q on the pinned 3.11.5, 2026-07),
# dangling !, a second half not /-delimited, more than one ! separator, or
# a flag char outside the verified set — the caller warns and suppresses.
# Pattern scanning mirrors dict_regexp: each half ends at its first
# UNESCAPED / delimiter, a backslash escapes the next character (so \/
# stays inside the pattern, exactly the escape escape_postfix_regex
# produces for the literal arms), and escapes are preserved verbatim —
# that is what Postfix hands to regcomp and what the grep probes must
# therefore see. The flag set was verified in-image against the pinned
# Postfix 3.11.5 (postmap -q probes on throwaway regexp maps, 2026-07):
# i, m, and x all load and match; any other char makes postmap warn
# 'unknown regexp option "<c>": skipping this rule' and drop that line
# while the rest of the map still loads, so an unknown-flag token is
# mirrored as unparseable structure (warn + ineffective), never emitted
# and never fatal.
# The scan is ONE linear awk pass, not a per-character shell loop: the
# shell spelling copied both the shrinking suffix and the growing prefix
# on every character, making token parsing quadratic — and with no length
# bound on RECIPIENT_RESTRICTIONS, a 5 KiB pattern held PID 1 in pre-start
# validation for ~100s in the built Alpine image. The single-line pipe and
# the heredoc read-back are safe because emit_recipient_rule already
# rejected any whitespace-bearing token fatally, so TOKEN can never
# contain a newline.
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

# half_flag_state FLAGS — fold one half's flag string into its effective
# matcher state, mirroring dict_regexp exactly: matching starts
# case-insensitive with extended (ERE) syntax; each i TOGGLES case
# sensitivity and each x TOGGLES extended-vs-basic syntax. Repeated flags
# re-toggle — verified in-image with postmap -q on 3.11.5 (2026-07):
# '/alerts@x/i OK' does NOT match ALERTS@X (i turns case sensitivity ON)
# while '/alerts@x/ii OK' does; '/a+b@x/x OK' matches the literal a+b@x
# and not aab@x (x switches regcomp to BASIC syntax) while /xx restores
# ERE. m toggles multi-line matching (REG_NEWLINE), which cannot change
# how a single-line recipient key matches, so it is accepted but not
# mirrored in the probes. Sets _hf_ext (1 = ERE, 0 = BRE) and _hf_icase
# (1 = case-insensitive).
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

# regex_half_compiles PATTERN EXT — compile-probe one pattern half with the
# grep syntax matching its effective flags (EXT=1: grep -E / ERE; EXT=0:
# plain grep / BRE — an x-flagged half hands Postfix's regcomp a BASIC
# regex, so the probe must compile it as one too). BusyBox grep links the
# same musl regcomp Postfix's regexp: tables use in this image. Same
# two-probe mechanism as always: a bad regex exits 2 on both BusyBox
# (v1.37, the pinned base) and GNU grep while valid-but-no-match exits 1,
# so the standalone probe classifies exit >= 2 as uncompilable; the
# prepended guaranteed-match alternation (^probe$|P, spelled ^probe$\|P
# under BRE — supported by both greps) backstops any grep variant that
# reports a bad regex as a silent exit 1. Prefixing rather than wrapping
# keeps capture/backreference numbering unchanged and leaves unmatched
# parentheses unmatched. Returns 0 when the half compiles.
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

# regex_half_matches PATTERN EXT ICASE STRING — match-probe one half
# against STRING with grep flags mirroring the half's effective
# regexp_table(5) state: -E only while the half is extended syntax, -i
# only while it is case-insensitive. This generalizes the earlier
# blanket -i (which mirrored the default only): a half whose effective
# flags toggled case sensitivity is probed case-SENSITIVELY, so
# /[A-Z]/i — a restrictive, case-sensitive pattern under Postfix's
# toggle semantics — is probed the way Postfix will actually match it.
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

# regexp_construct_matches PROBE — does the FULL parsed construct match
# PROBE the way Postfix will match a recipient key against the emitted
# line? Single form: P1 matches. Dual form: P1 matches AND NOT P2 matches
# (regexp_table(5) — verified in-image on 3.11.5:
# '/.*@example\.com/!/^noreply@/ OK' returns OK for user@example.com and
# nothing for noreply@example.com). Uses the per-half flag states the
# caller computed via half_flag_state.
regexp_construct_matches() {
  regex_half_matches "$_rx_p1" "$_rx_ext1" "$_rx_icase1" "$1" || return 1
  if [ "$_rx_dual" -eq 1 ] \
    && regex_half_matches "$_rx_p2" "$_rx_ext2" "$_rx_icase2" "$1"; then
    return 1
  fi
  return 0
}

# set_regexp_flag_states — fold the parsed construct's flag strings into
# per-half effective matcher states (see half_flag_state). Sets
# _rx_ext1/_rx_icase1 from _rx_f1 and defaults _rx_ext2/_rx_icase2 to the
# ERE/case-insensitive start state, folding _rx_f2 only for the dual form.
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

# warn_uncompilable_half PATTERN -- single source of the compile-warn log
# contract (the wording is Loki-queried; two hand-kept copies can drift)
# plus the shared ineffective-status bookkeeping.
warn_uncompilable_half() {
  printf 'level=warn msg="recipient restriction regex does not compile; Postfix skips an uncompilable rule at map load and matching recipients will be rejected" pattern="%s"\n' \
    "$(sanitize_token "$1")" >&2
  _rcpt_status=10
}

# classify_regexp_halves — compile-probe each parsed pattern half with its
# flag-mirrored grep syntax (same warn + status 10 handling as always,
# applied to each half; the round-1 all-malformed -> exit-2 semantics are
# unchanged because status 10 keeps the token out of the effective count).
# Sets _rcpt_status: 0 when every half compiles, 10 (ineffective) when
# either half draws the compile warn.
classify_regexp_halves() {
  _rcpt_status=0
  regex_half_compiles "$_rx_p1" "$_rx_ext1" || warn_uncompilable_half "$_rx_p1"
  if [ "$_rx_dual" -eq 1 ]; then
    regex_half_compiles "$_rx_p2" "$_rx_ext2" || warn_uncompilable_half "$_rx_p2"
  fi
}

# reject_universal_construct ENTRY — universal-match (possibly-allow-all)
# guard, applied to the FULL CONSTRUCT uniformly: single form — the
# construct matches a probe iff P matches it; dual form — iff P1 matches
# AND NOT P2 matches (exactly how Postfix evaluates the emitted line).
# Fatal iff the construct matches BOTH probes — same rule, same message,
# any spelling. The probes are two FIXED, dissimilar,
# syntactically-valid-but-impossible addresses on reserved TLDs (RFC
# 2606/6761). This is an honest HEURISTIC: matching both probes is treated
# as possibly allow-all, not proof of it. It closes every universal
# pattern — the empty-alternation typo class (/P|/, /|P/, /P||Q/, /()/),
# nullable-quantifier spellings ((foo)?, a{0,3}, ^|x), broad spellings
# (/./, /@/, /.+/, /.*/), and the dual near-allow-all /.*/!/^noreply@/
# (universal P1, narrow except: both probes match — the feature is an
# allowlist, so near-allow-all must be spelled as the empty var) — while
# the supported narrowing idiom /.*@example\.com/!/^noreply@/ matches
# neither probe and passes. Deliberately does NOT flag
# broad-but-not-universal patterns (e.g. /@e/, TLD unions) — operator
# judgment, mechanically undecidable. Over-fatal FP classes, fail-closed
# and loud: (a) patterns keyed to the probe structure (e.g. /\.invalid/
# beside a dead anchored-empty branch, or a nonce-structure-matching
# branch) — no plausible authoring path in a recipient allowlist; (b)
# shared-character members (/-/, /e/ — both probes contain hyphens and
# common letters). The split remediation in the fatal message resolves the
# plausible members of (b): /\.invalid$/ and /\.test$/ as SEPARATE entries
# each match one probe only and pass. Never-match patterns (/^$/,
# /^$|^addr$/) correctly PASS (not this guard's class; they boot as
# reject-heavy configs, the fail-closed direction). The probes mirror each
# half's EFFECTIVE flags via regex_half_matches (i/x toggle parity — the
# earlier blanket -i covered only the default state, when a flags suffix
# could not reach this arm), so a case-only-universal /[A-Z]/ still flags
# while the case-SENSITIVE /[A-Z]/i correctly passes. The guard only runs
# when every half compiled (an uncompilable half means Postfix skips the
# whole line at map load — already warned, status 10 — so match probes
# would be meaningless).
# Tier 1 per validate.sh's validation policy ("any input that silently
# turns a configured restriction into allow-all" — always fatal), the
# same posture as the empty-pattern arms in emit_regexp_recipient_rule;
# recorded in that policy header as explicit closed-set grants (2026-07
# round-3 judgement + user batch-closure approval; construct-level
# semantics, flags, and dual-pattern support are the 2026-07 round-4
# grant). Returns 0 when the construct passes (status nonzero or either
# probe misses); otherwise emits the fatal error, removes _rcpt_tmp, and
# exits 2.
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

# emit_regexp_recipient_rule ENTRY — render one leading-/ regexp-family
# token. Structure-parses the token into the supported regexp_table(5)
# forms (plain, flag-suffixed, dual-pattern), compile-probes each pattern
# half with flag-mirrored grep (see the helpers above), applies the
# construct-level universal-match guard, and emits structurally valid
# tokens VERBATIM (the whole original token + ' OK') — Postfix parses the
# dual/flags syntax natively, so the effective-rule count stays truthful.
# dict_regexp ignores an uncompilable line at map-open time with only a
# maillog warning, so the intended allow rule silently vanishes and the
# /.*/ REJECT terminator rejects that mail; surface it at deploy time.
# Compile-warn arms still warn and emit the line unchanged, but return 10
# (ineffective) so the entry no longer satisfies the zero-rules guard — an
# all-malformed list is fatal there (2026-07 decision). The
# unparseable-structure arm (which REPLACED the earlier unescaped-delimiter
# heuristic) also returns 10 but does NOT emit; see its comment.
emit_regexp_recipient_rule() {
  # Postfix's dict_regexp ends the pattern at the FIRST unescaped /, so any
  # entry beginning with // (//, ///, //foo/) has an EMPTY effective first
  # pattern whatever follows. An empty pattern compiles as
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
  # Structure parse. An unparseable leading-/ token (no closing delimiter,
  # dangling !, doubled !, unknown flag char) is warned and SUPPRESSED —
  # deliberately diverging from the never-match arms' emit-anyway contract:
  # those arms KNOW the rule is dead (Postfix loads it but no recipient can
  # match), whereas this arm cannot know what an unvalidated structure
  # would do inside Postfix (probed on 3.11.5: '/a@x/!/b/!/c/ OK' LOADS,
  # silently absorbing '!/c/' into the lookup RESULT — semantics this
  # validator never checked). Suppressing is safe: status 10 excludes the
  # token from the effective count, the warn names it, and an all-such
  # list exits 2 via the zero-effective-rules guard.
  if ! parse_regexp_construct "$1"; then
    printf 'level=warn msg="cannot parse regexp token structure; supported forms: /pattern/, /pattern/flags, /pattern1/!/pattern2/ (flags: i, m, x)" entry="%s"\n' \
      "$(sanitize_token "$1")" >&2
    return 10
  fi
  # An empty SECOND half (/x/!//) gets the same fatal posture as the //
  # empty-pattern arm above (an empty first half always begins the token
  # with //, so that arm already caught it): an empty pattern matches
  # every string, turning the construct into a rule whose match semantics
  # this validator refuses to vouch for.
  if [ "$_rx_dual" -eq 1 ] && [ -z "$_rx_p2" ]; then
    printf 'level=error msg="recipient restriction dual-form regexp has an empty pattern half (Postfix ends each pattern at the first unescaped /); an empty half matches every string, so the construct cannot mean what was configured; refusing to render it" entry="%s"\n' \
      "$(sanitize_token "$1")" >&2
    rm -f "$_rcpt_tmp"
    exit 2
  fi
  # Effective flag states, per-half compile probes, then the construct-level
  # universal-match (possibly-allow-all) guard — see each helper above for
  # the full semantics and policy grants.
  set_regexp_flag_states
  classify_regexp_halves
  reject_universal_construct "$1"
  emit_rcpt_line "$1 OK"
  return "$_rcpt_status"
}

# emit_recipient_rule ENTRY — classify one RECIPIENT_RESTRICTIONS token
# (leading-/ regexp-family construct, full address, or domain) and append
# its rendered rule via emit_rcpt_line. Any token STARTING with / routes to
# the regexp arm (which owns the full structure parse: plain, flags, dual);
# a mid-token slash without a leading slash is legal RFC 5321 atext and
# keeps its literal arm — john/doe@example.com is a correct address-arm
# literal, escaped and never warned. Shares the _rcpt_tmp contract with
# build_recipient_filter: fatal branches remove the temp file and exit 2.
# Returns 0 for an effective rule; the regexp arm is its case arm's last
# command, so it propagates emit_regexp_recipient_rule's ineffective
# status (10). The address arm's
# three deterministic never-match shapes (empty local part, empty domain,
# dot-after-@ — order-pinned so a bare @ classifies as empty-local) and the
# domain arm's two (slash-bearing token, leading dot) warn, still emit the
# rule line unchanged, and return 10 (ineffective) — same status-10 contract
# as the regexp arms, so an all-never-match list trips the zero-effective-
# rules guard while a mixed list still boots on its valid subset (2026-07
# decisions, extending the regexp-arm one: deterministic never-match domain
# and address shapes are also excluded from the effective count by explicit
# user decision; the warns themselves are unchanged shape hints, not load
# failures — Postfix still loads these lines, it just never matches them).
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
    /*) # leading slash: regexp-family (plain, /flags, or dual-pattern form)
      emit_regexp_recipient_rule "$1"
      ;;
    *@*) # full address: anchor both ends
      # Three deterministic never-match address shapes mirror the domain
      # arm's mechanism below (warn, still emit the rule line unchanged,
      # return 10 so the entry is excluded from the effective-rule count;
      # 2026-07 round-3 decision). The token is split on its LAST @;
      # classification order is PINNED — empty local part first, then
      # empty domain, then dot-after-@ — so a bare @ (both empty)
      # classifies as empty-local. The empty-local and empty-domain
      # shapes were probed live on Postfix 3.11.5 (the pinned version)
      # with strict_rfc821_envelopes = no: smtpd presents an empty local
      # part only in quoted form, so the anchored rule never matches a
      # recipient smtpd presents, and a domain-less recipient is rejected
      # before the access-map lookup — re-probe on a Postfix major bump.
      # The dot-after-@ shape needs no version caveat (DNS forbids an
      # empty label, so no deliverable address contains @.).
      _rcpt_status=0
      _local="${1%@*}"
      _domain="${1##*@}"
      if [ -z "$_local" ]; then
        printf 'level=warn msg="recipient restriction address has an empty local part; this anchored rule never matches a recipient smtpd presents" entry="%s"\n' \
          "$(sanitize_token "$1")" >&2
        _rcpt_status=10
      elif [ -z "$_domain" ]; then
        printf 'level=warn msg="recipient restriction address has an empty domain; Postfix rejects domain-less recipients before the access-map lookup, so this rule will never match any recipient" entry="%s"\n' \
          "$(sanitize_token "$1")" >&2
        _rcpt_status=10
      else
        case "$_domain" in
          .*)
            printf 'level=warn msg="recipient restriction address domain starts with a dot (no deliverable address contains @.); this rule will never match any recipient" entry="%s"\n' \
              "$(sanitize_token "$1")" >&2
            _rcpt_status=10
            ;;
        esac
      fi
      emit_escaped_literal_rule '/^' "$1"
      return "$_rcpt_status"
      ;;
    *) # domain-only: anchor the @-suffix
      # A domain can never contain a slash, so a slash-bearing token here
      # is almost certainly a mis-typed regexp literal (e.g. `foo/bar`
      # with its leading delimiter missing), and a leading-dot domain can never
      # match either (no address contains @.). Both are deterministic
      # never-match shapes: warn, still emit the rule line unchanged, but
      # return 10 (ineffective) so the entry no longer satisfies the
      # zero-effective-rules guard — same mechanism as the regexp arms
      # (2026-07 decision; the entry is still accepted, only its
      # effective-count status changed).
      _rcpt_status=0
      case "$1" in
        */*)
          printf 'level=warn msg="recipient restriction looks like a mis-typed regexp (a domain cannot contain /); this rule will never match any recipient" entry="%s"\n' \
            "$(sanitize_token "$1")" >&2
          _rcpt_status=10
          ;;
        .*)
          printf 'level=warn msg="recipient restriction domain starts with a dot (Postfix subdomain syntax is not supported by this regexp map; no address contains @.); this rule will never match any recipient" entry="%s"\n' \
            "$(sanitize_token "$1")" >&2
          _rcpt_status=10
          ;;
      esac
      emit_escaped_literal_rule '/@' "$1"
      return "$_rcpt_status"
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
    # expansion), every entry malformed (uncompilable halves warned above;
    # Postfix drops each at map-open) or structurally unparseable (warned
    # and suppressed above), or every entry a deterministic never-match domain or
    # address shape (warned above; Postfix loads the rule but no recipient
    # can ever match it). Without this guard the map's only live line is
    # `/.*/ REJECT`, Postfix rejects 100% of mail, and the healthcheck
    # still reports green.
    if [ "$_rule_count" -eq 0 ]; then
      printf 'level=error msg="RECIPIENT_RESTRICTIONS is non-empty but parsed zero effective rules (whitespace only, or every entry malformed or never-matching?); refusing to reject all mail"\n' >&2
      rm -f "$_rcpt_tmp"
      exit 2
    fi
    emit_rcpt_line '/.*/ REJECT'
    promote_rendered_file "$_rcpt_tmp" "$_rcpt_file" recipient_access
    # shellcheck disable=SC2034 # consumed by caller after sourcing
    SMTPD_RECIPIENT_RESTRICTIONS="check_recipient_access regexp:${_rcpt_file}, reject"
    # Count only EFFECTIVE operator-supplied allow rules (entries Postfix
    # will actually load AND that can match a real recipient;
    # warned-ineffective ones are excluded), never the
    # trailing /.*/ REJECT terminator — an internal implementation detail
    # that would confuse operators reading Loki.
    printf 'level=info msg="recipient filtering configured" rules=%d\n' \
      "$_rule_count" >&2
  else
    printf 'level=info msg="recipient filtering disabled; RECIPIENT_RESTRICTIONS is empty (all recipients from accepted networks are relayed)"\n' >&2
  fi
}
