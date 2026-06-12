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

- `entrypoint.sh` — the orchestrator (PID 1). Applies defaults, runs the
  validation pass, configures SASL, sources the recipient filter,
  renders `/etc/postfix/main.cf`, then `exec postfix start-fg`.
- `validate.sh` — pure validation helpers (`validate_no_newlines`,
  `validate_numeric`, `validate_no_metacharacters`, `validate_range`,
  `validate_no_open_relay`, `validate_tls_level`, `validate_sasl_*`).
  Sourced by the entrypoint; no side effects.
- `recipient-filter.sh` — builds `/etc/postfix/recipient_access` and sets
  `SMTPD_RECIPIENT_RESTRICTIONS` from `RECIPIENT_RESTRICTIONS`.

Validation is data-driven: `VALIDATION_SPEC` in `entrypoint.sh` maps each
env var to a comma-separated list of checks (`nl`, `num`, `meta`,
`range=MIN:MAX`). Add a new validated variable by extending that table
and the `case` that resolves its value — not by hand-writing another
`if` block. Field-specific checks that don't fit the table
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
fail the build. There is no unit-test harness in this repo: the entrypoint
validators mirror a shared reference library (see the `validate.sh` header
note, "Keep in sync with `lib/shell/validate.sh`") whose test suite runs in
CI. If you change a validator here, port the same change to that library so
the two stay aligned.

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
  workers drop privileges internally. `AVD-DS-0002` is suppressed in
  `.trivyignore` with the rationale — don't add a `USER` line.
- **Logs are structured.** Status lines use `level=... msg="..."` key-value
  format so they parse cleanly in Loki/Grafana. Match it for new output.
- Match the existing tab indentation in the shell scripts.

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
