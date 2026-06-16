# check=error=true

FROM alpine:3.24.1@sha256:bec4ccd3817e7c824eb0388971a0b83fab111d586285511ba0266b77e8dc65a9 AS base

# apk upgrade: the pinned base ships some packages (e.g. libssl3) at a stale,
# CVE-affected revision; upgrading floats them forward on each rebuild.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        ca-certificates \
        cyrus-sasl \
        cyrus-sasl-login \
        postfix \
        tzdata

# ---------------------------------------------------------------------------
# Test stage — runs the golden-file config-generation tests at build time.
# `entrypoint.sh render` validates env and renders main.cf + recipient_access
# without invoking Postfix, so the tests need only the busybox tools already
# in the base image. A diff against the committed fixtures fails the build.
# ---------------------------------------------------------------------------
FROM base AS test
COPY --chmod=755 validate.sh recipient-filter.sh entrypoint.sh /usr/local/bin/
COPY tests/ /tmp/tests/
RUN ENTRYPOINT_DIR=/usr/local/bin sh /tmp/tests/render-test.sh \
        && touch /tmp/tests-passed

# ---------------------------------------------------------------------------
# Final stage — the runtime image. It must remain the last stage so the
# centralized CI build-gate (which builds the default target) produces it.
# ---------------------------------------------------------------------------
FROM base AS final

COPY --chmod=755 validate.sh /usr/local/bin/validate.sh
COPY --chmod=755 recipient-filter.sh /usr/local/bin/recipient-filter.sh
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Pull a 0-byte marker from the test stage so building `final` forces the
# build-time golden tests to run and pass first. The marker is the only thing
# carried over; the tests/ tree never reaches the runtime image.
COPY --from=test /tmp/tests-passed /tmp/tests-passed

EXPOSE 25

# Run as root (uid:gid 0:0) by default — Postfix master needs root to bind
# port 25; smtpd workers drop to the postfix user internally via setuid+chroot.
# This is the image default and can be overridden at run time (e.g. compose
# `user:`) if you front the relay differently. AVD-DS-0002 is suppressed via
# .trivyignore at the repo root; see the rationale there.
# hadolint ignore=DL3002
USER 0:0

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD nc -w 3 127.0.0.1 25 < /dev/null | grep -q '^220 ' || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
