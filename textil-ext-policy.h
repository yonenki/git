#ifndef TEXTIL_EXT_POLICY_H
#define TEXTIL_EXT_POLICY_H

/*
 * Textil Git Extension Selection Policy runtime loader and evaluator.
 *
 * Phase1-3: env loading + minimal JSON check
 * Phase1-4: strict JSON parse + typed structs + rule evaluation
 *
 * Env contract:
 *   TEXTIL_GIT_EXT_POLICY_PATH    - absolute path to policy.v1.json
 *   TEXTIL_GIT_EXT_POLICY_VERSION - must be "v1"
 *
 * Both must be set or both unset.  Partial configuration is a fatal error.
 */

/* --- Enums ------------------------------------------------------------ */

enum textil_ext_phase {
	TEXTIL_PHASE_PREFLIGHT,
	TEXTIL_PHASE_MATERIALIZE,
	TEXTIL_PHASE_CHECKIN_CONVERT,
};

enum textil_ext_action {
	TEXTIL_ACTION_TAKEOVER,
	TEXTIL_ACTION_OBSERVE,
};

enum textil_ext_fallback {
	TEXTIL_FALLBACK_DENY,
	TEXTIL_FALLBACK_SKIP,
};

/* --- Selector --------------------------------------------------------- */

struct textil_ext_selector {
	/*
	 * gitattributes filter= value to match (e.g. "lfs").
	 * NULL means no filter constraint (matches any).
	 */
	char *attr_filter_equals;
	int regular_file_only;
};

/* --- Rule ------------------------------------------------------------- */

#define TEXTIL_MAX_PHASES 8
#define TEXTIL_MAX_CAPABILITIES 16

struct textil_ext_rule {
	char *id;
	enum textil_ext_phase phases[TEXTIL_MAX_PHASES];
	int nr_phases;
	struct textil_ext_selector selector;
	enum textil_ext_action action;
	int strict;
	enum textil_ext_fallback fallback;
	char *capabilities[TEXTIL_MAX_CAPABILITIES];
	int nr_capabilities;
};

/* --- Policy ----------------------------------------------------------- */

#define TEXTIL_MAX_RULES 32

struct textil_ext_policy {
	int nr_rules;
	struct textil_ext_rule rules[TEXTIL_MAX_RULES];
};

/* --- Evaluation result ------------------------------------------------ */

struct textil_ext_eval_result {
	int matched; /* 1 if a rule matched, 0 otherwise */
	const char *rule_id; /* NULL if not matched */
	enum textil_ext_action action;
	enum textil_ext_fallback fallback;
	int strict;
	const char * const *capabilities;
	int nr_capabilities;
};

/* --- Public API ------------------------------------------------------- */

/*
 * Initialize the Textil extension policy subsystem.
 * Call once during init_git().  Reads env vars, strict-parses JSON,
 * builds typed runtime structs.  On error, calls die() (fail-fast).
 * If env vars are unset, the subsystem is disabled (no-op).
 */
void textil_ext_policy_init(void);

/*
 * Returns 1 if a valid policy is loaded, 0 otherwise.
 */
int textil_ext_policy_is_active(void);

/*
 * Evaluate the loaded policy against the given context.
 *
 * Rules are evaluated in definition order (first match wins).
 * A rule matches if:
 *   - the phase is in the rule's phases list
 *   - selector.attr_filter_equals matches (or is NULL = any)
 *   - selector.regular_file_only is false, or is_regular_file is true
 *
 * If no rule matches, result.matched = 0 and result.action = OBSERVE,
 * result.fallback = SKIP (default: proceed with git standard behavior).
 *
 * Only valid when textil_ext_policy_is_active() returns 1.
 */
void textil_ext_policy_evaluate(
	enum textil_ext_phase phase,
	const char *attr_filter,
	int is_regular_file,
	struct textil_ext_eval_result *result);

/*
 * Return a pointer to the parsed policy struct.
 * Only valid when textil_ext_policy_is_active() returns 1.
 */
const struct textil_ext_policy *textil_ext_policy_get(void);

/* --- Convenience wrappers for hook points -------------------------------- */

/*
 * Evaluate policy for checkout (materialize) phase.
 * If policy is inactive, returns no-match default (observe + skip).
 */
void textil_ext_evaluate_for_checkout(
	const char *attr_filter,
	int is_regular_file,
	struct textil_ext_eval_result *result);

/*
 * Evaluate policy for checkin (convert_to_git) phase.
 * If policy is inactive, returns no-match default (observe + skip).
 */
void textil_ext_evaluate_for_checkin(
	const char *attr_filter,
	int is_regular_file,
	struct textil_ext_eval_result *result);

/*
 * Evaluate policy for preflight (pre-checkout batch) phase.
 * If policy is inactive, returns no-match default (observe + skip).
 */
void textil_ext_evaluate_for_preflight(
	const char *attr_filter,
	int is_regular_file,
	struct textil_ext_eval_result *result);

/*
 * Die if the evaluation result indicates takeover, since the takeover
 * executor is not yet wired (Phase1-6+).
 * Call after evaluate_for_checkout/checkin when action might be takeover.
 * No-op for observe/no-match.
 */
void textil_ext_require_supported_or_die(
	const struct textil_ext_eval_result *result,
	const char *operation,
	const char *path);

#endif /* TEXTIL_EXT_POLICY_H */
