#!/usr/bin/env bash
# Runs every entrypoint.sh unit test in this directory.
#
# This filename is the contract: cplieger/ci's shell-ci.yaml runs
# `tests/shell/run.sh` when it exists, and skips otherwise, so a repo opts into
# shell unit testing by committing this file. Keep the name.
#
# The hook tests -f and invokes this through `bash`, so the exec bit is not
# load-bearing (it was committed 100644 once, which under an -x check would have
# skipped the whole suite silently and still reported CI green). The bit is set
# anyway, for anyone running it directly.
#
# WHAT THIS REPO'S SUITE COVERS. This file is repo-owned (lib.sh and
# harness_test.sh beside it are synced from cplieger/ci), so the per-repo scope
# rationale lives here.
#
# Not the image smoke test, and not
# tests/render-test.sh: the shipped shell is THREE files — entrypoint.sh (PID 1,
# modes run|render) plus the sourced validate.sh and recipient-filter.sh — and the
# existing harnesses reach only part of it. tests/image-smoke.sh builds an image
# and asserts it boots, so it never takes a failure branch at all.
# tests/render-test.sh drives `entrypoint.sh render` across an env matrix, which
# covers config generation but stops at two hard edges: render mode returns before
# the whole run-mode half (the SASL secret write and its postmap, the upstream TCP
# probe, the queue-depth telemetry, the startup timeout accounting), and a
# process-level harness sees only ONE exit 2 for a validator that refuses on seven
# distinct arms. These tests take the other side of both edges: the run-mode
# helpers no render ever executes, and the individual refusal — its message, not
# just its exit code — that a matrix collapses.
#
# Each *_test.sh is a separate process, so one test's stubs, traps and shell
# options cannot leak into another's. All of them run even when an early one
# fails: a boot path's tests are cheap, and a maintainer wants the whole picture
# from one CI log rather than one failure at a time.
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
  if bash "$t"; then
    ran=$((ran + 1))
  else
    ran=$((ran + 1))
    failed=$((failed + 1))
  fi
  printf '\n'
done

if [ "$failed" -ne 0 ]; then
  printf 'FAILED: %d of %d entrypoint test files failed\n' "$failed" "$ran" >&2
  exit 1
fi
printf 'all %d entrypoint test files passed\n' "$ran"
