#!/usr/bin/env bash
# count_queue(): the startup queue-depth telemetry, and specifically its
# fail-soft chain.
#
# RUN-MODE ONLY (log_startup runs between the Postfix checks and the exec), so
# tests/render-test.sh never reaches it. It is the most dangerous kind of optional
# code: it runs inside a script under `set -euf` as PID 1, before Postfix starts.
# Two failure modes it must never have, and each one is a case below:
#
#   - Aborting the boot. A failed mktemp, a timed-out find over a pathological
#     spool, an unreadable temp file or a failed cleanup are all conditions of the
#     VOLUME, not of the relay; any of them killing the container would trade a
#     working relay for a restart loop.
#   - Reporting a fabricated zero. Grafana reads queue_active/queue_deferred from
#     this line; a failed scan presented as an authoritative 0 during a real spool
#     fault is worse than no metric, so the count travels with queue_scan_ok.
#
# THE ORACLE IS A FRESH `set -euf` CHILD, exactly like production. An in-process
# `count_queue ... || rc=$?` cannot demonstrate fail-softness: the `||` suppresses
# errexit through the entire function body (POSIX), so a chain link weakened into a
# bare failing command would still "survive" here while aborting the real boot. In
# the child the call sits on a line of its own; if count_queue lets a failure
# escape, the child dies before writing its results and the case fails.
#
# The SHIPPED scan_queue_files runs UNREPLACED for the populated case -- its real
# timeout+find do the counting, and a PATH shim records the argv so the 5s budget
# is pinned without duplicating the body in test code. Only the failure baits stub
# it, and never with a copy of the real body.
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

# The real functions, extracted once and sourced by every child. count_queue calls
# timeout_log_fields to attribute a timed-out scan, and scan_queue_files reads the
# shipped QUEUE_SCAN_TIMEOUT constant -- both come from entrypoint.sh rather than a
# copy, so a drifting budget or a changed attribution surfaces here.
FNS="$WORK/fns.sh"
budget_src=$(extract_range '^readonly QUEUE_SCAN_TIMEOUT=' '^$' "$WORK/queue_scan_timeout.sh") || exit 1
extract_function run_interruptible "$WORK/f1.sh" >/dev/null
extract_function scan_queue_files "$WORK/f2.sh" >/dev/null
extract_function timeout_log_fields "$WORK/f3.sh" >/dev/null
extract_function count_queue "$WORK/f4.sh" >/dev/null
cat "$budget_src" "$WORK/f1.sh" "$WORK/f2.sh" "$WORK/f3.sh" "$WORK/f4.sh" >"$FNS"

# The timeout PATH shim: records the supervisor argv, then hands off to the real
# binary. Recording is not reimplementing -- the shipped code still decides
# everything; the shim only proves WHAT it decided.
SHIM="$WORK/shim"
mkdir -p "$SHIM"
cat >"$SHIM/timeout" <<SHIMEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$TIMEOUT_ARGV"
exec /usr/bin/timeout "\$@"
SHIMEOF
chmod +x "$SHIM/timeout"

# The child template: production shape (set -euf), the real functions, then the
# per-case stubs ONLY where the bait needs them. The count_queue call is a plain
# line, not an OR-list, so an escaped failure kills the child before the results
# are written.
CHILD="$WORK/child.sh"
cat >"$CHILD" <<'CHILDEOF'
set -euf
. "$FNS"
case "${SCAN_MODE:-real}" in
  fail) scan_queue_files() { return 1; } ;;
  silent) scan_queue_files() { return 0; } ;;
esac
case "${MKTEMP_MODE:-real}" in
  fail) mktemp() { return 1; } ;;
  dir) mktemp() { command mktemp -d "$CASE/undeletable.XXXXXX"; } ;;
esac
count_queue "$1" "$2" 2>"$LOG"
printf '%s %s\n' "$_queue_count" "$_queue_ok" >"$RESULT"
CHILDEOF

setup() {
  CASE=$(mktemp -d "$WORK/case.XXXXXX")
  LOG="$CASE/log"
  RESULT="$CASE/result"
  TIMEOUT_ARGV="$CASE/timeout-argv"
  : >"$LOG"
  : >"$TIMEOUT_ARGV"
  SCAN_MODE=real
  MKTEMP_MODE=real
}

# run_case <queue-name> <dir> -> _rc, _queue_count, _queue_ok (from the child)
run_case() {
  _rc=0
  FNS="$FNS" CASE="$CASE" LOG="$LOG" RESULT="$RESULT" TIMEOUT_ARGV="$TIMEOUT_ARGV" \
    SCAN_MODE="$SCAN_MODE" MKTEMP_MODE="$MKTEMP_MODE" PATH="$SHIM:$PATH" \
    bash "$CHILD" "$1" "$2" || _rc=$?
  if [ -s "$RESULT" ]; then
    read -r _queue_count _queue_ok <"$RESULT"
  else
    _queue_count='(child died)'
    _queue_ok='(child died)'
  fi
}

warns() {
  grep -Fc "$1" "$LOG" 2>/dev/null || true
}

# --- 1. an absent queue directory is an empty spool, not a scan failure ---------
# A fresh volume does not carry the full Postfix layout yet. The shipped code uses
# an `if` rather than an AND-list precisely so this path completes with status 0
# instead of tripping the caller's set -e.
setup
run_case active "$CASE/nonexistent"
[ "$_rc" -eq 0 ] && [ "$_queue_count" = 0 ] && [ "$_queue_ok" = true ] && [ ! -s "$LOG" ] \
  && ok "an absent queue dir reports 0 as authoritative, silently, without aborting the set -euf child" \
  || no "absent queue dir" "rc=$_rc, count=$_queue_count, ok=$_queue_ok, log: $(cat "$LOG")"

# --- 2. a populated queue is counted by the SHIPPED scan ------------------------
# No stub anywhere on this path: the extracted scan_queue_files runs its own
# timeout+find. The recorded argv pins the 5s budget and the -k 5 kill grace; a
# lost redirect, a changed budget or a dropped -type f shows up here, which is
# exactly what a test-owned copy of the body could never detect.
setup
mkdir -p "$CASE/active/sub"
: >"$CASE/active/a"
: >"$CASE/active/b"
: >"$CASE/active/sub/c"
run_case active "$CASE/active"
[ "$_rc" -eq 0 ] && [ "$_queue_count" = 3 ] && [ "$_queue_ok" = true ] && [ ! -s "$LOG" ] \
  && grep -Fq -- "-k 5 5 find $CASE/active -type f" "$TIMEOUT_ARGV" \
  && ok "a populated spool is counted by the shipped scan under its recorded 5s budget" \
  || no "populated queue counted" "rc=$_rc, count=$_queue_count, ok=$_queue_ok, argv: $(cat "$TIMEOUT_ARGV")"

# --- 3. THE FAIL-SOFT CASE: a failed scan reports UNAVAILABLE, not a real zero ---
# Bait: the scan itself fails (an unreadable spool, or the 5s budget elapsing on a
# pathological volume). The directory exists, so the earlier `-d` guard is satisfied
# and the chain is genuinely entered.
setup
mkdir -p "$CASE/active"
: >"$CASE/active/a"
SCAN_MODE=fail
run_case active "$CASE/active"
[ "$_rc" -eq 0 ] && [ "$_queue_count" = 0 ] && [ "$_queue_ok" = false ] \
  && [ "$(warns 'msg="queue depth unavailable" queue=active')" -eq 1 ] \
  && ok "a failed scan marks the depth unavailable with one warn and the set -euf child survives" \
  || no "failed scan is fail-soft" "rc=$_rc, count=$_queue_count, ok=$_queue_ok, log: $(cat "$LOG")"

# --- 4. the same for a failed mktemp (a full /tmp) -------------------------------
# A different link of the same chain: no temp file means no scan at all, and the
# telemetry must still degrade rather than abort.
setup
mkdir -p "$CASE/active"
MKTEMP_MODE=fail
run_case active "$CASE/active"
[ "$_rc" -eq 0 ] && [ "$_queue_ok" = false ] \
  && [ "$(warns 'msg="queue depth unavailable"')" -eq 1 ] \
  && ok "a failed mktemp degrades the telemetry instead of aborting startup" \
  || no "failed mktemp is fail-soft" "rc=$_rc, ok=$_queue_ok, log: $(cat "$LOG")"

# --- 5. a temp file that cannot be removed warns, and only warns -----------------
# Bait: the temp path is a directory, so both the `wc -l <` read and the `rm -f`
# fail for root as well as for a non-root runner. Two warns are expected -- the
# depth is unavailable AND the cleanup failed -- and neither may end the boot.
setup
mkdir -p "$CASE/active"
MKTEMP_MODE=dir
SCAN_MODE=silent
run_case active "$CASE/active"
[ "$_rc" -eq 0 ] && [ "$_queue_ok" = false ] \
  && [ "$(warns 'msg="queue depth unavailable" queue=active')" -eq 1 ] \
  && [ "$(warns 'msg="queue temp cleanup failed" queue=active')" -eq 1 ] \
  && ok "a temp file that cannot be removed warns twice and startup continues" \
  || no "cleanup failure is warn-only" "rc=$_rc, ok=$_queue_ok, log: $(cat "$LOG")"

report
