#!/usr/bin/env bash
# probe_upstream() / probe_relay_tcp(): the fail-soft TCP reachability check the
# entrypoint runs against the upstream relay just before it execs Postfix.
#
# RUN-MODE ONLY, so tests/render-test.sh never reaches it, and the image smoke test
# only ever sees the healthy answer. Two properties carry the weight here:
#
#   - The host reaches `nc` as an ARGUMENT. A dash-leading RELAY_HOST passes every
#     env validator (no whitespace, no shell metacharacters) and would be parsed by
#     nc as a flag -- argument injection into a process the entrypoint spawns as
#     root. The guard skips the probe instead, because the probe is fail-soft by
#     contract.
#   - The timeout arithmetic. STARTUP_PROBE_TIMEOUT is range-validated 1-10, and
#     `08` satisfies that range while being an octal parse error inside $((...)).
#     Unnormalised, the pipeline fails and the fail-soft wrapper logs a FALSE
#     "upstream relay unreachable" at every boot. Production runs under busybox ash
#     and this suite under bash; both reject `08`, but the failure is silent
#     precisely because the wrapper is fail-soft, which is why it needs an
#     assertion rather than a smoke test.
#
# Only `timeout` is stubbed -- it is the process boundary, and it is also the
# cheapest place to observe the argv nc would have been handed. probe_relay_tcp
# itself stays real, so an empty argv record proves the probe never ran at all.
# Lint directives for this whole file, each against a stated guarantee rather than
# an assumption:
#   SC2015 - the assertion form `[ cond ] && ok "..." || no "..."` cannot mis-fire,
#     because lib.sh's ok/no return 0 unconditionally by design (see their comment).
#   SC2034 - the variables set below are the INPUTS to entrypoint.sh code that is
#     extracted and sourced at RUNTIME, so shellcheck cannot see the reads.
# shellcheck disable=SC2015,SC2034
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# The shipped shell is three files; ENTRYPOINT names the one an extraction reads.
# Both paths stay overridable so a red-check can point either at a mutated /tmp copy
# without editing the repo.
EP_SH="$ENTRYPOINT"
VALIDATE_SH="${VALIDATE_SH:-$REPO_ROOT/validate.sh}"

ENTRYPOINT="$VALIDATE_SH"
load_function sanitize_token

ENTRYPOINT="$EP_SH"
load_function run_interruptible
load_function probe_relay_tcp
load_function probe_upstream

# The one stub: `timeout` is where the probe leaves the shell. Recording its whole
# argv captures both halves of the contract -- the outer budget and the nc command
# line the host lands in. Defined once here for the in-process cases and once in
# the child template below for the survival cases.
timeout() {
  printf '%s\n' "$*" >>"$ARGV"
  return "$STUB_TIMEOUT_STATUS"
}

# The survival oracle is a FRESH `set -euf` child, matching the production caller.
# An in-process `( set -e; probe_upstream; ... ) || _rc=$?` proves nothing: the
# OR-list suppresses errexit through the whole subshell (POSIX), so a fail-soft
# regression would still print its marker here while killing the real boot. In the
# child the call sits on a line of its own; if probe_upstream lets a failure
# escape, the child dies before the marker is written.
CHILD="$WORK/probe-child.sh"
cat >"$CHILD" <<'CHILDEOF'
set -euf
. "$FNS"
timeout() {
  printf '%s\n' "$*" >>"$ARGV"
  return "$STUB_TIMEOUT_STATUS"
}
probe_upstream
printf 'survived\n' >"$SURVIVED"
CHILDEOF
# load_function left each extraction at $WORK/<name>.sh; the child sources them all.
FNS="$WORK/probe-fns.sh"
cat "$WORK/sanitize_token.sh" "$WORK/run_interruptible.sh" \
  "$WORK/probe_relay_tcp.sh" "$WORK/probe_upstream.sh" >"$FNS"

setup() {
  CASE=$(mktemp -d "$WORK/case.XXXXXX")
  ARGV="$CASE/argv"
  LOG="$CASE/log"
  SURVIVED="$CASE/survived"
  : >"$ARGV"
  : >"$LOG"
  STUB_TIMEOUT_STATUS=0
  STARTUP_PROBE=true
  STARTUP_PROBE_TIMEOUT=5
  RELAY_HOST=smtp.example.com
  RELAY_PORT=587
  RELAYHOST_VALUE='[smtp.example.com]:587'
}

# probe_upstream is called from a startup path running under `set -euf`, and its
# whole contract is that it returns 0 even when the relay is down. The child runs
# it exactly that way (see CHILD above); survival means the marker exists AND the
# child exited 0.
probe_under_set_e() {
  _rc=0
  # LOG is the child's stderr redirect here; the child does not need it in its
  # environment (nothing inside CHILD reads LOG), and passing it as well would
  # mean handing the same path to a reader and a writer in one pipeline.
  FNS="$FNS" ARGV="$ARGV" SURVIVED="$SURVIVED" \
    STUB_TIMEOUT_STATUS="$STUB_TIMEOUT_STATUS" STARTUP_PROBE="$STARTUP_PROBE" \
    STARTUP_PROBE_TIMEOUT="$STARTUP_PROBE_TIMEOUT" RELAY_HOST="$RELAY_HOST" \
    RELAY_PORT="$RELAY_PORT" RELAYHOST_VALUE="$RELAYHOST_VALUE" \
    bash "$CHILD" 2>"$LOG" || _rc=$?
}

logged() {
  grep -Fq "$1" "$LOG"
}

argv_line() {
  cat "$ARGV"
}

# --- 1. a leading-zero timeout is normalised before it enters $((...)) -----------
# 08 is what an operator writes for "eight seconds" and validate_range accepts it
# (08 -eq 8). Unstripped it is an octal literal with an invalid digit.
setup
STARTUP_PROBE_TIMEOUT=08
_rc=0
probe_relay_tcp smtp.example.com 587 || _rc=$?
[ "$_rc" -eq 0 ] && [ "$(argv_line)" = '-k 2 10 nc -w 8 smtp.example.com 587' ] \
  && ok "STARTUP_PROBE_TIMEOUT=08 probes with -w 8 under a 10s budget instead of failing arithmetic" \
  || no "leading-zero timeout normalised" "rc=$_rc, argv: $(argv_line)"

# --- 2. ... and a plain value is not over-stripped -------------------------------
# The companion direction: this case is what fails if the normalisation strips more
# than leading zeroes, where case 1 is what fails if it strips none.
setup
STARTUP_PROBE_TIMEOUT=5
probe_relay_tcp smtp.example.com 587
[ "$(argv_line)" = '-k 2 7 nc -w 5 smtp.example.com 587' ] \
  && ok "a plain timeout keeps its value, with the documented +2s margin on the outer budget" \
  || no "plain timeout preserved" "argv: $(argv_line)"

# --- 3. THE INJECTION CASE: an option-shaped relay host never reaches nc's argv --
# Bait the unguarded code would take: '-e/bin/sh' is dash-leading AND free of
# whitespace, ;, &, |, backtick and $, so validate_no_metacharacters passes it. nc
# builds that accept -e execute the named program, and this probe runs as root.
setup
RELAY_HOST='-e/bin/sh'
RELAYHOST_VALUE='[-e/bin/sh]:587'
probe_under_set_e
[ "$_rc" -eq 0 ] && [ ! -s "$ARGV" ] \
  && logged 'msg="startup probe skipped: relay host looks like an option"' \
  && ok "a dash-leading RELAY_HOST is skipped with a warn and never enters nc's argv" \
  || no "option-shaped host skipped" "rc=$_rc, argv: $(argv_line)"

# --- 4. brackets are stripped before the host reaches nc ------------------------
# A bare IPv6 RELAY_HOST is bracketed for Postfix's relayhost, but nc needs the
# address itself; a bracketed argv would make every IPv6 upstream look unreachable.
setup
RELAY_HOST='[2001:db8::1]'
RELAYHOST_VALUE='[2001:db8::1]:587'
probe_under_set_e
[ "$(argv_line)" = '-k 2 7 nc -w 5 2001:db8::1 587' ] \
  && ok "an IPv6 RELAY_HOST is unbracketed for nc while the log keeps the relayhost form" \
  || no "bracket stripping" "argv: $(argv_line)"

# --- 5. STARTUP_PROBE=false disables the probe entirely -------------------------
# Disabling the probe is a deliberate operator choice, so it is announced once
# rather than silently: an image that never probes and never says so is
# indistinguishable in the logs from one whose probe was skipped by a bug.
setup
STARTUP_PROBE=false
probe_under_set_e
[ "$_rc" -eq 0 ] && [ ! -s "$ARGV" ] \
  && logged 'msg="startup probe disabled" var=STARTUP_PROBE' \
  && ok "STARTUP_PROBE=false spawns nothing and logs the disabled state once" \
  || no "probe disabled" "rc=$_rc, argv: $(argv_line), log: $(cat "$LOG")"

# --- 6. an unreachable upstream is FAIL-SOFT ------------------------------------
# The relay may legitimately be down at boot; mail queues. If this returned
# non-zero the caller's `set -e` would kill PID 1 before Postfix ever started, so
# the assertion is that the caller survived, not merely that a warning was logged.
setup
STUB_TIMEOUT_STATUS=1
probe_under_set_e
[ "$_rc" -eq 0 ] && [ -f "$SURVIVED" ] \
  && logged 'msg="upstream relay unreachable at startup; continuing (mail will queue)"' \
  && ok "an unreachable upstream warns and returns 0, so startup continues to Postfix" \
  || no "probe is fail-soft" "rc=$_rc, survived=$([ -f "$SURVIVED" ] && echo yes || echo no), log: $(cat "$LOG")"

# --- 7. ... and a reachable one is reported as reachable ------------------------
# Paired with case 6: an inverted test would turn every healthy boot into a false
# "unreachable" warning, which is the failure mode operators would learn to ignore.
setup
STUB_TIMEOUT_STATUS=0
probe_under_set_e
logged 'msg="upstream relay reachable" relay="[smtp.example.com]:587"' \
  && ! logged 'unreachable' \
  && ok "a reachable upstream logs level=info reachable with the relayhost" \
  || no "reachable reported" "log: $(cat "$LOG")"

report
