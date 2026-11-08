#!/usr/bin/env bash
# How the run mode starts the METRICS_PORT queue reader, and which groups the
# reader and the spawn(8) responder end up holding.
#
# The reader gets postdrop as a supplementary group: BusyBox su takes a user's
# groups from /etc/group, and the Dockerfile lists smtp-metrics in postdrop.
# The responder must not: spawn(8) sets only the user's primary group
# (set_ugid.c, setgroups(1, &gid)), so it holds postdrop only if user= names it
# or it is smtp-metrics' primary group. Both sides are read from the shipped
# files at run time; the image smoke test reads the live processes.
# shellcheck disable=SC2015,SC2016,SC2034,SC2329
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

DOCKERFILE="${DOCKERFILE:-$REPO_ROOT/Dockerfile}"
[ -f "$DOCKERFILE" ] || {
  printf 'harness error: no Dockerfile at %s\n' "$DOCKERFILE" >&2
  exit 1
}

consts=$(extract_range '^readonly METRICS_SUMMARY=' '^readonly METRICS_SUMMARY_MAX_AGE=' "$WORK/consts.sh") || exit 1
# shellcheck disable=SC1090
. "$consts"
[ -n "${METRICS_SUMMARY:-}" ] && [ -n "${METRICS_READ_INTERVAL:-}" ] && [ -n "${METRICS_SUMMARY_MAX_AGE:-}" ] || {
  printf 'harness error: the METRICS_* constants did not load from %s\n' "$consts" >&2
  exit 1
}
load_function start_metrics_reader

su() {
  printf '%s\n' "$@" >"$ARGV"
  sleep 2
}

# --- 1. unset: no reader ------------------------------------------------------
ARGV="$WORK/argv-unset"
METRICS_PORT_VALUE=''
start_metrics_reader
wait
[ ! -e "$ARGV" ] && ok "with METRICS_PORT unset no reader starts" || no "unset" "su ran: $(cat "$ARGV")"

# --- 2. set: one reader, as smtp-metrics, in the background ------------------
ARGV="$WORK/argv-set"
METRICS_PORT_VALUE=9154
start=$(date +%s)
start_metrics_reader
returned=$(($(date +%s) - start))
wait
[ "$returned" -le 1 ] && ok "start_metrics_reader returns while the reader runs on" \
  || no "background" "returned after ${returned}s"
expected=$(printf '%s\n' -s /bin/sh smtp-metrics -c 'exec /usr/local/bin/metrics-reader.sh "$0" "$1"' \
  "$METRICS_SUMMARY" "$METRICS_READ_INTERVAL")
[ "$(cat "$ARGV")" = "$expected" ] \
  && ok "the reader runs through su as smtp-metrics with the summary path and interval" \
  || no "su argv" "$(cat "$ARGV")"
# -m and -p keep the caller's identity variables; -l clears the environment.
! grep -qx -- '-[lmp]' "$ARGV" && ok "su gets no option that changes how it sets the identity" \
  || no "su options" "$(cat "$ARGV")"

reached=$(
  set -euf
  su() { return 1; }
  start_metrics_reader
  wait || :
  printf reached
)
[ "$reached" = reached ] && ok "a reader that fails to start does not abort a set -euf shell" \
  || no "set -euf" "the shell stopped in start_metrics_reader"

# --- 3. the groups each side holds --------------------------------------------
grep -qE '(^|&& )addgroup smtp-metrics postdrop( |$)' "$DOCKERFILE" \
  && ok "the Dockerfile adds smtp-metrics to postdrop, which su gives the reader" \
  || no "reader group" "no 'addgroup smtp-metrics postdrop' in the Dockerfile"
primary=$(sed -n 's/.*adduser .*-G \([a-z]*\) smtp-metrics.*/\1/p' "$DOCKERFILE")
[ -n "$primary" ] && [ "$primary" != postdrop ] \
  && ok "smtp-metrics' primary group is $primary, so spawn(8) leaves the responder without postdrop" \
  || no "responder primary group" "adduser gives '${primary:-nothing}'"

load_function emit_metrics_service
METRICS_BLOCK_BEGIN='# begin'
METRICS_BLOCK_END='# end'
user_field=$(emit_metrics_service | grep -o 'user=[^ ]*')
[ "$user_field" = user=smtp-metrics ] && ok "the spawn(8) service names the user alone, with no group" \
  || no "spawn user" "got '$user_field'"
emit_metrics_service | grep -qF "argv=/usr/local/bin/metrics-responder.sh /usr/share/smtp-relay/build-info $METRICS_SUMMARY $METRICS_SUMMARY_MAX_AGE" \
  && ok "the responder serves the summary the reader writes, with the age bound" \
  || no "responder argv" "$(emit_metrics_service)"

# --- 4. the run mode starts it last, just before Postfix --------------------
run_src=$(extract_range '^  run)$' '^    ;;$' "$WORK/run_mode.sh") || exit 1
order=$(grep -nE '^ *(render_config|run_postfix_checks|log_startup|start_metrics_reader|exec postfix start-fg)$' "$run_src" \
  | sed 's/^[0-9]*: *//' | tr '\n' ' ')
[ "$order" = "render_config run_postfix_checks log_startup start_metrics_reader exec postfix start-fg " ] \
  && ok "run mode starts the reader after the startup checks and right before Postfix" \
  || no "run-mode order" "got '$order'"

report
