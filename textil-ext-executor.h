#ifndef TEXTIL_EXT_EXECUTOR_H
#define TEXTIL_EXT_EXECUTOR_H

#include "strbuf.h"

/*
 * Textil Git Extension Takeover Executor
 *
 * Phase1-7: batch payload contract.
 * Phase1-8a: IPC transport via Git's simple-ipc API.
 * Phase1-8c: pkt-line v1 payload (replaced JSON).
 *
 * The executor receives a batch of takeover candidates collected
 * during preflight, encodes them as pkt-line v1, and sends them to the
 * Textil backend controller via simple-ipc.
 *
 * Env contract:
 *   TEXTIL_GIT_EXT_ENDPOINT - path to the IPC socket/pipe.
 *     Must be set when a takeover rule matches.
 *     Unset/empty is a fatal error (not a silent fallback).
 */

#define TEXTIL_GIT_EXT_ENDPOINT "TEXTIL_GIT_EXT_ENDPOINT"

/* --- Phase enum --------------------------------------------------------- */

enum textil_ext_executor_phase {
	TEXTIL_EXT_EXEC_PHASE_PREFLIGHT = 0,
};

/* --- Takeover item (single candidate) ----------------------------------- */

/*
 * Ownership / lifetime:
 *   path         - caller-owned copy (xstrdup).  Freed by release helper.
 *   attr_filter  - caller-owned copy (xstrdup).  Freed by release helper.
 *                  May be NULL if no gitattributes filter.
 *   rule_id      - borrowed pointer into policy structs (valid for
 *                  process lifetime once policy is loaded).
 *   capabilities - borrowed pointer into policy structs (same lifetime).
 */
struct textil_ext_takeover_item {
	char *path;                  /* repo-relative path (owned, xstrdup) */
	const char *rule_id;         /* matched rule id (borrowed) */
	char *attr_filter;           /* selector input (owned, xstrdup; NULL ok) */
	int is_regular_file;         /* 0/1 */
	int strict;                  /* rule.strict */
	const char * const *capabilities; /* required_capabilities (borrowed) */
	int nr_capabilities;
};

/* --- Takeover batch (executor input) ------------------------------------ */

struct textil_ext_takeover_batch {
	enum textil_ext_executor_phase phase; /* PREFLIGHT only for now */
	const char *operation;       /* e.g. "checkout" (string literal) */
	const char *repo_root;       /* worktree root; NULL for bare repos */
	struct textil_ext_takeover_item *items; /* array of candidates */
	int nr_items;                /* must be > 0 when calling executor */
};

/* --- Executor status ---------------------------------------------------- */

enum textil_ext_executor_status {
	TEXTIL_EXT_EXECUTOR_OK = 0,
	TEXTIL_EXT_EXECUTOR_REJECTED = 1,
	TEXTIL_EXT_EXECUTOR_NOT_IMPLEMENTED = 2,
	TEXTIL_EXT_EXECUTOR_ERROR = 3,
};

/* --- Executor API ------------------------------------------------------- */

/*
 * Execute a takeover batch.  The executor does NOT die() on failure;
 * the caller is responsible for fail-fast control.
 *
 * Returns TEXTIL_EXT_EXECUTOR_OK on success.
 * On failure, returns a non-OK status and appends a message to err.
 *
 * Precondition: batch->nr_items > 0.
 */
enum textil_ext_executor_status textil_ext_execute_takeover_batch(
	const struct textil_ext_takeover_batch *batch,
	struct strbuf *err);

/*
 * Release owned fields (path, attr_filter) in each item of the batch.
 * Does NOT free the items array itself or the batch struct.
 * Safe to call with nr_items == 0 or items == NULL.
 */
void textil_ext_takeover_batch_release(struct textil_ext_takeover_batch *batch);

/* --- Preflight collection ----------------------------------------------- */

struct index_state; /* forward declaration */

/*
 * Scan the index for checkout candidates matching a takeover policy rule
 * and collect them into batch_out.
 *
 * Only considers entries with CE_UPDATE flag (checkout candidates) that
 * are regular files.  Evaluates the preflight policy for each candidate;
 * items whose matched rule action is takeover are added to the batch.
 *
 * batch_out must be zero-initialized by the caller.
 * On return, batch_out->items is heap-allocated (caller must free).
 * Always call textil_ext_takeover_batch_release() + free(items) after use.
 */
void textil_ext_collect_preflight_takeover_batch(
	const struct index_state *index,
	const char *operation,
	const char *repo_root,
	struct textil_ext_takeover_batch *batch_out);

#endif /* TEXTIL_EXT_EXECUTOR_H */
