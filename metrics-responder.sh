#!/bin/sh
# Answers one HTTP request with the queue summary metrics-reader.sh writes, in
# the Prometheus text format. spawn(8) runs it per connection, with the client on
# stdin, stdout and stderr, no PATH (only export_environment is passed) and a
# time limit set in master.cf. $1 is the build-info file, `key=value` lines for
# version and postfix_version; $2 the summary; $3 its maximum age in seconds.
set -u
: "${PATH:=/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH
# stderr is the client's socket too: a diagnostic there would corrupt the reply.
exec 2>/dev/null

# summary_metrics NOW MAX_AGE -- stdin: the summary metrics-reader.sh wrote. Its
# first line is the time of the read; its series pass through only while that
# is at most MAX_AGE seconds before NOW.
summary_metrics() {
  awk -v now="$1" -v max="$2" '
    NR == 1 { t = $0; next }
    { lines[++n] = $0 }
    END {
      ok = (now - t <= max + 0)
      if (ok) for (i = 1; i <= n; i++) print lines[i]
      print "# HELP smtp_relay_queue_scrape_ok 1 when the queue reader read the queue recently enough, 0 when its summary is stale or missing."
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
  # The reader replaces the summary by rename, so one open sees one whole
  # summary. A missing one reads as stale.
  _summary=/dev/null
  [ ! -r "$2" ] || _summary=$2
  _body="$(summary_metrics "$(date +%s)" "$3" <"$_summary")
$(build_info "$1")
"
  respond '200 OK' 'text/plain; version=0.0.4; charset=utf-8' "$_body"
}

main "$@"
