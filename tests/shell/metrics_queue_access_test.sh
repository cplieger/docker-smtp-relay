#!/usr/bin/env bash
# The run-mode step that lets the METRICS_PORT responder read the queue under
# no-new-privileges: no_new_privs and sync_metrics_queue_access, and their place
# after run_postfix_checks in the run mode.
#
# The responder reaches showq through public/, which only group postdrop may
# search. postqueue gets that group from its setgid bit, which the kernel ignores
# under no-new-privileges, and spawn(8) refuses to run a command as postdrop. A
# POSIX ACL entry for the responder's user is the one grant left, and only the
# image smoke, which runs with no-new-privileges, proves it end to end. These
# cases pin the arms a healthy smoke never takes: a spool that refuses ACLs, a
# timeout, and the removal of a grant nothing needs any more.
#
# `timeout` is the only command stub: run_bounded spawns setfacl through it.
# Lint directives for this whole file:
#   SC2015 - lib.sh's ok/no return 0 unconditionally, so `[ cond ] && ok || no`
#     cannot mis-fire.
#   SC2034 - the variables set below are inputs to entrypoint.sh code that is
#     extracted and sourced at runtime.
# shellcheck disable=SC2015,SC2034
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

budget_src=$(extract_range '^readonly STARTUP_CMD_TIMEOUT=' '^$' "$WORK/startup_cmd_timeout.sh") || exit 1
# shellcheck disable=SC1090
. "$budget_src"

load_function run_interruptible
load_function run_bounded
load_function timeout_log_fields
load_function no_new_privs
load_function sync_metrics_queue_access

PUBLIC=/var/spool/postfix/public

timeout() {
  printf '%s\n' "$*" >>"$ARGV"
  shift 3
  case "$1" in
    setfacl) return "$STUB_SETFACL" ;;
  esac
  return 0
}

setup() {
  CASE=$(mktemp -d "$WORK/case.XXXXXX")
  ARGV="$CASE/argv"
  LOG="$CASE/log"
  : >"$ARGV"
  : >"$LOG"
  STUB_SETFACL=0
  STARTUP_CHILD_PID=''
}

# --- 1. no_new_privs reads the kernel's flag, and only a 1 counts -------------
status_file() {
  printf 'Name:\tsh\n%sSeccomp:\t2\n' "$1" >"$WORK/status"
  printf '%s\n' "$WORK/status"
}

no_new_privs "$(status_file 'NoNewPrivs:	1
')" \
  && ok "NoNewPrivs 1 in the status file reads as set" \
  || no "NoNewPrivs 1" "no_new_privs returned non-zero"

! no_new_privs "$(status_file 'NoNewPrivs:	0
')" \
  && ok "NoNewPrivs 0 reads as unset" \
  || no "NoNewPrivs 0" "no_new_privs returned zero"

! no_new_privs "$(status_file '')" \
  && ok "a status file without the field reads as unset" \
  || no "NoNewPrivs absent" "no_new_privs returned zero"

! no_new_privs "$WORK/missing-status" 2>/dev/null \
  && ok "an unreadable status file reads as unset" \
  || no "status unreadable" "no_new_privs returned zero"

# The function under test is driven through a stub from here on, which records
# the file it was asked to read.
NNP_FILE=''
no_new_privs() {
  NNP_FILE=$1
  [ "$STUB_NNP" = 1 ]
}

run_sync() {
  _rc=0
  sync_metrics_queue_access 2>"$LOG" || _rc=$?
}

# --- 2. METRICS_PORT set under no-new-privileges: the grant -------------------
setup
METRICS_PORT_VALUE=9154
STUB_NNP=1
run_sync
[ "$_rc" -eq 0 ] && [ "$(cat "$ARGV")" = "-k 5 $STARTUP_CMD_TIMEOUT setfacl -m u:smtp-metrics:--x $PUBLIC" ] \
  && [ ! -s "$LOG" ] && [ "$NNP_FILE" = /proc/self/status ] \
  && ok "with METRICS_PORT set under no-new-privileges, smtp-metrics gets search on public/ and nothing is logged" \
  || no "grant" "rc=$_rc argv='$(cat "$ARGV")' nnp_file='$NNP_FILE' log='$(cat "$LOG")'"

# --- 3. a spool that refuses the ACL: one warning naming the effect, no exit ---
setup
METRICS_PORT_VALUE=9154
STUB_NNP=1
STUB_SETFACL=1
run_sync
[ "$_rc" -eq 0 ] && [ "$(wc -l <"$LOG")" -eq 1 ] \
  && grep -q '^level=warn ' "$LOG" && grep -qF 'smtp_relay_queue_scrape_ok 0' "$LOG" \
  && grep -qF "path=\"$PUBLIC\"" "$LOG" && ! grep -qF 'reason=timeout' "$LOG" \
  && ok "a refused grant logs one warning that scrapes will report scrape_ok 0, and the start goes on" \
  || no "grant refused" "rc=$_rc log='$(cat "$LOG")'"

# The entrypoint runs under set -euf, which `|| _rc=$?` above would mask.
reached=$(
  set -euf
  sync_metrics_queue_access 2>/dev/null
  printf reached
)
[ "$reached" = reached ] \
  && ok "a refused grant does not abort a set -euf shell" \
  || no "grant refused under set -euf" "the shell stopped inside sync_metrics_queue_access"

# --- 4. a grant that times out says so --------------------------------------
setup
METRICS_PORT_VALUE=9154
STUB_NNP=1
STUB_SETFACL=143
run_sync
[ "$_rc" -eq 0 ] && grep -qF "reason=timeout timeout_seconds=$STARTUP_CMD_TIMEOUT" "$LOG" \
  && ok "a timed-out grant carries the timeout fields" \
  || no "grant timeout" "rc=$_rc log='$(cat "$LOG")'"

# --- 5. nothing needs the grant: it is removed, quietly ---------------------
# setfacl -x on an entry that is not there, or on a filesystem without ACLs,
# exits 0 (acl 2.3.2), so a fresh spool logs nothing.
for state in 'unset:1' 'unset:0' '9154:0'; do
  setup
  METRICS_PORT_VALUE=${state%%:*}
  [ "$METRICS_PORT_VALUE" != unset ] || METRICS_PORT_VALUE=''
  STUB_NNP=${state##*:}
  run_sync
  [ "$_rc" -eq 0 ] && [ "$(cat "$ARGV")" = "-k 5 $STARTUP_CMD_TIMEOUT setfacl -x u:smtp-metrics $PUBLIC" ] \
    && [ ! -s "$LOG" ] \
    && ok "METRICS_PORT ${METRICS_PORT_VALUE:-unset} with NoNewPrivs $STUB_NNP removes the grant and logs nothing" \
    || no "removal ($state)" "rc=$_rc argv='$(cat "$ARGV")' log='$(cat "$LOG")'"
done

# --- 6. a failed removal warns and does not stop the start -------------------
setup
METRICS_PORT_VALUE=''
STUB_NNP=0
STUB_SETFACL=1
run_sync
[ "$_rc" -eq 0 ] && [ "$(wc -l <"$LOG")" -eq 1 ] && grep -q '^level=warn ' "$LOG" \
  && grep -qF "path=\"$PUBLIC\"" "$LOG" \
  && ok "a failed removal logs one warning and the start goes on" \
  || no "removal failed" "rc=$_rc log='$(cat "$LOG")'"

# --- 7. the run mode syncs after set-permissions -----------------------------
# On an empty spool folder public/ exists only once `postfix check` has created
# it, and METRICS_PORT_VALUE only once render_config has run.
run_src=$(extract_range '^  run)$' '^    ;;$' "$WORK/run_mode.sh") || exit 1
order=$(grep -nE '^ *(render_config|run_postfix_checks|sync_metrics_queue_access|exec postfix start-fg)$' "$run_src" \
  | sed 's/^[0-9]*: *//' | tr '\n' ' ')
[ "$order" = "render_config run_postfix_checks sync_metrics_queue_access exec postfix start-fg " ] \
  && ok "run mode calls sync_metrics_queue_access after run_postfix_checks and before Postfix starts" \
  || no "run-mode order" "got '$order'"

report
