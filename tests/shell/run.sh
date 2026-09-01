#!/usr/bin/env bash
# Runs every entrypoint.sh unit test in this directory.
#
# This filename is the contract: cplieger/ci's shell-ci.yaml runs
# `tests/shell/run.sh` when it exists, and skips otherwise, so a repo opts into
# shell unit testing by committing this file. Keep the name. The hook tests -f and
# invokes it through `bash`, so the exec bit is not load-bearing.
#
# SCOPE. The shipped shell is THREE files — entrypoint.sh (PID 1, modes
# run|render) plus the sourced validate.sh and recipient-filter.sh — and the other
# two harnesses reach only part of it. image-smoke.sh asserts the image boots, so
# it never takes a failure branch. render-test.sh drives `entrypoint.sh render`,
# which stops at two hard edges: render mode returns before the whole run-mode half
# (the SASL secret write and its postmap, the upstream TCP probe, queue telemetry,
# startup timeout accounting), and a process-level harness sees only ONE exit 2 for
# a validator that refuses on seven distinct arms. These tests take the other side
# of both edges.
#
# Each *_test.sh is a separate process, so one test's stubs, traps and shell
# options cannot leak into another's. All run even when an early one fails.
set -u

cd -- "$(dirname -- "$0")" || exit 1

failed=0
ran=0
for t in ./*_test.sh; do
  # A glob that matches nothing expands to itself; treat that as a harness fault
  # rather than a green run, since an empty suite passing silently is how a
  # test directory quietly stops testing anything.
  if [ ! -f "$t" ]; then
    printf 'harness error: no *_test.sh found in %s\n' "$PWD" >&2
    exit 1
  fi
  printf '=== %s\n' "$(basename "$t")"
  if ! bash "$t"; then
    failed=$((failed + 1))
  fi
  ran=$((ran + 1))
  printf '\n'
done

if [ "$failed" -ne 0 ]; then
  printf 'FAILED: %d of %d entrypoint test files failed\n' "$failed" "$ran" >&2
  exit 1
fi
printf 'all %d entrypoint test files passed\n' "$ran"
