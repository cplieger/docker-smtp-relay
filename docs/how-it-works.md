# How docker-smtp-relay works

This page describes the design of docker-smtp-relay and what happens each time the container starts, for readers who want to know what runs inside it.

## Design

- The relay only forwards mail. It does no local delivery, keeps no mailboxes and routes no inbound mail from the internet. Mail addressed to `localhost` is never delivered locally, and everything your apps send goes to the one server in `RELAY_HOST`.
- Configuration comes from environment variables only. The entrypoint writes `main.cf` and the recipient filter from them at every start, so there is no Postfix file to learn or keep in step.
- Every setting is checked before Postfix starts. A bad value stops the container with a log line, instead of starting a relay that is set up wrong.
- Postfix is the container's main process, started in the foreground with `postfix start-fg`, so Docker's stop signal reaches it directly. When it stops, the container exits and Docker's restart policy starts it again, with no supervisor in between.

## What happens at each start

1. The entrypoint fills in defaults and checks every setting. A failed check exits with code 2.
2. It writes `main.cf`, and the recipient filter when `RECIPIENT_RESTRICTIONS` is set. Each file is written to a temporary name and then moved into place, so Postfix never reads a half-written file.
3. With a login set, it writes the provider login to Postfix's lookup table and deletes the plaintext copy.
4. It runs `newaliases`, `postfix check` and `postfix set-permissions`. A failed check or permission fix exits with code 1 and the reason in the log.
5. With `STARTUP_PROBE` on, it checks that your provider's server answers on its port and logs the result. A failure only logs a warning, and mail queues.
6. It logs `starting smtp-relay` with the queue depth left from the previous run, then hands over to Postfix.

Each startup step that calls a Postfix tool has a 30-second limit, and the queue count has 5 seconds. A stuck disk cannot hold the start forever. A step that runs out of time logs `reason=timeout`. A stop request during startup ends the start cleanly within Docker's stop grace period.

Exit code 2 always means a setting to fix. Exit code 1 means a runtime failure, such as a full disk or a Postfix check that failed.

## Postfix version and defaults

The entrypoint sets `compatibility_level` to the major and minor version of the Postfix release the image ships, and a test keeps the two in step. Postfix then runs on that release's own defaults and logs no compatibility reminders at start.

Postfix and the entrypoint both log to the container's standard output in UTC, so their lines share one timeline. The image ships no time zone data, and `TZ` has no effect.
