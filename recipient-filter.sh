#!/bin/sh
# recipient-filter.sh — recipient-filtering logic sourced by entrypoint.sh.
# Reads RECIPIENT_RESTRICTIONS (already validated) and sets
# SMTPD_RECIPIENT_RESTRICTIONS for main.cf generation.
#
# The map itself is rendered by smtp-recipient-render (a C helper on PATH,
# source at smtp-recipient-render.c, installed at /usr/local/bin in the
# image). It reads the whole RECIPIENT_RESTRICTIONS value ONCE and writes the
# complete recipient_access content in one process, atomically. Every
# classification rule, warning, refusal, exit code and rendered byte lives
# there — including POSIX literal escaping, the regexp_table(5) structure
# parse (plain, /flags, and dual /P1/!/P2/ forms), the i/m/x flag toggles and
# their BRE-vs-ERE compile probes, the universal-match safety probes, and the
# effective-rule count. Its header documents the port; validate.sh's header
# carries the Tier 1/2/3 policy that decides which of those inputs are fatal.
#
# This file replaced a per-rule shell loop that spawned external processes per
# entry (one sed per literal; one awk plus two compile greps plus one or two
# safety greps per regexp, six to nine for a dual form) — ~1.42 ms per literal
# and ~4.27 ms per regexp on the maintainer's host, linear in the entry count,
# on the startup path before `exec postfix start-fg` and with no deadline. The
# per-rule path is gone, not kept as a fallback: two renderers for one map is
# two contracts to keep in step, and a silent fallback would hide a missing
# helper until an operator wondered why a refusal never fired.

# The renderer's name on PATH. entrypoint.sh's validation section owns the
# input bound the renderer relies on (byte length and entry count); the
# renderer re-checks both so it is safe to run standalone.
readonly RECIPIENT_RENDER_BIN=smtp-recipient-render

# build_recipient_filter — builds $CONF_DIR/recipient_access from
# RECIPIENT_RESTRICTIONS and sets SMTPD_RECIPIENT_RESTRICTIONS.
# Must be called (not subshelled) so the variable is visible to the caller.
# The renderer writes to a temp file in CONF_DIR and renames it into place
# only once the complete artifact is written, so Postfix never sees a partial
# map and every failure path is a structured level=error. Its exit status is
# the entrypoint's own contract — 2 for a config-validation refusal, 1 for a
# runtime failure — so it is propagated verbatim rather than collapsed.
build_recipient_filter() {
  # shellcheck disable=SC2034 # consumed by caller after sourcing
  SMTPD_RECIPIENT_RESTRICTIONS="permit_mynetworks, reject"

  if [ -n "$RECIPIENT_RESTRICTIONS" ]; then
    _rcpt_file="${CONF_DIR}/recipient_access"
    # Invoked as a condition so a refusal is not swallowed by set -e before
    # the status can be inspected and re-raised.
    _rcpt_status=0
    "$RECIPIENT_RENDER_BIN" "$CONF_DIR" "$RECIPIENT_RESTRICTIONS" \
      || _rcpt_status=$?
    if [ "$_rcpt_status" -eq 127 ]; then
      # A missing renderer is a broken image, not a bad config: name it
      # explicitly instead of surfacing the shell's bare "not found" as the
      # container's exit status. The renderer never exits 127 itself.
      printf 'level=error msg="recipient map renderer not found on PATH; the image is incomplete" helper=%s\n' \
        "$RECIPIENT_RENDER_BIN" >&2
      exit 1
    fi
    if [ "$_rcpt_status" -ne 0 ]; then
      exit "$_rcpt_status"
    fi
    # shellcheck disable=SC2034 # consumed by caller after sourcing
    SMTPD_RECIPIENT_RESTRICTIONS="check_recipient_access regexp:${_rcpt_file}, reject"
  else
    printf 'level=info msg="recipient filtering disabled; RECIPIENT_RESTRICTIONS is empty (all recipients from accepted networks are relayed)"\n' >&2
  fi
}
