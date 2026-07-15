# check=error=true

# Postfix is built from the pinned upstream source release below (the
# vdukhovni/postfix repo is the official upstream mirror; release tags are
# vX.Y.Z). versioning=semver keeps Renovate off the repo's ancient non-semver
# v20010228* historical tags, which semver-coerced ordering would rank higher.
# renovate: datasource=github-tags depName=vdukhovni/postfix versioning=semver
ARG POSTFIX_VERSION=v3.11.5
# When POSTFIX_VERSION is bumped, update this SHA256 to match the new dist
# tarball. Renovate can't recompute it (github-tags exposes the git sha, not
# the tarball hash), so the bump PR carries the recompute command - run it,
# paste the result here, push:
# curl -sL https://high5.nl/mirrors/postfix-release/official/postfix-<X.Y.Z>.tar.gz | sha256sum
ARG POSTFIX_SHA256=4a6ab3d0e9390989fa201fc6c446045fc702c4e16e7a247c3ae261c9e9bee610

# ---------------------------------------------------------------------------
# Builder stage - compiles Postfix from the pinned upstream source tarball
# (fetched from the same release mirror Alpine's own package builds use,
# SHA256-verified fail-closed) with feature parity to Alpine 3.24's
# main/postfix package, mirroring its APKBUILD makedefs selections: TLS
# (openssl), Cyrus SASL client auth, PCRE2, LMDB as the default database type
# with Berkeley DB disabled (hash:/btree: maps transparently use LMDB - see
# Postfix's NON_BERKELEYDB_README; the entrypoint's `hash:` sasl_passwd map
# and `btree:` TLS session cache both depend on this), NIS off, and
# EAI/SMTPUTF8 on (makedefs auto-detects icu-dev). The LDAP/MySQL/PgSQL/
# SQLite backends that Alpine splits into subpackages (never installed by
# this image) are skipped, and map types are compiled in statically
# (dynamicmaps=no) instead of split into plugin .so files. The postfix user
# and postfix/postdrop groups exist here only so postfix-install can resolve
# ownership while staging into /out; they use the same numeric IDs as the
# runtime stage, which COPY --from preserves.
# ---------------------------------------------------------------------------
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Build deps are build-only (discarded with this stage, absent from the final
# image), so their exact versions never reach the shipped artifact and are
# intentionally left unpinned - they track whatever the Alpine 3.24 repo
# serves at build time (the digest pins the base image, not the apk index).
# Postfix itself stays version+SHA pinned above - it is the shipped artifact.
# hadolint ignore=DL3018
RUN apk add --no-cache \
        build-base \
        coreutils \
        cyrus-sasl-dev \
        icu-dev \
        linux-headers \
        lmdb-dev \
        m4 \
        openssl-dev \
        pcre2-dev \
        pkgconf \
    && addgroup -S -g 101 postfix \
    && addgroup -S -g 102 postdrop \
    && adduser -S -u 100 -H -h /var/spool/postfix -G postfix -g postfix postfix

ARG POSTFIX_VERSION
ARG POSTFIX_SHA256
WORKDIR /build/postfix
# Fetch + verify + build + stage-install. The seds replicate Alpine's aports
# prepare()/package() steps so the installed tree matches the apk package
# byte-for-byte where it matters: NIS map support off, default alias database
# under /etc/postfix, /usr/local paths dropped from master.cf, mail_version
# resolved via the staged config dir (the builder has no /etc/postfix), and
# postfix-files trimmed of doc/manpage/.default/LICENSE entries so `postfix
# set-permissions` (run by the entrypoint at every boot) keeps working
# against the slimmed install. Each sed is grep-verified so silent drift in
# upstream sources fails the build instead of shipping a behavior change.
# The single-quoted `$CONFIG_DIRECTORY` in the postfix-install sed is meant
# literally (postfix-install expands it at install time, not this shell), so
# SC2016 is a false positive here.
# hadolint ignore=SC2016
RUN wget -q --tries=3 --timeout=30 \
        "https://high5.nl/mirrors/postfix-release/official/postfix-${POSTFIX_VERSION#v}.tar.gz" \
    && echo "${POSTFIX_SHA256}  postfix-${POSTFIX_VERSION#v}.tar.gz" | sha256sum -c - \
    && tar xzf "postfix-${POSTFIX_VERSION#v}.tar.gz" --strip-components=1 --no-same-owner \
    && rm "postfix-${POSTFIX_VERSION#v}.tar.gz" \
    && sed -i -e 's|#define HAS_NIS|//#define HAS_NIS|g' \
           -e '/^#define ALIAS_DB_MAP/s|:/etc/aliases|:/etc/postfix/aliases|' \
           src/util/sys_defs.h \
    && grep -q '//#define HAS_NIS' src/util/sys_defs.h \
    && grep -q ':/etc/postfix/aliases' src/util/sys_defs.h \
    && sed -i 's:/usr/local/:/usr/:g' conf/master.cf \
    && sed -i 's|"`bin/postconf -dhx mail_version`"|"`bin/postconf -c $CONFIG_DIRECTORY -dhx mail_version`"|' postfix-install \
    && grep -q 'postconf -c \$CONFIG_DIRECTORY' postfix-install \
    && cflags="-Os -fstack-clash-protection -Wformat -Werror=format-security" \
    && ldflags="-Wl,--as-needed,-O1,--sort-common" \
    && ccargs='-DNO_DB -DDEF_CACHE_DB_TYPE=\"lmdb\"' \
    && ccargs="$ccargs -DHAS_PCRE=2 $(pcre2-config --cflags)" \
    && ccargs="$ccargs -DUSE_TLS" \
    && ccargs="$ccargs -DUSE_SASL_AUTH -DDEF_SASL_SERVER=\\\"dovecot\\\"" \
    && ccargs="$ccargs -DUSE_CYRUS_SASL -I/usr/include/sasl" \
    && ccargs="$ccargs -DHAS_LMDB $(pkg-config --cflags lmdb) -DDEF_DB_TYPE=\\\"lmdb\\\"" \
    && auxlibs="$ldflags -lssl -lcrypto -lsasl2" \
    && make DEBUG="" \
        OPT="$cflags" \
        CCARGS="-std=gnu17 $ccargs" \
        AUXLIBS="$auxlibs" \
        AUXLIBS_PCRE="$(pkg-config --libs libpcre2-8)" \
        AUXLIBS_LMDB="$(pkg-config --libs lmdb)" \
        config_directory=/etc/postfix \
        meta_directory=/etc/postfix \
        daemon_directory=/usr/libexec/postfix \
        shlib_directory=/usr/lib/postfix \
        dynamicmaps=no \
        shared=yes \
        makefiles \
    && make -j"$(nproc)" OPT="$cflags" \
    && make non-interactive-package \
        install_root=/out \
        readme_directory=no \
        manpage_directory=/usr/share/man \
    && for i in postdrop postqueue; do \
         chgrp postdrop "/out/usr/sbin/$i" && chmod g+s "/out/usr/sbin/$i"; \
       done \
    && rm -f /out/etc/postfix/*.default /out/etc/postfix/*LICENSE* \
        /out/etc/postfix/makedefs.out \
    && sed -i \
        -e '/shlib_directory\/postfix-/d' \
        -e '/meta_directory\/makedefs.out/d' \
        -e '/manpage_directory/d' \
        -e '/config_directory\/LICENSE/d' \
        -e '/config_directory\/TLS_LICENSE/d' \
        -e '/config_directory\/[^/]\+\.cf\.default/d' \
        /out/etc/postfix/postfix-files \
    # Fail-closed guard on the postfix-files trims above, matching the grep
    # gates on the other seds: every deleted entry class must be gone (a
    # postfix-files format change would otherwise leave stale entries for
    # files the rm/trim removed, and `postfix set-permissions` — run by the
    # entrypoint at every boot — would trip on them at runtime instead of
    # build time), AND load-bearing surviving entries must still be present
    # (proves the seds did not over-delete or hit an empty/renamed file).
    && ! grep -q \
        -e 'shlib_directory/postfix-' \
        -e 'meta_directory/makedefs\.out' \
        -e 'manpage_directory' \
        -e 'config_directory/LICENSE' \
        -e 'config_directory/TLS_LICENSE' \
        -e 'config_directory/[^/]\+\.cf\.default' \
        /out/etc/postfix/postfix-files \
    && grep -q '^\$config_directory/main\.cf:' /out/etc/postfix/postfix-files \
    && grep -q '^\$daemon_directory/smtpd:' /out/etc/postfix/postfix-files \
    && grep -q '^\$queue_directory/maildrop:' /out/etc/postfix/postfix-files \
    && chown postfix /out/var/spool/postfix/* /out/var/lib/postfix \
    && chown root:postfix /out/var/spool/postfix/pid \
    && chgrp postdrop /out/var/spool/postfix/maildrop /out/var/spool/postfix/public

# ---------------------------------------------------------------------------
# Runtime base stage - digest-pinned base plus unpinned runtime libraries,
# with the staged Postfix installation copied from the builder (daemons,
# tools, shared libs, /etc/postfix defaults, spool/data skeletons; manpages
# and readmes excluded). cyrus-sasl/cyrus-sasl-login deliberately stay
# apk-installed: they are runtime SASL plugins, not the pinned payload.
# ---------------------------------------------------------------------------
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS base

# apk upgrade: the pinned base ships some packages (e.g. libssl3) at a stale,
# CVE-affected revision; upgrading floats them forward on each rebuild.
# The users/groups recreate the apk postfix package's numeric IDs (postfix
# 100:101, postdrop 102) so an existing spool volume keeps its ownership
# across the apk-to-source-build conversion.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        ca-certificates \
        cyrus-sasl \
        cyrus-sasl-login \
        icu-libs \
        libcrypto3 \
        libssl3 \
        lmdb \
        pcre2 \
    && addgroup -S -g 101 postfix \
    && addgroup -S -g 102 postdrop \
    && adduser -S -u 100 -H -h /var/spool/postfix -G postfix -g postfix postfix \
    && addgroup postfix mail \
    # data_directory starts empty (runtime caches/locks only), so create it
    # directly with the apk package's ownership/mode (postfix:root 700); a
    # COPY of the empty staged dir would land root-owned 755 and postfix
    # would warn "not owned by postfix" until set-permissions runs.
    && install -d -m 700 -o postfix -g root /var/lib/postfix

COPY --from=builder /out/usr/libexec/postfix/ /usr/libexec/postfix/
COPY --from=builder /out/usr/lib/postfix/ /usr/lib/postfix/
COPY --from=builder /out/usr/sbin/ /usr/sbin/
COPY --from=builder /out/etc/postfix/ /etc/postfix/
COPY --from=builder /out/var/spool/postfix/ /var/spool/postfix/

# newaliases/mailq are hard links to sendmail in the upstream install; COPY
# would materialize them as two extra full copies, so recreate the links the
# way postfix-install does. Ownership/modes are baked correctly above and
# `postfix set-permissions` (run by the entrypoint at every boot) re-asserts
# the whole layout from /etc/postfix/postfix-files on top of any volume.
RUN ln -f /usr/sbin/sendmail /usr/bin/newaliases \
    && ln -f /usr/sbin/sendmail /usr/bin/mailq

# ---------------------------------------------------------------------------
# Test stage - runs the golden-file config-generation tests at build time
# (`entrypoint.sh render` needs only busybox tools), then asserts the
# source-built Postfix: exact pinned version; TLS, Cyrus SASL client, and
# EAI/SMTPUTF8 compiled in; every map type the generated config relies on
# (hash:/btree: on lmdb, regexp:, plus cidr and pcre) present; setgid
# postdrop plumbing intact after COPY; and a boot-shaped sequence (render to
# /etc/postfix, newaliases, `postfix check`, regexp lookup, postmap/lmdb
# round-trip) passes. A failure fails the build.
# ---------------------------------------------------------------------------
FROM base AS test
ARG POSTFIX_VERSION
COPY --chmod=755 validate.sh recipient-filter.sh entrypoint.sh /usr/local/bin/
COPY tests/ /tmp/tests/
RUN ENTRYPOINT_DIR=/usr/local/bin sh /tmp/tests/render-test.sh \
    && test "$(postconf -h mail_version)" = "${POSTFIX_VERSION#v}" \
    && postconf -T compile-version >/dev/null \
    && ldd /usr/libexec/postfix/smtpd >/tmp/smtpd-libs \
    && grep -q libicuuc /tmp/smtpd-libs \
    && postconf -A >/tmp/sasl-client-types \
    && grep -qx cyrus /tmp/sasl-client-types \
    && postconf -m >/tmp/map-types \
    && for m in btree cidr hash lmdb pcre regexp; do \
         grep -qx "$m" /tmp/map-types || exit 1; \
       done \
    && test -g /usr/sbin/postdrop \
    && test -g /usr/sbin/postqueue \
    && env CONF_DIR=/etc/postfix RELAY_HOST=smtp.example.com \
        RECIPIENT_RESTRICTIONS="ops@example.com" \
        sh /usr/local/bin/entrypoint.sh render \
    && newaliases \
    && postfix check \
    && test "$(postconf -hx smtputf8_enable)" = "yes" \
    && test "$(postmap -q ops@example.com regexp:/etc/postfix/recipient_access)" = "OK" \
    && printf '%s\n' 'smtp.example.com probe:secret' >/tmp/sasl-probe \
    && postmap /tmp/sasl-probe \
    && test -f /tmp/sasl-probe.lmdb \
    && rm -f /tmp/sasl-probe /tmp/sasl-probe.lmdb /tmp/map-types \
        /tmp/sasl-client-types /tmp/smtpd-libs \
    && touch /tmp/tests-passed

# ---------------------------------------------------------------------------
# Final stage - the runtime image. It must remain the last stage so the
# centralized CI build-gate (which builds the default target) produces it.
# ---------------------------------------------------------------------------
FROM base AS final

COPY --chmod=755 validate.sh recipient-filter.sh entrypoint.sh /usr/local/bin/

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
