#!/bin/sh
# Answers one HTTP request with the Postfix queue in the Prometheus text format.
# spawn(8) runs it per connection, with the client on stdin, stdout and stderr,
# no PATH (only export_environment is passed) and a time limit set in master.cf.
# $1 is the build-info file, `key=value` lines for version and postfix_version.
set -u
: "${PATH:=/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH
# stderr is the client's socket too: a diagnostic there would corrupt the reply.
exec 2>/dev/null

readonly SCRAPE_OK_MARKER='smtp-relay-scrape-ok'

# queue_lines -- `postqueue -j` output, then SCRAPE_OK_MARKER only if it exited 0,
# so queue_metrics never reports a failed read as an empty queue.
queue_lines() {
  postqueue -j && printf '%s\n' "$SCRAPE_OK_MARKER"
}

# queue_metrics NOW -- stdin: queue_lines. A JSON string escapes its quotes, so
# no sender or recipient can forge the `"queue_name": "` key (postqueue(1)).
queue_metrics() {
  awk -v now="$1" -v marker="$SCRAPE_OK_MARKER" '
    $0 == marker { ok = 1; next }
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
      if (ok) {
        print "# HELP smtp_relay_queue_messages Messages in each Postfix queue."
        print "# TYPE smtp_relay_queue_messages gauge"
        n = split("active deferred hold incoming maildrop", names, " ")
        for (i = 1; i <= n; i++) printf "smtp_relay_queue_messages{queue=\"%s\"} %d\n", names[i], count[names[i]]
        age = (oldest == "") ? 0 : now - oldest
        print "# HELP smtp_relay_queue_oldest_message_age_seconds Seconds since the oldest deferred message arrived, 0 when none is deferred."
        print "# TYPE smtp_relay_queue_oldest_message_age_seconds gauge"
        printf "smtp_relay_queue_oldest_message_age_seconds{queue=\"deferred\"} %d\n", age
      }
      print "# HELP smtp_relay_queue_scrape_ok 1 when postqueue -j read the queue, 0 when it failed."
      print "# TYPE smtp_relay_queue_scrape_ok gauge"
      printf "smtp_relay_queue_scrape_ok %d\n", ok
    }'
}

# build_info FILE -- label values keep only version characters, so a stray quote
# or backslash cannot break the exposition.
build_info() {
  awk -F= '
    $1 == "version" || $1 == "postfix_version" { v = $2; gsub(/[^A-Za-z0-9._+-]/, "", v); info[$1] = v }
    END {
      print "# HELP smtp_relay_build_info The image version and its Postfix version."
      print "# TYPE smtp_relay_build_info gauge"
      printf "smtp_relay_build_info{version=\"%s\",postfix_version=\"%s\"} 1\n", info["version"], info["postfix_version"]
    }' "$1"
}

# respond STATUS CONTENT_TYPE BODY
respond() {
  _len=$(printf '%s' "$3" | wc -c)
  printf 'HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s' \
    "$1" "$2" "$((_len))" "$3"
}

main() {
  _cr=$(printf '\r')
  IFS= read -r _request || return 0
  _request=${_request%"$_cr"}
  # The headers are read to their end before replying: closing a socket with
  # unread input sends a reset, which can discard the reply at the client.
  while IFS= read -r _header; do
    _header=${_header%"$_cr"}
    [ -n "$_header" ] || break
  done
  _target=${_request#* }
  _target=${_target%% *}
  case "${_target%%\?*}" in
    /metrics) ;;
    *)
      respond '404 Not Found' 'text/plain; charset=utf-8' 'only /metrics is served
'
      return 0
      ;;
  esac
  _body="$(queue_lines | queue_metrics "$(date +%s)")
$(build_info "$1")
"
  respond '200 OK' 'text/plain; version=0.0.4; charset=utf-8' "$_body"
}

main "$@"
