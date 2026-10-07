#define USE_THE_REPOSITORY_VARIABLE

#include "git-compat-util.h"
#include "textil-ext-executor.h"
#include "textil-ext-policy.h"
#include "gettext.h"
#include "pkt-line.h"
#include "strbuf.h"
#include "string-list.h"
#include "read-cache-ll.h"
#include "unpack-trees.h"
#include "repository.h"
#include "convert.h"
#include "alloc.h"
#include "copy.h"
#include "hex.h"
#include "abspath.h"
#include "odb.h"
#include "trace.h"
#include "trace2.h"
#include "strmap.h"
#include "parse.h"

#ifdef SUPPORTS_SIMPLE_IPC
#include "simple-ipc.h"
#endif

#define ENV_TRACE_FILE "TEXTIL_GIT_EXT_TRACE_FILE"
#define ENV_OPERATION_ID "TEXTIL_GIT_EXT_OPERATION_ID"

static const char *phase_to_string(enum textil_ext_executor_phase phase);

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

static void trace_json_string(FILE *fp, const char *value)
{
	const unsigned char *p;

	fputc('"', fp);
	if (!value)
		value = "";
	for (p = (const unsigned char *)value; *p; p++) {
		switch (*p) {
		case '\\':
			fputs("\\\\", fp);
			break;
		case '"':
			fputs("\\\"", fp);
			break;
		case '\n':
			fputs("\\n", fp);
			break;
		case '\r':
			fputs("\\r", fp);
			break;
		case '\t':
			fputs("\\t", fp);
			break;
		default:
			if (*p < 0x20)
				fprintf(fp, "\\u%04x", (unsigned)*p);
			else
				fputc(*p, fp);
		}
	}
	fputc('"', fp);
}

static const char *executor_status_name(enum textil_ext_executor_status status)
{
	switch (status) {
	case TEXTIL_EXT_EXECUTOR_OK:
		return "ok";
	case TEXTIL_EXT_EXECUTOR_REJECTED:
		return "rejected";
	case TEXTIL_EXT_EXECUTOR_NOT_IMPLEMENTED:
		return "not_implemented";
	case TEXTIL_EXT_EXECUTOR_ERROR:
		return "error";
	}
	return "unknown";
}

#ifdef SUPPORTS_SIMPLE_IPC
/*
 * One controller round trip, visible in trace2 as a "textil-ext" region
 * named after the phase with the batch size, so request counts and their
 * cost can be read from GIT_TRACE2_EVENT without the Textil trace file.
 */
static int send_controller_request(
	const struct textil_ext_takeover_batch *batch,
	const char *endpoint,
	const struct ipc_client_connect_options *options,
	const struct strbuf *request,
	struct strbuf *answer)
{
	const char *phase = phase_to_string(batch->phase);
	int ret;

	trace2_region_enter("textil-ext", phase, the_repository);
	trace2_data_intmax("textil-ext", the_repository, "items",
			   batch->nr_items);
	ret = ipc_client_send_command(endpoint, options,
				      request->buf, request->len, answer);
	trace2_region_leave("textil-ext", phase, the_repository);
	return ret;
}
#endif

static void trace_batch_roundtrip(
	const struct textil_ext_takeover_batch *batch,
	const char *endpoint,
	enum textil_ext_executor_status status,
	const char *message,
	uint64_t start_ns)
{
	const char *trace_path = getenv(ENV_TRACE_FILE);
	const char *operation_id = getenv(ENV_OPERATION_ID);
	FILE *fp;
	uint64_t end_ns;

	if (!trace_path || !*trace_path || !operation_id || !*operation_id || !batch)
		return;

	fp = fopen(trace_path, "ab");
	if (!fp)
		return;

	end_ns = (uint64_t)getnanotime();
	fputs("{\"source\":\"git_ext\",\"category\":\"controller\",\"event\":\"ipc_roundtrip\"", fp);
	fputs(",\"operation_id\":", fp);
	trace_json_string(fp, operation_id);
	fputs(",\"ts_ns\":\"", fp);
	fprintf(fp, "%llu", (unsigned long long)end_ns);
	fputs("\"", fp);
	fputs(",\"phase\":", fp);
	trace_json_string(fp, phase_to_string(batch->phase));
	fputs(",\"operation\":", fp);
	trace_json_string(fp, batch->operation);
	fputs(",\"items\":", fp);
	fprintf(fp, "%d", batch->nr_items);
	fputs(",\"status\":", fp);
	trace_json_string(fp, executor_status_name(status));
	fputs(",\"start_ns\":\"", fp);
	fprintf(fp, "%llu", (unsigned long long)start_ns);
	fputs("\"", fp);
	fputs(",\"end_ns\":\"", fp);
	fprintf(fp, "%llu", (unsigned long long)end_ns);
	fputs("\"", fp);
	if (endpoint && *endpoint) {
		fputs(",\"endpoint\":", fp);
		trace_json_string(fp, endpoint);
	}
	if (message && *message) {
		fputs(",\"message\":", fp);
		trace_json_string(fp, message);
	}
	fputs("}\n", fp);
	fclose(fp);
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
 * CR (line injection), and DEL (0x7F). Git for Windows may present
 * LF/CR in path names as U+F00A/U+F00D private-use code points; those
 * are rejected as LF/CR equivalents.
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
		if (p[1] && p[2] &&
		    *p == 0xEF && p[1] == 0x80 &&
		    (p[2] == 0x8A || p[2] == 0x8D)) {
			strbuf_addf(err,
				_("textil-ext: request value for '%s' contains "
				  "forbidden character U+F00%X at byte %lu"),
				key, (unsigned)(p[2] & 0x0F),
				(unsigned long)(p - (const unsigned char *)value));
			return -1;
		}
	}
	return 0;
}

/*
 * Build a phase-specific pkt-line v1 takeover request.
 *
 * Paths and metadata are validated before emission.
 * Returns 0 on success, -1 on validation error (message appended to err).
 *
 * Format:
 *   <pkt> version=1
 *   <pkt> command=preflight_batch|materialize_batch|checkin_convert_batch
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
	const char *operation_id = getenv("TEXTIL_GIT_EXT_OPERATION_ID");
	const char *projection_workspace = getenv("TEXTIL_GIT_EXT_PROJECTION_WORKSPACE");

	/* Validate header values */
	if (validate_request_value("operation", batch->operation, err))
		return -1;
	if (batch->repo_root &&
	    validate_request_value("repo_root", batch->repo_root, err))
		return -1;
	if (operation_id &&
	    validate_request_value("operation_id", operation_id, err))
		return -1;
	if (projection_workspace &&
	    validate_request_value("projection_workspace", projection_workspace, err))
		return -1;

	/* Header fields */
	packet_buf_write(out, "version=1\n");
	packet_buf_write(out, "command=%s\n", command_for_phase(batch->phase));
	packet_buf_write(out, "phase=%s\n", phase_to_string(batch->phase));
	packet_buf_write(out, "operation=%s\n", batch->operation);
	if (batch->repo_root)
		packet_buf_write(out, "repo_root=%s\n", batch->repo_root);
	if (operation_id)
		packet_buf_write(out, "operation_id=%s\n", operation_id);
	if (projection_workspace)
		packet_buf_write(out, "projection_workspace=%s\n", projection_workspace);
	if (batch->phase == TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT &&
	    batch->deferred_durability)
		packet_buf_write(out, "durability=deferred\n");

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
		if (item->old_blob_oid &&
		    validate_request_value("old_blob_oid", item->old_blob_oid, err))
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
		if (batch->phase == TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT)
			packet_buf_write(out, "input_path=%s\n",
					 item->input_path);
		else
			packet_buf_write(out, "blob_oid=%s\n", item->blob_oid);
		if (item->old_blob_oid)
			packet_buf_write(out, "old_blob_oid=%s\n", item->old_blob_oid);
		if (batch->phase == TEXTIL_EXT_EXEC_PHASE_PREFLIGHT) {
			packet_buf_write(out, "checkout_two_tree=%s\n", item->two_tree_checkout ? "true" : "false");
			packet_buf_write(out, "checkout_verified=%s\n", item->old_worktree_verified ? "true" : "false");
			packet_buf_write(out, "checkout_overwrite=%s\n", item->overwrite_allowed ? "true" : "false");
		}
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

	/*
	 * Must be absolute.
	 *
	 * Keep this aligned with the backend-side src_path contract:
	 *   - Unix absolute: /tmp/file
	 *   - Windows drive-absolute: C:\path or C:/path
	 *   - Windows verbatim / UNC prefixes: \\?\C:\path, \\server\share\path
	 *
	 * ex-git is always launched by the backend, and on Windows the
	 * controller may canonicalize LFS object paths into verbatim form.
	 * Rejecting those here turns valid controller replies into
	 * "invalid response from endpoint" during checkout/materialize.
	 */
	if (path[0] != '/' &&
	    !(path_len >= 3 &&
	      ((path[0] >= 'A' && path[0] <= 'Z') ||
	       (path[0] >= 'a' && path[0] <= 'z')) &&
	      path[1] == ':' && (path[2] == '\\' || path[2] == '/')) &&
	    !(path_len >= 2 && path[0] == '\\' && path[1] == '\\'))
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
 * Preflight success (one ordered disposition per request item):
 *   <pkt> status=ok
 *   <delim>
 *   <pkt> disposition=projected|materialize
 *   ...
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
 * A successful preflight fills batch item dispositions; materialize fills
 * src_paths_out. Each item section contains exactly one value. Failed replies
 * have only status + required message, with no item sections.
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
				   struct string_list *src_paths_out,
				   struct string_list *fence_oids_out,
				   struct textil_ext_takeover_batch *preflight_batch)
{
	size_t pos = 0;
	int has_status = 0, has_message = 0;
	int in_src_path_section = 0;
	int has_src_path = 0;
	int has_fence_oid = 0;
	int disposition_nr = 0;
	int section_has_value = 0;

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
		if (st == PKTLINE_MEM_FLUSH) {
			if (in_src_path_section &&
			    !(preflight_batch ? section_has_value : has_src_path))
				return -1;
			break;
		}
		if (st == PKTLINE_MEM_DELIM) {
			/* Item sections require a successful batch reply. */
			if ((!src_paths_out && !preflight_batch) || !has_status)
				return -1;
			if (in_src_path_section &&
			    !(preflight_batch ? section_has_value : has_src_path))
				return -1;
			if (strcmp(status_out->buf, "ok"))
				return -1; /* delim not allowed for non-ok */
			has_src_path = 0;
			has_fence_oid = 0;
			section_has_value = 0;
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
			if (preflight_batch) {
				int projected;
				if (section_has_value)
					return -1;
				section_has_value = 1;
				if (key_len != 11 || memcmp(line, "disposition", 11))
					return -1;
				if (val_len == 9 && !memcmp(val, "projected", 9))
					projected = 1;
				else if (val_len == 11 && !memcmp(val, "materialize", 11))
					projected = 0;
				else
					return -1;
				if (disposition_nr >= preflight_batch->nr_items)
					return -1;
				preflight_batch->items[disposition_nr++].projected = projected;
				continue;
			}
			if (key_len == 8 && !memcmp(line, "src_path", 8)) {
				struct strbuf path_buf = STRBUF_INIT;
				if (has_src_path)
					return -1;
				if (validate_src_path(val, val_len))
					return -1;
				strbuf_add(&path_buf, val, val_len);
				string_list_append(src_paths_out, path_buf.buf);
				has_src_path = 1;
				strbuf_release(&path_buf);
			} else if (fence_oids_out && key_len == 9 &&
				   !memcmp(line, "fence_oid", 9)) {
				struct strbuf oid_buf = STRBUF_INIT;
				/* A sealed object's SHA-256 LFS OID, at most one per item. */
				if (has_fence_oid || val_len != 64)
					return -1;
				for (k = 0; k < val_len; k++)
					if (!isxdigit((unsigned char)val[k]))
						return -1;
				strbuf_add(&oid_buf, val, val_len);
				string_list_append(fence_oids_out, oid_buf.buf);
				has_fence_oid = 1;
				strbuf_release(&oid_buf);
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

	if (preflight_batch && in_src_path_section && !section_has_value)
		return -1;
	if (preflight_batch && !strcmp(status_out->buf, "ok") &&
	    (disposition_nr != preflight_batch->nr_items || has_message))
		return -1;

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

static enum textil_ext_executor_status execute_src_path_batch(
	const struct textil_ext_takeover_batch *batch,
	const char *count_mismatch_label,
	struct string_list *src_paths_out,
	struct string_list *fence_oids_out,
	struct strbuf *err)
{
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
	uint64_t trace_start_ns = (uint64_t)getnanotime();

	endpoint = endpoint_from_env(err);
	if (!endpoint) {
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	if (build_batch_request(batch, &request, err)) {
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	options.wait_if_busy = 1;
	options.wait_if_not_found = 0;

	ipc_ret = send_controller_request(batch, endpoint, &options,
					  &request, &answer);
	if (ipc_ret) {
		strbuf_addf(err,
			_("textil-ext: failed to connect to endpoint '%s'"),
			endpoint);
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	if (answer.len > TEXTIL_EXT_MAX_REPLY_SIZE) {
		strbuf_addf(err,
			_("textil-ext: reply too large (%lu bytes, max %d) "
			  "from endpoint '%s'"),
			(unsigned long)answer.len,
			TEXTIL_EXT_MAX_REPLY_SIZE, endpoint);
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	if (parse_executor_response(answer.buf, answer.len,
				    &status_str, &msg,
				    src_paths_out, fence_oids_out, NULL)) {
		strbuf_addf(err,
			_("textil-ext: invalid response from endpoint '%s'"),
			endpoint);
		status = TEXTIL_EXT_EXECUTOR_ERROR;
		goto done;
	}

	if (!strcmp(status_str.buf, "ok")) {
		if (src_paths_out->nr != batch->nr_items) {
			strbuf_addf(err,
				_("textil-ext: %s src_path count mismatch: got %lu, expected %d"),
				count_mismatch_label,
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
	trace_batch_roundtrip(batch, endpoint, status, err->buf, trace_start_ns);
	strbuf_release(&request);
	strbuf_release(&answer);
	strbuf_release(&status_str);
	strbuf_release(&msg);
	return status;
#endif /* SUPPORTS_SIMPLE_IPC */
}

/* --- Preflight collection ----------------------------------------------- */

#define TEXTIL_EXT_MAX_POINTER_BLOB_SIZE 8192
/* Keep in sync with textil-source-pointer's MAX_SOURCE_POINTER_BYTES. */
#define TEXTIL_EXT_MAX_SOURCE_POINTER_BLOB_SIZE 1024

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

static int blob_oid_is_pointer(
	const struct object_id *oid,
	const char *source_prefix,
	int *is_pointer,
	struct strbuf *err)
{
	enum object_type type;
	size_t size;
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

	if (size > (source_prefix ? TEXTIL_EXT_MAX_SOURCE_POINTER_BLOB_SIZE :
				   TEXTIL_EXT_MAX_POINTER_BLOB_SIZE)) {
		free(blob);
		*is_pointer = 0;
		return 0;
	}

	*is_pointer = source_prefix ?
		starts_with(blob, source_prefix) :
		blob_content_is_lfs_pointer(blob, size);
	free(blob);
	return 0;
}

int textil_ext_blob_oid_is_lfs_pointer(
	const struct object_id *oid,
	int *is_pointer,
	struct strbuf *err)
{
	return blob_oid_is_pointer(oid, NULL, is_pointer, err);
}

static int blob_oid_is_takeover_candidate(
	const struct object_id *oid,
	const char *filter_name,
	enum textil_ext_executor_phase phase,
	int *is_pointer,
	struct strbuf *err)
{
	const char *source_prefix;

	*is_pointer = 0;
	if (!filter_name)
		return 0;
	if (!strcmp(filter_name, "lfs"))
		return textil_ext_blob_oid_is_lfs_pointer(oid, is_pointer, err);
	if (phase != TEXTIL_EXT_EXEC_PHASE_PREFLIGHT)
		return 0;
	if (!strcmp(filter_name, "p4"))
		source_prefix = "version https://textil.dev/spec/perforce-pointer/";
	else if (!strcmp(filter_name, "svn"))
		source_prefix = "version https://textil.dev/spec/subversion-pointer/";
	else
		return 0;

	/* Rust textil-source-pointer owns validation; only select candidates. */
	return blob_oid_is_pointer(oid, source_prefix, is_pointer, err);
}

static void textil_ext_collect_takeover_batch(
	struct index_state *index,
	const char *operation,
	const char *repo_root,
	enum textil_ext_executor_phase phase,
	struct textil_ext_takeover_batch *batch_out)
{
	int i;
	int alloc = 0;

	memset(batch_out, 0, sizeof(*batch_out));
	batch_out->phase = phase;
	batch_out->operation = operation;
	batch_out->repo_root = repo_root;

	for (i = 0; i < index->cache_nr; i++) {
		struct cache_entry *ce = index->cache[i];
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
		if (phase == TEXTIL_EXT_EXEC_PHASE_PREFLIGHT)
			textil_ext_evaluate_for_preflight(
				filter_name, 1, &ext_result);
		else if (phase == TEXTIL_EXT_EXEC_PHASE_MATERIALIZE)
			textil_ext_evaluate_for_checkout(
				filter_name, 1, &ext_result);
		else
			BUG("unsupported checkout batch collection phase: %d",
			    phase);

		if (!ext_result.matched ||
		    ext_result.action != TEXTIL_ACTION_TAKEOVER)
			continue;

		if (blob_oid_is_takeover_candidate(&ce->oid, filter_name, phase,
						  &is_pointer, &pointer_err))
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
		item->checkout_entry = ce;
	}
}

void textil_ext_collect_preflight_takeover_batch(
	struct index_state *index,
	const struct unpack_trees_options *options,
	const char *operation,
	const char *repo_root,
	struct textil_ext_takeover_batch *batch_out)
{
	int i;
	struct index_state *source_index = options->src_index;
	int two_tree = options->merge && options->fn == twoway_merge &&
		options->internal.merge_size == 2;
	textil_ext_collect_takeover_batch(index, operation, repo_root,
					  TEXTIL_EXT_EXEC_PHASE_PREFLIGHT,
					  batch_out);
	for (i = 0; i < batch_out->nr_items; i++) {
		struct textil_ext_takeover_item *item = &batch_out->items[i];
		int pos = index_name_pos(source_index, item->path, strlen(item->path));
		item->two_tree_checkout = two_tree;
		item->overwrite_allowed = options->reset != UNPACK_RESET_NONE;
		if (pos >= 0 && !ce_stage(source_index->cache[pos])) {
			const struct cache_entry *old = source_index->cache[pos];
			item->old_blob_oid = xstrdup(oid_to_hex(&old->oid));
			item->old_worktree_verified = two_tree && !item->overwrite_allowed &&
				S_ISREG(old->ce_mode) && !(old->ce_flags & CE_CONFLICTED) &&
				!(!options->skip_sparse_checkout && ce_skip_worktree(old) &&
				  (old->ce_flags & CE_NEW_SKIP_WORKTREE));
		} else if (pos < 0 && two_tree && !item->overwrite_allowed) {
			item->old_worktree_verified = item->checkout_entry->textil_worktree_absent;
		}
	}
}

void textil_ext_collect_materialize_takeover_batch(
	struct index_state *index,
	const char *operation,
	const char *repo_root,
	struct textil_ext_takeover_batch *batch_out)
{
	textil_ext_collect_takeover_batch(index, operation, repo_root,
					  TEXTIL_EXT_EXEC_PHASE_MATERIALIZE,
					  batch_out);
}

/* --- Executor ----------------------------------------------------------- */

enum textil_ext_executor_status textil_ext_execute_takeover_batch(
	struct textil_ext_takeover_batch *batch,
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
	uint64_t trace_start_ns = (uint64_t)getnanotime();

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

	ipc_ret = send_controller_request(batch, endpoint, &options,
					  &request, &answer);
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
				    &status_str, &msg, NULL, NULL, batch)) {
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
	trace_batch_roundtrip(batch, endpoint, status, err->buf, trace_start_ns);
	strbuf_release(&request);
	strbuf_release(&answer);
	strbuf_release(&status_str);
	strbuf_release(&msg);
	return status;
#endif /* SUPPORTS_SIMPLE_IPC */
}

void textil_ext_materialize_batch_result_init(
	struct textil_ext_materialize_batch_result *result)
{
	if (!result)
		BUG("textil_ext_materialize_batch_result_init called with NULL result");

	memset(result, 0, sizeof(*result));
	string_list_init_dup(&result->src_paths);
}

void textil_ext_materialize_batch_result_release(
	struct textil_ext_materialize_batch_result *result)
{
	if (!result)
		return;

	string_list_clear(&result->src_paths, 0);
}

enum textil_ext_executor_status textil_ext_resolve_materialize_batch(
	const struct textil_ext_takeover_batch *batch,
	struct textil_ext_materialize_batch_result *result_out,
	struct strbuf *err)
{
	if (!batch || !batch->items || batch->nr_items <= 0)
		BUG("resolve_materialize_batch called with invalid batch");
	if (batch->phase != TEXTIL_EXT_EXEC_PHASE_MATERIALIZE)
		BUG("resolve_materialize_batch called with non-materialize phase");
	if (!result_out)
		BUG("resolve_materialize_batch called with NULL result_out");
	if (!err)
		BUG("resolve_materialize_batch called with NULL err");

	return execute_src_path_batch(batch, "materialize",
				      &result_out->src_paths, NULL, err);
}


void textil_ext_resolve_worktree_root(struct strbuf *out)
{
	struct strbuf realdir = STRBUF_INIT;
	const char *worktree = repo_get_work_tree(the_repository);
	const char *last_slash;

	/*
	 * The controller request belongs to the Git process' active worktree.
	 * Textil projects deliberately keep the common Git directory at
	 * <project>/.bare and the primary worktree at <project>/default; deriving
	 * a path by stripping ".bare" therefore names a non-repository project
	 * container.  Linked worktrees have the same authority requirement.
	 */
	if (worktree && *worktree) {
		strbuf_realpath(out, worktree, 1);
		return;
	}

	/* Bare/no-worktree callers retain the common-dir parent fallback. */
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
		free(batch->items[i].old_blob_oid);
		free(batch->items[i].input_path);
	}
}

/* --- Materialize pre-resolution cache ----------------------------------- */

#include "strmap.h"

/*
 * Global cache: "path\toid" → canonical src_path.
 * Populated once before the sequential checkout loop, looked up per-file.
 */
static struct strmap materialize_cache = STRMAP_INIT;
static int materialize_cache_populated;

static char *make_cache_key(const char *path, const char *oid_hex)
{
	struct strbuf key = STRBUF_INIT;
	strbuf_addstr(&key, path);
	strbuf_addch(&key, '\t');
	strbuf_addstr(&key, oid_hex);
	return strbuf_detach(&key, NULL);
}

int textil_ext_preresolve_materialize_cache(
	const struct textil_ext_takeover_batch *preflight_batch,
	struct strbuf *err)
{
	struct textil_ext_takeover_batch mat_batch;
	struct textil_ext_takeover_item *items;
	struct textil_ext_materialize_batch_result result;
	struct strbuf main_wt = STRBUF_INIT;
	enum textil_ext_executor_status status;
	int i;

	if (materialize_cache_populated)
		return 0;
	if (!preflight_batch || preflight_batch->nr_items <= 0)
		return 0;

	/* materialize batch を preflight batch と同じ候補で構築する */
	CALLOC_ARRAY(items, preflight_batch->nr_items);
	for (i = 0; i < preflight_batch->nr_items; i++) {
		const struct textil_ext_takeover_item *src = &preflight_batch->items[i];
		items[i].path = xstrdup(src->path);
		items[i].rule_id = src->rule_id;
		items[i].attr_filter = src->attr_filter ? xstrdup(src->attr_filter) : NULL;
		items[i].blob_oid = src->blob_oid ? xstrdup(src->blob_oid) : NULL;
		items[i].is_regular_file = src->is_regular_file;
		items[i].strict = src->strict;
		items[i].capabilities = src->capabilities;
		items[i].nr_capabilities = src->nr_capabilities;
	}

	textil_ext_resolve_worktree_root(&main_wt);
	memset(&mat_batch, 0, sizeof(mat_batch));
	mat_batch.phase = TEXTIL_EXT_EXEC_PHASE_MATERIALIZE;
	mat_batch.operation = "checkout";
	mat_batch.repo_root = main_wt.buf;
	mat_batch.items = items;
	mat_batch.nr_items = preflight_batch->nr_items;

	textil_ext_materialize_batch_result_init(&result);
	status = textil_ext_resolve_materialize_batch(&mat_batch, &result, err);

	if (status != TEXTIL_EXT_EXECUTOR_OK) {
		textil_ext_materialize_batch_result_release(&result);
		strbuf_release(&main_wt);
		textil_ext_takeover_batch_release(&mat_batch);
		free(items);
		return -1;
	}

	if (result.src_paths.nr != preflight_batch->nr_items)
		BUG("preresolve: batch returned %lu src_paths for %d items",
		    (unsigned long)result.src_paths.nr, preflight_batch->nr_items);

	/* cache にストアする */
	for (i = 0; i < preflight_batch->nr_items; i++) {
		char *key = make_cache_key(
			preflight_batch->items[i].path,
			preflight_batch->items[i].blob_oid);
		strmap_put(&materialize_cache, key, result.src_paths.items[i].string);
		result.src_paths.items[i].string = NULL;
		free(key);
	}
	materialize_cache_populated = 1;

	textil_ext_materialize_batch_result_release(&result);
	strbuf_release(&main_wt);
	textil_ext_takeover_batch_release(&mat_batch);
	free(items);
	return 0;
}

const char *textil_ext_materialize_cache_lookup(
	const char *path, const char *blob_oid_hex)
{
	char *key;
	const char *source;

	if (!materialize_cache_populated)
		return NULL;
	key = make_cache_key(path, blob_oid_hex);
	source = strmap_get(&materialize_cache, key);
	free(key);
	return source;
}

void textil_ext_materialize_cache_clear(void)
{
	struct hashmap_iter iter;
	struct strmap_entry *entry;

	hashmap_for_each_entry(&materialize_cache.map, &iter, entry, ent)
		free(entry->value);
	strmap_clear(&materialize_cache, 0);
	materialize_cache_populated = 0;
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
	struct textil_ext_materialize_batch_result result;
	enum textil_ext_executor_status st;
	int src_fd, ret = -1;

	memset(&batch, 0, sizeof(batch));
	memset(&item, 0, sizeof(item));
	textil_ext_materialize_batch_result_init(&result);

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

	st = textil_ext_resolve_materialize_batch(&batch, &result, err);
	if (st != TEXTIL_EXT_EXECUTOR_OK) {
		error("textil-ext: materialize failed for '%s': %s",
		      ce_name, err->buf);
		goto cleanup;
	}

	src_fd = open(result.src_paths.items[0].string, O_RDONLY);
	if (src_fd < 0) {
		error_errno("textil-ext: cannot open src_path '%s'",
			    result.src_paths.items[0].string);
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
	textil_ext_materialize_batch_result_release(&result);
	return ret;
}

/* --- Checkin convert executor ------------------------------------------- */

enum textil_ext_executor_status textil_ext_execute_checkin_convert_batch(
	const struct textil_ext_takeover_batch *batch,
	struct string_list *src_paths_out,
	struct string_list *fence_oids_out,
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

	return execute_src_path_batch(batch, "checkin_convert",
				      src_paths_out, fence_oids_out, err);
}

/* --- Deferred checkin durability ---------------------------------------- */

/*
 * OIDs sealed by deferred conversions in this process. A fence request
 * carries about 77 bytes per OID and the controller accepts at most
 * 8 MiB, so the set is fenced early once it reaches this size; every
 * fence still precedes the transaction commit and so the index write.
 */
#define TEXTIL_EXT_FENCE_MAX_OIDS 65536

static struct strset pending_fence_oids = STRSET_INIT;

static int build_fence_request(struct strbuf *out, struct strbuf *err)
{
	const char *operation_id = getenv("TEXTIL_GIT_EXT_OPERATION_ID");
	const char *projection_workspace = getenv("TEXTIL_GIT_EXT_PROJECTION_WORKSPACE");
	struct strbuf repo_root = STRBUF_INIT;
	struct hashmap_iter iter;
	struct strmap_entry *entry;
	int ret = -1;

	textil_ext_resolve_worktree_root(&repo_root);
	if (validate_request_value("repo_root", repo_root.buf, err) ||
	    (operation_id &&
	     validate_request_value("operation_id", operation_id, err)) ||
	    (projection_workspace &&
	     validate_request_value("projection_workspace", projection_workspace, err)))
		goto done;

	packet_buf_write(out, "version=1\n");
	packet_buf_write(out, "command=durability_fence\n");
	packet_buf_write(out, "phase=checkin_convert\n");
	packet_buf_write(out, "operation=checkin\n");
	packet_buf_write(out, "repo_root=%s\n", repo_root.buf);
	if (operation_id)
		packet_buf_write(out, "operation_id=%s\n", operation_id);
	if (projection_workspace)
		packet_buf_write(out, "projection_workspace=%s\n", projection_workspace);
	strset_for_each_entry(&pending_fence_oids, &iter, entry) {
		packet_buf_delim(out);
		packet_buf_write(out, "oid=%s\n", entry->key);
	}
	packet_buf_flush(out);
	ret = 0;
done:
	strbuf_release(&repo_root);
	return ret;
}

int textil_ext_flush_deferred_durability(struct strbuf *err)
{
#ifndef SUPPORTS_SIMPLE_IPC
	if (!strset_get_size(&pending_fence_oids))
		return 0;
	strbuf_addstr(err,
		_("textil-ext: simple-ipc not available on this platform"));
	return -1;
#else
	struct textil_ext_takeover_batch trace_batch = {
		.phase = TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT,
		.operation = "durability_fence",
	};
	struct ipc_client_connect_options options
		= IPC_CLIENT_CONNECT_OPTIONS_INIT;
	struct strbuf request = STRBUF_INIT;
	struct strbuf answer = STRBUF_INIT;
	struct strbuf status_str = STRBUF_INIT;
	struct strbuf msg = STRBUF_INIT;
	enum textil_ext_executor_status status = TEXTIL_EXT_EXECUTOR_ERROR;
	uint64_t trace_start_ns;
	const char *endpoint;

	if (!strset_get_size(&pending_fence_oids))
		return 0;
	trace_start_ns = (uint64_t)getnanotime();
	trace_batch.nr_items = strset_get_size(&pending_fence_oids);

	endpoint = endpoint_from_env(err);
	if (!endpoint || build_fence_request(&request, err))
		goto done;
	options.wait_if_busy = 1;
	options.wait_if_not_found = 0;
	if (send_controller_request(&trace_batch, endpoint, &options,
				    &request, &answer)) {
		strbuf_addf(err,
			_("textil-ext: failed to connect to endpoint '%s'"),
			endpoint);
		goto done;
	}
	if (answer.len > TEXTIL_EXT_MAX_REPLY_SIZE ||
	    parse_executor_response(answer.buf, answer.len, &status_str,
				    &msg, NULL, NULL, NULL)) {
		strbuf_addf(err,
			_("textil-ext: invalid response from endpoint '%s'"),
			endpoint);
		goto done;
	}
	if (strcmp(status_str.buf, "ok")) {
		strbuf_addf(err,
			_("textil-ext: durability fence failed: %s"),
			msg.len ? msg.buf : "(no message)");
		goto done;
	}
	status = TEXTIL_EXT_EXECUTOR_OK;
	strset_clear(&pending_fence_oids);
	strset_init(&pending_fence_oids);

done:
	trace_batch_roundtrip(&trace_batch, endpoint, status, err->buf,
			      trace_start_ns);
	strbuf_release(&request);
	strbuf_release(&answer);
	strbuf_release(&status_str);
	strbuf_release(&msg);
	return status == TEXTIL_EXT_EXECUTOR_OK ? 0 : -1;
#endif /* SUPPORTS_SIMPLE_IPC */
}

/*
 * Inside an open ODB transaction nothing can reference a converted
 * pointer before the transaction commits, so the durability fence moves
 * to that commit. Outside a transaction every conversion fences itself.
 */
static int checkin_durability_deferred(void)
{
	return the_repository->objects && the_repository->objects->transaction;
}

static int queue_deferred_fence(const struct string_list *fence_oids,
				struct strbuf *err)
{
	size_t i;

	for (i = 0; i < fence_oids->nr; i++)
		strset_add(&pending_fence_oids, fence_oids->items[i].string);
	if (strset_get_size(&pending_fence_oids) <
	    git_env_ulong("GIT_TEST_TEXTIL_EXT_FENCE_MAX_OIDS",
			  TEXTIL_EXT_FENCE_MAX_OIDS))
		return 0;
	return textil_ext_flush_deferred_durability(err);
}

/* Convert one item, queue its sealed OID if deferred, read the pointer. */
static int run_single_checkin(struct textil_ext_takeover_batch *batch,
			      struct textil_ext_takeover_item *item,
			      const char *repo_root, const char *path,
			      struct strbuf *dst, struct strbuf *err)
{
	struct string_list src_paths = STRING_LIST_INIT_DUP;
	struct string_list fence_oids = STRING_LIST_INIT_DUP;
	enum textil_ext_executor_status st;
	int src_fd, ret = -1;

	batch->phase = TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT;
	batch->operation = "checkin";
	batch->repo_root = repo_root;
	batch->items = item;
	batch->nr_items = 1;
	batch->deferred_durability = checkin_durability_deferred();

	st = textil_ext_execute_checkin_convert_batch(batch, &src_paths,
						      &fence_oids, err);
	if (st != TEXTIL_EXT_EXECUTOR_OK) {
		error("textil-ext: checkin_convert failed for '%s': %s",
		      path, err->buf);
		goto done;
	}
	if (fence_oids.nr && !batch->deferred_durability) {
		strbuf_addstr(err, _("textil-ext: fence_oid in an immediate checkin reply"));
		error("textil-ext: checkin_convert failed for '%s': %s",
		      path, err->buf);
		goto done;
	}
	if (queue_deferred_fence(&fence_oids, err)) {
		error("textil-ext: checkin_convert failed for '%s': %s",
		      path, err->buf);
		goto done;
	}

	/* Read the returned src_path content into dst */
	src_fd = open(src_paths.items[0].string, O_RDONLY);
	if (src_fd < 0) {
		error_errno("textil-ext: cannot open src_path '%s'",
			    src_paths.items[0].string);
		goto done;
	}
	strbuf_reset(dst);
	if (strbuf_read(dst, src_fd, 0) < 0) {
		close(src_fd);
		error_errno("textil-ext: read src_path failed for '%s'", path);
		goto done;
	}
	close(src_fd);
	ret = 0;
done:
	string_list_clear(&src_paths, 0);
	string_list_clear(&fence_oids, 0);
	return ret;
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
	struct strbuf tmp_path = STRBUF_INIT;
	int tmp_fd, ret = -1;

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

	ret = run_single_checkin(&batch, &item, repo_root, path, dst, err);

	/* Remove temp input file */
	if (item.input_path)
		unlink(item.input_path);
	textil_ext_takeover_batch_release(&batch);
	return ret;
}

/* --- Checkin convert fd-to-buf helper (streaming, no full-memory copy) --- */

int textil_ext_checkin_convert_fd_to_buf(
	const char *path,
	int input_fd,
	const char *input_path,
	const char *attr_filter,
	const struct textil_ext_eval_result *eval_result,
	const char *repo_root,
	struct strbuf *dst,
	struct strbuf *err)
{
	struct textil_ext_takeover_batch batch;
	struct textil_ext_takeover_item item;
	struct strbuf tmp_path = STRBUF_INIT;
	int tmp_fd = -1, ret = -1;
	int remove_input_path = 0;

	memset(&batch, 0, sizeof(batch));
	memset(&item, 0, sizeof(item));

	/* index_path() names the exact file backing input_fd. The backend can
	 * stream that file directly instead of duplicating large assets in the
	 * Git directory. Other callers retain the snapshot temp file.
	 */
	if (input_path) {
		strbuf_add_absolute_path(&tmp_path, input_path);
	} else {
		strbuf_add_absolute_path(&tmp_path,
					 repo_get_git_dir(the_repository));
		strbuf_addstr(&tmp_path, "/textil-tmp-XXXXXX");
		tmp_fd = git_mkstemp_mode(tmp_path.buf, 0600);
		if (tmp_fd < 0) {
			error_errno("textil-ext: cannot create "
				    "checkin temp file");
			strbuf_release(&tmp_path);
			return -1;
		}
		remove_input_path = 1;
		if (copy_fd(input_fd, tmp_fd)) {
			error("textil-ext: cannot stream input to temp file");
			close(tmp_fd);
			unlink(tmp_path.buf);
			strbuf_release(&tmp_path);
			return -1;
		}
		close(tmp_fd);
	}

	item.path = xstrdup(path);
	item.rule_id = eval_result->rule_id;
	item.attr_filter = attr_filter ? xstrdup(attr_filter) : NULL;
	item.blob_oid = NULL;
	item.input_path = strbuf_detach(&tmp_path, NULL);
	item.is_regular_file = 1;
	item.strict = eval_result->strict;
	item.capabilities = eval_result->capabilities;
	item.nr_capabilities = eval_result->nr_capabilities;

	ret = run_single_checkin(&batch, &item, repo_root, path, dst, err);

	if (remove_input_path && item.input_path)
		unlink(item.input_path);
	textil_ext_takeover_batch_release(&batch);
	return ret;
}
