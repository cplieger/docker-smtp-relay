#!/bin/sh
# Writes a summary of the Postfix queue to $1 every $2 seconds, for
# metrics-responder.sh to serve. entrypoint.sh starts it when METRICS_PORT is
# set, as smtp-metrics with the supplementary group postdrop, which postqueue
# needs to reach public/showq: no-new-privileges ignores postqueue's setgid bit.
# Nothing restarts it. It installs no TERM trap, so the TERM Postfix's master
# sends every process at stop ends it.
set -u
# The raw listing holds sender and recipient addresses.
umask 077

readonly SUMMARY="$1"
readonly INTERVAL="$2"
readonly RAW="$SUMMARY.raw"
readonly NEXT="$SUMMARY.next"
# A pass must end well inside the responder's age bound even when showq hangs.
readonly POSTQUEUE_TIMEOUT=10

# queue_summary NOW -- stdin: `postqueue -j` output. The first line is NOW, which
# the responder ages. A JSON string escapes its quotes, so no sender or recipient
# can forge the `"queue_name": "` key (postqueue(1)).
queue_summary() {
  awk -v now="$1" '
    match($0, /"queue_name": *"[a-z]+"/) {
      q = substr($0, RSTART, RLENGTH)
      sub(/^"queue_name": *"/, "", q)
      sub(/"$/, "", q)
      count[q]++
      if (q == "deferred" && match($0, /"arrival_time": *[0-9]+/)) {
        t = substr($0, RSTART, RLENGTH)
        sub(/^"arrival_time": */, "", t)
        if (oldest == "" || t + 0 < oldest + 0) oldest = t
      }
    }
    END {
      print now
      print "# HELP smtp_relay_queue_messages Messages in each Postfix queue."
      print "# TYPE smtp_relay_queue_messages gauge"
      n = split("active deferred hold incoming maildrop", names, " ")
      for (i = 1; i <= n; i++) printf "smtp_relay_queue_messages{queue=\"%s\"} %d\n", names[i], count[names[i]]
      age = (oldest == "") ? 0 : now - oldest
      print "# HELP smtp_relay_queue_oldest_message_age_seconds Seconds since the oldest deferred message arrived, 0 when none is deferred."
      print "# TYPE smtp_relay_queue_oldest_message_age_seconds gauge"
      printf "smtp_relay_queue_oldest_message_age_seconds{queue=\"deferred\"} %d\n", age
    }'
}

# read_queue -- one pass. The summary is replaced by mv only after postqueue -j
# exited 0, so the responder never serves a failed or half-written read.
read_queue() {
  _rq_status=0
  timeout -k 2 "$POSTQUEUE_TIMEOUT" postqueue -j >"$RAW" 2>/dev/null || _rq_status=$?
  if [ "$_rq_status" -eq 0 ]; then
    if queue_summary "$(date +%s)" <"$RAW" >"$NEXT"; then
      mv -f "$NEXT" "$SUMMARY" || _rq_status=1
    else
      _rq_status=1
    fi
  fi
  rm -f "$RAW" "$NEXT"
  return "$_rq_status"
}

# The first pass waits one interval: this process starts just before Postfix,
# and showq answers only once master is up.
main() {
  rm -f "$SUMMARY"
  _failing=0
  while :; do
    sleep "$INTERVAL"
    _status=0
    read_queue || _status=$?
    if [ "$_status" -eq 0 ]; then
      if [ "$_failing" -eq 1 ]; then
        printf 'level=info msg="METRICS_PORT queue reader reads the queue again"\n' >&2
      fi
      _failing=0
    elif [ "$_failing" -eq 0 ]; then
      printf 'level=warn msg="METRICS_PORT queue reader cannot read the queue; scrapes report smtp_relay_queue_scrape_ok 0 once its last summary is stale" status=%d\n' "$_status" >&2
      _failing=1
    fi
  done
}

main
