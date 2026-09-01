#!/usr/bin/env bash
# write_sasl_secret() and its helpers: the upstream SASL credentials are written
# to disk, indexed by postmap, and the plaintext removed again.
#
# This whole path is RUN-MODE ONLY — `entrypoint.sh render` returns before it, so
# render-test.sh drives none of it, and a healthy image smoke test never takes a
# failure branch inside it. What the guards here protect is the file mode of an
# indexed map that stores the relay login AND password verbatim (a table format, not
# a digest): postmap inherits the process umask for a file it CREATES but preserves
# the mode of one it rewrites in place, so both the stale plaintext and the stale
# indexed map have to be unlinked before it runs.
#
# The two mode guards are shadowed by a later belt-and-suspenders `chmod 600`, so a
# final-mode assertion cannot tell them apart — it passes with either guard removed.
# Every case below therefore asserts what postmap SAW (the stub records the
# plaintext's mode and whether a stale map was still on disk).
#   SC2015 - the assertion form `[ cond ] && ok "..." || no "..."` cannot mis-fire,
#     because lib.sh's ok/no return 0 unconditionally by design.
#   SC2034 - the variables set below are the INPUTS to entrypoint.sh code that is
#     extracted and sourced at RUNTIME, so shellcheck cannot see the reads.
# shellcheck disable=SC2015,SC2034
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

# Pin the ambient umask AWAY from the guarded value. Both credential-mode
# assertions (the plaintext create in case 2, the map create in case 12) compare
# against 077, so an invoking shell that already sets 077 -- hardened root shells and
# some CI images do -- makes them pass with the production `umask 077` deleted. The
# security property is then environment-conditional, which is the one thing a
# security assertion must not be.
umask 022

# The shipped shell is three files. ENTRYPOINT names the one an extraction reads,
# so it is reassigned before each group; both paths stay overridable so a red-check
# can point either at a mutated /tmp copy without editing the repo.
EP_SH="$ENTRYPOINT"
VALIDATE_SH="${VALIDATE_SH:-$REPO_ROOT/validate.sh}"

ENTRYPOINT="$VALIDATE_SH"
load_function sanitize_token

ENTRYPOINT="$EP_SH"
load_function sasl_enabled
load_function cleanup_sasl_plaintext
load_function cleanup_sasl_plaintext_or_log
load_function timeout_log_fields
load_function run_interruptible
load_function terminate_startup_child
load_function abort_sasl_secret
load_function write_sasl_secret

# postmap_restricted is the stub surface rather than a unit under test: every line
# of it is an external command (`umask 077` then `exec timeout ... postmap`). The
# stub records what postmap would have SEEN, because that -- not the state of the
# directory after the function returns -- is what the guards control. It also
# recreates the map the way postmap does, so the caller's chmod has a target.
# Two suffixes, deliberately separate: STALE_SUFFIX is the leftover artifact a case
# plants and the stub reports on, while the stub always CREATES .lmdb, because that
# is what real postmap writes in this build whatever was there before (-DNO_DB with
# DEF_DB_TYPE=lmdb, see compute_sasl_state). Collapsing the two would model a
# postmap that emits .db, which this image's postmap never does.
postmap_restricted() {
  stat -c %a "$1" >"$SEEN_MODE" 2>/dev/null || printf 'missing\n' >"$SEEN_MODE"
  cat "$1" >"$SEEN_CONTENT" 2>/dev/null || :
  if [ -e "$1$STALE_SUFFIX" ]; then
    printf 'present\n' >"$SEEN_MAP"
  else
    printf 'absent\n' >"$SEEN_MAP"
  fi
  : >"$1.lmdb"
  return "$STUB_POSTMAP_STATUS"
}

# Named by write_sasl_secret's closing `trap startup_abort INT TERM HUP QUIT`. The
# trap only records the name, so this exists to keep the re-arm honest rather than
# to be called.
startup_abort() { exit 1; }

setup() {
  CASE=$(mktemp -d "$WORK/case.XXXXXX")
  CONF_DIR="$CASE/postfix"
  mkdir -p "$CONF_DIR"
  SASL_PASSWD_FILE="$CONF_DIR/sasl_passwd"
  RELAYHOST_VALUE='[smtp.example.com]:587'
  RELAY_LOGIN=AKIAEXAMPLE
  RELAY_PASSWORD=secret-token
  STALE_SUFFIX=.lmdb
  STARTUP_CMD_TIMEOUT=30
  STARTUP_CHILD_PID=''
  STUB_POSTMAP_STATUS=0
  SEEN_MODE="$CASE/seen.mode"
  SEEN_MAP="$CASE/seen.map"
  SEEN_CONTENT="$CASE/seen.content"
  LOG="$CASE/log"
  TIMEOUT_ARGV="$CASE/timeout-argv"
  : >"$TIMEOUT_ARGV"
  : >"$SEEN_MODE"
  : >"$SEEN_MAP"
  : >"$SEEN_CONTENT"
  : >"$LOG"
}

# write_sasl_secret exits 1 on a failure rather than returning, so every case runs
# it in a subshell and keeps the status.
run_write() {
  _rc=0
  (write_sasl_secret) 2>"$LOG" || _rc=$?
}

logged() {
  grep -Fq "$1" "$LOG"
}

# --- 1. the stale indexed map is unlinked BEFORE postmap runs -------------------
# Bait the unguarded code would take: a pre-existing 0644 map file, exactly what a
# prior image build or a botched restart leaves behind. Without the rm, postmap
# rewrites that file in place and keeps its mode, so the credentials stay
# world-readable on the volume. Run over BOTH suffixes: .lmdb is what this build
# writes (compute_sasl_state renders an lmdb: map), .db is the downgrade path from
# an older image, and write_sasl_secret removes both -- so dropping either name
# from its rm fails here rather than passing on the other one's coverage.
for _map_suffix in .lmdb .db; do
  setup
  STALE_SUFFIX=$_map_suffix
  : >"${SASL_PASSWD_FILE}${STALE_SUFFIX}"
  chmod 644 "${SASL_PASSWD_FILE}${STALE_SUFFIX}"
  run_write
  [ "$(cat "$SEEN_MAP")" = absent ] \
    && ok "a stale sasl_passwd${STALE_SUFFIX} is gone before postmap runs, so the umask governs the new map" \
    || no "stale indexed map unlinked (${STALE_SUFFIX})" "postmap saw a pre-existing ${STALE_SUFFIX} ($(cat "$SEEN_MAP")) and would have rewritten it in place"
done

# --- 2. the plaintext is CREATED under umask 077, not truncated over a stale file -
# Same shape of bait on the plaintext half: `>file` truncates but preserves the
# mode, so only the create path honors the umask. Sampled at postmap time because
# the function deletes the plaintext before returning.
setup
# Premise: the scratch filesystem has to derive a new file's mode from the
# umask at all. An ACL-inheriting mount (measured on ZFS with nfs4acl) gives
# every new file the inherited mode whatever the umask -- `touch` reads 770
# under umask 022 -- so the assertion below would fail for a maintainer on
# such a tree while passing in CI. That is a premise that cannot hold here,
# which is what lib.sh's skip exists for. Note precisely what the skip costs:
# entrypoint.sh has TWO umask 077 guards, and case 12 pins the OTHER one
# (postmap_restricted's, recorded as a umask value rather than a mode, so it
# survives here). The plaintext write's own umask 077 is covered by THIS case
# alone, so on an ACL-inheriting tree it is verified only in CI, whose
# filesystem does derive modes from the umask.
(umask 077 && : >"$CASE/mode-probe")
_fs_mode=$(stat -c %a "$CASE/mode-probe")
if [ "$_fs_mode" != 600 ]; then
  skip "the plaintext credential file is 0600 while postmap reads it" \
    "this filesystem does not derive modes from the umask (umask 077 created mode $_fs_mode)"
else
  : >"$SASL_PASSWD_FILE"
  chmod 644 "$SASL_PASSWD_FILE"
  run_write
  [ "$(cat "$SEEN_MODE")" = 600 ] \
    && ok "the plaintext credential file is 0600 while postmap reads it, even over a stale 0644 file" \
    || no "plaintext created under umask 077" "mode at postmap time was $(cat "$SEEN_MODE"), not 600"
fi

# --- 3. the sasl_passwd record keeps the field format the validators protect -----
# `<relayhost> <login>:<password>`, split on the first whitespace then the first
# colon -- the contract validate_sasl_login's colon rejection exists to defend.
setup
run_write
[ "$(cat "$SEEN_CONTENT")" = '[smtp.example.com]:587 AKIAEXAMPLE:secret-token' ] \
  && ok "the map record is '<relayhost> <login>:<password>'" \
  || no "sasl_passwd record format" "got '$(cat "$SEEN_CONTENT")'"

# --- 3b. a password with interior spaces reaches postmap verbatim ----------------
# The Gmail App Password shape (four space-separated groups) that the validators now
# accept, issue #392. Only the run half writes this record, so render-test cannot see
# it: the write must quote the value, or postmap would receive a truncated password
# and every delivery would fail auth at the provider.
setup
RELAY_PASSWORD='irzm xpiz qnmq mkal'
run_write
[ "$_rc" -eq 0 ] \
  && [ "$(cat "$SEEN_CONTENT")" = '[smtp.example.com]:587 AKIAEXAMPLE:irzm xpiz qnmq mkal' ] \
  && ok "a password with interior spaces reaches postmap with every space intact" \
  || no "spaced password written verbatim" "rc=$_rc, got '$(cat "$SEEN_CONTENT")'"

# --- 4. the plaintext does not survive a successful setup -----------------------
setup
run_write
[ "$_rc" -eq 0 ] && [ ! -e "$SASL_PASSWD_FILE" ] && logged 'msg="SASL authentication configured"' \
  && ok "a successful setup returns 0, logs it, and leaves no plaintext credentials on disk" \
  || no "plaintext removed on success" "rc=$_rc, plaintext present=$([ -e "$SASL_PASSWD_FILE" ] && echo yes || echo no)"

# --- 5. a failed credentials WRITE aborts before postmap ever runs ---------------
# Bait that fails for root too: the target's parent directory does not exist, so
# the create inside the umask-077 subshell fails whoever runs it. Without this
# guard the function would carry on and hand postmap a path with no file behind it.
setup
SASL_PASSWD_FILE="$CASE/no-such-dir/sasl_passwd"
run_write
[ "$_rc" -ne 0 ] && logged 'msg="failed to write SASL credentials file"' \
  && [ "$(cat "$SEEN_MAP")" = "" ] \
  && ok "a failed credentials write aborts with level=error before postmap runs" \
  || no "credentials write failure aborts" "rc=$_rc, postmap saw '$(cat "$SEEN_MAP")', log: $(cat "$LOG")"

# --- 6. a failed postmap aborts startup instead of booting on an unindexed map ---
setup
STUB_POSTMAP_STATUS=1
run_write
[ "$_rc" -ne 0 ] && logged 'msg="postmap failed"' && ! logged 'reason=timeout' \
  && ok "a failed postmap aborts with level=error and no timeout attribution" \
  || no "postmap failure aborts" "rc=$_rc, log: $(cat "$LOG")"

# --- 7. ... and still leaves no plaintext behind (the EXIT trap) -----------------
# The explicit cleanup at the end of the function is never reached on this path, so
# this case exercises the trap and nothing else.
setup
STUB_POSTMAP_STATUS=1
run_write
[ ! -e "$SASL_PASSWD_FILE" ] \
  && ok "the EXIT trap removes the plaintext even when postmap fails mid-setup" \
  || no "plaintext removed on failure" "plaintext survived a failed postmap"

# --- 8. a timed-out postmap is attributed as a timeout, not a plain failure -----
# BusyBox timeout (the only timeout in the runtime image) reports its own TERM as
# 143; the log has to say so or an operator reads a wedged spool as a broken map.
setup
STUB_POSTMAP_STATUS=143
run_write
[ "$_rc" -ne 0 ] && logged 'msg="postmap failed" reason=timeout timeout_seconds=30' \
  && ok "a postmap killed by the elapsed budget logs reason=timeout with the budget" \
  || no "timeout attribution" "log: $(cat "$LOG")"

# --- 9. no credentials configured: nothing is written and postmap never runs -----
setup
RELAY_LOGIN=''
RELAY_PASSWORD=''
run_write
[ "$_rc" -eq 0 ] && [ ! -e "$SASL_PASSWD_FILE" ] && [ ! -s "$SEEN_MAP" ] \
  && ok "with no RELAY_LOGIN/RELAY_PASSWORD the secret path is skipped entirely" \
  || no "SASL disabled short-circuit" "rc=$_rc, postmap ran=$([ -s "$SEEN_MAP" ] && echo yes || echo no)"

# --- 10. a termination signal mid-write cleans up AND aborts ---------------------
# A cleanup-only handler would return control to the run path and let startup
# continue into Postfix after a docker stop, so the handler owns two obligations:
# the plaintext is gone, and the status is non-zero.
setup
: >"$SASL_PASSWD_FILE"
_rc=0
(abort_sasl_secret) 2>"$LOG" || _rc=$?
[ ! -e "$SASL_PASSWD_FILE" ] \
  && ok "the signal handler removes the plaintext credentials" \
  || no "signal handler cleanup" "plaintext survived abort_sasl_secret"
[ "$_rc" -ne 0 ] && logged 'msg="received termination signal during SASL setup' \
  && ok "the signal handler exits non-zero so the stop request is honored" \
  || no "signal handler aborts" "rc=$_rc, log: $(cat "$LOG")"

# --- 11. the TRAPS are actually INSTALLED, not just correct as bodies ------------
# Everything above calls the handlers directly, which proves cleanup code and
# nothing about wiring: with all three production trap statements deleted, cases
# 1-10 stay green while a docker stop mid-postmap leaves plaintext credentials on
# disk until forced termination. These two cases prove delivery and re-arming
# against the REAL function in a real child process, using PATH shims (postmap
# blocks; the harness never replaces write_sasl_secret or its helpers).

# The child sources the real functions, runs the real write_sasl_secret against a
# postmap shim that blocks, and is TERMed mid-postmap from out here. The trap must
# turn that into: plaintext gone, non-zero exit, the handler's own log line.
SHIM="$WORK/shim"
mkdir -p "$SHIM"
cat >"$SHIM/postmap" <<'SHIMEOF'
#!/usr/bin/env bash
: >"${POSTMAP_STARTED:?}"
sleep 30
SHIMEOF
# The timeout shim RECORDS its argv before handing off: postmap_restricted's whole
# supervision (`exec timeout -k 5 "$STARTUP_CMD_TIMEOUT" postmap`) was otherwise
# deletable with every assertion green, because a shim that blindly `shift 3`s
# cannot tell a supervised call from a bare one. No real timeout runs here: the shim
# drops the supervisor's own options (shift 3) and execs the supervised command
# directly, so nothing in this file depends on where a timeout binary lives.
cat >"$SHIM/timeout" <<'SHIMEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${TIMEOUT_ARGV:?}"
shift 3
exec "$@"
SHIMEOF
chmod +x "$SHIM/postmap" "$SHIM/timeout"

FNS="$WORK/real-fns.sh"
for _fn in sasl_enabled cleanup_sasl_plaintext cleanup_sasl_plaintext_or_log \
  abort_sasl_secret startup_abort \
  postmap_restricted terminate_startup_child run_interruptible timeout_log_fields \
  write_sasl_secret; do
  extract_function "$_fn" "$WORK/_rf_$_fn.sh" >/dev/null
done
cat "$WORK"/_rf_*.sh >"$FNS"

setup
POSTMAP_STARTED="$CASE/postmap-started"
export FNS SASL_PASSWD_FILE RELAYHOST_VALUE RELAY_LOGIN RELAY_PASSWORD POSTMAP_STARTED TIMEOUT_ARGV
PATH="$SHIM:$PATH" bash -c '
  set -u
  . "$FNS"
  readonly STARTUP_CMD_TIMEOUT=30
  write_sasl_secret
' _ >/dev/null 2>"$LOG" &
_writer=$!
_i=0
while [ ! -e "$POSTMAP_STARTED" ] && [ "$_i" -lt 100 ]; do
  sleep 0.1
  _i=$((_i + 1))
done
kill -TERM "$_writer" 2>/dev/null
_rc=0
wait "$_writer" || _rc=$?
[ "$_rc" -ne 0 ] && [ ! -e "$SASL_PASSWD_FILE" ] \
  && logged 'msg="received termination signal during SASL setup' \
  && ok "a real TERM mid-postmap reaches the trap: plaintext removed, startup aborted" \
  || no "trap delivery" "rc=$_rc, plaintext=$([ -e "$SASL_PASSWD_FILE" ] && echo present || echo gone), log: $(cat "$LOG")"

# After a SUCCESSFUL write_sasl_secret, the EXIT cleanup trap must be gone and the
# startup handler re-armed -- clearing all traps would leave the rest of startup
# (postfix checks, upstream probe) without signal handling as PID 1. trap -p is
# the observable, printed from inside the same shell.
setup
cat >"$SHIM/postmap" <<'SHIMEOF'
#!/usr/bin/env bash
: >"${1:?}.lmdb"
SHIMEOF
chmod +x "$SHIM/postmap"
TRAPS="$CASE/traps"
export SASL_PASSWD_FILE RELAYHOST_VALUE RELAY_LOGIN RELAY_PASSWORD TRAPS TIMEOUT_ARGV
PATH="$SHIM:$PATH" bash -c '
  set -u
  . "$FNS"
  readonly STARTUP_CMD_TIMEOUT=30
  write_sasl_secret >/dev/null 2>&1
  trap -p EXIT >"$TRAPS.exit"
  trap -p TERM >"$TRAPS.term"
' _ 2>>"$LOG"
# Two separate captures, so neither can be read into the other's section.
grep -q 'startup_abort' "$TRAPS.term" \
  && ! grep -q 'cleanup_sasl_plaintext' "$TRAPS.exit" \
  && ok "after success the EXIT cleanup trap is dropped and TERM re-arms startup_abort" \
  || no "trap re-arming" "EXIT=[$(tr '\n' ' ' <"$TRAPS.exit")] TERM=[$(tr '\n' ' ' <"$TRAPS.term")]"

# --- 12. the map file's AT-CREATE-TIME umask, through the REAL postmap_restricted -
# The stub cases above cover the plaintext half (its umask subshell is inside
# write_sasl_secret itself); this is the indexed-map half, where the guard lives in
# postmap_restricted and a stubbed postmap() would remove it from coverage
# entirely. The shim records the umask it inherits at the moment postmap would
# create the map -- the belt-and-suspenders chmod 600 afterwards cannot recover a
# permissive CREATE, because the credentials were exposed in that window.
setup
cat >"$SHIM/postmap" <<'SHIMEOF'
#!/usr/bin/env bash
umask >"${UMASK_SEEN:?}"
: >"${1:?}.lmdb"
SHIMEOF
chmod +x "$SHIM/postmap"
UMASK_SEEN="$CASE/umask-seen"
export SASL_PASSWD_FILE RELAYHOST_VALUE RELAY_LOGIN RELAY_PASSWORD UMASK_SEEN TIMEOUT_ARGV
PATH="$SHIM:$PATH" bash -c '
  set -u
  . "$FNS"
  readonly STARTUP_CMD_TIMEOUT=30
  write_sasl_secret
' _ >/dev/null 2>"$LOG"
_rc=$?
# Two properties from one real run: the umask postmap inherits at creation, AND that
# postmap was reached THROUGH the timeout supervisor with the shipped budget and kill
# grace. Without the argv half, deleting the whole `exec timeout -k 5 ...` wrapper
# left every assertion green.
[ "$_rc" -eq 0 ] && [ "$(cat "$UMASK_SEEN" 2>/dev/null)" = "0077" ] \
  && grep -Fq -- "-k 5 $STARTUP_CMD_TIMEOUT postmap $SASL_PASSWD_FILE" "$TIMEOUT_ARGV" \
  && ok "postmap runs under umask 077 via the timeout supervisor, so the map is 0600 at creation" \
  || no "postmap umask + supervision" "rc=$_rc, umask seen: '$(cat "$UMASK_SEEN" 2>/dev/null)', argv: $(cat "$TIMEOUT_ARGV"), log: $(cat "$LOG")"

report
