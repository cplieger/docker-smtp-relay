# Contributing to docker-smtp-relay

Notes on the architecture and conventions specific to this image. The
generic [cplieger contributing defaults](https://github.com/cplieger/.github/blob/main/CONTRIBUTING.md)
still apply; this file covers what is particular to a Postfix relay
configured entirely from a POSIX `sh` entrypoint.

## Architecture

This is a relay-only Postfix MTA built on Alpine. There is no `main.cf`
template — the entrypoint generates the whole config from environment
variables at container start, validating every input before Postfix
runs. Three scripts are copied into `/usr/local/bin/` and run as a unit:

- `entrypoint.sh` — the orchestrator (PID 1). Runs in one of two modes
  (dispatched on `$1`): `run` (default) applies defaults, validates,
  configures SASL, renders the config, probes the upstream relay, then
  `exec postfix start-fg`; `render` does defaults + validation + config
  rendering only (no secrets written, no Postfix invoked) and is what the
  golden-file tests drive. The generated files are written under `CONF_DIR`
  (default `/etc/postfix`; the tests override it to a temp dir). Logic is
  decomposed into functions (`apply_defaults`, `validate_config`,
  `compute_sasl_state`, `render_main_cf`, `probe_upstream`, …) shared between
  the two modes.
- `validate.sh` — pure validation helpers (`validate_no_newlines`,
  `validate_numeric`, `validate_no_metacharacters`, `validate_range`,
  `validate_no_open_relay`, `validate_tls_level`, `validate_sasl_*`).
  Sourced by the entrypoint; no side effects.
- `recipient-filter.sh` — builds `/etc/postfix/recipient_access` and sets
  `SMTPD_RECIPIENT_RESTRICTIONS` from `RECIPIENT_RESTRICTIONS`.

Validation is data-driven: `_spec_table` in `entrypoint.sh` maps each
env var to a comma-separated list of checks (`nl`, `num`, `meta`,
`range=MIN:MAX`). Add a new validated variable by extending that table —
the loop resolves each row's value indirectly from the named variable, so
the name lives in exactly one place (no per-var `case` to keep in sync, and
no hand-written `if` block). Field-specific checks that don't fit the table
(`validate_sasl_login`, `validate_tls_level`, open-relay rejection) run
explicitly after the table loop.

## Local build and validate

The shell scripts are linted with [ShellCheck](https://www.shellcheck.net/)
and the `Dockerfile` with [hadolint](https://github.com/hadolint/hadolint);
both are enforced in CI. Run them before pushing:

```sh
shellcheck entrypoint.sh validate.sh recipient-filter.sh
hadolint Dockerfile
```

CI is centralized — `.github/workflows/*.yaml` call reusable workflows in
`cplieger/ci` and are marked `DO NOT EDIT`. Change CI behavior there, not
here.

Build the image locally to exercise config generation and startup:

```sh
docker build -t smtp-relay:dev .
```

The `Dockerfile` sets `# check=error=true`, so BuildKit check warnings
fail the build. Config generation is covered by golden-file tests in
`tests/`: `tests/render-test.sh` runs `entrypoint.sh render` across a matrix
of env inputs and diffs the generated `main.cf` / `recipient_access` against
the fixtures in `tests/golden/`, asserting exit 2 for invalid inputs. Run them
locally from the repo root:

```sh
sh tests/render-test.sh
```

After an intended change to the generated config, regenerate the fixtures and
review the diff before committing:

```sh
sh tests/render-test.sh --record
```

The build runs the same harness in a dedicated `test` stage (the final image
`COPY --from=test` a marker, so the tests must pass before the image is
produced); the centralized `ci / validate` Docker build-gate therefore runs
them too.

The validators live entirely in this repo's `validate.sh`; there is no shared
validation library. When you change a validator, update the golden fixtures
under `tests/` that exercise it and re-run `sh tests/render-test.sh` -- there is
no second copy to keep in sync.

## Conventions and gotchas

- **`set -euf`.** The `-f` (disable globbing) is load-bearing:
  `ACCEPTED_NETWORKS` and `RECIPIENT_RESTRICTIONS` are iterated via
  unquoted word-splitting, so a glob metacharacter in an entry must not
  expand against the working directory. Don't drop `-f`.
- **Source, don't subshell.** `build_recipient_filter` sets
  `SMTPD_RECIPIENT_RESTRICTIONS` for the caller, so `recipient-filter.sh`
  is sourced (`. "$(dirname "$0")/recipient-filter.sh"`) and the function
  is called directly. Running it in a subshell would lose the variable.
- **`main.cf` is generated.** It carries a "Do not edit; edits are
  discarded on restart" banner. Change the heredoc in `entrypoint.sh`, not
  a checked-in config file.
- **Recipient tokens are escaped before regex.** `escape_postfix_regex`
  renders operator-supplied addresses and domains as literals inside
  Postfix `regexp:` patterns. A non-empty `RECIPIENT_RESTRICTIONS` that
  parses to zero rules is treated as a fatal error (exit 2) rather than
  silently rejecting all mail.
- **Exit codes.** `2` = config/validation failure, `1` = runtime failure.
  Keep that split when adding new failure paths.
- **Runs as root by design.** Postfix's master needs root to bind port 25;
  workers drop privileges internally. The Dockerfile sets `USER 0:0` as the
  overridable default; the resulting `AVD-DS-0002` (trivy) and `DL3002`
  (hadolint, "last USER root") findings are suppressed with rationale
  (`.trivyignore` and an inline `# hadolint ignore=DL3002`). Keep root as the
  default unless you also rework the port-25 bind.
- **Logs are structured.** Status lines use `level=... msg="..."` key-value
  format so they parse cleanly in Loki/Grafana. Match it for new output.
- **`render` mode must stay side-effect-free.** `entrypoint.sh render` may
  only apply defaults, validate, and write the generated files under
  `CONF_DIR`. Don't add `postmap`, `postfix`, secret writes, or `nc` to the
  shared render path — those belong to `run`-only functions so the golden
  tests stay runnable without root or a Postfix install.
- **Startup probe is fail-soft.** `probe_upstream` is a plain TCP check and
  must never block startup: a failure logs a warning and returns 0 so mail
  still queues. Keep it bounded by `STARTUP_PROBE_TIMEOUT` (under the
  healthcheck `--start-period`) and never make it attempt SASL AUTH.
- Match the existing 2-space indentation in the shell scripts
  (`shfmt -i 2 -ci`, matching `.editorconfig`).

## Commits and PRs

Commits follow [Conventional Commits](https://www.conventionalcommits.org/);
`cliff.toml` parses them for release notes and version bumps (`feat:` →
minor, `fix:`/`sec:` → patch/security, breaking → major). Write the subject
as the changelog line a user would read. Open an issue first for larger
changes so the approach can be discussed.

## Conduct and security

By participating you agree to the
[Code of Conduct](https://github.com/cplieger/.github/blob/main/CODE_OF_CONDUCT.md).
Report vulnerabilities through the
[security policy](https://github.com/cplieger/.github/blob/main/SECURITY.md) —
never in a public issue.
