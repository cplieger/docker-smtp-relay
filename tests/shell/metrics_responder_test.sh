#!/usr/bin/env bash
# metrics-responder.sh: the spawn(8) program METRICS_PORT runs for each scrape.
#
# It is a whole program rather than a sourced function, so each case runs the
# shipped file as a process, as spawn(8) does: the request on stdin, the reply on
# stdout. Only the two commands that read the host are stubbed on PATH, and each
# stub refuses any argv but the one the responder must pass: postqueue (`-j`,
# replaying a fixture in the JSON shape postqueue(1) documents) and date (`+%s`,
# a fixed clock). The image runs it under BusyBox ash; this suite runs it under
# sh, and the Dockerfile test stage runs it again under ash.
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
[ "$*" = "-j" ] || { printf 'postqueue stub: unexpected argv: %s\n' "$*" >"$STUB_LOG"; exit 64; }
cat "$QUEUE_FIXTURE"
exit "${QUEUE_STATUS:-0}"
EOF
cat >"$STUB/date" <<'EOF'
#!/bin/sh
[ "$*" = "+%s" ] || { printf 'date stub: unexpected argv: %s\n' "$*" >"$STUB_LOG"; exit 64; }
printf '4000\n'
EOF
chmod +x "$STUB/postqueue" "$STUB/date"

BUILD_INFO="$WORK/build-info"
printf 'version=v2.6.0\npostfix_version=3.11.7\n' >"$BUILD_INFO"

# scrape FIXTURE STATUS [REQUEST] -- runs the responder; the reply lands in
# $WORK/reply, its body in $WORK/body.
scrape() {
  : >"$WORK/stub.log"
  printf '%b' "${3:-GET /metrics HTTP/1.1\r\nHost: relay\r\nAccept: text/plain\r\n\r\n}" \
    | QUEUE_FIXTURE=$1 QUEUE_STATUS=$2 STUB_LOG="$WORK/stub.log" PATH="$STUB:$PATH" \
      sh "$RESPONDER" "$BUILD_INFO" >"$WORK/reply"
  sed '1,/^\r$/d' "$WORK/reply" >"$WORK/body"
}

value() {
  awk -v s="$1" '$1 == s { print $2 }' "$WORK/body"
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

scrape "$WORK/two-deferred.json" 0
[ -s "$WORK/body" ] || {
  printf 'harness error: the responder wrote no body\n%s\n' "$(cat "$WORK/reply")" >&2
  exit 1
}
[ ! -s "$WORK/stub.log" ] && ok "the responder calls postqueue -j and date +%s only" \
  || no "stub argv" "$(cat "$WORK/stub.log")"
[ "$(head -1 "$WORK/reply")" = $'HTTP/1.1 200 OK\r' ] && ok "a /metrics scrape answers 200" \
  || no "status line" "$(head -1 "$WORK/reply")"
grep -qx $'Content-Type: text/plain; version=0.0.4; charset=utf-8\r' "$WORK/reply" \
  && ok "the reply is typed as text format 0.0.4" || no "content type" "$(cat "$WORK/reply")"
len=$(sed -n 's/^Content-Length: \([0-9]*\)\r$/\1/p' "$WORK/reply")
[ "$len" = "$(wc -c <"$WORK/body" | tr -d ' ')" ] && ok "Content-Length counts the body bytes" \
  || no "content length" "header $len, body $(wc -c <"$WORK/body")"
[ "$(value 'smtp_relay_queue_messages{queue="deferred"}')" = 2 ] \
  && [ "$(value 'smtp_relay_queue_messages{queue="active"}')" = 1 ] \
  && [ "$(value 'smtp_relay_queue_messages{queue="hold"}')" = 1 ] \
  && [ "$(value 'smtp_relay_queue_messages{queue="incoming"}')" = 0 ] \
  && [ "$(value 'smtp_relay_queue_messages{queue="maildrop"}')" = 0 ] \
  && ok "each queue is counted by its queue_name" || no "queue counts" "$(cat "$WORK/body")"
[ "$(value 'smtp_relay_queue_oldest_message_age_seconds{queue="deferred"}')" = 3000 ] \
  && ok "the oldest age is the clock minus the oldest deferred arrival, not an older held one" \
  || no "oldest age" "$(cat "$WORK/body")"
[ "$(value smtp_relay_queue_scrape_ok)" = 1 ] && ok "a read queue reports scrape_ok 1" \
  || no "scrape_ok" "$(cat "$WORK/body")"
[ "$(value 'smtp_relay_build_info{version="v2.6.0",postfix_version="3.11.7"}')" = 1 ] \
  && ok "build_info carries both versions from the build-info file" || no "build_info" "$(cat "$WORK/body")"
for family in smtp_relay_queue_messages smtp_relay_queue_oldest_message_age_seconds smtp_relay_queue_scrape_ok smtp_relay_build_info; do
  grep -qx "# TYPE $family gauge" "$WORK/body" && grep -q "^# HELP $family " "$WORK/body" \
    && ok "$family has HELP and TYPE gauge" || no "$family metadata" "$(cat "$WORK/body")"
done

scrape "$WORK/three-deferred.json" 0
[ "$(value 'smtp_relay_queue_messages{queue="deferred"}')" = 3 ] \
  && [ "$(value 'smtp_relay_queue_oldest_message_age_seconds{queue="deferred"}')" = 1500 ] \
  && ok "a second fixture moves the count and the age" || no "second fixture" "$(cat "$WORK/body")"

scrape "$WORK/empty.json" 0
[ "$(value 'smtp_relay_queue_messages{queue="deferred"}')" = 0 ] \
  && [ "$(value 'smtp_relay_queue_oldest_message_age_seconds{queue="deferred"}')" = 0 ] \
  && [ "$(value smtp_relay_queue_scrape_ok)" = 1 ] \
  && ok "an empty queue reads as zero with scrape_ok 1" || no "empty queue" "$(cat "$WORK/body")"

scrape "$WORK/two-deferred.json" 1
[ "$(value smtp_relay_queue_scrape_ok)" = 0 ] && ok "a failed postqueue -j reports scrape_ok 0" \
  || no "failed read" "$(cat "$WORK/body")"
! grep -q '^smtp_relay_queue_messages\|^smtp_relay_queue_oldest' "$WORK/body" \
  && ok "a failed read reports no queue series, never a partial count" || no "failed read series" "$(cat "$WORK/body")"
[ "$(value 'smtp_relay_build_info{version="v2.6.0",postfix_version="3.11.7"}')" = 1 ] \
  && ok "build_info survives a failed read" || no "build_info on failure" "$(cat "$WORK/body")"

scrape "$WORK/forged.json" 0
[ "$(value 'smtp_relay_queue_messages{queue="active"}')" = 1 ] \
  && [ "$(value 'smtp_relay_queue_messages{queue="deferred"}')" = 0 ] \
  && ok "an escaped key inside a sender is not counted" || no "forged key" "$(cat "$WORK/body")"

scrape "$WORK/empty.json" 0 'GET /metrics?debug=1 HTTP/1.1\r\n\r\n'
[ "$(head -1 "$WORK/reply")" = $'HTTP/1.1 200 OK\r' ] && ok "a query string still reaches /metrics" \
  || no "query string" "$(head -1 "$WORK/reply")"

scrape "$WORK/two-deferred.json" 0 'GET / HTTP/1.1\r\nHost: relay\r\n\r\n'
[ "$(head -1 "$WORK/reply")" = $'HTTP/1.1 404 Not Found\r' ] && ! grep -q smtp_relay "$WORK/reply" \
  && ok "any other path answers 404 with no metrics" || no "other path" "$(cat "$WORK/reply")"

# spawn(8) hands over a socket: a reply sent while request headers are still
# unread can be lost to the reset the close sends. From a regular file, what is
# left after the responder exits shows how far it read.
printf 'GET /metrics HTTP/1.1\r\nHost: relay\r\nAccept: text/plain\r\n\r\nafter-headers' >"$WORK/request"
(
  QUEUE_FIXTURE="$WORK/empty.json" STUB_LOG="$WORK/stub.log" PATH="$STUB:$PATH" sh "$RESPONDER" "$BUILD_INFO" >/dev/null
  cat >"$WORK/rest"
) <"$WORK/request"
[ "$(cat "$WORK/rest")" = after-headers ] && ok "the responder reads the request headers to their end" \
  || no "header drain" "left unread: $(cat "$WORK/rest")"

printf 'version=v2"x\\\npostfix_version=3.11.7\n' >"$BUILD_INFO"
scrape "$WORK/empty.json" 0
grep -qx 'smtp_relay_build_info{version="v2x",postfix_version="3.11.7"} 1' "$WORK/body" \
  && ok "build_info drops quote and backslash bytes from a label value" || no "label sanitising" "$(cat "$WORK/body")"

report
