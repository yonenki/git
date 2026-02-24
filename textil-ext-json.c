#include "git-compat-util.h"
#include "textil-ext-json.h"

void textil_json_skip_ws(struct textil_json_ctx *ctx)
{
	while (ctx->pos < ctx->len) {
		char c = ctx->buf[ctx->pos];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
			ctx->pos++;
		else
			break;
	}
}

char textil_json_peek(struct textil_json_ctx *ctx)
{
	textil_json_skip_ws(ctx);
	if (ctx->pos >= ctx->len)
		return '\0';
	return ctx->buf[ctx->pos];
}

int textil_json_expect(struct textil_json_ctx *ctx, char expected)
{
	textil_json_skip_ws(ctx);
	if (ctx->pos >= ctx->len || ctx->buf[ctx->pos] != expected)
		return -1;
	ctx->pos++;
	return 0;
}

int textil_json_parse_string(struct textil_json_ctx *ctx, struct strbuf *out)
{
	textil_json_skip_ws(ctx);
	if (ctx->pos >= ctx->len || ctx->buf[ctx->pos] != '"')
		return TEXTIL_JSON_ERR_STRING_GENERIC;
	ctx->pos++; /* skip opening '"' */

	while (ctx->pos < ctx->len) {
		char c = ctx->buf[ctx->pos++];
		if (c == '"')
			return 0;
		if ((unsigned char)c <= 0x1f)
			return TEXTIL_JSON_ERR_STRING_CONTROL;
		if (c == '\\') {
			if (ctx->pos >= ctx->len)
				return TEXTIL_JSON_ERR_STRING_UNTERMINATED;
			c = ctx->buf[ctx->pos++];
			switch (c) {
			case '"': case '\\': case '/':
				strbuf_addch(out, c);
				break;
			case 'b': strbuf_addch(out, '\b'); break;
			case 'f': strbuf_addch(out, '\f'); break;
			case 'n': strbuf_addch(out, '\n'); break;
			case 't': strbuf_addch(out, '\t'); break;
			case 'r': strbuf_addch(out, '\r'); break;
			case 'u': {
				int i;
				unsigned int cp = 0;
				for (i = 0; i < 4; i++) {
					char h;
					if (ctx->pos >= ctx->len)
						return TEXTIL_JSON_ERR_STRING_ESCAPE;
					h = ctx->buf[ctx->pos++];
					cp <<= 4;
					if (h >= '0' && h <= '9')
						cp |= h - '0';
					else if (h >= 'a' && h <= 'f')
						cp |= h - 'a' + 10;
					else if (h >= 'A' && h <= 'F')
						cp |= h - 'A' + 10;
					else
						return TEXTIL_JSON_ERR_STRING_ESCAPE;
				}
				if (cp < 0x80)
					strbuf_addch(out, (char)cp);
				else
					strbuf_addf(out, "\\u%04x", cp);
				break;
			}
			default:
				return TEXTIL_JSON_ERR_STRING_ESCAPE;
			}
		} else {
			strbuf_addch(out, c);
		}
	}
	return TEXTIL_JSON_ERR_STRING_UNTERMINATED;
}

int textil_json_parse_bool(struct textil_json_ctx *ctx, int *value_out)
{
	textil_json_skip_ws(ctx);
	if (ctx->pos + 4 <= ctx->len &&
	    !strncmp(ctx->buf + ctx->pos, "true", 4)) {
		ctx->pos += 4;
		*value_out = 1;
		return 0;
	}
	if (ctx->pos + 5 <= ctx->len &&
	    !strncmp(ctx->buf + ctx->pos, "false", 5)) {
		ctx->pos += 5;
		*value_out = 0;
		return 0;
	}
	return -1;
}

int textil_json_parse_key(struct textil_json_ctx *ctx, struct strbuf *out)
{
	if (textil_json_parse_string(ctx, out))
		return -1;
	if (out->len > TEXTIL_JSON_MAX_KEY_LEN)
		return -1; /* key too long */
	return textil_json_expect(ctx, ':');
}

int textil_json_skip_value(struct textil_json_ctx *ctx)
{
	char c = textil_json_peek(ctx);

	if (c == '"') {
		struct strbuf tmp = STRBUF_INIT;
		int ret = textil_json_parse_string(ctx, &tmp);
		strbuf_release(&tmp);
		return ret;
	}
	if (c == 't') {
		if (ctx->pos + 4 > ctx->len ||
		    strncmp(ctx->buf + ctx->pos, "true", 4))
			return -1;
		ctx->pos += 4;
		return 0;
	}
	if (c == 'f') {
		if (ctx->pos + 5 > ctx->len ||
		    strncmp(ctx->buf + ctx->pos, "false", 5))
			return -1;
		ctx->pos += 5;
		return 0;
	}
	if (c == 'n') {
		if (ctx->pos + 4 > ctx->len ||
		    strncmp(ctx->buf + ctx->pos, "null", 4))
			return -1;
		ctx->pos += 4;
		return 0;
	}
	if (c == '{') {
		ctx->pos++;
		if (textil_json_peek(ctx) != '}') {
			int first = 1;
			for (;;) {
				struct strbuf k = STRBUF_INIT;
				if (!first && textil_json_expect(ctx, ',')) {
					strbuf_release(&k);
					return -1;
				}
				first = 0;
				if (textil_json_parse_key(ctx, &k)) {
					strbuf_release(&k);
					return -1;
				}
				strbuf_release(&k);
				if (textil_json_skip_value(ctx))
					return -1;
				if (textil_json_peek(ctx) != ',')
					break;
			}
		}
		return textil_json_expect(ctx, '}');
	}
	if (c == '[') {
		ctx->pos++;
		if (textil_json_peek(ctx) != ']') {
			int first = 1;
			for (;;) {
				if (!first && textil_json_expect(ctx, ','))
					return -1;
				first = 0;
				if (textil_json_skip_value(ctx))
					return -1;
				if (textil_json_peek(ctx) != ',')
					break;
			}
		}
		return textil_json_expect(ctx, ']');
	}
	/* numbers: -?[0-9]+(.digits)?(e/E[+-]?digits)? */
	if (c == '-' || (c >= '0' && c <= '9')) {
		if (ctx->buf[ctx->pos] == '-')
			ctx->pos++;
		if (ctx->pos >= ctx->len ||
		    ctx->buf[ctx->pos] < '0' || ctx->buf[ctx->pos] > '9')
			return -1;
		while (ctx->pos < ctx->len &&
		       ctx->buf[ctx->pos] >= '0' && ctx->buf[ctx->pos] <= '9')
			ctx->pos++;
		if (ctx->pos < ctx->len && ctx->buf[ctx->pos] == '.') {
			ctx->pos++;
			while (ctx->pos < ctx->len &&
			       ctx->buf[ctx->pos] >= '0' &&
			       ctx->buf[ctx->pos] <= '9')
				ctx->pos++;
		}
		if (ctx->pos < ctx->len &&
		    (ctx->buf[ctx->pos] == 'e' ||
		     ctx->buf[ctx->pos] == 'E')) {
			ctx->pos++;
			if (ctx->pos < ctx->len &&
			    (ctx->buf[ctx->pos] == '+' ||
			     ctx->buf[ctx->pos] == '-'))
				ctx->pos++;
			while (ctx->pos < ctx->len &&
			       ctx->buf[ctx->pos] >= '0' &&
			       ctx->buf[ctx->pos] <= '9')
				ctx->pos++;
		}
		return 0;
	}
	return -1; /* unexpected character */
}

int textil_json_at_end(struct textil_json_ctx *ctx)
{
	textil_json_skip_ws(ctx);
	return ctx->pos >= ctx->len;
}
