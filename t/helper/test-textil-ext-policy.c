#include "test-tool.h"
#include "textil-ext-policy.h"
#include "strbuf.h"

/*
 * test-tool textil-ext-policy evaluate <phase> <attr_filter|-> <is_regular_file>
 *
 * Evaluates the loaded policy and prints the result.
 * Requires a policy source env plus TEXTIL_GIT_EXT_POLICY_VERSION
 * to be set (policy_init is called by init_git via common-init.c).
 *
 * Output format (one field per line):
 *   matched=<0|1>
 *   rule_id=<id|>
 *   action=<takeover|observe>
 *   fallback=<deny|skip>
 *   strict=<0|1>
 *   capabilities=<cap1,cap2,...>
 */

static enum textil_ext_phase parse_phase_arg(const char *s)
{
	if (!strcmp(s, "preflight"))
		return TEXTIL_PHASE_PREFLIGHT;
	if (!strcmp(s, "materialize"))
		return TEXTIL_PHASE_MATERIALIZE;
	if (!strcmp(s, "checkin_convert"))
		return TEXTIL_PHASE_CHECKIN_CONVERT;
	die("unknown phase: %s", s);
}

int cmd__textil_ext_policy(int argc, const char **argv)
{
	if (argc < 2)
		die("usage: test-tool textil-ext-policy <subcommand>");

	if (!strcmp(argv[1], "is-active")) {
		printf("active=%d\n", textil_ext_policy_is_active());
		return 0;
	}

	if (!strcmp(argv[1], "evaluate")) {
		enum textil_ext_phase phase;
		const char *attr_filter;
		int is_regular_file;
		struct textil_ext_eval_result result;
		int i;

		if (argc != 5)
			die("usage: test-tool textil-ext-policy evaluate "
			    "<phase> <attr_filter|-> <is_regular_file>");

		phase = parse_phase_arg(argv[2]);
		attr_filter = strcmp(argv[3], "-") ? argv[3] : NULL;
		is_regular_file = atoi(argv[4]);

		if (!textil_ext_policy_is_active())
			die("policy not active");

		textil_ext_policy_evaluate(phase, attr_filter,
					   is_regular_file, &result);

		printf("matched=%d\n", result.matched);
		printf("rule_id=%s\n", result.rule_id ? result.rule_id : "");
		printf("action=%s\n",
		       result.action == TEXTIL_ACTION_TAKEOVER ?
		       "takeover" : "observe");
		printf("fallback=%s\n",
		       result.fallback == TEXTIL_FALLBACK_DENY ?
		       "deny" : "skip");
		printf("strict=%d\n", result.strict);

		printf("capabilities=");
		for (i = 0; i < result.nr_capabilities; i++) {
			if (i > 0)
				printf(",");
			printf("%s", result.capabilities[i]);
		}
		printf("\n");

		return 0;
	}

	if (!strcmp(argv[1], "rule-count")) {
		const struct textil_ext_policy *pol;
		if (!textil_ext_policy_is_active())
			die("policy not active");
		pol = textil_ext_policy_get();
		printf("rules=%d\n", pol->nr_rules);
		return 0;
	}

	die("unknown subcommand: %s", argv[1]);
}
