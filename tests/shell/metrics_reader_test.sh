#!/usr/bin/env bash
# metrics-reader.sh: the background process METRICS_PORT starts, which writes a
# queue summary for the responder to serve.
#
# Each case runs the shipped file as a process. postqueue, date and sleep are
# stubbed on PATH and refuse any argv but the one the reader must pass. The sleep
# stub ends the run: on its Nth call it sends TERM to the reader, the signal
# Postfix's master sends every process at stop. The image runs it under BusyBox
# ash; the Dockerfile test stage runs it there again.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# Overridable so a red-check can point the suite at a mutated /tmp copy.
READER="${READER:-$REPO_ROOT/metrics-reader.sh}"
[ -f "$READER" ] || {
  printf 'harness error: no reader at %s\n' "$READER" >&2
  exit 1
}

STUB="$WORK/stub"
mkdir -p "$STUB"
# PLAN holds one `status fixture` line per postqueue call, in order.
cat >"$STUB/postqueue" <<'EOF'
#!/bin/sh
[ "$*" = "-j" ] || { printf 'postqueue stub: unexpected argv: %s\n' "$*" >>"$STUB_LOG"; exit 64; }
n=$(($(cat "$CALLS/postqueue" 2>/dev/null || echo 0) + 1))
printf '%s\n' "$n" >"$CALLS/postqueue"
set -- $(sed -n "${n}p" "$PLAN")
[ -n "${2:-}" ] && cat "$2"
exit "${1:-0}"
EOF
cat >"$STUB/date" <<'EOF'
#!/bin/sh
[ "$*" = "+%s" ] || { printf 'date stub: unexpected argv: %s\n' "$*" >>"$STUB_LOG"; exit 64; }
printf '4000\n'
EOF
cat >"$STUB/sleep" <<'EOF'
#!/bin/sh
[ "$*" = "$WANT_INTERVAL" ] || { printf 'sleep stub: unexpected argv: %s\n' "$*" >>"$STUB_LOG"; kill -15 "$PPID"; exit 64; }
n=$(($(cat "$CALLS/sleep" 2>/dev/null || echo 0) + 1))
printf '%s\n' "$n" >"$CALLS/sleep"
[ -n "${SUMMARY_AT:-}" ] && cp "$SUMMARY_FILE" "$SUMMARY_AT.$n" 2>/dev/null
# Self-limited, so a reader that stops honouring TERM fails instead of looping.
if [ "$n" -ge "$STOP_AT" ] || [ "$n" -gt 20 ]; then
  kill -15 "$PPID"
fi
exit 0
EOF
chmod +x "$STUB/postqueue" "$STUB/date" "$STUB/sleep"

# run_reader STOP_AT PLAN-LINES... -- runs the reader until its STOP_AT-th sleep,
# so it makes STOP_AT-1 passes. Sets RC, and leaves the log in $CASE/log.
run_reader() {
  CASE=$(mktemp -d "$WORK/case.XXXXXX")
  CALLS="$CASE/calls"
  mkdir -p "$CALLS" "$CASE/run"
  SUMMARY="$CASE/run/queue-summary"
  STOP_AT=$1
  shift
  printf '%s\n' "$@" >"$CASE/plan"
  : >"$CASE/stub.log"
  [ -z "${PRESEED:-}" ] || printf '%s\n' "$PRESEED" >"$SUMMARY"
  RC=0
  # The outer stderr only carries bash's own "Terminated" notice.
  (
    CALLS=$CALLS PLAN="$CASE/plan" STUB_LOG="$CASE/stub.log" STOP_AT=$STOP_AT \
      WANT_INTERVAL=15 SUMMARY_FILE="$SUMMARY" SUMMARY_AT="${SUMMARY_AT:-}" PATH="$STUB:$PATH" \
      timeout -k 2 20 sh "$READER" "$SUMMARY" 15 2>"$CASE/log" || exit $?
  ) 2>/dev/null || RC=$?
}

value() {
  awk -v s="$1" '$1 == s { print $2 }' "$2"
}

q() {
  printf '{"queue_name": "%s", "queue_id": "%s", "arrival_time": %s, "message_size": 512, "forced_expire": false, "sender": "%s", "recipients": [{"address": "ops@example.com"}]}\n' "$@"
}

{
  q deferred 4F1A2B3C4D 1000 app@example.com
  q deferred 5A1A2B3C4D 1500 app@example.com
  q active 6B1A2B3C4D 3900 app@example.com
  q hold 7C1A2B3C4D 500 app@example.com
} >"$WORK/two-deferred.json"
{
  q deferred 4F1A2B3C4D 2500 app@example.com
  q deferred 5A1A2B3C4D 3000 app@example.com
  q deferred 6B1A2B3C4D 3500 app@example.com
} >"$WORK/three-deferred.json"
: >"$WORK/empty.json"
# A sender holding the key bytes: JSON escapes its quotes, so only the real
# queue_name member may count.
q active 8D1A2B3C4D 3990 'x\"queue_name\": \"deferred\", \"arrival_time\": 1@example.com' >"$WORK/forged.json"

# --- 1. one pass writes the summary -----------------------------------------
run_reader 2 "0 $WORK/two-deferred.json"
[ -s "$SUMMARY" ] || {
  printf 'harness error: the reader wrote no summary (rc=%s)\n%s\n%s\n' "$RC" "$(cat "$CASE/log")" "$(cat "$CASE/stub.log")" >&2
  exit 1
}
[ "$RC" -eq 143 ] && ok "the reader ends on TERM, the signal Postfix's master sends at stop" \
  || no "TERM" "rc=$RC"
[ ! -s "$CASE/stub.log" ] && ok "the reader calls postqueue -j, date +%s and sleep with its interval only" \
  || no "stub argv" "$(cat "$CASE/stub.log")"
[ "$(cat "$CALLS/postqueue")" = 1 ] && ok "the reader sleeps before its first pass, then reads once per interval" \
  || no "pass count" "postqueue ran $(cat "$CALLS/postqueue") times for 2 sleeps"
[ "$(head -n 1 "$SUMMARY")" = 4000 ] && ok "the summary's first line is the time of the read" \
  || no "summary time" "$(head -n 1 "$SUMMARY")"
[ "$(value 'smtp_relay_queue_messages{queue="deferred"}' "$SUMMARY")" = 2 ] \
  && [ "$(value 'smtp_relay_queue_messages{queue="active"}' "$SUMMARY")" = 1 ] \
  && [ "$(value 'smtp_relay_queue_messages{queue="hold"}' "$SUMMARY")" = 1 ] \
  && [ "$(value 'smtp_relay_queue_messages{queue="incoming"}' "$SUMMARY")" = 0 ] \
  && [ "$(value 'smtp_relay_queue_messages{queue="maildrop"}' "$SUMMARY")" = 0 ] \
  && ok "each queue is counted by its queue_name" || no "queue counts" "$(cat "$SUMMARY")"
[ "$(value 'smtp_relay_queue_oldest_message_age_seconds{queue="deferred"}' "$SUMMARY")" = 3000 ] \
  && ok "the oldest age is the clock minus the oldest deferred arrival, not an older held one" \
  || no "oldest age" "$(cat "$SUMMARY")"
for family in smtp_relay_queue_messages smtp_relay_queue_oldest_message_age_seconds; do
  grep -qx "# TYPE $family gauge" "$SUMMARY" && grep -q "^# HELP $family " "$SUMMARY" \
    && ok "$family has HELP and TYPE gauge" || no "$family metadata" "$(cat "$SUMMARY")"
done
! grep -q 'scrape_ok\|build_info\|example.com\|4F1A2B3C4D' "$SUMMARY" \
  && ok "the summary holds only the queue series, with no address or queue id" || no "summary content" "$(cat "$SUMMARY")"
[ "$(ls -A "$CASE/run")" = queue-summary ] && ok "a pass leaves no raw queue listing or temporary file beside the summary" \
  || no "leftover files" "$(ls -A "$CASE/run")"
[ "$(stat -c %a "$SUMMARY")" = 600 ] && ok "the summary is readable by its own user only" \
  || no "summary mode" "$(stat -c %a "$SUMMARY")"
[ ! -s "$CASE/log" ] && ok "a successful pass logs nothing" || no "quiet pass" "$(cat "$CASE/log")"

# --- 2. a second pass replaces the summary ----------------------------------
SUMMARY_AT="$WORK/at" run_reader 3 "0 $WORK/two-deferred.json" "0 $WORK/three-deferred.json"
[ "$(value 'smtp_relay_queue_messages{queue="deferred"}' "$WORK/at.2")" = 2 ] \
  && [ "$(value 'smtp_relay_queue_messages{queue="deferred"}' "$SUMMARY")" = 3 ] \
  && [ "$(value 'smtp_relay_queue_oldest_message_age_seconds{queue="deferred"}' "$SUMMARY")" = 1500 ] \
  && ok "each pass replaces the summary with the new count and age" || no "second pass" "$(cat "$SUMMARY")"
SUMMARY_AT=''

run_reader 2 "0 $WORK/empty.json"
[ "$(value 'smtp_relay_queue_messages{queue="deferred"}' "$SUMMARY")" = 0 ] \
  && [ "$(value 'smtp_relay_queue_oldest_message_age_seconds{queue="deferred"}' "$SUMMARY")" = 0 ] \
  && ok "an empty queue reads as zero" || no "empty queue" "$(cat "$SUMMARY")"

run_reader 2 "0 $WORK/forged.json"
[ "$(value 'smtp_relay_queue_messages{queue="active"}' "$SUMMARY")" = 1 ] \
  && [ "$(value 'smtp_relay_queue_messages{queue="deferred"}' "$SUMMARY")" = 0 ] \
  && ok "an escaped key inside a sender is not counted" || no "forged key" "$(cat "$SUMMARY")"

# --- 3. a summary from an earlier start is never served ---------------------
PRESEED='3999' run_reader 1
[ ! -e "$SUMMARY" ] && ok "the reader removes a summary left by an earlier start before it sleeps" \
  || no "stale summary" "still there: $(cat "$SUMMARY")"

# --- 4. a failed read keeps the last summary and says so once ----------------
SUMMARY_AT="$WORK/fail" run_reader 5 "0 $WORK/two-deferred.json" "1 $WORK/three-deferred.json" "75 $WORK/three-deferred.json" "0 $WORK/three-deferred.json"
cmp -s "$WORK/fail.2" "$WORK/fail.4" \
  && [ "$(value 'smtp_relay_queue_messages{queue="deferred"}' "$WORK/fail.4")" = 2 ] \
  && ok "a failed postqueue -j leaves the last good summary in place, never a partial one" \
  || no "failed read" "after the failures: $(cat "$WORK/fail.4" 2>/dev/null)"
[ "$(value 'smtp_relay_queue_messages{queue="deferred"}' "$SUMMARY")" = 3 ] \
  && ok "the next good read replaces it" || no "recovery" "$(cat "$SUMMARY")"
[ "$(wc -l <"$CASE/log")" -eq 2 ] \
  && sed -n 1p "$CASE/log" | grep -q '^level=warn msg="METRICS_PORT queue reader cannot read the queue; .*" status=1$' \
  && sed -n 2p "$CASE/log" | grep -qx 'level=info msg="METRICS_PORT queue reader reads the queue again"' \
  && ok "two failures in a row log one warning with the first status, and the recovery one info line" \
  || no "failure log" "$(cat "$CASE/log")"
[ "$(ls -A "$CASE/run")" = queue-summary ] && ok "a failed pass leaves no raw queue listing behind" \
  || no "leftover files after failure" "$(ls -A "$CASE/run")"
SUMMARY_AT=''

# --- 5. TERM ends the reader while it sleeps --------------------------------
# A real sleep this time: dash and ash keep the default TERM action only while
# the script installs no trap, and that is what lets master's TERM end it.
cat >"$STUB/sleep" <<'EOF'
#!/bin/sh
printf '%s\n' "$$" >"$SLEEP_PID"
exec /bin/sleep "$@"
EOF
chmod +x "$STUB/sleep"
CASE=$(mktemp -d "$WORK/case.XXXXXX")
mkdir -p "$CASE/run"
SLEEP_PID="$CASE/sleep.pid" PATH="$STUB:$PATH" sh "$READER" "$CASE/run/queue-summary" 30 2>"$CASE/log" &
reader=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$CASE/sleep.pid" ] && break
  /bin/sleep 0.1
done
[ -s "$CASE/sleep.pid" ] || {
  printf 'harness error: the reader never reached its sleep\n' >&2
  kill -9 "$reader" 2>/dev/null
  exit 1
}
kill -15 "$reader"
# Bounded, so a reader that ignores TERM fails here instead of hanging the suite.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  kill -0 "$reader" 2>/dev/null || break
  /bin/sleep 0.1
done
alive=0
kill -0 "$reader" 2>/dev/null && alive=1 && kill -9 "$reader"
RC=0
wait "$reader" 2>/dev/null || RC=$?
kill -9 "$(cat "$CASE/sleep.pid")" 2>/dev/null
[ "$alive" -eq 0 ] && [ "$RC" -eq 143 ] \
  && ok "a TERM during the 30 s sleep ends the reader within 2 s" \
  || no "TERM while sleeping" "rc=$RC, still running after 2 s: $alive"

report
