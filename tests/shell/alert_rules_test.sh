#!/usr/bin/env bash
# alerts/: the alert names the rule files define, and the series the PromQL
# rules read, checked against what the shipped metrics-responder.sh prints.
#
# A PromQL rule over a series the responder no longer prints never fires and
# never errors, so each metric name in alerts/promql.yaml (functions, keywords
# and `up`, which Prometheus writes for every scrape, aside) must appear as a
# sample in a real scrape, with every `label="value"` matcher the rule uses. The
# scrape runs the shipped responder over a postqueue stub holding one message in
# every queue. KNOWN lists every alert name ever released, so adding or dropping
# a condition is a decision made in this file.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

PROMQL="$REPO_ROOT/alerts/promql.yaml"
LOGQL="$REPO_ROOT/alerts/logql.yaml"
RESPONDER="$REPO_ROOT/metrics-responder.sh"
for f in "$PROMQL" "$LOGQL" "$RESPONDER"; do
  [ -f "$f" ] || {
    printf 'harness error: missing %s\n' "$f" >&2
    exit 1
  }
done

# Alert name -> the file that holds it now, or `removed: <successor>`.
KNOWN='SmtpRelayMailStuck promql.yaml logql.yaml
SmtpRelayMailBounced logql.yaml
SmtpRelayDown promql.yaml
SmtpRelayDeliveryFailing removed: SmtpRelayMailStuck and SmtpRelayMailBounced'

defined() {
  sed -n 's/^ *- alert: *\([A-Za-z0-9]*\) *$/\1/p' "$1"
}

for file in promql.yaml logql.yaml; do
  for alert in $(defined "$REPO_ROOT/alerts/$file"); do
    entry=$(printf '%s\n' "$KNOWN" | awk -v a="$alert" '$1 == a')
    case "$entry" in
      '') no "$alert in $file" "not in KNOWN; add it with the file that holds it" ;;
      *' removed: '*) no "$alert in $file" "KNOWN records it as removed" ;;
      *" $file"*) ok "$alert is defined in $file, as KNOWN records" ;;
      *) no "$alert in $file" "KNOWN does not place it in $file: $entry" ;;
    esac
  done
done
while read -r alert where; do
  case "$where" in
    removed:*) continue ;;
  esac
  for file in $where; do
    defined "$REPO_ROOT/alerts/$file" | grep -qx "$alert" && ok "KNOWN's $alert is still in $file" \
      || no "$alert" "KNOWN places it in $file, which no longer defines it"
  done
done <<<"$KNOWN"

STUB="$WORK/stub"
mkdir -p "$STUB"
cat >"$STUB/postqueue" <<'EOF'
#!/bin/sh
for q in active deferred hold incoming maildrop; do
  printf '{"queue_name": "%s", "queue_id": "4F1A2B3C4D", "arrival_time": 1000, "sender": "app@example.com", "recipients": []}\n' "$q"
done
EOF
chmod +x "$STUB/postqueue"
printf 'version=v0.0.0\npostfix_version=3.11.7\n' >"$WORK/build-info"
printf 'GET /metrics HTTP/1.1\r\n\r\n' | PATH="$STUB:$PATH" sh "$RESPONDER" "$WORK/build-info" \
  | sed '1,/^\r$/d' | grep -v '^#' >"$WORK/samples"
[ -s "$WORK/samples" ] || {
  printf 'harness error: the responder printed no samples\n' >&2
  exit 1
}

# Every expr, one per line: an inline value, or a `|` block up to the next key.
awk '
  /^ *expr: *[|>]-? *$/ { block = 1; buf = ""; next }
  /^ *expr: / { sub(/^ *expr: */, ""); print; next }
  block && /^ *[a-z_]+:/ { print buf; block = 0; next }
  block { buf = buf " " $0 }
' "$PROMQL" >"$WORK/exprs"
[ -s "$WORK/exprs" ] || {
  printf 'harness error: no expr read from %s\n' "$PROMQL" >&2
  exit 1
}

# Selectors as `name{matchers}` or a bare name: label lists of by/on/ignoring/
# group_* and ranges are cut, then any identifier followed by `(` is a function.
awk '
  {
    e = $0
    gsub(/(by|without|on|ignoring|group_left|group_right) *[(][^)]*[)]/, " ", e)
    gsub(/\[[^]]*\]/, " ", e)
    while (match(e, /[a-zA-Z_:][a-zA-Z0-9_:]*( *[{][^}]*[}])?/)) {
      tok = substr(e, RSTART, RLENGTH)
      rest = substr(e, RSTART + RLENGTH)
      e = rest
      if (rest ~ /^ *[(]/) continue
      name = tok
      sub(/ *[{].*/, "", name)
      if (name ~ /^(and|or|unless|bool|offset|up)$/) continue
      matchers = ""
      if (tok ~ /[{]/) { matchers = tok; sub(/^[^{]*[{]/, "", matchers); sub(/[}]$/, "", matchers) }
      print name "\t" matchers
    }
  }
' "$WORK/exprs" | sort -u >"$WORK/selectors"
[ -s "$WORK/selectors" ] || {
  printf 'harness error: no series read from the PromQL rules\n' >&2
  exit 1
}

while IFS=$'\t' read -r name matchers; do
  lines=$(grep -E "^$name([{ ])" "$WORK/samples" || true)
  if [ -z "$lines" ]; then
    no "$name" "a PromQL rule reads it, but the responder prints no such sample"
    continue
  fi
  missing=''
  IFS=',' read -ra pairs <<<"$matchers"
  for pair in "${pairs[@]}"; do
    pair=${pair// /}
    case "$pair" in
      '' | *'!='* | *'=~'*) continue ;;
    esac
    printf '%s\n' "$lines" | grep -qF -- "$pair" || missing="$missing $pair"
  done
  [ -z "$missing" ] && ok "the responder prints $name{${matchers}} that a PromQL rule reads" \
    || no "$name" "no sample carries$missing"
done <"$WORK/selectors"

report
