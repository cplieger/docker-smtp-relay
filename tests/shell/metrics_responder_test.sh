#!/usr/bin/env bash
# metrics-responder.sh: the spawn(8) program METRICS_PORT runs for each scrape.
#
# Each case runs the shipped file as a process, as spawn(8) does: the request
# on stdin, the reply on stdout. date is stubbed on PATH (`+%s`, a fixed clock)
# and refuses any other argv; a postqueue stub records any call, because the
# responder must never read the queue itself. The image runs it under BusyBox
# ash, and the Dockerfile test stage runs it there again.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# Overridable so a red-check can point the suite at a mutated /tmp copy.
RESPONDER="${RESPONDER:-$REPO_ROOT/metrics-responder.sh}"
[ -f "$RESPONDER" ] || {
  printf 'harness error: no responder at %s\n' "$RESPONDER" >&2
  exit 1
}

STUB="$WORK/stub"
mkdir -p "$STUB"
cat >"$STUB/postqueue" <<'EOF'
#!/bin/sh
printf 'postqueue stub: called with %s\n' "$*" >>"$STUB_LOG"
exit 1
EOF
cat >"$STUB/date" <<'EOF'
#!/bin/sh
[ "$*" = "+%s" ] || { printf 'date stub: unexpected argv: %s\n' "$*" >>"$STUB_LOG"; exit 64; }
printf '4000\n'
EOF
chmod +x "$STUB/postqueue" "$STUB/date"

BUILD_INFO="$WORK/build-info"
printf 'version=v2.6.0\npostfix_version=3.11.7\n' >"$BUILD_INFO"
SUMMARY="$WORK/queue-summary"
MAX_AGE=60

# summary TIME -- a summary in the shape metrics-reader.sh writes, read at TIME.
summary() {
  {
    printf '%s\n' "$1"
    printf '# HELP smtp_relay_queue_messages Messages in each Postfix queue.\n'
    printf '# TYPE smtp_relay_queue_messages gauge\n'
    for q in active deferred hold incoming maildrop; do
      printf 'smtp_relay_queue_messages{queue="%s"} %d\n' "$q" "$([ "$q" = deferred ] && echo 2 || echo 0)"
    done
    printf '# HELP smtp_relay_queue_oldest_message_age_seconds Seconds since the oldest deferred message arrived, 0 when none is deferred.\n'
    printf '# TYPE smtp_relay_queue_oldest_message_age_seconds gauge\n'
    printf 'smtp_relay_queue_oldest_message_age_seconds{queue="deferred"} 3000\n'
  } >"$SUMMARY"
}

# scrape [REQUEST] -- runs the responder; the reply lands in $WORK/reply, its
# body in $WORK/body.
scrape() {
  : >"$WORK/stub.log"
  printf '%b' "${1:-GET /metrics HTTP/1.1\r\nHost: relay\r\nAccept: text/plain\r\n\r\n}" \
    | STUB_LOG="$WORK/stub.log" PATH="$STUB:$PATH" \
      sh "$RESPONDER" "$BUILD_INFO" "$SUMMARY" "$MAX_AGE" >"$WORK/reply"
  sed '1,/^\r$/d' "$WORK/reply" >"$WORK/body"
}

value() {
  awk -v s="$1" '$1 == s { print $2 }' "$WORK/body"
}

queue_series() {
  grep -c '^smtp_relay_queue_messages\|^smtp_relay_queue_oldest' "$WORK/body"
}

# --- 1. a fresh summary is served -------------------------------------------
summary 3990
scrape
[ -s "$WORK/body" ] || {
  printf 'harness error: the responder wrote no body\n%s\n' "$(cat "$WORK/reply")" >&2
  exit 1
}
[ ! -s "$WORK/stub.log" ] && ok "the responder calls date +%s only, never postqueue" \
  || no "stub argv" "$(cat "$WORK/stub.log")"
[ "$(head -1 "$WORK/reply")" = $'HTTP/1.1 200 OK\r' ] && ok "a /metrics scrape answers 200" \
  || no "status line" "$(head -1 "$WORK/reply")"
grep -qx $'Content-Type: text/plain; version=0.0.4; charset=utf-8\r' "$WORK/reply" \
  && ok "the reply is typed as text format 0.0.4" || no "content type" "$(cat "$WORK/reply")"
len=$(sed -n 's/^Content-Length: \([0-9]*\)\r$/\1/p' "$WORK/reply")
[ "$len" = "$(wc -c <"$WORK/body" | tr -d ' ')" ] && ok "Content-Length counts the body bytes" \
  || no "content length" "header $len, body $(wc -c <"$WORK/body")"
sed 1d "$SUMMARY" >"$WORK/want"
head -n "$(wc -l <"$WORK/want")" "$WORK/body" | cmp -s - "$WORK/want" \
  && ok "the summary's series are served as the reader wrote them, without its time line" \
  || no "summary passthrough" "$(cat "$WORK/body")"
! grep -qx 3990 "$WORK/body" && ok "the time line never reaches the exposition" || no "time line" "$(cat "$WORK/body")"
[ "$(value smtp_relay_queue_scrape_ok)" = 1 ] && ok "a summary 10 s old reports scrape_ok 1" \
  || no "scrape_ok fresh" "$(cat "$WORK/body")"
[ "$(value 'smtp_relay_build_info{version="v2.6.0",postfix_version="3.11.7"}')" = 1 ] \
  && ok "build_info carries both versions from the build-info file" || no "build_info" "$(cat "$WORK/body")"
for family in smtp_relay_queue_scrape_ok smtp_relay_build_info; do
  grep -qx "# TYPE $family gauge" "$WORK/body" && grep -q "^# HELP $family " "$WORK/body" \
    && ok "$family has HELP and TYPE gauge" || no "$family metadata" "$(cat "$WORK/body")"
done

# --- 2. the age bound, at its edge -------------------------------------------
summary $((4000 - MAX_AGE))
scrape
[ "$(value smtp_relay_queue_scrape_ok)" = 1 ] && [ "$(queue_series)" -eq 6 ] \
  && ok "a summary exactly $MAX_AGE s old is still fresh" || no "bound edge" "$(cat "$WORK/body")"

summary $((4000 - MAX_AGE - 1))
scrape
[ "$(value smtp_relay_queue_scrape_ok)" = 0 ] && ok "a summary older than $MAX_AGE s reports scrape_ok 0" \
  || no "stale" "$(cat "$WORK/body")"
[ "$(queue_series)" -eq 0 ] && ok "a stale summary serves no queue series, never an old count" \
  || no "stale series" "$(cat "$WORK/body")"
[ "$(value 'smtp_relay_build_info{version="v2.6.0",postfix_version="3.11.7"}')" = 1 ] \
  && ok "build_info survives a stale summary" || no "build_info when stale" "$(cat "$WORK/body")"

MAX_AGE=10
summary 3985
scrape
[ "$(value smtp_relay_queue_scrape_ok)" = 0 ] && ok "the bound is the argument master.cf passes, not a constant" \
  || no "bound argument" "$(cat "$WORK/body")"
MAX_AGE=60

# --- 3. no usable summary ------------------------------------------------------
rm -f "$SUMMARY"
scrape
[ "$(head -1 "$WORK/reply")" = $'HTTP/1.1 200 OK\r' ] && [ "$(value smtp_relay_queue_scrape_ok)" = 0 ] \
  && [ "$(queue_series)" -eq 0 ] \
  && ok "a missing summary answers 200 with scrape_ok 0 and no queue series" || no "missing summary" "$(cat "$WORK/reply")"

summary 'not-a-time'
scrape
[ "$(value smtp_relay_queue_scrape_ok)" = 0 ] && [ "$(queue_series)" -eq 0 ] \
  && ok "a summary whose first line is not a time reports scrape_ok 0" || no "bad time line" "$(cat "$WORK/body")"

: >"$SUMMARY"
scrape
[ "$(value smtp_relay_queue_scrape_ok)" = 0 ] && ok "an empty summary reports scrape_ok 0" \
  || no "empty summary" "$(cat "$WORK/body")"

# --- 4. the HTTP side -----------------------------------------------------------
summary 3990
scrape 'GET /metrics?debug=1 HTTP/1.1\r\n\r\n'
[ "$(head -1 "$WORK/reply")" = $'HTTP/1.1 200 OK\r' ] && ok "a query string still reaches /metrics" \
  || no "query string" "$(head -1 "$WORK/reply")"

scrape 'GET / HTTP/1.1\r\nHost: relay\r\n\r\n'
[ "$(head -1 "$WORK/reply")" = $'HTTP/1.1 404 Not Found\r' ] && ! grep -q smtp_relay "$WORK/reply" \
  && ok "any other path answers 404 with no metrics" || no "other path" "$(cat "$WORK/reply")"

# spawn(8) hands over a socket: a reply sent while request headers are still
# unread can be lost to the reset the close sends. From a regular file, what is
# left after the responder exits shows how far it read.
printf 'GET /metrics HTTP/1.1\r\nHost: relay\r\nAccept: text/plain\r\n\r\nafter-headers' >"$WORK/request"
(
  STUB_LOG="$WORK/stub.log" PATH="$STUB:$PATH" sh "$RESPONDER" "$BUILD_INFO" "$SUMMARY" "$MAX_AGE" >/dev/null
  cat >"$WORK/rest"
) <"$WORK/request"
[ "$(cat "$WORK/rest")" = after-headers ] && ok "the responder reads the request headers to their end" \
  || no "header drain" "left unread: $(cat "$WORK/rest")"

printf 'version=v2"x\\\npostfix_version=3.11.7\n' >"$BUILD_INFO"
scrape
grep -qx 'smtp_relay_build_info{version="v2x",postfix_version="3.11.7"} 1' "$WORK/body" \
  && ok "build_info drops quote and backslash bytes from a label value" || no "label sanitising" "$(cat "$WORK/body")"

report
