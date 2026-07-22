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
# (fetched from the release mirror Alpine's own package builds use, falling
# back to the upstream origin server on a mirror outage, SHA256-verified
# fail-closed either way) with feature parity to Alpine 3.24's
# main/postfix package, mirroring its APKBUILD makedefs selections: TLS
# (openssl), Cyrus SASL client auth, PCRE2, LMDB as the default database type
# with Berkeley DB disabled (hash:/btree: maps transparently use LMDB - see
# Postfix's NON_BERKELEYDB_README; the entrypoint's `hash:` sasl_passwd map
# depends on this; its TLS session cache is an explicit lmdb: map), NIS off, and
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
        gpgv \
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
# Wietse Venema's Postfix release signing key as a minimal dearmored keyring
# (fingerprint 622C7C012254C186677469C50C0B590E80CA15A7, dsa2048/2015-10-10),
# cross-checked against high5.nl and ftp.porcupine.org (wietse.pgp, identical
# bytes on both) and keyserver.ubuntu.com. gpgv below verifies the release's
# detached .gpg2 signature against it, authenticating the publisher
# independently of the mirrors: the SHA256 pin alone is refreshed from the
# same mirror that serves the tarball, so a compromised mirror could supply
# both a malicious tarball and its matching hash during a version bump.
# Refresh (only if upstream ever rotates the key - verify the new fingerprint
# against multiple authoritative sources first):
# curl -sL https://high5.nl/mirrors/postfix-release/wietse.pgp | gpg --dearmor > postfix-release.gpg
COPY postfix-release.gpg /usr/local/share/postfix-release.gpg
# Fetch + verify + build + stage-install. The seds replicate Alpine's aports
# prepare()/package() steps so the installed tree matches the apk package
# byte-for-byte where it matters: NIS map support off, default alias database
# under /etc/postfix, /usr/local paths dropped from master.cf, mail_version
# resolved via the staged config dir (the builder has no /etc/postfix), and
# postfix-files trimmed of doc/manpage/.default/LICENSE entries so `postfix
# set-permissions` (run by the entrypoint at every boot) keeps working
# against the slimmed install. Each sed is guarded fail-closed: a pre-sed
# grep requires the exact expected upstream form (so source drift during a
# version bump fails the build), and post-sed greps require the old form
# absent and the new form present (so a sed that silently no-ops fails too).
# The single-quoted `$CONFIG_DIRECTORY` in the postfix-install sed is meant
# literally (postfix-install expands it at install time, not this shell), so
# SC2016 is a false positive here.
# The tarball is fetched from the primary mirror (high5.nl, the release
# mirror Alpine's own package builds use) with the upstream origin server
# (ftp.porcupine.org, plain HTTP — integrity comes from the SHA256 pin and
# the gpgv signature check, not the transport) as fallback, so a
# single-mirror outage cannot block builds. The detached .gpg2 signature is
# fetched with the same primary/fallback pair and verified with gpgv against
# the committed release keyring before the SHA check and extraction; both
# gates are fail-closed. -O pins the output name on both attempts so a
# partial file from a failed primary fetch is truncated by the fallback
# instead of being saved aside. wget deliberately runs without -q so a
# mirror/network failure keeps its diagnostic in the BuildKit log (DL3047
# wants -q/-nv/--progress back, but busybox wget has no -nv/--progress and
# -q is what silenced fetch failures; BuildKit hides the output on success).
# hadolint ignore=SC2016,DL3047
RUN { wget --tries=3 --timeout=30 -O "postfix-${POSTFIX_VERSION#v}.tar.gz" \
        "https://high5.nl/mirrors/postfix-release/official/postfix-${POSTFIX_VERSION#v}.tar.gz" \
      || wget --tries=3 --timeout=30 -O "postfix-${POSTFIX_VERSION#v}.tar.gz" \
        "http://ftp.porcupine.org/mirrors/postfix-release/official/postfix-${POSTFIX_VERSION#v}.tar.gz"; } \
    && { wget --tries=3 --timeout=30 -O "postfix-${POSTFIX_VERSION#v}.tar.gz.gpg2" \
        "https://high5.nl/mirrors/postfix-release/official/postfix-${POSTFIX_VERSION#v}.tar.gz.gpg2" \
      || wget --tries=3 --timeout=30 -O "postfix-${POSTFIX_VERSION#v}.tar.gz.gpg2" \
        "http://ftp.porcupine.org/mirrors/postfix-release/official/postfix-${POSTFIX_VERSION#v}.tar.gz.gpg2"; } \
    && gpgv --keyring /usr/local/share/postfix-release.gpg \
        "postfix-${POSTFIX_VERSION#v}.tar.gz.gpg2" "postfix-${POSTFIX_VERSION#v}.tar.gz" \
    && printf '%s  %s\n' "$POSTFIX_SHA256" "postfix-${POSTFIX_VERSION#v}.tar.gz" | sha256sum -c - \
    && tar xzf "postfix-${POSTFIX_VERSION#v}.tar.gz" --strip-components=1 --no-same-owner \
    && rm "postfix-${POSTFIX_VERSION#v}.tar.gz" "postfix-${POSTFIX_VERSION#v}.tar.gz.gpg2" \
    && { grep -q '^#define HAS_NIS' src/util/sys_defs.h \
      || { printf '%s\n' 'FAIL: expected active #define HAS_NIS missing from src/util/sys_defs.h (upstream source drift)' >&2; exit 1; }; } \
    && { grep -q '^#define ALIAS_DB_MAP.*:/etc/aliases' src/util/sys_defs.h \
      || { printf '%s\n' 'FAIL: expected ALIAS_DB_MAP :/etc/aliases form missing from src/util/sys_defs.h (upstream source drift)' >&2; exit 1; }; } \
    && sed -i -e 's|#define HAS_NIS|//#define HAS_NIS|g' \
           -e '/^#define ALIAS_DB_MAP/s|:/etc/aliases|:/etc/postfix/aliases|' \
           src/util/sys_defs.h \
    && { ! grep -q '^#define HAS_NIS' src/util/sys_defs.h \
      || { printf '%s\n' 'FAIL: an active #define HAS_NIS survived the sed in src/util/sys_defs.h' >&2; exit 1; }; } \
    && { grep -q '^//#define HAS_NIS' src/util/sys_defs.h \
      || { printf '%s\n' 'FAIL: HAS_NIS was not commented out in src/util/sys_defs.h' >&2; exit 1; }; } \
    && { ! grep -q '^#define ALIAS_DB_MAP.*:/etc/aliases' src/util/sys_defs.h \
      || { printf '%s\n' 'FAIL: an ALIAS_DB_MAP :/etc/aliases form survived the sed in src/util/sys_defs.h' >&2; exit 1; }; } \
    && { grep -q '^#define ALIAS_DB_MAP.*:/etc/postfix/aliases' src/util/sys_defs.h \
      || { printf '%s\n' 'FAIL: ALIAS_DB_MAP was not rewritten to /etc/postfix/aliases in src/util/sys_defs.h' >&2; exit 1; }; } \
    && { grep -q '/usr/local/' conf/master.cf \
      || { printf '%s\n' 'FAIL: expected /usr/local/ paths missing from conf/master.cf (upstream source drift)' >&2; exit 1; }; } \
    && sed -i 's:/usr/local/:/usr/:g' conf/master.cf \
    && { ! grep -q '/usr/local/' conf/master.cf \
      || { printf '%s\n' 'FAIL: /usr/local/ paths remain in conf/master.cf' >&2; exit 1; }; } \
    && { grep -q 'bin/postconf -dhx mail_version' postfix-install \
      || { printf '%s\n' 'FAIL: expected mail_version lookup missing from postfix-install (upstream source drift)' >&2; exit 1; }; } \
    && sed -i 's|"`bin/postconf -dhx mail_version`"|"`bin/postconf -c $CONFIG_DIRECTORY -dhx mail_version`"|' postfix-install \
    && { ! grep -q 'postconf -dhx mail_version' postfix-install \
      || { printf '%s\n' 'FAIL: the original mail_version lookup survived the sed in postfix-install' >&2; exit 1; }; } \
    && { grep -q 'postconf -c \$CONFIG_DIRECTORY -dhx mail_version' postfix-install \
      || { printf '%s\n' 'FAIL: mail_version lookup in postfix-install was not rewritten to use $CONFIG_DIRECTORY' >&2; exit 1; }; } \
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
    && { ! grep -q \
        -e 'shlib_directory/postfix-' \
        -e 'meta_directory/makedefs\.out' \
        -e 'manpage_directory' \
        -e 'config_directory/LICENSE' \
        -e 'config_directory/TLS_LICENSE' \
        -e 'config_directory/[^/]\+\.cf\.default' \
        /out/etc/postfix/postfix-files \
      || { printf '%s\n' 'FAIL: trimmed doc/manpage/.default/LICENSE entries remain in /out/etc/postfix/postfix-files' >&2; exit 1; }; } \
    && { grep -q '^\$config_directory/main\.cf:' /out/etc/postfix/postfix-files \
      || { printf '%s\n' 'FAIL: $config_directory/main.cf entry missing from /out/etc/postfix/postfix-files' >&2; exit 1; }; } \
    && { grep -q '^\$daemon_directory/smtpd:' /out/etc/postfix/postfix-files \
      || { printf '%s\n' 'FAIL: $daemon_directory/smtpd entry missing from /out/etc/postfix/postfix-files' >&2; exit 1; }; } \
    && { grep -q '^\$queue_directory/maildrop:' /out/etc/postfix/postfix-files \
      || { printf '%s\n' 'FAIL: $queue_directory/maildrop entry missing from /out/etc/postfix/postfix-files' >&2; exit 1; }; } \
    && chown postfix /out/var/spool/postfix/* /out/var/lib/postfix \
    && chown root:postfix /out/var/spool/postfix/pid \
    && chgrp postdrop /out/var/spool/postfix/maildrop /out/var/spool/postfix/public \
    # Embed a minimal CycloneDX component document naming the source-built
    # Postfix. It ships as loose staged files (no apk package), so Syft's
    # default image catalogers record the files but no package identity; the
    # sbom-cataloger (enabled centrally by the release pipeline via the
    # SYFT_SELECT_CATALOGERS env in cplieger/ci docker-release.yaml; no
    # per-repo .syft.yaml - the env var overrides the config-file key)
    # imports this document, so the signed release SBOM carries
    # name/version/purl/cpe and future Postfix advisories can be matched
    # against shipped images. CPE vendor:product is postfix:postfix per the
    # NVD CPE dictionary, e.g.
    # https://nvd.nist.gov/products/cpe/detail/6320E431-6032-481D-87A0-30EECE8EDFD6/
    && mkdir -p /out/usr/share/sbom \
    && printf '{"bomFormat":"CycloneDX","specVersion":"1.5","version":1,"components":[{"type":"application","name":"postfix","version":"%s","purl":"pkg:generic/postfix@%s","cpe":"cpe:2.3:a:postfix:postfix:%s:*:*:*:*:*:*:*"}]}\n' \
        "${POSTFIX_VERSION#v}" "${POSTFIX_VERSION#v}" "${POSTFIX_VERSION#v}" \
        >/out/usr/share/sbom/postfix.cdx.json

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
# The embedded Postfix SBOM component (see the builder stage) rides along so
# Syft's sbom-cataloger can identify the source-built Postfix version.
COPY --from=builder /out/usr/share/sbom/ /usr/share/sbom/

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
# source-built Postfix: exact pinned version; embedded SBOM fragment
# shipped, JSON-shaped, naming postfix at the same ARG-pinned version;
# TLS, Cyrus SASL client, and
# EAI/SMTPUTF8 compiled in; every map type the generated config relies on
# (hash:/btree: on lmdb, regexp:, plus cidr and pcre) present; setgid
# postdrop plumbing intact after COPY; toolchain hardening (PIE, non-exec
# stack, RELRO + BIND_NOW, stack protector) present on the shipped daemons;
# and a boot-shaped sequence (render to
# /etc/postfix, newaliases, `postfix check`, regexp lookup, postmap/lmdb
# round-trip) passes. A failure fails the build.
# ---------------------------------------------------------------------------
FROM base AS test
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
ARG POSTFIX_VERSION
COPY --chmod=755 validate.sh recipient-filter.sh entrypoint.sh /usr/local/bin/
COPY tests/render-test.sh /tmp/tests/render-test.sh
COPY tests/golden/ /tmp/tests/golden/
RUN ENTRYPOINT_DIR=/usr/local/bin sh /tmp/tests/render-test.sh \
    && { test "$(postconf -h mail_version)" = "${POSTFIX_VERSION#v}" \
      || { printf 'FAIL: mail_version %s does not match pinned %s\n' \
             "$(postconf -h mail_version)" "${POSTFIX_VERSION#v}" >&2; exit 1; }; } \
    && postconf -T compile-version >/dev/null \
    # Embedded SBOM fragment (builder stage): must ship, be JSON-shaped,
    # name postfix, and carry exactly one version-shaped component version
    # equal to the ARG-pinned release - a hardcoded version would drift
    # silently on the next Renovate bump, which is exactly the failure mode
    # the fragment exists to prevent. BusyBox has no jq, so shape is
    # asserted with head/tail bytes and grep; the fragment is single-line
    # compact JSON, so the version count uses grep -o (line-counting grep -c
    # could never see a duplicate on one line). || true keeps the pipefail
    # shell from aborting the count assignment before the FAIL report.
    && sbom=/usr/share/sbom/postfix.cdx.json \
    && { test -s "$sbom" \
      || { printf 'FAIL: embedded SBOM fragment missing or empty: %s\n' "$sbom" >&2; exit 1; }; } \
    && { test "$(head -c 1 "$sbom")" = '{' \
      || { printf '%s\n' 'FAIL: embedded SBOM fragment does not start with { (not a JSON object)' >&2; exit 1; }; } \
    && { test "$(tail -c 2 "$sbom")" = '}' \
      || { printf '%s\n' 'FAIL: embedded SBOM fragment does not end with } (not a JSON object)' >&2; exit 1; }; } \
    && { grep -q '"name":"postfix"' "$sbom" \
      || { printf '%s\n' 'FAIL: embedded SBOM fragment missing component: postfix' >&2; exit 1; }; } \
    && versions=$(grep -o '"version":"[0-9][0-9.]*"' "$sbom" | wc -l || true) \
    && { test "$versions" -eq 1 \
      || { printf 'FAIL: embedded SBOM fragment has %s version-shaped component versions (want 1)\n' "$versions" >&2; exit 1; }; } \
    && { grep -qF "\"version\":\"${POSTFIX_VERSION#v}\"" "$sbom" \
      || { printf 'FAIL: embedded SBOM fragment version is not %s (ARG wiring broken?)\n' "${POSTFIX_VERSION#v}" >&2; exit 1; }; } \
    && ldd /usr/libexec/postfix/smtpd >/tmp/smtpd-libs \
    && { grep -q libicuuc /tmp/smtpd-libs \
      || { printf '%s\n' 'FAIL: smtpd is not linked against libicuuc (EAI/SMTPUTF8 missing)' >&2; exit 1; }; } \
    && postconf -A >/tmp/sasl-client-types \
    && { grep -qx cyrus /tmp/sasl-client-types \
      || { printf '%s\n' 'FAIL: cyrus missing from postconf -A (SASL client auth not compiled in)' >&2; exit 1; }; } \
    && postconf -m >/tmp/map-types \
    && for m in btree cidr hash lmdb pcre regexp; do \
         grep -qx "$m" /tmp/map-types \
           || { printf 'FAIL: map type %s missing from postconf -m\n' "$m" >&2; exit 1; }; \
       done \
    && { test -g /usr/sbin/postdrop \
      || { printf '%s\n' 'FAIL: /usr/sbin/postdrop lost its setgid bit' >&2; exit 1; }; } \
    && { test -g /usr/sbin/postqueue \
      || { printf '%s\n' 'FAIL: /usr/sbin/postqueue lost its setgid bit' >&2; exit 1; }; } \
    # Fail-closed toolchain-hardening assertions: the daemons' PIE, non-exec
    # stack, RELRO+BIND_NOW, and stack-protector properties currently come
    # from Alpine toolchain defaults; asserting them here turns silent
    # hardening regressions (a toolchain or makedefs change) into build
    # failures. pax-utils (scanelf) is test-stage-only and never ships.
    # If a strip or UPX step is ever added, keep the symbol check before
    # strip and the header checks before UPX.
    && apk add --no-cache pax-utils \
    && for b in /usr/libexec/postfix/master /usr/libexec/postfix/smtpd \
                /usr/libexec/postfix/smtp /usr/sbin/postmap; do \
         scanelf -B -E ET_DYN "$b" | grep -q . \
           || { printf 'hardening: %s is not PIE (ET_DYN)\n' "$b" >&2; exit 1; }; \
         scanelf -Bb "$b" | awk 'NR==1 { ok = ($2 == "NOW") } END { exit !(NR >= 1 && ok) }' \
           || { printf 'hardening: %s lacks BIND_NOW\n' "$b" >&2; exit 1; }; \
         scanelf -Be "$b" | awk 'NR==1 { ok = ($2 == "RW-" && $3 == "R--") } END { exit !(NR >= 1 && ok) }' \
           || { printf 'hardening: %s lacks RW- GNU_STACK + R-- RELRO\n' "$b" >&2; exit 1; }; \
         scanelf -Bs __stack_chk_fail "$b" | grep -q __stack_chk_fail \
           || { printf 'hardening: %s lacks stack protector\n' "$b" >&2; exit 1; }; \
       done \
    && env CONF_DIR=/etc/postfix RELAY_HOST=smtp.example.com \
        RECIPIENT_RESTRICTIONS="ops@example.com" \
        sh /usr/local/bin/entrypoint.sh render \
    && newaliases \
    && postfix check \
    && { test "$(postconf -hx smtputf8_enable)" = "yes" \
      || { printf '%s\n' 'FAIL: smtputf8_enable is not yes in the rendered config' >&2; exit 1; }; } \
    && { test "$(postmap -q ops@example.com regexp:/etc/postfix/recipient_access)" = "OK" \
      || { printf '%s\n' 'FAIL: regexp lookup of ops@example.com in recipient_access did not return OK' >&2; exit 1; }; } \
    && printf '%s\n' 'smtp.example.com probe:secret' >/tmp/sasl-probe \
    && postmap /tmp/sasl-probe \
    && { test -f /tmp/sasl-probe.lmdb \
      || { printf '%s\n' 'FAIL: postmap did not produce /tmp/sasl-probe.lmdb (lmdb default map type broken)' >&2; exit 1; }; } \
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
# port 25; smtpd workers drop to the unprivileged postfix user internally (setuid;
# the stock upstream master.cf runs all services with chroot=n since Postfix 3.0).
# This is the image default and can be overridden at run time (e.g. compose
# `user:`) if you front the relay differently. AVD-DS-0002 is suppressed via
# .trivyignore at the repo root; see the rationale there.
# hadolint ignore=DL3002
USER 0:0

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD nc -w 3 127.0.0.1 25 < /dev/null | grep -q '^220 ' || exit 1
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
