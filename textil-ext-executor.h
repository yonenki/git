#ifndef TEXTIL_EXT_EXECUTOR_H
#define TEXTIL_EXT_EXECUTOR_H

#include "strbuf.h"
#include "string-list.h"

/*
 * Textil Git Extension Controller Client
 *
 * Phase1-7: batch payload contract.
 * Phase1-8a: IPC transport via Git's simple-ipc API.
 * Phase1-8c: pkt-line v1 payload (replaced JSON).
 *
 * The executor receives a batch of takeover candidates collected during
 * preflight, encodes them as pkt-line v1, and sends them to the Textil
 * backend controller via simple-ipc.
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
	TEXTIL_EXT_EXEC_PHASE_MATERIALIZE = 1,
	TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT = 2,
};

enum textil_ext_checkout_admission {
	TEXTIL_EXT_CHECKOUT_MATERIALIZE = 0,
	TEXTIL_EXT_CHECKOUT_VERIFIED_TWO_TREE,
	TEXTIL_EXT_CHECKOUT_VERIFIED_INITIAL_ABSENCE,
};

/* --- Takeover item (single candidate) ----------------------------------- */

/*
 * Ownership / lifetime:
 *   path         - caller-owned copy (xstrdup).  Freed by release helper.
 *   attr_filter  - caller-owned copy (xstrdup).  Freed by release helper.
 *                  May be NULL if no gitattributes filter.
 *   blob_oid     - caller-owned copy (xstrdup).  Freed by release helper.
 *                  Hex representation of the blob object id (ce->oid).
 *                  Required for preflight/materialize; NULL for checkin_convert.
 *   input_path   - caller-owned copy (xstrdup).  Freed by release helper.
 *                  Absolute path to working tree file content.
 *                  Required for checkin_convert; NULL for preflight/materialize.
 *   rule_id      - borrowed pointer into policy structs (valid for
 *                  process lifetime once policy is loaded).
 *   capabilities - borrowed pointer into policy structs (same lifetime).
 */
struct textil_ext_takeover_item {
	char *path;                  /* repo-relative path (owned, xstrdup) */
	const char *rule_id;         /* matched rule id (borrowed) */
	char *attr_filter;           /* selector input (owned, xstrdup; NULL ok) */
	char *blob_oid;              /* blob object id hex (owned, xstrdup; NULL for checkin_convert) */
	char *old_blob_oid;          /* preflight predecessor (owned); NULL for target-only paths */
	char *input_path;            /* abs path to input file (owned, xstrdup; NULL for preflight/materialize) */
	int is_regular_file;         /* 0/1 */
	int strict;                  /* rule.strict */
	const char * const *capabilities; /* required_capabilities (borrowed) */
	int nr_capabilities;
	int projected;              /* preflight disposition; suppress checkout payload */
	enum textil_ext_checkout_admission checkout_admission;
	struct cache_entry *checkout_entry; /* borrowed checkout candidate, collection only */
};

/* --- Takeover batch (executor input) ------------------------------------ */

struct textil_ext_takeover_batch {
	enum textil_ext_executor_phase phase; /* PREFLIGHT, MATERIALIZE, or CHECKIN_CONVERT */
	const char *operation;       /* e.g. "checkout" (string literal) */
	const char *repo_root;       /* worktree root; NULL for bare repos */
	struct textil_ext_takeover_item *items; /* array of candidates */
	int nr_items;                /* must be > 0 when calling executor */
	/*
	 * checkin_convert only: the controller seals objects without making
	 * them durable; their OIDs are fenced before the ODB transaction
	 * commits, i.e. before Git can reference the returned pointers.
	 */
	int deferred_durability;
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
 * Execute a preflight takeover batch (preflight phase only).
 *
 * The executor does NOT die() on runtime failure; the caller is
 * responsible for fail-fast control.  However, calling with a
 * non-preflight phase is a programming error and triggers BUG().
 *
 * Returns TEXTIL_EXT_EXECUTOR_OK on success.
 * On failure, returns a non-OK status and appends a message to err.
 *
 * Preconditions:
 *   - batch->phase == TEXTIL_EXT_EXEC_PHASE_PREFLIGHT (BUG otherwise)
 *   - batch->nr_items > 0
 *
 * For materialize, use textil_ext_resolve_materialize_batch() instead.
 */
enum textil_ext_executor_status textil_ext_execute_takeover_batch(
	struct textil_ext_takeover_batch *batch,
	struct strbuf *err);

struct textil_ext_eval_result; /* forward declaration (textil-ext-policy.h) */
struct object_id; /* forward declaration (hash.h) */
struct strbuf; /* forward declaration */

/*
 * Ordered materialize resolution result.
 *
 * `src_paths` is owned by the result object and preserves the same order as
 * the batch items that were sent to the backend. The executor validates that
 * the reply count matches the batch count before returning OK.
 *
 * Lifetime:
 *   - initialize with textil_ext_materialize_batch_result_init()
 *   - release with textil_ext_materialize_batch_result_release()
 */
struct textil_ext_materialize_batch_result {
	struct string_list src_paths;
};

void textil_ext_materialize_batch_result_init(
	struct textil_ext_materialize_batch_result *result);
void textil_ext_materialize_batch_result_release(
	struct textil_ext_materialize_batch_result *result);

/*
 * Resolve materialize src_paths for a batch.
 *
 * This is the primary hot-path materialize executor API. It sends one batch
 * request over IPC, parses one ordered batch reply, and returns one src_path
 * per batch item in the same order as the request.
 *
 * Preconditions:
 *   - batch->phase == TEXTIL_EXT_EXEC_PHASE_MATERIALIZE
 *   - batch->nr_items > 0
 *   - result_out is initialized with
 *     textil_ext_materialize_batch_result_init()
 */
enum textil_ext_executor_status textil_ext_resolve_materialize_batch(
	const struct textil_ext_takeover_batch *batch,
	struct textil_ext_materialize_batch_result *result_out,
	struct strbuf *err);

/*
 * Compatibility helper retained for downstream checkout callers that have not
 * migrated to generic takeover handling yet.
 *
 * This helper is not used by preflight collection or the executor's generic
 * production flow in this file.
 *
 * Returns 0 on success and sets *is_pointer to 1 or 0.
 * Returns -1 on object read/type failure and appends a diagnostic to err.
 */
int textil_ext_blob_oid_is_lfs_pointer(
	const struct object_id *oid,
	int *is_pointer,
	struct strbuf *err);

/*
 * High-level helper: resolve and copy a single file to an open fd.
 *
 * Builds a 1-item materialize batch from the eval_result and file metadata,
 * calls the batch-first materialize resolution API, opens the returned
 * src_path, and copies content to out_fd via copy_fd().
 * All internal resources (batch, string_list, strbuf) are cleaned up.
 *
 * Returns 0 on success, -1 on any failure (error() already emitted).
 * The caller retains ownership of out_fd (not closed by this function).
 */
int textil_ext_materialize_one_to_fd(
	const char *ce_name,
	const struct object_id *ce_oid,
	const char *attr_filter,
	const struct textil_ext_eval_result *eval_result,
	const char *repo_root,
	int out_fd,
	struct strbuf *err);

/*
 * Execute a checkin_convert takeover batch and return validated hex pointers.
 *
 * The backend reads the input file (item->input_path) and returns exact
 * pointer bytes inline; no backend output file is created.
 *
 * Preconditions:
 *   - batch->phase == TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT
 *   - batch->nr_items > 0
 *   - pointers_out is initialized
 */
enum textil_ext_executor_status textil_ext_execute_checkin_convert_batch(
	const struct textil_ext_takeover_batch *batch,
	struct string_list *pointers_out,
	struct string_list *fence_oids_out,
	struct strbuf *err);

/*
 * Make every object sealed by deferred checkin conversions durable.
 * Called before an ODB transaction commits, so before Git publishes the
 * returned pointers through the index or any tree. No-op when nothing
 * is pending. Returns 0 on success, -1 with err filled on failure.
 */
int textil_ext_flush_deferred_durability(struct strbuf *err);

/*
 * High-level helper: checkin_convert a single file to a strbuf.
 *
 * Writes the working tree file to a temp file, builds a 1-item
 * checkin_convert batch, calls the executor, and decodes the returned
 * inline pointer into dst.
 *
 * Returns 0 on success, -1 on any failure (error() already emitted).
 */
int textil_ext_checkin_convert_one_to_buf(
	const char *path,
	const char *src, size_t src_len,
	const char *attr_filter,
	const struct textil_ext_eval_result *eval_result,
	const char *repo_root,
	struct strbuf *dst,
	struct strbuf *err);

/*
 * High-level helper: checkin_convert from an fd to a strbuf.
 *
 * When input_path names the file backing fd, passes that absolute path
 * directly to the backend. Otherwise streams fd to a temp file. Builds a
 * 1-item checkin_convert batch, calls the executor, and decodes the returned
 * inline pointer into dst.
 *
 * Returns 0 on success, -1 on any failure (error() already emitted).
 */
int textil_ext_checkin_convert_fd_to_buf(
	const char *path,
	int input_fd,
	const char *input_path,
	const char *attr_filter,
	const struct textil_ext_eval_result *eval_result,
	const char *repo_root,
	struct strbuf *dst,
	struct strbuf *err);

/*
 * Resolve the main (non-linked) worktree path.
 *
 * For linked worktrees, the_repository->worktree points to the linked
 * directory which lacks .textil/ config.  This function resolves the
 * main worktree from the_repository->commondir (the shared .git dir).
 *
 * Requires USE_THE_REPOSITORY_VARIABLE.  Caller must release the strbuf.
 */
void textil_ext_resolve_worktree_root(struct strbuf *out);

/*
 * Release owned fields (path, attr_filter, blob_oid, input_path) in each
 * item of the batch.  Does NOT free the items array itself or the batch
 * struct.  Safe to call with nr_items == 0 or items == NULL.
 */
void textil_ext_takeover_batch_release(struct textil_ext_takeover_batch *batch);

/* --- Materialize pre-resolution cache ----------------------------------- */

/*
 * Batch-first materialize cache.
 *
 * Pre-resolves all materialize src_paths in a single IPC roundtrip before
 * the per-file checkout loop. entry.c looks up pre-resolved paths here
 * instead of issuing per-file IPC.
 *
 * Lifecycle: create after preflight, populate with preresolve, lookup during
 * checkout, destroy after the checkout wave completes.
 */

/*
 * Populate the global materialize cache from a preflight batch.
 *
 * Builds a materialize-phase batch from the same items used for preflight,
 * resolves all src_paths in one IPC call, and stores them keyed by
 * "path\0oid" for O(1) lookup during sequential checkout.
 *
 * Returns 0 on success. On failure, returns -1 and appends to err.
 * If the cache is already populated, this is a no-op (returns 0).
 */
int textil_ext_preresolve_materialize_cache(
	const struct textil_ext_takeover_batch *preflight_batch,
	struct strbuf *err);

/* Look up a canonical source. The returned path is owned by the cache. */
const char *textil_ext_materialize_cache_lookup(
	const char *path, const char *blob_oid_hex);

/*
 * Release all resources held by the global materialize cache.
 * Safe to call when the cache is empty or not populated.
 */
void textil_ext_materialize_cache_clear(void);

/* --- Preflight collection ----------------------------------------------- */

struct index_state; /* forward declaration */

/*
 * Scan the index for checkout candidates matching a takeover policy rule and
 * collect them into batch_out.
 *
 * Only considers entries with CE_UPDATE flag (checkout candidates) that
 * are regular files. Evaluates the preflight policy for each candidate; items
 * whose matched rule action is takeover are added to the batch in index order.
 *
 * batch_out must be zero-initialized by the caller.
 * On return, batch_out->items is heap-allocated (caller must free).
 * Always call textil_ext_takeover_batch_release() + free(items) after use.
 * Returns -1 on an initial-absence metadata error (message appended to err).
 */
struct unpack_trees_options;
int textil_ext_collect_preflight_takeover_batch(
	struct index_state *index,
	const struct unpack_trees_options *options,
	const char *operation,
	const char *repo_root,
	struct textil_ext_takeover_batch *batch_out,
	struct strbuf *err);

void textil_ext_collect_materialize_takeover_batch(
	struct index_state *index,
	const char *operation,
	const char *repo_root,
	struct textil_ext_takeover_batch *batch_out);

#endif /* TEXTIL_EXT_EXECUTOR_H */
