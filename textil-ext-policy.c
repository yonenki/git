#include "git-compat-util.h"
#include "abspath.h"
#include "textil-ext-policy.h"
#include "textil-ext-json.h"
#include "strbuf.h"
#include "trace.h"
#include "gettext.h"

#define ENV_POLICY_JSON    "TEXTIL_GIT_EXT_POLICY_JSON"
#define ENV_POLICY_B64     "TEXTIL_GIT_EXT_POLICY_B64"
#define ENV_POLICY_PATH    "TEXTIL_GIT_EXT_POLICY_PATH"
#define ENV_POLICY_VERSION "TEXTIL_GIT_EXT_POLICY_VERSION"
#define EXPECTED_VERSION   "v1"

static struct trace_key trace_textil_ext = TRACE_KEY_INIT(TEXTIL_EXT);

static int policy_active;
static struct textil_ext_policy the_policy;

/* ======================================================================
 * Die-on-error wrappers around shared textil_json_* primitives.
 *
 * Policy parsing is fail-fast: any structural error is fatal.
 * The shared primitives return error codes; these wrappers die()
 * with file-path context on failure.
 * ====================================================================== */

/* File path for error messages (set during init, valid for parse lifetime) */
static const char *policy_parse_path;

static int b64_value(unsigned char ch)
{
	if (ch >= 'A' && ch <= 'Z')
		return ch - 'A';
	if (ch >= 'a' && ch <= 'z')
		return ch - 'a' + 26;
	if (ch >= '0' && ch <= '9')
		return ch - '0' + 52;
	if (ch == '+')
		return 62;
	if (ch == '/')
		return 63;
	return -1;
}

static void decode_policy_base64(const char *encoded, struct strbuf *out)
{
	size_t len = strlen(encoded);
	size_t i;

	if (!len)
		die(_("textil-ext: %s must not be empty"), ENV_POLICY_B64);
	if (len % 4)
		die(_("textil-ext: invalid base64 policy payload in %s"),
		    ENV_POLICY_B64);

	for (i = 0; i < len; i += 4) {
		unsigned char c0 = encoded[i];
		unsigned char c1 = encoded[i + 1];
		unsigned char c2 = encoded[i + 2];
		unsigned char c3 = encoded[i + 3];
		int v0 = b64_value(c0);
		int v1 = b64_value(c1);
		int v2 = (c2 == '=') ? -2 : b64_value(c2);
		int v3 = (c3 == '=') ? -2 : b64_value(c3);

		if (v0 < 0 || v1 < 0 || v2 == -1 || v3 == -1)
			die(_("textil-ext: invalid base64 policy payload in %s"),
			    ENV_POLICY_B64);
		if (v2 == -2 && c3 != '=')
			die(_("textil-ext: invalid base64 policy payload in %s"),
			    ENV_POLICY_B64);
		if ((v2 == -2 || v3 == -2) && i + 4 != len)
			die(_("textil-ext: invalid base64 policy payload in %s"),
			    ENV_POLICY_B64);

		strbuf_addch(out, (char)((v0 << 2) | (v1 >> 4)));
		if (v2 != -2) {
			strbuf_addch(out, (char)(((v1 & 0xf) << 4) | (v2 >> 2)));
			if (v3 != -2)
				strbuf_addch(out, (char)(((v2 & 0x3) << 6) | v3));
		}
	}
}

static void policy_expect(struct textil_json_ctx *ctx, char expected)
{
	if (textil_json_expect(ctx, expected))
		die(_("textil-ext: parse error in '%s' at pos %lu: "
		      "expected '%c', got '%c'"),
		    policy_parse_path, (unsigned long)ctx->pos,
		    expected,
		    (ctx->pos < ctx->len) ? ctx->buf[ctx->pos] : '?');
}

static char *policy_parse_string(struct textil_json_ctx *ctx)
{
	struct strbuf sb = STRBUF_INIT;
	int ret = textil_json_parse_string(ctx, &sb);
	if (ret) {
		size_t err_pos = ctx->pos > 0 ? ctx->pos - 1 : 0;
		strbuf_release(&sb);
		switch (ret) {
		case TEXTIL_JSON_ERR_STRING_CONTROL:
			die(_("textil-ext: parse error in '%s' at pos %lu: "
			      "unescaped control character 0x%02x in string"),
			    policy_parse_path, (unsigned long)err_pos,
			    (unsigned char)ctx->buf[err_pos]);
		case TEXTIL_JSON_ERR_STRING_ESCAPE:
			die(_("textil-ext: parse error in '%s' at pos %lu: "
			      "invalid escape '\\%c'"),
			    policy_parse_path, (unsigned long)err_pos,
			    ctx->buf[err_pos]);
		case TEXTIL_JSON_ERR_STRING_UNTERMINATED:
			die(_("textil-ext: parse error in '%s': "
			      "unterminated string"),
			    policy_parse_path);
		default:
			die(_("textil-ext: parse error in '%s' at pos %lu: "
			      "expected string"),
			    policy_parse_path, (unsigned long)ctx->pos);
		}
	}
	return strbuf_detach(&sb, NULL);
}

static int policy_parse_bool(struct textil_json_ctx *ctx)
{
	int val;
	if (textil_json_parse_bool(ctx, &val))
		die(_("textil-ext: parse error in '%s' at pos %lu: "
		      "expected boolean"),
		    policy_parse_path, (unsigned long)ctx->pos);
	return val;
}

/* ======================================================================
 * Enum parsing
 * ====================================================================== */

static enum textil_ext_phase parse_phase(const char *s, const char *path)
{
	if (!strcmp(s, "preflight"))
		return TEXTIL_PHASE_PREFLIGHT;
	if (!strcmp(s, "materialize"))
		return TEXTIL_PHASE_MATERIALIZE;
	if (!strcmp(s, "checkin_convert"))
		return TEXTIL_PHASE_CHECKIN_CONVERT;
	die(_("textil-ext: '%s': unknown phase '%s'"), path, s);
}

static enum textil_ext_action parse_action(const char *s, const char *path)
{
	if (!strcmp(s, "takeover"))
		return TEXTIL_ACTION_TAKEOVER;
	if (!strcmp(s, "observe"))
		return TEXTIL_ACTION_OBSERVE;
	die(_("textil-ext: '%s': unknown action '%s'"), path, s);
}

static enum textil_ext_fallback parse_fallback(const char *s, const char *path)
{
	if (!strcmp(s, "deny"))
		return TEXTIL_FALLBACK_DENY;
	if (!strcmp(s, "skip"))
		return TEXTIL_FALLBACK_SKIP;
	die(_("textil-ext: '%s': unknown fallback '%s'"), path, s);
}

/* ======================================================================
 * Strict schema parser
 * ====================================================================== */

static void parse_selector(struct textil_json_ctx *ctx,
			    struct textil_ext_selector *sel)
{
	int has_attr = 0, has_rfo = 0;
	int field_count = 0;

	policy_expect(ctx, '{');
	sel->attr_filter_equals = NULL;
	sel->regular_file_only = 0;

	while (textil_json_peek(ctx) != '}') {
		char *key;
		if (field_count > 0) {
			policy_expect(ctx, ',');
			if (textil_json_peek(ctx) == '}')
				die(_("textil-ext: parse error in '%s': "
				      "trailing comma in selector"),
				    policy_parse_path);
		}
		key = policy_parse_string(ctx);
		policy_expect(ctx, ':');

		if (!strcmp(key, "attr_filter_equals")) {
			char *val;
			char *trimmed;
			if (has_attr)
				die(_("textil-ext: '%s': duplicate key "
				      "'attr_filter_equals' in selector"),
				    policy_parse_path);
			val = policy_parse_string(ctx);
			/* trim and validate non-empty */
			trimmed = val;
			while (*trimmed == ' ' || *trimmed == '\t') trimmed++;
			if (!*trimmed)
				die(_("textil-ext: '%s': selector."
				      "attr_filter_equals must not be "
				      "empty or whitespace-only"),
				    policy_parse_path);
			sel->attr_filter_equals = val;
			has_attr = 1;
		} else if (!strcmp(key, "regular_file_only")) {
			if (has_rfo)
				die(_("textil-ext: '%s': duplicate key "
				      "'regular_file_only' in selector"),
				    policy_parse_path);
			sel->regular_file_only = policy_parse_bool(ctx);
			has_rfo = 1;
		} else {
			die(_("textil-ext: '%s': unknown key '%s' in selector"),
			    policy_parse_path, key);
		}
		free(key);
		field_count++;
	}
	policy_expect(ctx, '}');

	/* regular_file_only is required */
	if (!has_rfo)
		die(_("textil-ext: '%s': selector missing required field "
		      "'regular_file_only'"), policy_parse_path);
}

static void parse_string_array(struct textil_json_ctx *ctx, char **out,
			       int max, int *nr, const char *field_name)
{
	*nr = 0;
	policy_expect(ctx, '[');
	while (textil_json_peek(ctx) != ']') {
		char *val, *trimmed;
		if (*nr > 0) {
			policy_expect(ctx, ',');
			if (textil_json_peek(ctx) == ']')
				die(_("textil-ext: parse error in '%s': "
				      "trailing comma in %s"),
				    policy_parse_path, field_name);
		}
		if (*nr >= max)
			die(_("textil-ext: '%s': too many entries in '%s' "
			      "(max %d)"), policy_parse_path, field_name, max);
		val = policy_parse_string(ctx);
		trimmed = val;
		while (*trimmed == ' ' || *trimmed == '\t') trimmed++;
		if (!*trimmed)
			die(_("textil-ext: '%s': %s[%d] must not be empty "
			      "or whitespace-only"),
			    policy_parse_path, field_name, *nr);
		out[(*nr)++] = val;
	}
	policy_expect(ctx, ']');
}

static void parse_phases_array(struct textil_json_ctx *ctx,
			       enum textil_ext_phase *out, int max,
			       int *nr)
{
	*nr = 0;
	policy_expect(ctx, '[');
	while (textil_json_peek(ctx) != ']') {
		char *val;
		if (*nr > 0) {
			policy_expect(ctx, ',');
			if (textil_json_peek(ctx) == ']')
				die(_("textil-ext: parse error in '%s': "
				      "trailing comma in phases"),
				    policy_parse_path);
		}
		if (*nr >= max)
			die(_("textil-ext: '%s': too many phases (max %d)"),
			    policy_parse_path, max);
		val = policy_parse_string(ctx);
		out[(*nr)++] = parse_phase(val, policy_parse_path);
		free(val);
	}
	policy_expect(ctx, ']');

	if (*nr == 0)
		die(_("textil-ext: '%s': phases must not be empty"),
		    policy_parse_path);
}

static void parse_rule(struct textil_json_ctx *ctx,
		       struct textil_ext_rule *rule)
{
	int has_id = 0, has_phases = 0, has_selector = 0;
	int has_action = 0, has_strict = 0, has_fallback = 0;
	int has_caps = 0;
	int field_count = 0;

	memset(rule, 0, sizeof(*rule));
	policy_expect(ctx, '{');

	while (textil_json_peek(ctx) != '}') {
		char *key;
		if (field_count > 0) {
			policy_expect(ctx, ',');
			if (textil_json_peek(ctx) == '}')
				die(_("textil-ext: parse error in '%s': "
				      "trailing comma in rule"),
				    policy_parse_path);
		}
		key = policy_parse_string(ctx);
		policy_expect(ctx, ':');

		if (!strcmp(key, "id")) {
			char *val, *trimmed;
			if (has_id)
				die(_("textil-ext: '%s': duplicate key 'id'"),
				    policy_parse_path);
			val = policy_parse_string(ctx);
			trimmed = val;
			while (*trimmed == ' ' || *trimmed == '\t') trimmed++;
			if (!*trimmed)
				die(_("textil-ext: '%s': rule id must not be "
				      "empty or whitespace-only"),
				    policy_parse_path);
			rule->id = val;
			has_id = 1;
		} else if (!strcmp(key, "phases")) {
			if (has_phases)
				die(_("textil-ext: '%s': duplicate key 'phases'"),
				    policy_parse_path);
			parse_phases_array(ctx, rule->phases,
					   TEXTIL_MAX_PHASES,
					   &rule->nr_phases);
			has_phases = 1;
		} else if (!strcmp(key, "selector")) {
			if (has_selector)
				die(_("textil-ext: '%s': duplicate key 'selector'"),
				    policy_parse_path);
			parse_selector(ctx, &rule->selector);
			has_selector = 1;
		} else if (!strcmp(key, "action")) {
			char *val;
			if (has_action)
				die(_("textil-ext: '%s': duplicate key 'action'"),
				    policy_parse_path);
			val = policy_parse_string(ctx);
			rule->action = parse_action(val, policy_parse_path);
			free(val);
			has_action = 1;
		} else if (!strcmp(key, "strict")) {
			if (has_strict)
				die(_("textil-ext: '%s': duplicate key 'strict'"),
				    policy_parse_path);
			rule->strict = policy_parse_bool(ctx);
			has_strict = 1;
		} else if (!strcmp(key, "fallback")) {
			char *val;
			if (has_fallback)
				die(_("textil-ext: '%s': duplicate key 'fallback'"),
				    policy_parse_path);
			val = policy_parse_string(ctx);
			rule->fallback = parse_fallback(val, policy_parse_path);
			free(val);
			has_fallback = 1;
		} else if (!strcmp(key, "required_capabilities")) {
			if (has_caps)
				die(_("textil-ext: '%s': duplicate key "
				      "'required_capabilities'"),
				    policy_parse_path);
			parse_string_array(ctx, rule->capabilities,
					   TEXTIL_MAX_CAPABILITIES,
					   &rule->nr_capabilities,
					   "required_capabilities");
			has_caps = 1;
		} else {
			die(_("textil-ext: '%s': unknown key '%s' in rule"),
			    policy_parse_path, key);
		}
		free(key);
		field_count++;
	}
	policy_expect(ctx, '}');

	/* Required fields check */
	if (!has_id)
		die(_("textil-ext: '%s': rule missing required field 'id'"),
		    policy_parse_path);
	if (!has_phases)
		die(_("textil-ext: '%s': rule '%s' missing required field "
		      "'phases'"), policy_parse_path, rule->id);
	if (!has_selector)
		die(_("textil-ext: '%s': rule '%s' missing required field "
		      "'selector'"), policy_parse_path, rule->id);
	if (!has_action)
		die(_("textil-ext: '%s': rule '%s' missing required field "
		      "'action'"), policy_parse_path, rule->id);
	if (!has_strict)
		die(_("textil-ext: '%s': rule '%s' missing required field "
		      "'strict'"), policy_parse_path, rule->id);
	if (!has_fallback)
		die(_("textil-ext: '%s': rule '%s' missing required field "
		      "'fallback'"), policy_parse_path, rule->id);
	if (!has_caps)
		die(_("textil-ext: '%s': rule '%s' missing required field "
		      "'required_capabilities'"), policy_parse_path, rule->id);

	/* Takeover => fallback=Deny */
	if (rule->action == TEXTIL_ACTION_TAKEOVER &&
	    rule->fallback != TEXTIL_FALLBACK_DENY)
		die(_("textil-ext: '%s': rule '%s': takeover action requires "
		      "fallback=deny"), policy_parse_path, rule->id);
}

static void parse_policy(struct textil_json_ctx *ctx,
			  struct textil_ext_policy *pol)
{
	int has_version = 0, has_rules = 0;
	int field_count = 0;
	int i, j;

	memset(pol, 0, sizeof(*pol));
	policy_expect(ctx, '{');

	while (textil_json_peek(ctx) != '}') {
		char *key;
		if (field_count > 0) {
			policy_expect(ctx, ',');
			if (textil_json_peek(ctx) == '}')
				die(_("textil-ext: parse error in '%s': "
				      "trailing comma in policy object"),
				    policy_parse_path);
		}
		key = policy_parse_string(ctx);
		policy_expect(ctx, ':');

		if (!strcmp(key, "version")) {
			char *val;
			if (has_version)
				die(_("textil-ext: '%s': duplicate key "
				      "'version'"), policy_parse_path);
			val = policy_parse_string(ctx);
			if (strcmp(val, EXPECTED_VERSION))
				die(_("textil-ext: '%s': unsupported version "
				      "'%s' (expected '%s')"),
				    policy_parse_path, val, EXPECTED_VERSION);
			free(val);
			has_version = 1;
		} else if (!strcmp(key, "rules")) {
			if (has_rules)
				die(_("textil-ext: '%s': duplicate key "
				      "'rules'"), policy_parse_path);
			policy_expect(ctx, '[');
			while (textil_json_peek(ctx) != ']') {
				if (pol->nr_rules > 0) {
					policy_expect(ctx, ',');
					if (textil_json_peek(ctx) == ']')
						die(_("textil-ext: parse error "
						      "in '%s': trailing comma "
						      "in rules array"),
						    policy_parse_path);
				}
				if (pol->nr_rules >= TEXTIL_MAX_RULES)
					die(_("textil-ext: '%s': too many "
					      "rules (max %d)"),
					    policy_parse_path,
					    TEXTIL_MAX_RULES);
				parse_rule(ctx,
					   &pol->rules[pol->nr_rules]);
				pol->nr_rules++;
			}
			policy_expect(ctx, ']');
			has_rules = 1;
		} else {
			die(_("textil-ext: '%s': unknown top-level key '%s'"),
			    policy_parse_path, key);
		}
		free(key);
		field_count++;
	}
	policy_expect(ctx, '}');

	if (!has_version)
		die(_("textil-ext: '%s': missing required field 'version'"),
		    policy_parse_path);
	if (!has_rules)
		die(_("textil-ext: '%s': missing required field 'rules'"),
		    policy_parse_path);
	if (pol->nr_rules == 0)
		die(_("textil-ext: '%s': rules must not be empty"),
		    policy_parse_path);

	/* Check trailing content */
	if (!textil_json_at_end(ctx))
		die(_("textil-ext: '%s': unexpected content after JSON"),
		    policy_parse_path);

	/* Check duplicate rule ids */
	for (i = 0; i < pol->nr_rules; i++) {
		for (j = i + 1; j < pol->nr_rules; j++) {
			if (!strcmp(pol->rules[i].id, pol->rules[j].id))
				die(_("textil-ext: '%s': duplicate rule id "
				      "'%s'"), policy_parse_path,
				    pol->rules[i].id);
		}
	}
}

/* ======================================================================
 * Initialization
 * ====================================================================== */

void textil_ext_policy_init(void)
{
	const char *env_json, *env_b64, *env_path, *env_version;
	int source_count = 0;
	const char *loaded_from = NULL;
	struct strbuf json_buf = STRBUF_INIT;
	struct textil_json_ctx ctx;

	env_json = getenv(ENV_POLICY_JSON);
	env_b64 = getenv(ENV_POLICY_B64);
	env_path = getenv(ENV_POLICY_PATH);
	env_version = getenv(ENV_POLICY_VERSION);
	source_count += !!env_json;
	source_count += !!env_b64;
	source_count += !!env_path;

	/* Both unset: disabled (normal git operation) */
	if (!source_count && !env_version) {
		trace_printf_key(&trace_textil_ext,
				 "textil-ext: policy disabled (env not set)\n");
		return;
	}

	/* Partial configuration: fatal */
	if (!env_version)
		die(_("textil-ext: policy source env is set but %s is not"),
		    ENV_POLICY_VERSION);
	if (!source_count)
		die(_("textil-ext: %s is set but no policy source env is set"),
		    ENV_POLICY_VERSION);
	if (source_count > 1)
		die(_("textil-ext: policy source envs are mutually exclusive "
		      "(set only one of %s, %s, %s)"),
		    ENV_POLICY_JSON, ENV_POLICY_B64, ENV_POLICY_PATH);

	/* Version check (env) */
	if (strcmp(env_version, EXPECTED_VERSION))
		die(_("textil-ext: unsupported policy version '%s' "
		      "(expected '%s')"), env_version, EXPECTED_VERSION);

	if (env_json) {
		if (!*env_json)
			die(_("textil-ext: %s must not be empty"), ENV_POLICY_JSON);
		strbuf_addstr(&json_buf, env_json);
		loaded_from = "env:TEXTIL_GIT_EXT_POLICY_JSON";
	} else if (env_b64) {
		decode_policy_base64(env_b64, &json_buf);
		loaded_from = "env:TEXTIL_GIT_EXT_POLICY_B64";
	} else {
		/* Absolute path check */
		if (!is_absolute_path(env_path))
			die(_("textil-ext: %s must be an absolute path, got '%s'"),
			    ENV_POLICY_PATH, env_path);

		/* Read the file */
		if (strbuf_read_file(&json_buf, env_path, 0) < 0)
			die_errno(_("textil-ext: unable to read policy file '%s'"),
				  env_path);
		loaded_from = env_path;
	}

	/* Strict parse */
	ctx.buf = json_buf.buf;
	ctx.pos = 0;
	ctx.len = json_buf.len;
	policy_parse_path = loaded_from;
	parse_policy(&ctx, &the_policy);
	policy_parse_path = NULL;

	strbuf_release(&json_buf);

	policy_active = 1;
	trace_printf_key(&trace_textil_ext,
			 "textil-ext: policy loaded from '%s' (%d rules)\n",
			 loaded_from, the_policy.nr_rules);
}

int textil_ext_policy_is_active(void)
{
	return policy_active;
}

const struct textil_ext_policy *textil_ext_policy_get(void)
{
	return &the_policy;
}

/* ======================================================================
 * Rule evaluator
 *
 * First-match wins.  No match → default Observe + Skip.
 * ====================================================================== */

static int phase_matches(const struct textil_ext_rule *rule,
			 enum textil_ext_phase phase)
{
	int i;
	for (i = 0; i < rule->nr_phases; i++) {
		if (rule->phases[i] == phase)
			return 1;
	}
	return 0;
}

static int selector_matches(const struct textil_ext_selector *sel,
			    const char *attr_filter,
			    int is_regular_file)
{
	/* regular_file_only check */
	if (sel->regular_file_only && !is_regular_file)
		return 0;

	/* attr_filter_equals check */
	if (sel->attr_filter_equals) {
		if (!attr_filter)
			return 0;
		if (strcmp(sel->attr_filter_equals, attr_filter))
			return 0;
	}

	return 1;
}

void textil_ext_policy_evaluate(
	enum textil_ext_phase phase,
	const char *attr_filter,
	int is_regular_file,
	struct textil_ext_eval_result *result)
{
	int i;

	/* Default: no match → Observe + Skip */
	memset(result, 0, sizeof(*result));
	result->action = TEXTIL_ACTION_OBSERVE;
	result->fallback = TEXTIL_FALLBACK_SKIP;

	for (i = 0; i < the_policy.nr_rules; i++) {
		const struct textil_ext_rule *rule = &the_policy.rules[i];

		if (!phase_matches(rule, phase))
			continue;
		if (!selector_matches(&rule->selector, attr_filter,
				      is_regular_file))
			continue;

		/* First match wins */
		result->matched = 1;
		result->rule_id = rule->id;
		result->action = rule->action;
		result->fallback = rule->fallback;
		result->strict = rule->strict;
		result->capabilities = (const char * const *)rule->capabilities;
		result->nr_capabilities = rule->nr_capabilities;

		trace_printf_key(&trace_textil_ext,
				 "textil-ext: rule '%s' matched "
				 "(action=%s, fallback=%s)\n",
				 rule->id,
				 rule->action == TEXTIL_ACTION_TAKEOVER ?
				 "takeover" : "observe",
				 rule->fallback == TEXTIL_FALLBACK_DENY ?
				 "deny" : "skip");
		return;
	}

	trace_printf_key(&trace_textil_ext,
			 "textil-ext: no rule matched (default observe+skip)\n");
}

/* ======================================================================
 * Convenience wrappers for hook points
 * ====================================================================== */

static void evaluate_or_default(enum textil_ext_phase phase,
				const char *attr_filter,
				int is_regular_file,
				struct textil_ext_eval_result *result)
{
	if (!policy_active) {
		memset(result, 0, sizeof(*result));
		result->action = TEXTIL_ACTION_OBSERVE;
		result->fallback = TEXTIL_FALLBACK_SKIP;
		return;
	}
	textil_ext_policy_evaluate(phase, attr_filter,
				   is_regular_file, result);
}

void textil_ext_evaluate_for_checkout(
	const char *attr_filter,
	int is_regular_file,
	struct textil_ext_eval_result *result)
{
	evaluate_or_default(TEXTIL_PHASE_MATERIALIZE,
			    attr_filter, is_regular_file, result);
}

void textil_ext_evaluate_for_checkin(
	const char *attr_filter,
	int is_regular_file,
	struct textil_ext_eval_result *result)
{
	evaluate_or_default(TEXTIL_PHASE_CHECKIN_CONVERT,
			    attr_filter, is_regular_file, result);
}

void textil_ext_evaluate_for_preflight(
	const char *attr_filter,
	int is_regular_file,
	struct textil_ext_eval_result *result)
{
	evaluate_or_default(TEXTIL_PHASE_PREFLIGHT,
			    attr_filter, is_regular_file, result);
}

void textil_ext_require_supported_or_die(
	const struct textil_ext_eval_result *result,
	const char *operation,
	const char *path)
{
	if (!result->matched)
		return;
	if (result->action != TEXTIL_ACTION_TAKEOVER)
		return;
	die(_("textil-ext: rule '%s' requested takeover for %s on '%s', "
	      "but takeover executor is not wired yet"),
	    result->rule_id, operation, path);
}
