# Contributing to docker-smtp-relay

The [shared rules](https://github.com/cplieger/.github/blob/main/CONTRIBUTING.md) for commits, releases, synced files and checks apply here.

## Rules

- A new setting needs a default in `apply_defaults` and a row in `_spec_table` in `entrypoint.sh`, a case in `tests/render-test.sh`, and a row in the settings table of `docs/configuration.md`. Without the `_spec_table` row, its value skips the newline check.
- Nothing `render_config` calls, in `entrypoint.sh` or `recipient-filter.sh`, runs Postfix, writes a secret or opens a connection. The golden tests run that path without Postfix, and CI runs them only inside the image, so CI can miss the break.
- Write every new log line as a `level=... msg="..."` record. The README and `docs/monitoring.md` quote the startup lines that readers search for and alert on, so a change to a quoted line updates those pages in the same commit.
- A package the `apk add` of the Dockerfile's `base` stage gains, its dependencies included, needs a line in `licenses/APK-MANIFEST`. A new origin also needs `licenses/<origin>/` with a one-line `SOURCE` and each license file it publishes. No check catches a gap.

## Checks

Run `sh tests/render-test.sh` after a change to a validator or to what the entrypoint renders. It needs no Docker and no Postfix. CI runs it only inside the image build, so without Docker the local CI run skips it.
