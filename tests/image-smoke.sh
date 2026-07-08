#!/bin/sh
# Runtime image smoke test for docker-smtp-relay. Invoked by the central CI
# docker job:
#   sh tests/image-smoke.sh <image-ref>
#
# Waits for the container's own HEALTHCHECK (nc 127.0.0.1 25 expecting a 220
# banner) to report "healthy". This proves the thing the build-time golden test
# (tests/render-test.sh) cannot: that the Postfix DAEMON actually starts and
# serves in the assembled image. render-test only runs the entrypoint in
# `render` mode (validate + write main.cf, no Postfix); this exercises the
# default `run` path -> exec postfix start-fg -> smtpd binds :25 and answers
# 220. The two are complementary (config renders vs the daemon serves).
#
# RELAY_HOST is the one required env var (entrypoint validation exits 2 without
# it); a valid dummy hostname satisfies it. No live upstream is needed: the
# startup probe of RELAY_HOST is fail-soft (logs and continues), and the smtpd
# 220 banner does not depend on upstream relay reachability, so Postfix binds
# :25 and reports healthy regardless.
set -eu

IMG="${1:?usage: image-smoke.sh <image-ref>}"
NAME="smoke-smtp-relay-$$"
TIMEOUT=90 # must cover the image's 15s healthcheck start-period + a few intervals

# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() {
  code=$?
  # Dump container logs only on failure (a passing run stays quiet).
  if [ "$code" -ne 0 ]; then
    printf '%s\n' "--- container logs (tail) ---" >&2
    docker logs "$NAME" 2>&1 | tail -40 >&2 || true
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# RELAY_HOST is required to pass startup validation; the value is a valid dummy
# (the fail-soft startup probe never blocks boot, and the smtpd banner does not
# depend on the upstream being reachable).
docker run -d --name "$NAME" -e RELAY_HOST=smtp.example.com "$IMG" >/dev/null

i=0
status=starting
while [ "$i" -lt "$TIMEOUT" ]; do
  # Fail fast on an early exit: poll .State.Running before the health status so
  # a crash-boot is caught by its exit code (more debuggable than "unhealthy")
  # and the verdict never depends on what health a stopped container reports.
  if [ "$(docker inspect --format '{{ .State.Running }}' "$NAME" 2>/dev/null || echo missing)" != "true" ]; then
    ec=$(docker inspect --format '{{ .State.ExitCode }}' "$NAME" 2>/dev/null || echo '?')
    printf 'FAIL: smtp-relay container exited early (exit code %s)\n' "$ec" >&2
    exit 1
  fi
  status=$(docker inspect --format '{{ if .State.Health }}{{ .State.Health.Status }}{{ else }}no-healthcheck{{ end }}' "$NAME" 2>/dev/null || echo gone)
  case "$status" in
    healthy)
      printf 'smtp-relay image smoke: ok (healthy after %ss)\n' "$i"
      exit 0
      ;;
    unhealthy)
      printf 'FAIL: smtp-relay reported unhealthy\n' >&2
      exit 1
      ;;
    no-healthcheck)
      printf 'FAIL: image has no HEALTHCHECK to assert against\n' >&2
      exit 1
      ;;
    gone)
      printf 'FAIL: smtp-relay container is gone\n' >&2
      exit 1
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
printf 'FAIL: smtp-relay did not become healthy within %ss (last status: %s)\n' "$TIMEOUT" "$status" >&2
exit 1
