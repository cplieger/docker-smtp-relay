# Changelog

## 2026.05.17-fd05130 (2026-05-21)

### Added

- Add file-based healthcheck for distroless containers
- Tighten TLS posture, add input range validation, fail fast on misconfig

### Security

- Move healthcheck to Dockerfile and harden security

### Changed

- Annotate entrypoint sources for stricter shellcheck
- Compact skill specs + refactor age/nut-upsd/smtp-relay/docker-cron + kweb improvements (#289)
- Simplify healthcheck documentation
- Refactor compose (no user-visible change)

## 2026.04.16-cedf8b7 (2026-04-16)

### Dependencies

- Update alpine:3.23.4 docker digest to 5b10f43

## 2026.04.13-98ff0b3 (2026-04-13)

### Fixed

- Improve input validation and security hardening

## 2026.04.01-c71639f (2026-04-01)

### Added

- Add validation to prevent open relay configuration

### Fixed

- Improve credential handling and regex escaping
- Simplify to postfix-only architecture

### Security

- Improve error handling, validation, and security

### Changed

- Quote port mapping in compose file
- Migrate to structured logging and enhance validation
- Consolidate age encryption hooks and re-encrypt all env files
- Update memory limits and SMTP healthcheck across services
- Rename ses-relay to smtp-relay across infrastructure

## 2026.03.12-b843b96 (2026-03-12)

### Fixed

- Improve credential handling and regex escaping

### Changed

- Quote port mapping in compose file

## 2026.03.11-8e3804d (2026-03-11)

### Security

- Improve error handling, validation, and security

### Changed

- Migrate to structured logging and enhance validation

## 2026.03.07-8899e09 (2026-03-08)

### Added

- Add validation to prevent open relay configuration

## 2026.03.03-d346956 (2026-03-04)

- Initial release
