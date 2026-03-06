#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "textil-ext-executor.h"
#include "textil-ext-policy.h"
#include "gettext.h"
#include "pkt-line.h"
#include "strbuf.h"
#include "string-list.h"
#include "read-cache-ll.h"
#include "repository.h"
#include "convert.h"
#include "alloc.h"
#include "copy.h"
#include "hex.h"
#include "abspath.h"
#include "odb.h"

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
	case TEXTIL_EXT_EXEC_PHASE_MATERIALIZE:
		return "materialize";
	case TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT:
		return "checkin_convert";
	}
	BUG("unknown executor phase: %d", (int)phase);
}

/*
 * Validate a request value for pkt-line emission.
 *
 * Rejects characters that would break pkt-line framing or cause
 * protocol confusion: NUL (truncation), LF (line injection),
 * CR (line injection), and DEL (0x7F).
 * TAB and other control characters are permitted for Git path
 * compatibility (Git allows TAB in filenames).
 *
 * Returns 0 on success, -1 if the value contains a forbidden character.
 * On failure, appends a diagnostic to err.
 */
static int validate_request_value(const char *key, const char *value,
				  struct strbuf *err)
{
	const unsigned char *p;

	if (!value)
		BUG("validate_request_value called with NULL value for key '%s'", key);

	for (p = (const unsigned char *)value; *p; p++) {
		if (*p == '\n' || *p == '\r' || *p == 0x7F) {
			strbuf_addf(err,
				_("textil-ext: request value for '%s' contains "
				  "forbidden character 0x%02x at byte %lu"),
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
static const char *command_for_phase(enum textil_ext_executor_phase phase)
{
	switch (phase) {
	case TEXTIL_EXT_EXEC_PHASE_PREFLIGHT:
		return "preflight_batch";
	case TEXTIL_EXT_EXEC_PHASE_MATERIALIZE:
		return "materialize_batch";
	case TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT:
		return "checkin_convert_batch";
	}
	BUG("unknown executor phase for command: %d", (int)phase);
}

static int build_batch_request(
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
	packet_buf_write(out, "command=%s\n", command_for_phase(batch->phase));
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
		/*
		 * Phase-specific required fields:
		 *   preflight/materialize: blob_oid required, input_path absent
		 *   checkin_convert: input_path required, blob_oid absent
		 */
		if (batch->phase == TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT) {
			if (!item->input_path)
				BUG("checkin_convert item missing input_path");
			if (validate_request_value("input_path",
						   item->input_path, err))
				return -1;
		} else {
			if (!item->blob_oid)
				BUG("preflight/materialize item missing blob_oid");
			if (validate_request_value("blob_oid",
						   item->blob_oid, err))
				return -1;
		}
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
		if (batch->phase == TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT)
			packet_buf_write(out, "input_path=%s\n",
					 item->input_path);
		else
			packet_buf_write(out, "blob_oid=%s\n", item->blob_oid);
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
#define TEXTIL_EXT_MAX_SRC_PATH_LEN 4096

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
 * Validate a src_path value from a materialize response.
 *
 * Rules:
 * - Must be an absolute path (starts with '/' or Windows drive letter)
 * - Must not contain forbidden characters: NUL (implicit), LF, CR, DEL (0x7F)
 * - Must not exceed TEXTIL_EXT_MAX_SRC_PATH_LEN
 *
 * Returns 0 on success, -1 on validation failure.
 */
static int validate_src_path(const char *path, size_t path_len)
{
	size_t k;

	if (!path_len)
		return -1;
	if (path_len > TEXTIL_EXT_MAX_SRC_PATH_LEN)
		return -1;

	/* Must be absolute: starts with '/' or drive letter (e.g. C:\) */
	if (path[0] != '/' &&
	    !(path_len >= 3 &&
	      ((path[0] >= 'A' && path[0] <= 'Z') ||
	       (path[0] >= 'a' && path[0] <= 'z')) &&
	      path[1] == ':' && (path[2] == '\\' || path[2] == '/')))
		return -1;

	/* Forbidden characters: LF, CR, DEL */
	for (k = 0; k < path_len; k++) {
		unsigned char c = (unsigned char)path[k];
		if (c == '\n' || c == '\r' || c == 0x7F)
			return -1;
	}

	return 0;
}

/*
 * Parse a pkt-line v1 executor response.
 *
 * Preflight format:
 *   <pkt> status=ok|rejected|error
 *   <pkt> message=<text>           (required when status != ok)
 *   <flush>
 *
 * Materialize format (when src_paths_out is non-NULL):
 *   <pkt> status=ok
 *   <delim>
 *   <pkt> src_path=<abs_path>
 *   <delim>
 *   <pkt> src_path=<abs_path>
 *   ...
 *   <flush>
 *
 *   OR (status != ok):
 *   <pkt> status=rejected|error
 *   <pkt> message=<text>
 *   <flush>
 *
 * When src_paths_out is NULL, delim packets and src_path keys are rejected
 * (preflight mode).  When src_paths_out is non-NULL, delim packets are
 * allowed after status=ok to introduce src_path items.  src_path is
 * forbidden when status != ok.
 *
 * Key order within a section is independent.  Unknown keys, duplicate
 * keys (within a section), and trailing data after flush are rejected.
 * Control characters (< 0x20, except TAB) in values are rejected.
 *
 * Returns 0 on success, -1 on parse error.
 */
static int parse_executor_response(const char *buf, size_t len,
				   struct strbuf *status_out,
				   struct strbuf *msg_out,
				   struct string_list *src_paths_out)
{
	size_t pos = 0;
	int has_status = 0, has_message = 0;
	int in_src_path_section = 0;

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
		if (st == PKTLINE_MEM_DELIM) {
			/*
			 * Delim is only valid in materialize mode
			 * (src_paths_out != NULL) after seeing status=ok.
			 */
			if (!src_paths_out || !has_status)
				return -1;
			if (strcmp(status_out->buf, "ok"))
				return -1; /* delim not allowed for non-ok */
			in_src_path_section = 1;
			continue;
		}

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

		if (in_src_path_section) {
			/* In src_path section: only src_path key is allowed */
			if (key_len == 8 && !memcmp(line, "src_path", 8)) {
				struct strbuf path_buf = STRBUF_INIT;
				if (validate_src_path(val, val_len))
					return -1;
				strbuf_add(&path_buf, val, val_len);
				string_list_append(src_paths_out, path_buf.buf);
				strbuf_release(&path_buf);
			} else {
				return -1; /* unknown key in src_path section */
			}
		} else if (key_len == 6 && !memcmp(line, "status", 6)) {
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

	/* src_path is forbidden when status != ok */
	if (src_paths_out && src_paths_out->nr > 0 &&
	    strcmp(status_out->buf, "ok"))
		return -1;

	/* materialize ok requires at least one src_path */
	if (src_paths_out && !strcmp(status_out->buf, "ok") &&
	    src_paths_out->nr == 0)
		return -1;

	/* materialize ok forbids message (only delim+src_path allowed) */
	if (src_paths_out && !strcmp(status_out->buf, "ok") && has_message)
		return -1;

	return 0;
}

/* --- Preflight collection ----------------------------------------------- */

#define TEXTIL_EXT_MAX_POINTER_BLOB_SIZE 8192

static const char lfs_pointer_version_line[] =
	"version https://git-lfs.github.com/spec/v1";

static int is_ascii_hex_n(const char *s, size_t len)
{
	size_t i;

	for (i = 0; i < len; i++) {
		if (!isxdigit((unsigned char)s[i]))
			return 0;
	}
	return 1;
}

static const char *trim_ascii_space(const char *start, const char *end,
				    const char **trimmed_end)
{
	while (start < end && (*start == ' ' || *start == '\t'))
		start++;
	while (end > start && (end[-1] == ' ' || end[-1] == '\t'))
		end--;
	*trimmed_end = end;
	return start;
}

static int blob_content_is_lfs_pointer(const char *buf, size_t len)
{
	const char *p = buf;
	const char *end = buf + len;
	int has_version = 0, has_oid = 0;

	while (p < end) {
		const char *line_end = memchr(p, '\n', end - p);
		const char *trimmed_end;
		const char *line;
		size_t line_len;

		if (!line_end)
			line_end = end;

		line = trim_ascii_space(p, line_end, &trimmed_end);
		line_len = trimmed_end - line;

		if (!line_len) {
			p = (line_end < end) ? line_end + 1 : end;
			continue;
		}

		if (line_len == strlen(lfs_pointer_version_line) &&
		    !memcmp(line, lfs_pointer_version_line, line_len)) {
			has_version = 1;
		} else if (line_len > strlen("oid sha256:") &&
			   !memcmp(line, "oid sha256:", strlen("oid sha256:"))) {
			const char *oid = line + strlen("oid sha256:");
			size_t oid_len = trimmed_end - oid;

			if (oid_len != 64 || !is_ascii_hex_n(oid, oid_len))
				return 0;
			has_oid = 1;
		} else if (line_len > strlen("size ") &&
			   !memcmp(line, "size ", strlen("size "))) {
			const char *size_val = line + strlen("size ");
			size_t i;

			for (i = 0; size_val + i < trimmed_end; i++) {
				if (!isdigit(size_val[i]))
					return 0;
			}
		} else {
			return 0;
		}

		p = (line_end < end) ? line_end + 1 : end;
	}

	return has_version && has_oid;
}

int textil_ext_blob_oid_is_lfs_pointer(
	const struct object_id *oid,
	int *is_pointer,
	struct strbuf *err)
{
	enum object_type type;
	unsigned long size;
	void *blob;

	if (!oid || !is_pointer || !err)
		BUG("textil_ext_blob_oid_is_lfs_pointer called with NULL argument");

	blob = odb_read_object(the_repository->objects, oid, &type, &size);
	if (!blob) {
		strbuf_addf(err,
			    _("textil-ext: failed to read blob '%s'"),
			    oid_to_hex(oid));
		return -1;
	}
	if (type != OBJ_BLOB) {
		free(blob);
		strbuf_addf(err,
			    _("textil-ext: object '%s' is not a blob"),
			    oid_to_hex(oid));
		return -1;
	}

	if (size > TEXTIL_EXT_MAX_POINTER_BLOB_SIZE) {
		free(blob);
		*is_pointer = 0;
		return 0;
	}

	*is_pointer = blob_content_is_lfs_pointer(blob, size);
	free(blob);
	return 0;
}

void textil_ext_collect_preflight_takeover_batch(
	struct index_state *index,
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
		struct strbuf pointer_err = STRBUF_INIT;
		int is_pointer = 0;

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

		if (textil_ext_blob_oid_is_lfs_pointer(&ce->oid, &is_pointer,
						       &pointer_err))
			die("%s", pointer_err.buf);
		strbuf_release(&pointer_err);
		if (!is_pointer)
			continue;

		ALLOC_GROW(batch_out->items,
			   batch_out->nr_items + 1, alloc);
		item = &batch_out->items[batch_out->nr_items++];
		memset(item, 0, sizeof(*item));
		item->path = xstrdup(ce->name);
		item->rule_id = ext_result.rule_id;
		item->attr_filter = filter_name ?
			xstrdup(filter_name) : NULL;
		item->blob_oid = xstrdup(oid_to_hex(&ce->oid));
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
	/* Preconditions (common, evaluated before #ifdef split) */
	if (!batch || !batch->items || batch->nr_items <= 0)
		BUG("execute_takeover_batch called with invalid batch");
	if (batch->phase != TEXTIL_EXT_EXEC_PHASE_PREFLIGHT)
		BUG("execute_takeover_batch called with non-preflight phase (phase=%d)",
		    batch->phase);
	if (!err)
		BUG("execute_takeover_batch called with NULL err");

#ifndef SUPPORTS_SIMPLE_IPC
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

	/* 1. Resolve endpoint */
	endpoint = endpoint_from_env(err);
	if (!endpoint) {
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 2. Build pkt-line request (validates values before emission) */
	if (build_batch_request(batch, &request, err)) {
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

	/* 5. Parse pkt-line response (preflight: no src_paths) */
	if (parse_executor_response(answer.buf, answer.len,
				    &status_str, &msg, NULL)) {
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

enum textil_ext_executor_status textil_ext_execute_materialize_batch(
	const struct textil_ext_takeover_batch *batch,
	struct string_list *src_paths_out,
	struct strbuf *err)
{
	/* Preconditions (common, evaluated before #ifdef split) */
	if (!batch || !batch->items || batch->nr_items <= 0)
		BUG("execute_materialize_batch called with invalid batch");
	if (batch->phase != TEXTIL_EXT_EXEC_PHASE_MATERIALIZE)
		BUG("execute_materialize_batch called with non-materialize phase");
	if (!src_paths_out)
		BUG("execute_materialize_batch called with NULL src_paths_out");
	if (!err)
		BUG("execute_materialize_batch called with NULL err");

#ifndef SUPPORTS_SIMPLE_IPC
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

	/* 1. Resolve endpoint */
	endpoint = endpoint_from_env(err);
	if (!endpoint) {
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 2. Build pkt-line request */
	if (build_batch_request(batch, &request, err)) {
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

	/* 4. Size guard */
	if (answer.len > TEXTIL_EXT_MAX_REPLY_SIZE) {
		strbuf_addf(err,
			_("textil-ext: reply too large (%lu bytes, max %d) "
			  "from endpoint '%s'"),
			(unsigned long)answer.len,
			TEXTIL_EXT_MAX_REPLY_SIZE, endpoint);
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 5. Parse pkt-line response with src_paths */
	if (parse_executor_response(answer.buf, answer.len,
				    &status_str, &msg,
				    src_paths_out)) {
		strbuf_addf(err,
			_("textil-ext: invalid response from endpoint '%s'"),
			endpoint);
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 6. Map status */
	if (!strcmp(status_str.buf, "ok")) {
		/* Validate src_path count matches batch items */
		if (src_paths_out->nr != batch->nr_items) {
			strbuf_addf(err,
				_("textil-ext: materialize src_path count "
				  "mismatch: got %lu, expected %d"),
				(unsigned long)src_paths_out->nr,
				batch->nr_items);
			status = TEXTIL_EXT_EXECUTOR_ERROR;
			goto done;
		}
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

void textil_ext_resolve_main_worktree(struct strbuf *out)
{
	struct strbuf realdir = STRBUF_INIT;
	const char *last_slash;

	strbuf_realpath(&realdir, the_repository->commondir, 1);
	last_slash = strrchr(realdir.buf, '/');
	if (last_slash && last_slash > realdir.buf)
		strbuf_add(out, realdir.buf, last_slash - realdir.buf);
	else
		strbuf_addstr(out, realdir.buf);
	strbuf_release(&realdir);
}

void textil_ext_takeover_batch_release(struct textil_ext_takeover_batch *batch)
{
	int i;

	if (!batch || !batch->items)
		return;

	for (i = 0; i < batch->nr_items; i++) {
		free(batch->items[i].path);
		free(batch->items[i].attr_filter);
		free(batch->items[i].blob_oid);
		free(batch->items[i].input_path);
	}
}

/* --- Materialize one-to-fd helper --------------------------------------- */

int textil_ext_materialize_one_to_fd(
	const char *ce_name,
	const struct object_id *ce_oid,
	const char *attr_filter,
	const struct textil_ext_eval_result *eval_result,
	const char *repo_root,
	int out_fd,
	struct strbuf *err)
{
	struct textil_ext_takeover_batch batch;
	struct textil_ext_takeover_item item;
	struct string_list src_paths = STRING_LIST_INIT_DUP;
	enum textil_ext_executor_status st;
	int src_fd, ret = -1;

	memset(&batch, 0, sizeof(batch));
	memset(&item, 0, sizeof(item));

	item.path = xstrdup(ce_name);
	item.rule_id = eval_result->rule_id;
	item.attr_filter = attr_filter ? xstrdup(attr_filter) : NULL;
	item.blob_oid = xstrdup(oid_to_hex(ce_oid));
	item.is_regular_file = 1;
	item.strict = eval_result->strict;
	item.capabilities = eval_result->capabilities;
	item.nr_capabilities = eval_result->nr_capabilities;

	batch.phase = TEXTIL_EXT_EXEC_PHASE_MATERIALIZE;
	batch.operation = "checkout";
	batch.repo_root = repo_root;
	batch.items = &item;
	batch.nr_items = 1;

	st = textil_ext_execute_materialize_batch(&batch, &src_paths, err);
	if (st != TEXTIL_EXT_EXECUTOR_OK) {
		error("textil-ext: materialize failed for '%s': %s",
		      ce_name, err->buf);
		goto cleanup;
	}

	src_fd = open(src_paths.items[0].string, O_RDONLY);
	if (src_fd < 0) {
		error_errno("textil-ext: cannot open src_path '%s'",
			    src_paths.items[0].string);
		goto cleanup;
	}

	if (copy_fd(src_fd, out_fd)) {
		close(src_fd);
		error("textil-ext: copy_fd failed for '%s'", ce_name);
		goto cleanup;
	}

	close(src_fd);
	ret = 0;

cleanup:
	textil_ext_takeover_batch_release(&batch);
	string_list_clear(&src_paths, 0);
	return ret;
}

/* --- Checkin convert executor ------------------------------------------- */

enum textil_ext_executor_status textil_ext_execute_checkin_convert_batch(
	const struct textil_ext_takeover_batch *batch,
	struct string_list *src_paths_out,
	struct strbuf *err)
{
	/* Preconditions (common, evaluated before #ifdef split) */
	if (!batch || !batch->items || batch->nr_items <= 0)
		BUG("execute_checkin_convert_batch called with invalid batch");
	if (batch->phase != TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT)
		BUG("execute_checkin_convert_batch called with non-checkin_convert phase");
	if (!src_paths_out)
		BUG("execute_checkin_convert_batch called with NULL src_paths_out");
	if (!err)
		BUG("execute_checkin_convert_batch called with NULL err");

#ifndef SUPPORTS_SIMPLE_IPC
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

	/* 1. Resolve endpoint */
	endpoint = endpoint_from_env(err);
	if (!endpoint) {
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 2. Build pkt-line request */
	if (build_batch_request(batch, &request, err)) {
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

	/* 4. Size guard */
	if (answer.len > TEXTIL_EXT_MAX_REPLY_SIZE) {
		strbuf_addf(err,
			_("textil-ext: reply too large (%lu bytes, max %d) "
			  "from endpoint '%s'"),
			(unsigned long)answer.len,
			TEXTIL_EXT_MAX_REPLY_SIZE, endpoint);
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 5. Parse pkt-line response with src_paths (same as materialize) */
	if (parse_executor_response(answer.buf, answer.len,
				    &status_str, &msg,
				    src_paths_out)) {
		strbuf_addf(err,
			_("textil-ext: invalid response from endpoint '%s'"),
			endpoint);
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	/* 6. Map status */
	if (!strcmp(status_str.buf, "ok")) {
		if (src_paths_out->nr != batch->nr_items) {
			strbuf_addf(err,
				_("textil-ext: checkin_convert src_path count "
				  "mismatch: got %lu, expected %d"),
				(unsigned long)src_paths_out->nr,
				batch->nr_items);
			status = TEXTIL_EXT_EXECUTOR_ERROR;
			goto done;
		}
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

/* --- Checkin convert one-to-buf helper ---------------------------------- */

int textil_ext_checkin_convert_one_to_buf(
	const char *path,
	const char *src, size_t src_len,
	const char *attr_filter,
	const struct textil_ext_eval_result *eval_result,
	const char *repo_root,
	struct strbuf *dst,
	struct strbuf *err)
{
	struct textil_ext_takeover_batch batch;
	struct textil_ext_takeover_item item;
	struct string_list src_paths = STRING_LIST_INIT_DUP;
	enum textil_ext_executor_status st;
	struct strbuf tmp_path = STRBUF_INIT;
	int tmp_fd, src_fd, ret = -1;

	memset(&batch, 0, sizeof(batch));
	memset(&item, 0, sizeof(item));

	/* Write working tree content to a temp file for backend input.
	 * Use the resolved gitdir (works for linked worktrees where
	 * .git is a file pointing to the real gitdir).
	 * Absolutize the gitdir so the path is valid regardless of CWD
	 * (the backend reads this path from its own process context).
	 */
	strbuf_add_absolute_path(&tmp_path, repo_get_git_dir(the_repository));
	strbuf_addstr(&tmp_path, "/textil-tmp-XXXXXX");
	tmp_fd = git_mkstemp_mode(tmp_path.buf, 0600);
	if (tmp_fd < 0) {
		error_errno("textil-ext: cannot create temp file for checkin");
		strbuf_release(&tmp_path);
		return -1;
	}
	if (write_in_full(tmp_fd, src, src_len) < 0) {
		error_errno("textil-ext: write to temp file failed");
		close(tmp_fd);
		unlink(tmp_path.buf);
		strbuf_release(&tmp_path);
		return -1;
	}
	close(tmp_fd);

	item.path = xstrdup(path);
	item.rule_id = eval_result->rule_id;
	item.attr_filter = attr_filter ? xstrdup(attr_filter) : NULL;
	item.blob_oid = NULL;
	item.input_path = strbuf_detach(&tmp_path, NULL);
	item.is_regular_file = 1;
	item.strict = eval_result->strict;
	item.capabilities = eval_result->capabilities;
	item.nr_capabilities = eval_result->nr_capabilities;

	batch.phase = TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT;
	batch.operation = "checkin";
	batch.repo_root = repo_root;
	batch.items = &item;
	batch.nr_items = 1;

	st = textil_ext_execute_checkin_convert_batch(&batch, &src_paths, err);
	if (st != TEXTIL_EXT_EXECUTOR_OK) {
		error("textil-ext: checkin_convert failed for '%s': %s",
		      path, err->buf);
		goto cleanup;
	}

	/* Read the returned src_path content into dst */
	src_fd = open(src_paths.items[0].string, O_RDONLY);
	if (src_fd < 0) {
		error_errno("textil-ext: cannot open src_path '%s'",
			    src_paths.items[0].string);
		goto cleanup;
	}

	strbuf_reset(dst);
	if (strbuf_read(dst, src_fd, 0) < 0) {
		close(src_fd);
		error_errno("textil-ext: read src_path failed for '%s'", path);
		goto cleanup;
	}
	close(src_fd);
	ret = 0;

cleanup:
	/* Remove temp input file */
	if (item.input_path)
		unlink(item.input_path);
	textil_ext_takeover_batch_release(&batch);
	string_list_clear(&src_paths, 0);
	return ret;
}

/* --- Checkin convert fd-to-buf helper (streaming, no full-memory copy) --- */

int textil_ext_checkin_convert_fd_to_buf(
	const char *path,
	int input_fd,
	const char *attr_filter,
	const struct textil_ext_eval_result *eval_result,
	const char *repo_root,
	struct strbuf *dst,
	struct strbuf *err)
{
	struct textil_ext_takeover_batch batch;
	struct textil_ext_takeover_item item;
	struct string_list src_paths = STRING_LIST_INIT_DUP;
	enum textil_ext_executor_status st;
	struct strbuf tmp_path = STRBUF_INIT;
	int tmp_fd, src_fd, ret = -1;

	memset(&batch, 0, sizeof(batch));
	memset(&item, 0, sizeof(item));

	/*
	 * Stream fd content directly to a temp file — avoids loading
	 * the entire input into memory (important for large binaries).
	 * Absolutize gitdir so backend can always resolve the path.
	 */
	strbuf_add_absolute_path(&tmp_path, repo_get_git_dir(the_repository));
	strbuf_addstr(&tmp_path, "/textil-tmp-XXXXXX");
	tmp_fd = git_mkstemp_mode(tmp_path.buf, 0600);
	if (tmp_fd < 0) {
		error_errno("textil-ext: cannot create temp file for checkin");
		strbuf_release(&tmp_path);
		return -1;
	}
	if (copy_fd(input_fd, tmp_fd)) {
		error("textil-ext: failed to stream input to temp file");
		close(tmp_fd);
		unlink(tmp_path.buf);
		strbuf_release(&tmp_path);
		return -1;
	}
	close(tmp_fd);

	item.path = xstrdup(path);
	item.rule_id = eval_result->rule_id;
	item.attr_filter = attr_filter ? xstrdup(attr_filter) : NULL;
	item.blob_oid = NULL;
	item.input_path = strbuf_detach(&tmp_path, NULL);
	item.is_regular_file = 1;
	item.strict = eval_result->strict;
	item.capabilities = eval_result->capabilities;
	item.nr_capabilities = eval_result->nr_capabilities;

	batch.phase = TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT;
	batch.operation = "checkin";
	batch.repo_root = repo_root;
	batch.items = &item;
	batch.nr_items = 1;

	st = textil_ext_execute_checkin_convert_batch(&batch, &src_paths, err);
	if (st != TEXTIL_EXT_EXECUTOR_OK) {
		error("textil-ext: checkin_convert failed for '%s': %s",
		      path, err->buf);
		goto cleanup;
	}

	/* Read the returned src_path content into dst */
	src_fd = open(src_paths.items[0].string, O_RDONLY);
	if (src_fd < 0) {
		error_errno("textil-ext: cannot open src_path '%s'",
			    src_paths.items[0].string);
		goto cleanup;
	}

	strbuf_reset(dst);
	if (strbuf_read(dst, src_fd, 0) < 0) {
		close(src_fd);
		error_errno("textil-ext: read src_path failed for '%s'", path);
		goto cleanup;
	}
	close(src_fd);
	ret = 0;

cleanup:
	if (item.input_path)
		unlink(item.input_path);
	textil_ext_takeover_batch_release(&batch);
	string_list_clear(&src_paths, 0);
	return ret;
}
