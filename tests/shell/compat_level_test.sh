#!/usr/bin/env bash
# The rendered main.cf's compatibility_level against the Postfix version the
# Dockerfile pins: below the release's own level postfix(1) logs a reminder on
# every call, though this image renders every value the level would default.
# Only this host-side suite can read both files: render-test.sh's stage lacks the
# Dockerfile and the image smoke runs with the level already baked. On a Postfix
# major.minor bump this fails until the level is raised: read COMPATIBILITY_README
# for the new level's gated defaults first.

# SC2015: `[ cond ] && ok || no` cannot mis-fire, lib.sh's ok/no always return 0.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

DOCKERFILE="${DOCKERFILE:-$REPO_ROOT/Dockerfile}"

# --- 0. preconditions, fatal for the whole file ----------------------------------
# Both reads must succeed before any comparison: an unreadable Dockerfile or a
# renamed ARG produces the same empty string as a mismatch would, which would turn
# the assertion below green against nothing.
if [ ! -r "$DOCKERFILE" ]; then
  no "the Dockerfile is readable" "not readable: $DOCKERFILE"
  report
  exit 1
fi

pinned=$(sed -n 's/^ARG POSTFIX_VERSION=v\([0-9][0-9.]*\)$/\1/p' "$DOCKERFILE")
case "$pinned" in
  [0-9]*.[0-9]*.[0-9]*) ok "the Dockerfile pins a three-part Postfix version ($pinned)" ;;
  *)
    no "the Dockerfile pins a three-part Postfix version" \
      "ARG POSTFIX_VERSION did not yield major.minor.patch, got '$pinned'"
    report
    exit 1
    ;;
esac
want="${pinned%.*}"

# The rendered file, not the template line: render mode needs no postfix binary, so
# the artifact itself is available on the host and is what Postfix would read.
render_dir="$WORK/render"
mkdir -p "$render_dir"
if env -i PATH="$PATH" CONF_DIR="$render_dir" RELAY_HOST=smtp.example.com \
  sh "$ENTRYPOINT" render >/dev/null 2>&1; then
  ok "entrypoint.sh render produced a main.cf to read the level out of"
else
  no "entrypoint.sh render produced a main.cf to read the level out of" \
    "render exited $? (CONF_DIR=$render_dir)"
  report
  exit 1
fi

# --- 1. the rendered level matches the pinned release's major.minor -------------
# Asserting the exact value rather than an ordering: a level ABOVE the pin would
# also silence the reminder, and would adopt defaults from a Postfix this image
# does not ship.
got=$(sed -n 's/^compatibility_level = \(.*\)$/\1/p' "$render_dir/main.cf")
[ "$got" = "$want" ] \
  && ok "the rendered compatibility_level ($got) is the pinned Postfix major.minor" \
  || no "rendered compatibility_level tracks the Postfix pin" \
    "rendered '$got', pinned Postfix $pinned wants '$want'; below it every startup postfix invocation prints the backwards-compatibility reminder"

# --- 2. exactly one level line is rendered --------------------------------------
# Postfix reads the LAST assignment, so a second line would decide the level while
# case 1 kept passing on the first.
count=$(grep -c '^compatibility_level' "$render_dir/main.cf" || true)
[ "$count" = 1 ] \
  && ok "main.cf carries exactly one compatibility_level line" \
  || no "one compatibility_level line" "found $count; Postfix honours the last one"

report
