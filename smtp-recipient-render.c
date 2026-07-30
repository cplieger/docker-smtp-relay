/* ---------------------------------------------------------------------------
 * smtp-recipient-render.c -- single-pass renderer for the Postfix
 * recipient_access map, invoked once by recipient-filter.sh.
 *
 *   smtp-recipient-render CONF_DIR RECIPIENT_RESTRICTIONS
 *
 * Reads the whole RECIPIENT_RESTRICTIONS value ONCE and writes the complete
 * CONF_DIR/recipient_access content in ONE process, atomically (mkstemp in
 * CONF_DIR, chmod 0644, rename), exactly as the shell renderer did.
 *
 * WHY THIS EXISTS. The shell renderer looped once per token and spawned
 * external processes per rule: one sed per literal, and one awk plus two
 * compile greps plus one or two safety greps per single regexp (six to nine
 * for a dual form). Measured on the maintainer's host that is ~1.42 ms per
 * literal and ~4.27 ms per regexp, linear in the entry count, on the startup
 * path before `exec postfix start-fg` and with no deadline of its own. The
 * work itself is trivial -- a bounded string walk plus regcomp -- so it is
 * one process here, and the input is EXPLICITLY bounded (RCPT_MAX_INPUT_BYTES
 * / RCPT_MAX_TOKENS below) instead of unbounded.
 *
 * The compile checks the shell delegated to `grep -E` / `grep` are POSIX
 * regcomp() calls here. That is strictly closer to what Postfix's dict_regexp
 * does with the pattern (it calls regcomp too) and it removes the whole
 * two-probe dance the shell needed: regcomp reports a bad pattern by return
 * code, so there is no "a grep variant might report a bad regex as exit 1"
 * case left to backstop with a guaranteed-match alternation.
 *
 * SEMANTICS. This is a port, not a redesign: every classification, warning,
 * refusal, exit code, log line and rendered byte matches the shell renderer
 * it replaced. In particular:
 *   - token classification: leading / => regexp family; otherwise @ => full
 *     address; otherwise domain. A mid-token slash without a leading slash is
 *     legal RFC 5321 atext and stays an address literal.
 *   - regexp_table(5) structure parse, mirroring dict_regexp: each half ends
 *     at its first UNESCAPED /, a backslash escapes the next character, and
 *     escapes are preserved verbatim. Forms: /P/, /P/FLAGS, and the dual
 *     /P1/[FLAGS]!/P2/[FLAGS] (P1 AND NOT P2). FLAGS is one or more of i m x.
 *   - flag folding: matching starts case-INSENSITIVE with extended (ERE)
 *     syntax; each i toggles case sensitivity, each x toggles ERE-vs-BRE, and
 *     m (REG_NEWLINE) is accepted but cannot change how a single-line
 *     recipient key matches, so it is not mirrored in the probes.
 *   - per-half compile warning + ineffective status; the universal-match
 *     (possibly-allow-all) guard applied to the FULL construct against BOTH
 *     fixed impossible probes; empty-pattern refusal; unparseable structure
 *     warned and SUPPRESSED (never emitted) while never-match shapes are
 *     warned and emitted; effective-rule counting; and the /.*<slash> REJECT
 *     terminator.
 * The rationale behind each of those decisions lives in recipient-filter.sh's
 * header and in validate.sh's validation-policy header (Tier 1/2/3); this
 * file does not restate it.
 *
 * Exit codes match the entrypoint's contract: 2 = config-validation failure
 * (the caller propagates it), 1 = runtime failure (write/rename/usage).
 * --------------------------------------------------------------------------- */

#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <limits.h>
#include <regex.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Explicit input bounds. RECIPIENT_RESTRICTIONS is an allowlist an operator
 * hand-writes; 4 KiB across at most 128 entries is far past any plausible
 * relay allowlist while keeping this pass provably short. entrypoint.sh
 * enforces the same two numbers in its validation section (fatal exit 2) so
 * an oversized value is refused in the same style and log format as every
 * other env var; these checks are what makes the renderer safe to run
 * standalone, and tests/render-test.sh asserts the two sides agree. */
#define RCPT_MAX_INPUT_BYTES 4096
#define RCPT_MAX_TOKENS 128

/* Exit codes, mirroring entrypoint.sh: 2 = config, 1 = runtime. */
#define EXIT_CONFIG 2
#define EXIT_RUNTIME 1

/* Per-entry status, mirroring the shell renderer's return values: 0 = an
 * effective rule (counts toward the zero-effective-rules guard), 10 = the
 * rule is ineffective (warned; may or may not have been emitted). */
#define RCPT_EFFECTIVE 0
#define RCPT_INEFFECTIVE 10

/* validate.sh's sanitize_token bounds a logged value to 512 bytes and appends
 * a literal [truncated] marker beyond that. */
#define SANITIZE_CAP 512
#define SANITIZE_MAX (SANITIZE_CAP + sizeof "[truncated]")

/* The two FIXED, dissimilar, syntactically-valid-but-impossible addresses on
 * reserved TLDs (RFC 2606/6761) the universal-match guard probes with. Same
 * literals the shell renderer used; changing either changes which patterns
 * the guard refuses. */
static const char *const PROBE_A = "q7probe@nonce-a.invalid";
static const char *const PROBE_B = "k2xrf@check-b.test";

/* POSIX metacharacters escaped so an operator-supplied literal is matched
 * literally inside /^.../ or /@.../. Same set as the shell's sed class
 * (`].[\\^$*+?(){}|/`): / is escaped because it is the Postfix regexp
 * delimiter, and { } are escaped together so the set obviously covers every
 * metacharacter of the POSIX regular expressions a regexp: table uses. */
static const char ESCAPE_SET[] = "].[\\^$*+?(){}|/";

/* Render state. Single-purpose, single-threaded program; the shell renderer
 * kept the same two values in globals ($_rcpt_tmp and the open temp file). */
static char tmp_path[PATH_MAX];
static FILE *tmp_fp;

/* sanitize -- port of validate.sh's sanitize_token: strip logfmt delimiters
 * (backslash, double quote) and control bytes, bound the result to
 * SANITIZE_CAP source bytes, and mark a truncated value. Writes into a
 * caller-supplied buffer so two sanitized fields can never share one. */
static void sanitize(char *dst, size_t dstsz, const char *src) {
  size_t n = 0;
  size_t i;

  for (i = 0; i < SANITIZE_CAP && src[i] != '\0'; i++) {
    unsigned char c = (unsigned char)src[i];
    if (c == '\\' || c == '"' || iscntrl(c)) {
      continue;
    }
    if (n + 1 >= dstsz) {
      break;
    }
    dst[n++] = (char)c;
  }
  if (strlen(src) > SANITIZE_CAP) {
    const char *marker = "[truncated]";
    size_t m;
    for (m = 0; marker[m] != '\0' && n + 1 < dstsz; m++) {
      dst[n++] = marker[m];
    }
  }
  dst[n] = '\0';
}

/* logfmt -- one structured stderr line. Every diagnostic in this file goes
 * through here so the level=... msg="..." shape stays uniform. The format
 * attribute makes -Wformat check every call site, so a field/argument
 * mismatch in a log contract is a build error rather than a broken logfmt
 * record in Loki. */
static void logfmt(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void die(int code, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

static void logfmt(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
}

/* discard_tmp -- drop a partially rendered map so Postfix never sees one, the
 * counterpart of the shell renderer's `rm -f "$_rcpt_tmp"` on every fatal
 * path. */
static void discard_tmp(void) {
  if (tmp_fp != NULL) {
    fclose(tmp_fp);
    tmp_fp = NULL;
  }
  if (tmp_path[0] != '\0') {
    unlink(tmp_path);
    tmp_path[0] = '\0';
  }
}

/* die -- emit the diagnostic, discard any partial render, exit with CODE. */
static void die(int code, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  discard_tmp();
  exit(code);
}

/* die_entry / die_pattern / warn_entry / warn_pattern -- the fatal and
 * warning shapes whose only field is one sanitized token. */
static void die_entry(const char *msg, const char *tok) {
  char safe[SANITIZE_MAX];
  sanitize(safe, sizeof safe, tok);
  die(EXIT_CONFIG, "level=error msg=\"%s\" entry=\"%s\"\n", msg, safe);
}

static void die_pattern(const char *msg, const char *tok) {
  char safe[SANITIZE_MAX];
  sanitize(safe, sizeof safe, tok);
  die(EXIT_CONFIG, "level=error msg=\"%s\" pattern=\"%s\"\n", msg, safe);
}

static void warn_entry(const char *msg, const char *tok) {
  char safe[SANITIZE_MAX];
  sanitize(safe, sizeof safe, tok);
  logfmt("level=warn msg=\"%s\" entry=\"%s\"\n", msg, safe);
}

static void warn_pattern(const char *msg, const char *pat) {
  char safe[SANITIZE_MAX];
  sanitize(safe, sizeof safe, pat);
  logfmt("level=warn msg=\"%s\" pattern=\"%s\"\n", msg, safe);
}

/* emit -- append one rule line, converting a write failure (ENOSPC, EROFS)
 * into a structured level=error plus temp-file cleanup. stdio buffers, so a
 * full filesystem can surface here or at the flush in promote(); both report
 * the same contract line. */
static void emit(const char *line) {
  if (fprintf(tmp_fp, "%s\n", line) >= 0) {
    return;
  }
  {
    char safe[SANITIZE_MAX];
    sanitize(safe, sizeof safe, tmp_path);
    die(EXIT_RUNTIME,
        "level=error msg=\"failed to write recipient_access (disk full or "
        "read-only?)\" path=\"%s\"\n",
        safe);
  }
}

/* escape_literal -- escape TOK for literal matching and wrap it in the
 * anchored form PREFIX...$/ OK (PREFIX is "/^" for the address arm, "/@" for
 * the domain arm). A result that does not fit DST is an internal-capacity
 * failure, not an operator error: the input bounds make it unreachable (worst
 * case is two bytes out per input byte), but it keeps the shell renderer's
 * escape-failure contract line rather than silently truncating a rule. */
static void escape_literal(char *dst, size_t dstsz, const char *prefix,
                           const char *tok) {
  size_t n = 0;
  size_t i;

  for (i = 0; prefix[i] != '\0'; i++) {
    if (n + 1 >= dstsz) {
      goto overflow;
    }
    dst[n++] = prefix[i];
  }
  for (i = 0; tok[i] != '\0'; i++) {
    if (strchr(ESCAPE_SET, tok[i]) != NULL) {
      if (n + 2 >= dstsz) {
        goto overflow;
      }
      dst[n++] = '\\';
    } else if (n + 1 >= dstsz) {
      goto overflow;
    }
    dst[n++] = tok[i];
  }
  {
    const char *suffix = "$/ OK";
    for (i = 0; suffix[i] != '\0'; i++) {
      if (n + 1 >= dstsz) {
        goto overflow;
      }
      dst[n++] = suffix[i];
    }
  }
  dst[n] = '\0';
  return;

overflow:
  die(EXIT_RUNTIME,
      "level=error msg=\"failed to escape recipient restriction for "
      "rendering\"\n");
}

/* The parsed regexp construct: the two pattern halves with their flag
 * strings, and whether the dual form was used. */
struct construct {
  char p1[RCPT_MAX_INPUT_BYTES + 1];
  char f1[RCPT_MAX_INPUT_BYTES + 1];
  char p2[RCPT_MAX_INPUT_BYTES + 1];
  char f2[RCPT_MAX_INPUT_BYTES + 1];
  int dual;
};

/* parse_regexp_construct -- structure-parse a leading-/ token into the
 * regexp_table(5) forms this image supports. Returns 0 on success, -1 on any
 * other leading-/ structure: no closing delimiter (Postfix skips such a line
 * at map load with a "no closing regexp delimiter" warning), a trailing lone
 * backslash, a dangling !, a second half not /-delimited, more than one !
 * separator, or a flag character outside the verified i/m/x set. The caller
 * warns and suppresses those.
 *
 * The scan mirrors dict_regexp: each half ends at its first UNESCAPED /, a
 * backslash escapes the next character (so \/ stays inside the pattern,
 * exactly the escape escape_literal produces for the literal arms), and
 * escapes are preserved verbatim -- that is what Postfix hands to regcomp and
 * therefore what the compile check below must see. Character-for-character
 * port of the awk pass it replaced. */
static int parse_regexp_construct(const char *tok, struct construct *c) {
  enum { ST_P1, ST_F1, ST_P2, ST_F2 } state = ST_P1;
  size_t len = strlen(tok);
  int closed1 = 0;
  int closed2 = 0;
  size_t i;
  size_t n1 = 0;
  size_t n2 = 0;
  size_t nf1 = 0;
  size_t nf2 = 0;

  memset(c, 0, sizeof *c);
  if (tok[0] != '/') {
    return -1;
  }
  for (i = 1; i < len; i++) {
    char ch = tok[i];
    char *pat = (state == ST_P1) ? c->p1 : c->p2;
    size_t *pn = (state == ST_P1) ? &n1 : &n2;

    if (state == ST_P1 || state == ST_P2) {
      if (ch == '\\') {
        /* A trailing lone backslash has nothing to escape: unparseable. */
        if (i == len - 1) {
          return -1;
        }
        pat[(*pn)++] = ch;
        pat[(*pn)++] = tok[++i];
      } else if (ch == '/') {
        if (state == ST_P1) {
          state = ST_F1;
          closed1 = 1;
        } else {
          state = ST_F2;
          closed2 = 1;
        }
      } else {
        pat[(*pn)++] = ch;
      }
    } else if (state == ST_F1 && ch == '!') {
      /* The dual separator must introduce a /-delimited second half. */
      if (i + 1 >= len || tok[i + 1] != '/') {
        return -1;
      }
      c->dual = 1;
      state = ST_P2;
      i++;
    } else if (state == ST_F1) {
      c->f1[nf1++] = ch;
    } else {
      c->f2[nf2++] = ch;
    }
  }
  if (!closed1 || (c->dual && !closed2)) {
    return -1;
  }
  if (strspn(c->f1, "imx") != nf1 || strspn(c->f2, "imx") != nf2) {
    return -1;
  }
  return 0;
}

/* half_flag_state -- fold one half's flag string into its effective matcher
 * state, mirroring dict_regexp exactly: matching starts case-insensitive with
 * extended (ERE) syntax; each i TOGGLES case sensitivity and each x TOGGLES
 * extended-vs-basic syntax, so repeated flags re-toggle. m toggles multi-line
 * matching (REG_NEWLINE), which cannot change how a single-line recipient key
 * matches, so it is accepted but not mirrored. */
static void half_flag_state(const char *flags, int *ext, int *icase) {
  size_t i;

  *ext = 1;
  *icase = 1;
  for (i = 0; flags[i] != '\0'; i++) {
    if (flags[i] == 'i') {
      *icase = 1 - *icase;
    } else if (flags[i] == 'x') {
      *ext = 1 - *ext;
    }
  }
}

/* half_compiles -- compile-probe one pattern half with the syntax its
 * effective flags select (ERE unless x switched it to BRE) and its case
 * sensitivity, i.e. the way Postfix's dict_regexp will compile it. Returns 1
 * and a compiled RE on success, 0 when the half does not compile. */
static int half_compiles(const char *pat, int ext, int icase, regex_t *re) {
  int cflags = 0;

  if (ext) {
    cflags |= REG_EXTENDED;
  }
  if (icase) {
    cflags |= REG_ICASE;
  }
  return regcomp(re, pat, cflags) == 0;
}

/* construct_matches -- does the FULL parsed construct match PROBE the way
 * Postfix will match a recipient key against the emitted line? Single form:
 * P1 matches. Dual form: P1 matches AND NOT P2 matches (regexp_table(5)). */
static int construct_matches(const struct construct *c, const regex_t *re1,
                             const regex_t *re2, const char *probe) {
  if (regexec(re1, probe, 0, NULL, 0) != 0) {
    return 0;
  }
  if (c->dual && regexec(re2, probe, 0, NULL, 0) == 0) {
    return 0;
  }
  return 1;
}

/* render_regexp -- render one leading-/ regexp-family token. Emits a
 * structurally valid token VERBATIM (the whole original token + " OK"):
 * Postfix parses the flags and dual syntax natively, so the effective-rule
 * count stays truthful. Returns RCPT_EFFECTIVE or RCPT_INEFFECTIVE; the
 * refusal arms exit 2. */
static int render_regexp(const char *tok) {
  struct construct c;
  regex_t re1;
  regex_t re2;
  int have_re1 = 0;
  int have_re2 = 0;
  int ext1;
  int icase1;
  int ext2;
  int icase2;
  int status = RCPT_EFFECTIVE;
  char line[RCPT_MAX_INPUT_BYTES + 8];

  /* Postfix's dict_regexp ends the pattern at the FIRST unescaped /, so any
   * entry beginning with // has an EMPTY effective first pattern whatever
   * follows. An empty pattern matches every string, so the rendered rule
   * would allow ALL recipients before the /.*<slash> REJECT terminator (or
   * dict_regexp drops the line as bad flags and matching mail is rejected) --
   * the operator configured a restriction and silently got allow-all or
   * reject-all. Fatal, matching the zero-rules guard's posture. */
  if (tok[0] == '/' && tok[1] == '/') {
    die_entry("recipient restriction regex is empty (Postfix ends the pattern "
              "at the first unescaped /) and would match all recipients; "
              "refusing to allow all mail",
              tok);
  }
  /* An unparseable leading-/ token is warned and SUPPRESSED -- deliberately
   * diverging from the never-match arms' emit-anyway contract: those arms
   * KNOW the rule is dead (Postfix loads it but no recipient can match),
   * whereas this arm cannot know what an unvalidated structure would do
   * inside Postfix ('/a@x/!/b/!/c/' LOADS, silently absorbing '!/c/' into the
   * lookup RESULT). Suppressing is safe: the ineffective status excludes the
   * token from the effective count, the warn names it, and an all-such list
   * exits 2 via the zero-effective-rules guard. */
  if (parse_regexp_construct(tok, &c) != 0) {
    warn_entry("cannot parse regexp token structure; supported forms: "
               "/pattern/, /pattern/flags, /pattern1/!/pattern2/ "
               "(flags: i, m, x)",
               tok);
    return RCPT_INEFFECTIVE;
  }
  /* An empty SECOND half (/x/!//) gets the same fatal posture as the //
   * empty-pattern arm above (an empty FIRST half always begins the token with
   * //, so that arm already caught it). */
  if (c.dual && c.p2[0] == '\0') {
    die_entry("recipient restriction dual-form regexp has an empty pattern "
              "half (Postfix ends each pattern at the first unescaped /); an "
              "empty half matches every string, so the construct cannot mean "
              "what was configured; refusing to render it",
              tok);
  }

  half_flag_state(c.f1, &ext1, &icase1);
  half_flag_state(c.f2, &ext2, &icase2);

  /* Per-half compile probes. dict_regexp ignores an uncompilable line at
   * map-open time with only a maillog warning, so the intended allow rule
   * silently vanishes and the /.*<slash> REJECT terminator rejects that mail;
   * surface it at deploy time. The line is still emitted unchanged, but the
   * entry becomes ineffective so it no longer satisfies the zero-rules
   * guard. */
  have_re1 = half_compiles(c.p1, ext1, icase1, &re1);
  if (!have_re1) {
    warn_pattern("recipient restriction regex does not compile; Postfix skips "
                 "an uncompilable rule at map load and matching recipients "
                 "will be rejected",
                 c.p1);
    status = RCPT_INEFFECTIVE;
  }
  if (c.dual) {
    have_re2 = half_compiles(c.p2, ext2, icase2, &re2);
    if (!have_re2) {
      warn_pattern("recipient restriction regex does not compile; Postfix "
                   "skips an uncompilable rule at map load and matching "
                   "recipients will be rejected",
                   c.p2);
      status = RCPT_INEFFECTIVE;
    }
  }

  /* Universal-match (possibly-allow-all) guard, applied to the FULL
   * construct: fatal iff it matches BOTH fixed impossible probes. An honest
   * heuristic -- matching both is treated as possibly allow-all, not proof of
   * it. It only runs when every half compiled: an uncompilable half means
   * Postfix skips the whole line at map load (already warned), so match
   * probes would be meaningless. */
  if (status == RCPT_EFFECTIVE &&
      construct_matches(&c, &re1, &re2, PROBE_A) &&
      construct_matches(&c, &re1, &re2, PROBE_B)) {
    if (have_re1) {
      regfree(&re1);
    }
    if (have_re2) {
      regfree(&re2);
    }
    die_pattern("recipient restriction regexp matches both universal-match "
                "safety probes and is treated as possibly allow-all; refusing "
                "to render it (split a narrow alternation into separate "
                "RECIPIENT_RESTRICTIONS entries; leave RECIPIENT_RESTRICTIONS "
                "empty only if allow-all is intended)",
                tok);
  }
  if (have_re1) {
    regfree(&re1);
  }
  if (have_re2) {
    regfree(&re2);
  }

  snprintf(line, sizeof line, "%s OK", tok);
  emit(line);
  return status;
}

/* render_address -- render one full-address token as an anchored escaped
 * literal. Three deterministic never-match shapes warn, still emit the rule
 * line unchanged, and return the ineffective status so the entry is excluded
 * from the effective-rule count. The token is split on its LAST @;
 * classification order is PINNED -- empty local part first, then empty
 * domain, then dot-after-@ -- so a bare @ (both empty) classifies as
 * empty-local. */
static int render_address(const char *tok) {
  const char *at = strrchr(tok, '@');
  const char *domain = at + 1;
  int status = RCPT_EFFECTIVE;
  char line[2 * RCPT_MAX_INPUT_BYTES + 16];

  if (at == tok) {
    warn_entry("recipient restriction address has an empty local part; this "
               "anchored rule never matches a recipient smtpd presents",
               tok);
    status = RCPT_INEFFECTIVE;
  } else if (*domain == '\0') {
    warn_entry("recipient restriction address has an empty domain; Postfix "
               "rejects domain-less recipients before the access-map lookup, "
               "so this rule will never match any recipient",
               tok);
    status = RCPT_INEFFECTIVE;
  } else if (*domain == '.') {
    warn_entry("recipient restriction address domain starts with a dot (no "
               "deliverable address contains @.); this rule will never match "
               "any recipient",
               tok);
    status = RCPT_INEFFECTIVE;
  }
  escape_literal(line, sizeof line, "/^", tok);
  emit(line);
  return status;
}

/* render_domain -- render one domain-only token as an anchored escaped
 * @-suffix literal. A domain can never contain a slash, so a slash-bearing
 * token here is almost certainly a mis-typed regexp literal, and a
 * leading-dot domain can never match either. Both are deterministic
 * never-match shapes: warn, still emit the rule line unchanged, ineffective
 * status. Arm order is the shell case's: slash first, then leading dot. */
static int render_domain(const char *tok) {
  int status = RCPT_EFFECTIVE;
  char line[2 * RCPT_MAX_INPUT_BYTES + 16];

  if (strchr(tok, '/') != NULL) {
    warn_entry("recipient restriction looks like a mis-typed regexp (a domain "
               "cannot contain /); this rule will never match any recipient",
               tok);
    status = RCPT_INEFFECTIVE;
  } else if (tok[0] == '.') {
    warn_entry("recipient restriction domain starts with a dot (Postfix "
               "subdomain syntax is not supported by this regexp map; no "
               "address contains @.); this rule will never match any "
               "recipient",
               tok);
    status = RCPT_INEFFECTIVE;
  }
  escape_literal(line, sizeof line, "/@", tok);
  emit(line);
  return status;
}

/* render_token -- classify one RECIPIENT_RESTRICTIONS token and render its
 * rule. Any token STARTING with / routes to the regexp arm (which owns the
 * full structure parse); a mid-token slash without a leading slash is legal
 * RFC 5321 atext and keeps its literal arm -- john/doe@example.com is a
 * correct address-arm literal, escaped and never warned. */
static int render_token(const char *tok) {
  size_t i;

  for (i = 0; tok[i] != '\0'; i++) {
    /* Word splitting already consumed spaces, tabs, and line feeds, so
     * residual whitespace here is CR/FF/VT -- it would render a rule no real
     * recipient matches, silently rejecting all mail. */
    if (isspace((unsigned char)tok[i])) {
      die_entry("recipient restriction contains invalid whitespace", tok);
    }
  }
  if (tok[0] == '/') {
    return render_regexp(tok);
  }
  if (strrchr(tok, '@') != NULL) {
    return render_address(tok);
  }
  return render_domain(tok);
}

/* start_render -- create the temp file the map is rendered into, beside the
 * destination in CONF_DIR so the rename is same-filesystem and atomic. */
static void start_render(const char *conf_dir) {
  int fd;

  if (snprintf(tmp_path, sizeof tmp_path, "%s/recipient_access.XXXXXX",
               conf_dir) >= (int)sizeof tmp_path) {
    tmp_path[0] = '\0';
    goto fail;
  }
  fd = mkstemp(tmp_path);
  if (fd < 0) {
    tmp_path[0] = '\0';
    goto fail;
  }
  tmp_fp = fdopen(fd, "w");
  if (tmp_fp == NULL) {
    close(fd);
    goto fail;
  }
  return;

fail:
  {
    char safe[SANITIZE_MAX];
    sanitize(safe, sizeof safe, conf_dir);
    die(EXIT_RUNTIME,
        "level=error msg=\"failed to create temporary file for "
        "recipient_access\" conf_dir=\"%s\"\n",
        safe);
  }
}

/* promote -- finish the atomic render: flush (a full filesystem can surface
 * here rather than at a write), chmod to the world-readable 0644 the Postfix
 * daemons need (mkstemp creates 0600), then rename into place so Postfix
 * never sees a partial map. */
static void promote(const char *dest) {
  char safe[SANITIZE_MAX];

  if (fflush(tmp_fp) != 0) {
    sanitize(safe, sizeof safe, tmp_path);
    die(EXIT_RUNTIME,
        "level=error msg=\"failed to write recipient_access (disk full or "
        "read-only?)\" path=\"%s\"\n",
        safe);
  }
  sanitize(safe, sizeof safe, dest);
  if (fchmod(fileno(tmp_fp), 0644) != 0) {
    die(EXIT_RUNTIME,
        "level=error msg=\"failed to move rendered recipient_access into "
        "place\" path=\"%s\"\n",
        safe);
  }
  if (fclose(tmp_fp) != 0) {
    tmp_fp = NULL;
    die(EXIT_RUNTIME,
        "level=error msg=\"failed to move rendered recipient_access into "
        "place\" path=\"%s\"\n",
        safe);
  }
  tmp_fp = NULL;
  if (rename(tmp_path, dest) != 0) {
    die(EXIT_RUNTIME,
        "level=error msg=\"failed to move rendered recipient_access into "
        "place\" path=\"%s\"\n",
        safe);
  }
  tmp_path[0] = '\0';
}

int main(int argc, char **argv) {
  char value[RCPT_MAX_INPUT_BYTES + 1];
  char *tokens[RCPT_MAX_TOKENS];
  char dest[PATH_MAX];
  char *save = NULL;
  char *tok;
  size_t len;
  int count = 0;
  int rules = 0;
  int i;

  if (argc != 3) {
    logfmt("level=error msg=\"usage: smtp-recipient-render CONF_DIR "
           "RECIPIENT_RESTRICTIONS\"\n");
    return EXIT_RUNTIME;
  }

  /* Input bounds first: refuse an oversized value before creating any file.
   * entrypoint.sh enforces the same two limits in its validation section, so
   * in the shipped boot path these are the standalone-safety backstop. */
  len = strlen(argv[2]);
  if (len > RCPT_MAX_INPUT_BYTES) {
    logfmt("level=error msg=\"RECIPIENT_RESTRICTIONS exceeds the recipient "
           "map renderer's input limit\" bytes=%zu max_bytes=%d\n",
           len, RCPT_MAX_INPUT_BYTES);
    return EXIT_CONFIG;
  }
  memcpy(value, argv[2], len + 1);

  /* Tokenize once. strtok_r on the IFS whitespace set reproduces the shell's
   * word splitting: leading delimiters are skipped and runs collapse. The
   * whole value is bounded above, so the token count is bounded too; count
   * every token but store only up to the cap, so the refusal can name the
   * real count. */
  for (tok = strtok_r(value, " \t\n", &save); tok != NULL;
       tok = strtok_r(NULL, " \t\n", &save)) {
    if (count < RCPT_MAX_TOKENS) {
      tokens[count] = tok;
    }
    count++;
  }
  if (count > RCPT_MAX_TOKENS) {
    logfmt("level=error msg=\"RECIPIENT_RESTRICTIONS exceeds the recipient "
           "map renderer's entry limit\" tokens=%d max_tokens=%d\n",
           count, RCPT_MAX_TOKENS);
    return EXIT_CONFIG;
  }

  if (snprintf(dest, sizeof dest, "%s/recipient_access", argv[1]) >=
      (int)sizeof dest) {
    char safe[SANITIZE_MAX];
    sanitize(safe, sizeof safe, argv[1]);
    logfmt("level=error msg=\"failed to create temporary file for "
           "recipient_access\" conf_dir=\"%s\"\n",
           safe);
    return EXIT_RUNTIME;
  }

  start_render(argv[1]);
  for (i = 0; i < count; i++) {
    if (render_token(tokens[i]) == RCPT_EFFECTIVE) {
      rules++;
    }
  }

  /* Refuse to proceed if a non-empty RECIPIENT_RESTRICTIONS parses to zero
   * EFFECTIVE rules: whitespace-only value (quoting bug, empty-var
   * expansion), every entry malformed (uncompilable halves warned above;
   * Postfix drops each at map-open) or structurally unparseable (warned and
   * suppressed above), or every entry a deterministic never-match domain or
   * address shape (warned above; Postfix loads the rule but no recipient can
   * ever match it). Without this guard the map's only live line is
   * `/.*<slash> REJECT`, Postfix rejects 100% of mail, and the healthcheck
   * still reports green. */
  if (rules == 0) {
    die(EXIT_CONFIG,
        "level=error msg=\"RECIPIENT_RESTRICTIONS is non-empty but parsed "
        "zero effective rules (whitespace only, or every entry malformed or "
        "never-matching?); refusing to reject all mail\"\n");
  }
  emit("/.*/ REJECT");
  promote(dest);

  /* Count only EFFECTIVE operator-supplied allow rules (entries Postfix will
   * actually load AND that can match a real recipient; warned-ineffective
   * ones are excluded), never the trailing /.*<slash> REJECT terminator -- an
   * internal implementation detail that would confuse operators reading
   * Loki. */
  logfmt("level=info msg=\"recipient filtering configured\" rules=%d\n", rules);
  return 0;
}
