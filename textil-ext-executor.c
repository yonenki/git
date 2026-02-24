#include "git-compat-util.h"
#include "textil-ext-executor.h"
#include "textil-ext-policy.h"
#include "gettext.h"
#include "pkt-line.h"
#include "strbuf.h"
#include "read-cache-ll.h"
#include "convert.h"
#include "alloc.h"

#ifdef SUPPORTS_SIMPLE_IPC
#include "simple-ipc.h"
#endif

/* --- Env helper --------------------------------------------------------- */

static const char *endpoint_from_env(struct strbuf *err)
{
	const char *ep = getenv(TEXTIL_GIT_EXT_ENDPOINT);

	if (!ep || !*ep) {
		strbuf_addstr(err,
			_("textil-ext: TEXTIL_GIT_EXT_ENDPOINT is not set; "
			  "cannot dispatch takeover batch"));
		return NULL;
	}
	return ep;
}

/* --- pkt-line request builder ------------------------------------------- */

static const char *phase_to_string(enum textil_ext_executor_phase phase)
{
	switch (phase) {
	case TEXTIL_EXT_EXEC_PHASE_PREFLIGHT:
		return "preflight";
	}
	BUG("unknown executor phase: %d", (int)phase);
}

/*
 * Validate a request value for pkt-line emission.
 *
 * Rejects control characters (0x00-0x1F, 0x7F) to prevent
 * pkt-line protocol confusion (LF injection, NUL truncation).
 * Returns 0 on success, -1 if the value contains a control character.
 * On failure, appends a diagnostic to err.
 */
static int validate_request_value(const char *key, const char *value,
				  struct strbuf *err)
{
	const unsigned char *p;

	if (!value)
		BUG("validate_request_value called with NULL value for key '%s'", key);

	for (p = (const unsigned char *)value; *p; p++) {
		if (*p < 0x20 || *p == 0x7F) {
			strbuf_addf(err,
				_("textil-ext: request value for '%s' contains "
				  "control character 0x%02x at byte %lu"),
				key, (unsigned)*p,
				(unsigned long)(p - (const unsigned char *)value));
			return -1;
		}
	}
	return 0;
}

/*
 * Build a pkt-line v1 preflight_batch request.
 *
 * All string values are validated for control characters before emission.
 * Returns 0 on success, -1 on validation error (message appended to err).
 *
 * Format:
 *   <pkt> version=1
 *   <pkt> command=preflight_batch
 *   <pkt> phase=<phase>
 *   <pkt> operation=<operation>
 *   <pkt> repo_root=<path>          (optional, omitted when NULL)
 *   <delim>                         (start first item)
 *   <pkt> path=<path>
 *   <pkt> rule_id=<id>
 *   <pkt> attr_filter=<value>       (optional)
 *   <pkt> is_regular_file=true|false
 *   <pkt> strict=true|false
 *   <pkt> capability=<cap>          (repeated for each capability)
 *   <delim>                         (start next item, if any)
 *   ...
 *   <flush>
 */
static int build_preflight_request(
	const struct textil_ext_takeover_batch *batch,
	struct strbuf *out,
	struct strbuf *err)
{
	int i, j;

	/* Validate header values */
	if (validate_request_value("operation", batch->operation, err))
		return -1;
	if (batch->repo_root &&
	    validate_request_value("repo_root", batch->repo_root, err))
		return -1;

	/* Header fields */
	packet_buf_write(out, "version=1\n");
	packet_buf_write(out, "command=preflight_batch\n");
	packet_buf_write(out, "phase=%s\n", phase_to_string(batch->phase));
	packet_buf_write(out, "operation=%s\n", batch->operation);
	if (batch->repo_root)
		packet_buf_write(out, "repo_root=%s\n", batch->repo_root);

	/* Items (delim-separated) */
	for (i = 0; i < batch->nr_items; i++) {
		const struct textil_ext_takeover_item *item = &batch->items[i];

		/* Validate item values before emission */
		if (validate_request_value("path", item->path, err))
			return -1;
		if (validate_request_value("rule_id", item->rule_id, err))
			return -1;
		if (item->attr_filter &&
		    validate_request_value("attr_filter", item->attr_filter, err))
			return -1;
		for (j = 0; j < item->nr_capabilities; j++) {
			if (validate_request_value("capability",
						   item->capabilities[j], err))
				return -1;
		}

		packet_buf_delim(out);
		packet_buf_write(out, "path=%s\n", item->path);
		packet_buf_write(out, "rule_id=%s\n", item->rule_id);
		if (item->attr_filter)
			packet_buf_write(out, "attr_filter=%s\n",
					 item->attr_filter);
		packet_buf_write(out, "is_regular_file=%s\n",
				 item->is_regular_file ? "true" : "false");
		packet_buf_write(out, "strict=%s\n",
				 item->strict ? "true" : "false");
		for (j = 0; j < item->nr_capabilities; j++)
			packet_buf_write(out, "capability=%s\n",
					 item->capabilities[j]);
	}

	packet_buf_flush(out);
	return 0;
}

/* --- pkt-line reply parser ---------------------------------------------- */

/*
 * Size / length limits for executor reply parsing.
 *
 * TEXTIL_EXT_MAX_REPLY_SIZE (64 KiB):
 *   Maximum raw byte length of an IPC reply.  The reply is a small
 *   pkt-line stream (status + optional message + flush) so 64 KiB is
 *   vastly generous.  Rejects oversized payloads before any parsing
 *   to prevent DoS.
 *
 * TEXTIL_EXT_MAX_MESSAGE_LEN (4096 = 4 KiB):
 *   Maximum length of the "message" value.  Messages are
 *   human-readable error descriptions.  4 KiB is sufficient.
 */
#define TEXTIL_EXT_MAX_REPLY_SIZE  (64 * 1024)
#define TEXTIL_EXT_MAX_MESSAGE_LEN 4096

/*
 * In-memory pkt-line reader.
 *
 * Git's packet_read_with_status() can die() on malformed input,
 * even with PACKET_READ_GENTLE_ON_READ_ERROR for certain conditions
 * (e.g. bad hex chars, length 1-3).  Since the executor must NOT die
 * on malformed replies, we parse pkt-lines ourselves from the
 * in-memory IPC response buffer.
 */
enum pktline_mem_status {
	PKTLINE_MEM_DATA,
	PKTLINE_MEM_FLUSH,
	PKTLINE_MEM_DELIM,
	PKTLINE_MEM_ERROR,
};

static int hexval_safe(unsigned char c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

static enum pktline_mem_status pktline_read_mem(
	const char *buf, size_t total, size_t *pos,
	const char **out_line, size_t *out_len)
{
	int pkt_len = 0;
	size_t data_len;
	int i;

	if (*pos + 4 > total)
		return PKTLINE_MEM_ERROR;

	for (i = 0; i < 4; i++) {
		int v = hexval_safe((unsigned char)buf[*pos + i]);
		if (v < 0)
			return PKTLINE_MEM_ERROR;
		pkt_len = (pkt_len << 4) | v;
	}

	if (pkt_len == 0) {
		*pos += 4;
		return PKTLINE_MEM_FLUSH;
	}
	if (pkt_len == 1) {
		*pos += 4;
		return PKTLINE_MEM_DELIM;
	}
	if (pkt_len < 4)
		return PKTLINE_MEM_ERROR;

	data_len = (size_t)(pkt_len - 4);
	if (*pos + 4 + data_len > total)
		return PKTLINE_MEM_ERROR;

	*out_line = buf + *pos + 4;
	*out_len = data_len;
	*pos += 4 + data_len;

	/* Chomp trailing LF */
	if (*out_len > 0 && (*out_line)[*out_len - 1] == '\n')
		(*out_len)--;

	return PKTLINE_MEM_DATA;
}

/*
 * Parse a pkt-line v1 executor response.
 *
 * Expected format:
 *   <pkt> status=ok|rejected|error
 *   <pkt> message=<text>           (required when status != ok)
 *   <flush>
 *
 * Key order is independent.  Unknown keys, duplicate keys, and
 * trailing data after the flush packet are rejected.
 * Control characters (< 0x20, except TAB) in values are rejected.
 *
 * Returns 0 on success, -1 on parse error.
 */
static int parse_executor_response(const char *buf, size_t len,
				   struct strbuf *status_out,
				   struct strbuf *msg_out)
{
	size_t pos = 0;
	int has_status = 0, has_message = 0;

	for (;;) {
		const char *line;
		size_t line_len;
		enum pktline_mem_status st;
		const char *eq;
		size_t key_len, val_len;
		const char *val;
		size_t k;

		st = pktline_read_mem(buf, len, &pos, &line, &line_len);

		if (st == PKTLINE_MEM_ERROR)
			return -1;
		if (st == PKTLINE_MEM_FLUSH)
			break;
		if (st == PKTLINE_MEM_DELIM)
			return -1; /* unexpected delim in reply */

		/* PKTLINE_MEM_DATA: parse key=value */
		eq = memchr(line, '=', line_len);
		if (!eq)
			return -1;

		key_len = (size_t)(eq - line);
		val = eq + 1;
		val_len = line_len - key_len - 1;

		/* Reject control characters (< 0x20) in value, except TAB */
		for (k = 0; k < val_len; k++) {
			if ((unsigned char)val[k] < 0x20 && val[k] != '\t')
				return -1;
		}

		if (key_len == 6 && !memcmp(line, "status", 6)) {
			if (has_status)
				return -1; /* duplicate */
			strbuf_add(status_out, val, val_len);
			has_status = 1;
		} else if (key_len == 7 && !memcmp(line, "message", 7)) {
			if (has_message)
				return -1; /* duplicate */
			if (val_len > TEXTIL_EXT_MAX_MESSAGE_LEN)
				return -1;
			strbuf_add(msg_out, val, val_len);
			has_message = 1;
		} else {
			return -1; /* unknown key */
		}
	}

	/* Reject trailing data after flush */
	if (pos < len)
		return -1;

	/* status is always required */
	if (!has_status)
		return -1;

	/* Validate status value */
	if (strcmp(status_out->buf, "ok") &&
	    strcmp(status_out->buf, "rejected") &&
	    strcmp(status_out->buf, "error"))
		return -1;

	/* message is required when status != ok */
	if (strcmp(status_out->buf, "ok") && !has_message)
		return -1;

	return 0;
}

/* --- Preflight collection ----------------------------------------------- */

void textil_ext_collect_preflight_takeover_batch(
	const struct index_state *index,
	const char *operation,
	const char *repo_root,
	struct textil_ext_takeover_batch *batch_out)
{
	int i;
	int alloc = 0;

	memset(batch_out, 0, sizeof(*batch_out));
	batch_out->phase = TEXTIL_EXT_EXEC_PHASE_PREFLIGHT;
	batch_out->operation = operation;
	batch_out->repo_root = repo_root;

	for (i = 0; i < index->cache_nr; i++) {
		const struct cache_entry *ce = index->cache[i];
		struct conv_attrs ca;
		struct textil_ext_eval_result ext_result;
		const char *filter_name;
		struct textil_ext_takeover_item *item;

		if (!(ce->ce_flags & CE_UPDATE))
			continue;
		if (!S_ISREG(ce->ce_mode))
			continue;

		convert_attrs(index, &ca, ce->name);
		filter_name = conv_attrs_filter_name(&ca);
		textil_ext_evaluate_for_preflight(
			filter_name, 1, &ext_result);

		if (!ext_result.matched ||
		    ext_result.action != TEXTIL_ACTION_TAKEOVER)
			continue;

		ALLOC_GROW(batch_out->items,
			   batch_out->nr_items + 1, alloc);
		item = &batch_out->items[batch_out->nr_items++];
		item->path = xstrdup(ce->name);
		item->rule_id = ext_result.rule_id;
		item->attr_filter = filter_name ?
			xstrdup(filter_name) : NULL;
		item->is_regular_file = 1;
		item->strict = ext_result.strict;
		item->capabilities = ext_result.capabilities;
		item->nr_capabilities = ext_result.nr_capabilities;
	}
}

/* --- Executor ----------------------------------------------------------- */

enum textil_ext_executor_status textil_ext_execute_takeover_batch(
	const struct textil_ext_takeover_batch *batch,
	struct strbuf *err)
{
#ifndef SUPPORTS_SIMPLE_IPC
	if (!batch || !batch->items || batch->nr_items <= 0)
		BUG("execute_takeover_batch called with invalid batch");
	if (!err)
		BUG("execute_takeover_batch called with NULL err");

	strbuf_addstr(err,
		_("textil-ext: simple-ipc not available on this platform"));
	return TEXTIL_EXT_EXECUTOR_ERROR;
#else
	const char *endpoint;
	struct strbuf request = STRBUF_INIT;
	struct strbuf answer = STRBUF_INIT;
	struct strbuf status_str = STRBUF_INIT;
	struct strbuf msg = STRBUF_INIT;
	struct ipc_client_connect_options options
		= IPC_CLIENT_CONNECT_OPTIONS_INIT;
	int ipc_ret;
	enum textil_ext_executor_status status;

	if (!batch || !batch->items || batch->nr_items <= 0)
		BUG("execute_takeover_batch called with invalid batch");
	if (!err)
		BUG("execute_takeover_batch called with NULL err");

	/* 1. Resolve endpoint */
	endpoint = endpoint_from_env(err);
	if (!endpoint) {
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 2. Build pkt-line request (validates values before emission) */
	if (build_preflight_request(batch, &request, err)) {
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 3. Send via simple-ipc */
	options.wait_if_busy = 1;
	options.wait_if_not_found = 0;

	ipc_ret = ipc_client_send_command(endpoint, &options,
					  request.buf, request.len,
					  &answer);
	if (ipc_ret) {
		strbuf_addf(err,
			_("textil-ext: failed to connect to endpoint '%s'"),
			endpoint);
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 4. Size guard: reject oversized replies before parsing */
	if (answer.len > TEXTIL_EXT_MAX_REPLY_SIZE) {
		strbuf_addf(err,
			_("textil-ext: reply too large (%lu bytes, max %d) "
			  "from endpoint '%s'"),
			(unsigned long)answer.len,
			TEXTIL_EXT_MAX_REPLY_SIZE, endpoint);
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 5. Parse pkt-line response */
	if (parse_executor_response(answer.buf, answer.len,
				    &status_str, &msg)) {
		strbuf_addf(err,
			_("textil-ext: invalid response from endpoint '%s'"),
			endpoint);
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 6. Map status */
	if (!strcmp(status_str.buf, "ok")) {
		status = TEXTIL_EXT_EXECUTOR_OK;
		goto done;
	}

	if (!strcmp(status_str.buf, "rejected")) {
		strbuf_addf(err,
			_("textil-ext: takeover rejected: %s"),
			msg.len ? msg.buf : "(no message)");
		status = TEXTIL_EXT_EXECUTOR_REJECTED;
	} else {
		strbuf_addf(err,
			_("textil-ext: takeover error: %s"),
			msg.len ? msg.buf : "(no message)");
		status = TEXTIL_EXT_EXECUTOR_ERROR;
	}

done:
	strbuf_release(&request);
	strbuf_release(&answer);
	strbuf_release(&status_str);
	strbuf_release(&msg);
	return status;
#endif /* SUPPORTS_SIMPLE_IPC */
}

void textil_ext_takeover_batch_release(struct textil_ext_takeover_batch *batch)
{
	int i;

	if (!batch || !batch->items)
		return;

	for (i = 0; i < batch->nr_items; i++) {
		free(batch->items[i].path);
		free(batch->items[i].attr_filter);
	}
}
