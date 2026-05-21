#!/bin/sh
# recipient-filter.sh — recipient-filtering logic sourced by entrypoint.sh.
# Reads RECIPIENT_RESTRICTIONS (already validated) and sets
# SMTPD_RECIPIENT_RESTRICTIONS for main.cf generation.

# Escape user-supplied recipient tokens so they are matched literally (not as
# regex) when rendered inside /^.../ or /@.../ patterns below. The character
# class uses ] first (POSIX requirement), escapes / because it is the Postfix
# regexp delimiter, and uses # as the sed delimiter to avoid doubling slashes.
# Both { and } are escaped together so the class stays symmetric and obviously
# covers every PCRE metacharacter Postfix regexp supports.
escape_postfix_regex() {
	printf '%s' "$1" | sed 's#[].[\\^$*+?(){}|/]#\\&#g'
}

# build_recipient_filter — builds /etc/postfix/recipient_access from
# RECIPIENT_RESTRICTIONS tokens and sets SMTPD_RECIPIENT_RESTRICTIONS.
# Must be called (not subshelled) so the variable is visible to the caller.
build_recipient_filter() {
	# shellcheck disable=SC2034 # consumed by caller after sourcing
	SMTPD_RECIPIENT_RESTRICTIONS="permit_mynetworks, reject"

	if [ -n "$RECIPIENT_RESTRICTIONS" ]; then
		RCPT_FILE="/etc/postfix/recipient_access"
		: >"$RCPT_FILE"
		rule_count=0
		for entry in $RECIPIENT_RESTRICTIONS; do
			case "$entry" in
			/*/) # already a Postfix regexp literal
				printf '%s OK\n' "$entry" >>"$RCPT_FILE"
				;;
			*@*) # full address: anchor both ends
				esc=$(escape_postfix_regex "$entry")
				printf '/^%s$/ OK\n' "$esc" >>"$RCPT_FILE"
				;;
			*) # domain-only: anchor the @-suffix
				esc=$(escape_postfix_regex "$entry")
				printf '/@%s$/ OK\n' "$esc" >>"$RCPT_FILE"
				;;
			esac
			rule_count=$((rule_count + 1))
		done
		# Refuse to proceed if a non-empty RECIPIENT_RESTRICTIONS parses to zero
		# rules (whitespace-only value from a quoting bug or empty-var expansion).
		# Without this guard the file ends up containing only `/.*/ REJECT`, Postfix
		# rejects 100% of mail, and the healthcheck still reports green.
		if [ "$rule_count" -eq 0 ]; then
			printf 'level=error msg="RECIPIENT_RESTRICTIONS is non-empty but parsed zero rules (whitespace only?); refusing to reject all mail" value="%s"\n' \
				"$RECIPIENT_RESTRICTIONS" >&2
			rm -f "$RCPT_FILE"
			exit 2
		fi
		printf '/.*/ REJECT\n' >>"$RCPT_FILE"
		# shellcheck disable=SC2034 # consumed by caller after sourcing
		SMTPD_RECIPIENT_RESTRICTIONS="check_recipient_access regexp:${RCPT_FILE}, reject"
		# Count only operator-supplied allow rules; the trailing /.*/ REJECT terminator
		# is an internal implementation detail and would confuse operators reading Loki.
		printf 'level=info msg="recipient filtering configured" rules=%d\n' \
			"$rule_count" >&2
	fi
}
