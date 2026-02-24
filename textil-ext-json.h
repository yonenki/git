#ifndef TEXTIL_EXT_JSON_H
#define TEXTIL_EXT_JSON_H

#include "strbuf.h"

/*
 * Minimal shared JSON parsing primitives for textil-ext subsystem.
 *
 * Used by both textil-ext-policy.c (die on error) and
 * textil-ext-executor.c (return error code).
 *
 * All parsing functions return 0 on success, -1 on parse error.
 * Callers decide how to handle errors (die vs propagate).
 *
 * RFC 8259 compliance:
 *   - Unescaped control characters (0x00-0x1F) in strings are rejected.
 *   - Only RFC 8259 escape sequences are accepted:
 *       \" \\ \/ \b \f \n \t \r \uXXXX
 *   - \uXXXX: accepted and decoded.  Code points < 0x80 become the
 *     literal ASCII byte; others are preserved as \uXXXX text.
 *     Surrogate pairs are NOT decoded (out of scope for policy/executor).
 *   - Any other escape (e.g. \a, \x) is rejected.
 *
 * Error messages:
 *   Parse failures return -1 without embedding raw input in messages.
 *   Callers are responsible for formatting user-facing errors with
 *   fixed text + position info (ctx->pos), never raw input data.
 */

/*
 * Max key length enforced by parse_string when used via parse_key.
 * Prevents allocation bombs from malformed input.
 * Rationale: no protocol key exceeds ~30 chars; 64 is generous.
 */
#define TEXTIL_JSON_MAX_KEY_LEN 64

struct textil_json_ctx {
	const char *buf;
	size_t pos;
	size_t len;
};

#define TEXTIL_JSON_CTX_INIT(b, l) { (b), 0, (l) }

/* Skip whitespace (space, tab, newline, carriage return) */
void textil_json_skip_ws(struct textil_json_ctx *ctx);

/* Peek at next non-whitespace character; '\0' if at end */
char textil_json_peek(struct textil_json_ctx *ctx);

/*
 * Consume expected character after skipping whitespace.
 * On failure, ctx->pos points at the unexpected character.
 */
int textil_json_expect(struct textil_json_ctx *ctx, char expected);

/*
 * Parse a JSON string value (opening '"' must be next).
 * Appends parsed content to 'out'.
 * Strict: rejects unescaped control chars (0x00-0x1F) per RFC 8259.
 * Supports standard JSON escapes including \uXXXX.
 *
 * Returns 0 on success, or a negative error code:
 *   TEXTIL_JSON_ERR_STRING_GENERIC     - not a string (no opening '"')
 *   TEXTIL_JSON_ERR_STRING_CONTROL     - unescaped control character
 *   TEXTIL_JSON_ERR_STRING_ESCAPE      - invalid escape sequence
 *   TEXTIL_JSON_ERR_STRING_UNTERMINATED - unterminated string
 */
#define TEXTIL_JSON_ERR_STRING_GENERIC      (-1)
#define TEXTIL_JSON_ERR_STRING_CONTROL      (-2)
#define TEXTIL_JSON_ERR_STRING_ESCAPE       (-3)
#define TEXTIL_JSON_ERR_STRING_UNTERMINATED (-4)
int textil_json_parse_string(struct textil_json_ctx *ctx, struct strbuf *out);

/* Parse a JSON boolean (true/false). */
int textil_json_parse_bool(struct textil_json_ctx *ctx, int *value_out);

/* Parse a JSON object key string and consume the following ':'. */
int textil_json_parse_key(struct textil_json_ctx *ctx, struct strbuf *out);

/*
 * Skip a single JSON value (string, object, array, boolean, null, number).
 * Useful for skipping unknown fields or validation-only traversal.
 */
int textil_json_skip_value(struct textil_json_ctx *ctx);

/* Returns 1 if all remaining content is whitespace (or empty) */
int textil_json_at_end(struct textil_json_ctx *ctx);

#endif /* TEXTIL_EXT_JSON_H */
