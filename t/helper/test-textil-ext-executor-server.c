/*
 * test-textil-ext-executor-server.c: mock IPC server for executor tests.
 *
 * Subcommands:
 *   SUPPORTS_SIMPLE_IPC   - exits 0 if simple-ipc is available
 *   run-daemon            - run synchronous IPC server (foreground)
 *   start-daemon          - start IPC server in background
 *   stop-daemon           - send quit to running server
 *   is-active             - probe server liveness
 *
 * Options:
 *   --name=<path>         - socket/pipe path (default: "textil-executor-test")
 *   --reply-mode=<mode>   - ok, rejected, error, invalid-pkt, echo, ...
 *   --threads=<n>         - server threads (default: 1)
 */

#include "test-tool.h"
#include "textil-ext-executor.h"
#include "gettext.h"
#include "strbuf.h"
#include "parse-options.h"
#include "alloc.h"
#include "string-list.h"
#include "write-or-die.h"

#ifndef SUPPORTS_SIMPLE_IPC
int cmd__textil_ext_executor_server(int argc, const char **argv)
{
	die("simple IPC not available on this platform");
}
#else

#include "simple-ipc.h"
#include "strvec.h"
#include "run-command.h"
#include "pkt-line.h"

enum reply_mode {
	REPLY_OK,
	REPLY_REJECTED,
	REPLY_ERROR,
	REPLY_INVALID_PKT,
	REPLY_ECHO,
	REPLY_VALIDATE_REQUEST,
	REPLY_TRAILING_AFTER_FLUSH,
	REPLY_INVALID_STATUS,
	REPLY_MISSING_STATUS,
	REPLY_NO_FLUSH,
	REPLY_MISSING_MESSAGE,
	REPLY_REORDERED,
	REPLY_OK_WITH_MESSAGE,
	REPLY_CONTROL_CHAR,
	REPLY_UNKNOWN_KEY,
	REPLY_OVERSIZED,
	REPLY_DUPLICATE_KEY,
	REPLY_MATERIALIZE_OK,
	REPLY_MATERIALIZE_REJECTED,
	REPLY_MATERIALIZE_SRC_PATH_RELATIVE,
	REPLY_MATERIALIZE_SRC_PATH_WITH_STATUS_ERROR,
	REPLY_MATERIALIZE_OK_WITHOUT_SRC_PATH,
	REPLY_MATERIALIZE_OK_WITH_MESSAGE,
	REPLY_MATERIALIZE_CHECKOUT,
	REPLY_MATERIALIZE_COUNT_MISMATCH,
	REPLY_VALIDATE_REQUEST_MATERIALIZE,
	REPLY_CHECKIN_CONVERT_CHECKIN,
	REPLY_VALIDATE_REQUEST_CHECKIN_CONVERT,
};

static struct {
	const char *path;
	enum reply_mode mode;
	int nr_threads;
	int max_wait_sec;
} server_args = {
	.path = "textil-executor-test",
	.mode = REPLY_OK,
	.nr_threads = 1,
	.max_wait_sec = 30,
};

static enum reply_mode parse_reply_mode(const char *s)
{
	if (!strcmp(s, "ok"))
		return REPLY_OK;
	if (!strcmp(s, "rejected"))
		return REPLY_REJECTED;
	if (!strcmp(s, "error"))
		return REPLY_ERROR;
	if (!strcmp(s, "invalid-pkt"))
		return REPLY_INVALID_PKT;
	if (!strcmp(s, "echo"))
		return REPLY_ECHO;
	if (!strcmp(s, "validate-request"))
		return REPLY_VALIDATE_REQUEST;
	if (!strcmp(s, "trailing-after-flush"))
		return REPLY_TRAILING_AFTER_FLUSH;
	if (!strcmp(s, "invalid-status"))
		return REPLY_INVALID_STATUS;
	if (!strcmp(s, "missing-status"))
		return REPLY_MISSING_STATUS;
	if (!strcmp(s, "no-flush"))
		return REPLY_NO_FLUSH;
	if (!strcmp(s, "missing-message"))
		return REPLY_MISSING_MESSAGE;
	if (!strcmp(s, "reordered"))
		return REPLY_REORDERED;
	if (!strcmp(s, "ok-with-message"))
		return REPLY_OK_WITH_MESSAGE;
	if (!strcmp(s, "control-char"))
		return REPLY_CONTROL_CHAR;
	if (!strcmp(s, "unknown-key"))
		return REPLY_UNKNOWN_KEY;
	if (!strcmp(s, "oversized"))
		return REPLY_OVERSIZED;
	if (!strcmp(s, "duplicate-key"))
		return REPLY_DUPLICATE_KEY;
	if (!strcmp(s, "materialize-ok"))
		return REPLY_MATERIALIZE_OK;
	if (!strcmp(s, "materialize-rejected"))
		return REPLY_MATERIALIZE_REJECTED;
	if (!strcmp(s, "materialize-src-path-relative"))
		return REPLY_MATERIALIZE_SRC_PATH_RELATIVE;
	if (!strcmp(s, "materialize-src-path-with-status-error"))
		return REPLY_MATERIALIZE_SRC_PATH_WITH_STATUS_ERROR;
	if (!strcmp(s, "materialize-ok-without-src-path"))
		return REPLY_MATERIALIZE_OK_WITHOUT_SRC_PATH;
	if (!strcmp(s, "materialize-ok-with-message"))
		return REPLY_MATERIALIZE_OK_WITH_MESSAGE;
	if (!strcmp(s, "materialize-checkout"))
		return REPLY_MATERIALIZE_CHECKOUT;
	if (!strcmp(s, "materialize-count-mismatch"))
		return REPLY_MATERIALIZE_COUNT_MISMATCH;
	if (!strcmp(s, "validate-request-materialize"))
		return REPLY_VALIDATE_REQUEST_MATERIALIZE;
	if (!strcmp(s, "checkin-convert-checkin"))
		return REPLY_CHECKIN_CONVERT_CHECKIN;
	if (!strcmp(s, "validate-request-checkin-convert"))
		return REPLY_VALIDATE_REQUEST_CHECKIN_CONVERT;
	die("unknown reply-mode: '%s'", s);
}

/*
 * Max request size accepted by the validator.
 * Prevents allocation bombs in the test helper.
 * 1 MiB is generous for any realistic preflight batch.
 */
#define MAX_VALIDATE_REQUEST_SIZE (1024 * 1024)

/* --- In-memory pkt-line reader (same as executor, local copy) ----------- */

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

/* --- Helper: write raw bytes as a pkt-line ------------------------------ */

static void pkt_buf_add_raw(struct strbuf *buf, const char *data, size_t len)
{
	char hdr[4];
	set_packet_header(hdr, (int)(4 + len));
	strbuf_add(buf, hdr, 4);
	strbuf_add(buf, data, len);
}

/* --- Helper: parse key=value from a data line --------------------------- */

static int parse_kv(const char *line, size_t line_len,
		    const char **key_out, size_t *key_len_out,
		    const char **val_out, size_t *val_len_out)
{
	const char *eq = memchr(line, '=', line_len);
	if (!eq)
		return -1;
	*key_out = line;
	*key_len_out = (size_t)(eq - line);
	*val_out = eq + 1;
	*val_len_out = line_len - *key_len_out - 1;
	return 0;
}

static int kv_matches(const char *key, size_t key_len,
		      const char *expected)
{
	return key_len == strlen(expected) &&
	       !memcmp(key, expected, key_len);
}

static int val_equals(const char *val, size_t val_len,
		      const char *expected)
{
	return val_len == strlen(expected) &&
	       !memcmp(val, expected, val_len);
}

/*
 * Structural pkt-line v1 validation of a batch request.
 *
 * Validates:
 *   Header section (before first delim):
 *   - "version": must be "1"
 *   - "command": must be "preflight_batch" or "materialize_batch"
 *   - "phase": must be "preflight" or "materialize"
 *   - "operation": non-empty string
 *   - "repo_root": optional string
 *
 *   Item sections (between delims, terminated by flush):
 *   - "path": required, non-empty
 *   - "rule_id": required, non-empty
 *   - other item fields accepted
 *
 *   At least one item is required.
 *
 * Returns 1 if valid, 0 if not.
 * On failure, writes a short reason to 'reason'.
 */
static int validate_batch_request(const char *req, size_t req_len,
				  struct strbuf *reason)
{
	size_t pos = 0;
	int has_version = 0, has_command = 0, has_phase = 0;
	int has_operation = 0;
	int nr_items = 0;
	int in_header = 1;
	int has_path = 0, has_rule_id = 0;
	int command_is_preflight = 0, phase_is_preflight = 0;
	int command_is_checkin_convert = 0, phase_is_checkin_convert = 0;

	if (req_len > MAX_VALIDATE_REQUEST_SIZE) {
		strbuf_addstr(reason, "request too large");
		return 0;
	}

	for (;;) {
		const char *line;
		size_t line_len;
		enum pktline_mem_status st;
		const char *key, *val;
		size_t key_len, val_len;

		st = pktline_read_mem(req, req_len, &pos, &line, &line_len);

		if (st == PKTLINE_MEM_ERROR) {
			strbuf_addstr(reason, "malformed pkt-line");
			return 0;
		}

		if (st == PKTLINE_MEM_FLUSH) {
			/* Validate last item if we were in item mode */
			if (!in_header) {
				if (!has_path) {
					strbuf_addstr(reason,
						      "item missing path");
					return 0;
				}
				if (!has_rule_id) {
					strbuf_addstr(reason,
						      "item missing rule_id");
					return 0;
				}
			}
			break;
		}

		if (st == PKTLINE_MEM_DELIM) {
			if (in_header) {
				/* Validate header completeness */
				if (!has_version) {
					strbuf_addstr(reason,
						      "missing version");
					return 0;
				}
				if (!has_command) {
					strbuf_addstr(reason,
						      "missing command");
					return 0;
				}
				if (!has_phase) {
					strbuf_addstr(reason,
						      "missing phase");
					return 0;
				}
				if (!has_operation) {
					strbuf_addstr(reason,
						      "missing operation");
					return 0;
				}
				/* Verify command-phase pairing */
				if (command_is_preflight != phase_is_preflight ||
				    command_is_checkin_convert != phase_is_checkin_convert) {
					strbuf_addstr(reason,
						      "command-phase mismatch");
					return 0;
				}
				in_header = 0;
			} else {
				/* Validate previous item */
				if (!has_path) {
					strbuf_addstr(reason,
						      "item missing path");
					return 0;
				}
				if (!has_rule_id) {
					strbuf_addstr(reason,
						      "item missing rule_id");
					return 0;
				}
			}
			nr_items++;
			has_path = 0;
			has_rule_id = 0;
			continue;
		}

		/* PKTLINE_MEM_DATA */
		if (parse_kv(line, line_len, &key, &key_len,
			     &val, &val_len)) {
			strbuf_addstr(reason, "malformed key=value");
			return 0;
		}

		if (in_header) {
			if (kv_matches(key, key_len, "version")) {
				if (!val_equals(val, val_len, "1")) {
					strbuf_addstr(reason,
						      "version must be 1");
					return 0;
				}
				has_version = 1;
			} else if (kv_matches(key, key_len, "command")) {
				if (!val_equals(val, val_len,
						"preflight_batch") &&
				    !val_equals(val, val_len,
						"materialize_batch") &&
				    !val_equals(val, val_len,
						"checkin_convert_batch")) {
					strbuf_addstr(reason,
						      "command must be "
						      "preflight_batch, "
						      "materialize_batch, or "
						      "checkin_convert_batch");
					return 0;
				}
				command_is_preflight = val_equals(
					val, val_len, "preflight_batch");
				command_is_checkin_convert = val_equals(
					val, val_len, "checkin_convert_batch");
				has_command = 1;
			} else if (kv_matches(key, key_len, "phase")) {
				if (!val_equals(val, val_len, "preflight") &&
				    !val_equals(val, val_len, "materialize") &&
				    !val_equals(val, val_len, "checkin_convert")) {
					strbuf_addstr(reason,
						      "phase must be "
						      "preflight, "
						      "materialize, or "
						      "checkin_convert");
					return 0;
				}
				phase_is_preflight = val_equals(
					val, val_len, "preflight");
				phase_is_checkin_convert = val_equals(
					val, val_len, "checkin_convert");
				has_phase = 1;
			} else if (kv_matches(key, key_len, "operation")) {
				if (!val_len) {
					strbuf_addstr(reason,
						      "operation must be "
						      "non-empty");
					return 0;
				}
				has_operation = 1;
			} else if (kv_matches(key, key_len, "repo_root")) {
				/* optional, accept any value */
			} else {
				/* accept unknown header keys */
			}
		} else {
			/* Item fields */
			if (kv_matches(key, key_len, "path")) {
				if (!val_len) {
					strbuf_addstr(reason,
						      "path must be "
						      "non-empty");
					return 0;
				}
				has_path = 1;
			} else if (kv_matches(key, key_len, "rule_id")) {
				if (!val_len) {
					strbuf_addstr(reason,
						      "rule_id must be "
						      "non-empty");
					return 0;
				}
				has_rule_id = 1;
			} else if (kv_matches(key, key_len, "blob_oid")) {
				if (!val_len) {
					strbuf_addstr(reason,
						      "blob_oid must be "
						      "non-empty");
					return 0;
				}
			} else if (kv_matches(key, key_len, "input_path")) {
				if (!val_len) {
					strbuf_addstr(reason,
						      "input_path must be "
						      "non-empty");
					return 0;
				}
			}
			/* Accept other item fields without validation */
		}
	}

	if (nr_items == 0) {
		strbuf_addstr(reason, "no items");
		return 0;
	}

	if (!has_version) {
		strbuf_addstr(reason, "missing version");
		return 0;
	}

	return 1;
}

/* --- Build pkt-line reply helpers --------------------------------------- */

static void build_ok_reply(struct strbuf *out)
{
	packet_buf_write(out, "status=ok\n");
	packet_buf_flush(out);
}

static void build_rejected_reply(struct strbuf *out, const char *message)
{
	packet_buf_write(out, "status=rejected\n");
	packet_buf_write(out, "message=%s\n", message);
	packet_buf_flush(out);
}

static void build_error_reply(struct strbuf *out, const char *message)
{
	packet_buf_write(out, "status=error\n");
	packet_buf_write(out, "message=%s\n", message);
	packet_buf_flush(out);
}

static int app_cb(void *application_data UNUSED,
		  const char *request, size_t request_len,
		  ipc_server_reply_cb *reply_cb,
		  struct ipc_server_reply_data *reply_data)
{
	struct strbuf reply = STRBUF_INIT;
	int ret;

	if (request_len == 4 && !strncmp(request, "quit", 4))
		return SIMPLE_IPC_QUIT;

	switch (server_args.mode) {
	case REPLY_OK:
		build_ok_reply(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_REJECTED:
		build_rejected_reply(&reply, "mock rejection");
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_ERROR:
		build_error_reply(&reply, "mock error");
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_INVALID_PKT:
		return reply_cb(reply_data,
				"this is not pkt-line at all",
				strlen("this is not pkt-line at all"));

	case REPLY_ECHO:
		return reply_cb(reply_data, request, request_len);

	case REPLY_VALIDATE_REQUEST: {
		struct strbuf reason = STRBUF_INIT;

		if (validate_batch_request(request, request_len,
					   &reason)) {
			build_ok_reply(&reply);
			ret = reply_cb(reply_data, reply.buf, reply.len);
		} else {
			build_error_reply(&reply, reason.buf);
			ret = reply_cb(reply_data, reply.buf, reply.len);
		}
		strbuf_release(&reason);
		strbuf_release(&reply);
		return ret;
	}

	case REPLY_TRAILING_AFTER_FLUSH:
		/* Valid ok reply + extra data after flush */
		build_ok_reply(&reply);
		strbuf_addstr(&reply, "GARBAGE");
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_INVALID_STATUS:
		/* status value not ok|rejected|error */
		packet_buf_write(&reply, "status=maybe\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_MISSING_STATUS:
		/* No status line, just message + flush */
		packet_buf_write(&reply, "message=no status here\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_NO_FLUSH:
		/* status=ok pkt-line but no flush terminator */
		packet_buf_write(&reply, "status=ok\n");
		/* deliberately omit flush */
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_MISSING_MESSAGE:
		/* status=rejected but no message line */
		packet_buf_write(&reply, "status=rejected\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_REORDERED:
		/* message before status (key-order independence test) */
		packet_buf_write(&reply, "message=reordered rejection\n");
		packet_buf_write(&reply, "status=rejected\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_OK_WITH_MESSAGE:
		/* status=ok with optional message (should be accepted) */
		packet_buf_write(&reply, "status=ok\n");
		packet_buf_write(&reply, "message=extra info\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_CONTROL_CHAR: {
		/* status=error with control char (0x01) in message value */
		struct strbuf line = STRBUF_INIT;
		packet_buf_write(&reply, "status=error\n");
		strbuf_addstr(&line, "message=bad");
		strbuf_addch(&line, 0x01);
		strbuf_addstr(&line, "char\n");
		pkt_buf_add_raw(&reply, line.buf, line.len);
		strbuf_release(&line);
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;
	}

	case REPLY_UNKNOWN_KEY:
		/* status=ok + unknown key "extra" */
		packet_buf_write(&reply, "status=ok\n");
		packet_buf_write(&reply, "extra=nope\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_OVERSIZED: {
		/*
		 * Return a reply larger than TEXTIL_EXT_MAX_REPLY_SIZE
		 * (64 KiB).  Generate 65537 bytes of raw padding.
		 * The size guard rejects before parsing.
		 */
		strbuf_addchars(&reply, 'A', 65537);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;
	}

	case REPLY_DUPLICATE_KEY:
		/* status appears twice */
		packet_buf_write(&reply, "status=ok\n");
		packet_buf_write(&reply, "status=rejected\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_MATERIALIZE_OK:
		/* materialize ok with 1 src_path (matches 1-item batch) */
		packet_buf_write(&reply, "status=ok\n");
		packet_buf_delim(&reply);
		packet_buf_write(&reply, "src_path=/tmp/textil/materialize/aa/bb/aabb1234\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_MATERIALIZE_REJECTED:
		/* materialize rejected with message, no src_path */
		packet_buf_write(&reply, "status=rejected\n");
		packet_buf_write(&reply, "message=2 object(s) not available for materialize\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_MATERIALIZE_SRC_PATH_RELATIVE:
		/* materialize ok but src_path is relative (invalid) */
		packet_buf_write(&reply, "status=ok\n");
		packet_buf_delim(&reply);
		packet_buf_write(&reply, "src_path=relative/path/file.bin\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_MATERIALIZE_SRC_PATH_WITH_STATUS_ERROR:
		/* status=error but includes src_path (forbidden) */
		packet_buf_write(&reply, "status=error\n");
		packet_buf_write(&reply, "message=something failed\n");
		packet_buf_delim(&reply);
		packet_buf_write(&reply, "src_path=/tmp/should/not/be/here\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_MATERIALIZE_OK_WITHOUT_SRC_PATH:
		/* materialize status=ok but no delim/src_path (contract violation) */
		packet_buf_write(&reply, "status=ok\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_MATERIALIZE_OK_WITH_MESSAGE:
		/* materialize status=ok with message (forbidden for materialize ok) */
		packet_buf_write(&reply, "status=ok\n");
		packet_buf_write(&reply, "message=should not be here\n");
		packet_buf_delim(&reply);
		packet_buf_write(&reply, "src_path=/tmp/textil/materialize/aa/bb/aabb1234\n");
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;

	case REPLY_MATERIALIZE_CHECKOUT: {
		/*
		 * Parse request to extract item paths, create temp files
		 * with predictable content, return src_paths.
		 */
		size_t pos = 0;
		int in_header = 1;
		int nr_items = 0;
		struct strbuf *item_paths = NULL;
		int alloc_items = 0;
		struct strbuf cur_path = STRBUF_INIT;
		int i;

		/* Parse request to count items and extract paths */
		for (;;) {
			const char *line;
			size_t line_len;
			enum pktline_mem_status st;
			const char *key, *val;
			size_t key_len, val_len;

			st = pktline_read_mem(request, request_len,
					      &pos, &line, &line_len);
			if (st == PKTLINE_MEM_FLUSH || st == PKTLINE_MEM_ERROR)
				break;
			if (st == PKTLINE_MEM_DELIM) {
				if (!in_header && cur_path.len) {
					/* save previous item path */
					ALLOC_GROW(item_paths, nr_items + 1,
						   alloc_items);
					strbuf_init(&item_paths[nr_items], 0);
					strbuf_addbuf(&item_paths[nr_items],
						      &cur_path);
					nr_items++;
				}
				in_header = 0;
				strbuf_reset(&cur_path);
				continue;
			}
			if (st != PKTLINE_MEM_DATA)
				continue;
			if (in_header)
				continue;
			if (!parse_kv(line, line_len, &key, &key_len,
				      &val, &val_len) &&
			    kv_matches(key, key_len, "path"))
				strbuf_add(&cur_path, val, val_len);
		}
		/* Save last item if any */
		if (!in_header && cur_path.len) {
			ALLOC_GROW(item_paths, nr_items + 1, alloc_items);
			strbuf_init(&item_paths[nr_items], 0);
			strbuf_addbuf(&item_paths[nr_items], &cur_path);
			nr_items++;
		}
		strbuf_release(&cur_path);

		if (!nr_items) {
			build_error_reply(&reply,
					  "no items in materialize request");
			ret = reply_cb(reply_data, reply.buf, reply.len);
			strbuf_release(&reply);
			free(item_paths);
			return ret;
		}

		/* Build reply: status=ok + src_paths */
		packet_buf_write(&reply, "status=ok\n");
		for (i = 0; i < nr_items; i++) {
			struct strbuf tmp_path = STRBUF_INIT;
			int tmp_fd;

			strbuf_addf(&tmp_path, "%s/materialize-XXXXXX",
				    getenv("TMPDIR") ? getenv("TMPDIR")
						     : "/tmp");
			tmp_fd = mkstemp(tmp_path.buf);
			if (tmp_fd >= 0) {
				const char *content = "materialized-by-textil\n";
				write_in_full(tmp_fd, content, strlen(content));
				close(tmp_fd);
			}
			packet_buf_delim(&reply);
			packet_buf_write(&reply, "src_path=%s\n",
					 tmp_path.buf);
			strbuf_release(&tmp_path);
			strbuf_release(&item_paths[i]);
		}
		packet_buf_flush(&reply);
		free(item_paths);

		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;
	}

	case REPLY_MATERIALIZE_COUNT_MISMATCH: {
		/*
		 * Return more src_paths than items in the request.
		 * Parse request to count items, then return items+1 paths.
		 */
		size_t pos = 0;
		int in_header = 1;
		int nr_items = 0;
		int i;

		for (;;) {
			const char *line;
			size_t line_len;
			enum pktline_mem_status st;

			st = pktline_read_mem(request, request_len,
					      &pos, &line, &line_len);
			if (st == PKTLINE_MEM_FLUSH || st == PKTLINE_MEM_ERROR)
				break;
			if (st == PKTLINE_MEM_DELIM) {
				if (!in_header)
					nr_items++;
				in_header = 0;
				continue;
			}
		}
		/* Last item (after last delim before flush) */
		if (!in_header)
			nr_items++;

		/* Return nr_items + 1 src_paths (mismatch) */
		packet_buf_write(&reply, "status=ok\n");
		for (i = 0; i < nr_items + 1; i++) {
			packet_buf_delim(&reply);
			packet_buf_write(&reply,
					 "src_path=/tmp/mismatch-%d\n", i);
		}
		packet_buf_flush(&reply);
		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;
	}

	case REPLY_VALIDATE_REQUEST_MATERIALIZE: {
		/*
		 * Validate request structure (including command-phase pairing),
		 * then reply with proper materialize format (ok + 1 src_path).
		 */
		struct strbuf reason = STRBUF_INIT;

		if (validate_batch_request(request, request_len,
					   &reason)) {
			/* Valid: reply with materialize ok + 1 fake src_path */
			packet_buf_write(&reply, "status=ok\n");
			packet_buf_delim(&reply);
			packet_buf_write(&reply,
					 "src_path=/tmp/validate-ok\n");
			packet_buf_flush(&reply);
			ret = reply_cb(reply_data, reply.buf, reply.len);
		} else {
			build_error_reply(&reply, reason.buf);
			ret = reply_cb(reply_data, reply.buf, reply.len);
		}
		strbuf_release(&reason);
		strbuf_release(&reply);
		return ret;
	}

	case REPLY_CHECKIN_CONVERT_CHECKIN: {
		/*
		 * Parse request to extract item paths, create temp files
		 * with predictable LFS pointer content, return src_paths.
		 * Mirror of REPLY_MATERIALIZE_CHECKOUT for checkin_convert.
		 */
		size_t pos = 0;
		int in_header = 1;
		int nr_items = 0;
		struct strbuf *item_paths = NULL;
		int alloc_items = 0;
		struct strbuf cur_path = STRBUF_INIT;
		int i;

		/* Parse request to count items and extract paths */
		for (;;) {
			const char *line;
			size_t line_len;
			enum pktline_mem_status st;
			const char *key, *val;
			size_t key_len, val_len;

			st = pktline_read_mem(request, request_len,
					      &pos, &line, &line_len);
			if (st == PKTLINE_MEM_FLUSH || st == PKTLINE_MEM_ERROR)
				break;
			if (st == PKTLINE_MEM_DELIM) {
				if (!in_header && cur_path.len) {
					ALLOC_GROW(item_paths, nr_items + 1,
						   alloc_items);
					strbuf_init(&item_paths[nr_items], 0);
					strbuf_addbuf(&item_paths[nr_items],
						      &cur_path);
					nr_items++;
				}
				in_header = 0;
				strbuf_reset(&cur_path);
				continue;
			}
			if (st != PKTLINE_MEM_DATA)
				continue;
			if (in_header)
				continue;
			if (!parse_kv(line, line_len, &key, &key_len,
				      &val, &val_len) &&
			    kv_matches(key, key_len, "path"))
				strbuf_add(&cur_path, val, val_len);
		}
		/* Save last item if any */
		if (!in_header && cur_path.len) {
			ALLOC_GROW(item_paths, nr_items + 1, alloc_items);
			strbuf_init(&item_paths[nr_items], 0);
			strbuf_addbuf(&item_paths[nr_items], &cur_path);
			nr_items++;
		}
		strbuf_release(&cur_path);

		if (!nr_items) {
			build_error_reply(&reply,
					  "no items in checkin_convert request");
			ret = reply_cb(reply_data, reply.buf, reply.len);
			strbuf_release(&reply);
			free(item_paths);
			return ret;
		}

		/* Build reply: status=ok + src_paths with LFS pointer content */
		packet_buf_write(&reply, "status=ok\n");
		for (i = 0; i < nr_items; i++) {
			struct strbuf tmp_path = STRBUF_INIT;
			int tmp_fd;

			strbuf_addf(&tmp_path, "%s/checkin-convert-XXXXXX",
				    getenv("TMPDIR") ? getenv("TMPDIR")
						     : "/tmp");
			tmp_fd = mkstemp(tmp_path.buf);
			if (tmp_fd >= 0) {
				/*
				 * Write a predictable LFS pointer.
				 * Use a fixed OID to make test assertions simple.
				 */
				const char *content =
					"version https://git-lfs.github.com/spec/v1\n"
					"oid sha256:0000000000000000000000000000000000000000000000000000000000000000\n"
					"size 42\n";
				write_in_full(tmp_fd, content, strlen(content));
				close(tmp_fd);
			}
			packet_buf_delim(&reply);
			packet_buf_write(&reply, "src_path=%s\n",
					 tmp_path.buf);
			strbuf_release(&tmp_path);
			strbuf_release(&item_paths[i]);
		}
		packet_buf_flush(&reply);
		free(item_paths);

		ret = reply_cb(reply_data, reply.buf, reply.len);
		strbuf_release(&reply);
		return ret;
	}

	case REPLY_VALIDATE_REQUEST_CHECKIN_CONVERT: {
		/*
		 * Validate request structure (including command-phase pairing),
		 * then reply with proper checkin_convert format (ok + 1 src_path).
		 */
		struct strbuf reason = STRBUF_INIT;

		if (validate_batch_request(request, request_len,
					   &reason)) {
			packet_buf_write(&reply, "status=ok\n");
			packet_buf_delim(&reply);
			packet_buf_write(&reply,
					 "src_path=/tmp/validate-cc-ok\n");
			packet_buf_flush(&reply);
			ret = reply_cb(reply_data, reply.buf, reply.len);
		} else {
			build_error_reply(&reply, reason.buf);
			ret = reply_cb(reply_data, reply.buf, reply.len);
		}
		strbuf_release(&reason);
		strbuf_release(&reply);
		return ret;
	}
	}

	BUG("unhandled reply_mode");
}

static int daemon__run_server(void)
{
	struct ipc_server_opts opts = {
		.nr_threads = server_args.nr_threads,
	};

	int ret = ipc_server_run(server_args.path, &opts, app_cb, NULL);
	if (ret == -2)
		error("socket/pipe already in use: '%s'", server_args.path);
	else if (ret == -1)
		error_errno("could not start server on: '%s'", server_args.path);
	return ret;
}

static start_bg_wait_cb bg_wait_cb;

static int bg_wait_cb(const struct child_process *cp UNUSED,
		      void *cb_data UNUSED)
{
	int s = ipc_get_active_state(server_args.path);

	switch (s) {
	case IPC_STATE__LISTENING:
		return 0;
	case IPC_STATE__NOT_LISTENING:
	case IPC_STATE__PATH_NOT_FOUND:
		return 1;
	default:
		return -1;
	}
}

static int daemon__start_server(const char *reply_mode_str)
{
	struct child_process cp = CHILD_PROCESS_INIT;
	enum start_bg_result sbgr;

	strvec_push(&cp.args, "test-tool");
	strvec_push(&cp.args, "textil-ext-executor-server");
	strvec_push(&cp.args, "run-daemon");
	strvec_pushf(&cp.args, "--name=%s", server_args.path);
	strvec_pushf(&cp.args, "--threads=%d", server_args.nr_threads);
	if (reply_mode_str)
		strvec_pushf(&cp.args, "--reply-mode=%s", reply_mode_str);

	cp.no_stdin = 1;
	cp.no_stdout = 1;
	cp.no_stderr = 1;

	sbgr = start_bg_command(&cp, bg_wait_cb, NULL, server_args.max_wait_sec);

	switch (sbgr) {
	case SBGR_READY:
		return 0;
	default:
	case SBGR_ERROR:
	case SBGR_CB_ERROR:
		return error("daemon failed to start");
	case SBGR_TIMEOUT:
		return error("daemon not online yet");
	case SBGR_DIED:
		return error("daemon terminated");
	}
}

static int client__probe_server(void)
{
	enum ipc_active_state s = ipc_get_active_state(server_args.path);

	switch (s) {
	case IPC_STATE__LISTENING:
		return 0;
	case IPC_STATE__NOT_LISTENING:
		return error("no server listening at '%s'", server_args.path);
	case IPC_STATE__PATH_NOT_FOUND:
		return error("path not found '%s'", server_args.path);
	default:
		return error("other error for '%s'", server_args.path);
	}
}

static int client__stop_server(void)
{
	struct strbuf buf = STRBUF_INIT;
	struct ipc_client_connect_options options
		= IPC_CLIENT_CONNECT_OPTIONS_INIT;
	const char *quit_cmd = "quit";
	int ret;
	time_t time_limit, now;

	options.wait_if_busy = 1;
	options.wait_if_not_found = 0;

	ret = ipc_client_send_command(server_args.path, &options,
				      quit_cmd, strlen(quit_cmd), &buf);
	strbuf_release(&buf);

	if (ret)
		return error("failed to send quit to '%s'", server_args.path);

	time(&time_limit);
	time_limit += server_args.max_wait_sec;

	for (;;) {
		sleep_millisec(100);
		if (ipc_get_active_state(server_args.path)
		    != IPC_STATE__LISTENING)
			return 0;
		time(&now);
		if (now > time_limit)
			return error("daemon has not shutdown yet");
	}
}

int cmd__textil_ext_executor_server(int argc, const char **argv)
{
	const char *reply_mode_str = NULL;

	const char * const usage[] = {
		N_("test-tool textil-ext-executor-server <subcommand> [<options>]"),
		NULL
	};

	struct option options[] = {
		OPT_STRING(0, "name", &server_args.path, N_("name"),
			   N_("socket/pipe path")),
		OPT_STRING(0, "reply-mode", &reply_mode_str, N_("mode"),
			   N_("ok, rejected, error, invalid-pkt, echo, validate-request")),
		OPT_INTEGER(0, "threads", &server_args.nr_threads,
			    N_("server threads")),
		OPT_INTEGER(0, "max-wait", &server_args.max_wait_sec,
			    N_("seconds to wait")),
		OPT_END()
	};

	if (argc < 2)
		usage_with_options(usage, options);

	if (argc == 2 && !strcmp(argv[1], "SUPPORTS_SIMPLE_IPC"))
		return 0;

	const char *subcmd = argv[1];

	argc--;
	argv++;
	argc = parse_options(argc, argv, NULL, options, usage, 0);

	if (reply_mode_str)
		server_args.mode = parse_reply_mode(reply_mode_str);

	if (!strcmp(subcmd, "run-daemon"))
		return !!daemon__run_server();

	if (!strcmp(subcmd, "start-daemon"))
		return !!daemon__start_server(reply_mode_str);

	if (!strcmp(subcmd, "is-active"))
		return !!client__probe_server();

	if (!strcmp(subcmd, "stop-daemon")) {
		if (client__probe_server())
			return 1;
		return !!client__stop_server();
	}

	/*
	 * send-materialize: invoke textil_ext_execute_materialize_batch()
	 * with a fake 1-item batch.
	 * Uses TEXTIL_GIT_EXT_ENDPOINT from env (must be set).
	 * Prints executor status, src_paths, and any error message to stdout.
	 */
	if (!strcmp(subcmd, "send-materialize")) {
		struct textil_ext_takeover_batch batch;
		struct textil_ext_takeover_item item;
		struct string_list src_paths = STRING_LIST_INIT_DUP;
		struct strbuf err_buf = STRBUF_INIT;
		enum textil_ext_executor_status st;
		int i;

		memset(&batch, 0, sizeof(batch));
		memset(&item, 0, sizeof(item));

		item.path = xstrdup("test/a.bin");
		item.rule_id = "lfs-takeover";
		item.attr_filter = xstrdup("lfs");
		item.blob_oid = xstrdup("aabbccdd00112233445566778899aabbccddeeff");
		item.is_regular_file = 1;
		item.strict = 1;
		item.capabilities = NULL;
		item.nr_capabilities = 0;

		batch.phase = TEXTIL_EXT_EXEC_PHASE_MATERIALIZE;
		batch.operation = "checkout";
		batch.repo_root = "/tmp/fake-repo";
		batch.items = &item;
		batch.nr_items = 1;

		st = textil_ext_execute_materialize_batch(&batch, &src_paths,
							  &err_buf);

		switch (st) {
		case TEXTIL_EXT_EXECUTOR_OK:
			printf("status=ok\n");
			break;
		case TEXTIL_EXT_EXECUTOR_REJECTED:
			printf("status=rejected\n");
			break;
		case TEXTIL_EXT_EXECUTOR_NOT_IMPLEMENTED:
			printf("status=not-implemented\n");
			break;
		case TEXTIL_EXT_EXECUTOR_ERROR:
			printf("status=error\n");
			break;
		}
		for (i = 0; i < src_paths.nr; i++)
			printf("src_path=%s\n", src_paths.items[i].string);
		if (err_buf.len)
			printf("message=%s\n", err_buf.buf);

		free(item.path);
		free(item.attr_filter);
		free(item.blob_oid);
		string_list_clear(&src_paths, 0);
		strbuf_release(&err_buf);
		return (st != TEXTIL_EXT_EXECUTOR_OK) ? 1 : 0;
	}

	/*
	 * send-preflight-wrong-phase: call textil_ext_execute_takeover_batch()
	 * with phase=MATERIALIZE.  This is a programming error and must
	 * trigger BUG() / SIGABRT.  Used to verify the preflight-only
	 * API contract.
	 */
	if (!strcmp(subcmd, "send-preflight-wrong-phase")) {
		struct textil_ext_takeover_batch batch;
		struct textil_ext_takeover_item item;
		struct strbuf err_buf = STRBUF_INIT;

		memset(&batch, 0, sizeof(batch));
		memset(&item, 0, sizeof(item));

		item.path = xstrdup("test/a.bin");
		item.rule_id = "lfs-takeover";
		item.attr_filter = xstrdup("lfs");
		item.blob_oid = xstrdup("aabbccdd00112233445566778899aabbccddeeff");
		item.is_regular_file = 1;
		item.strict = 1;
		item.capabilities = NULL;
		item.nr_capabilities = 0;

		/* Deliberately wrong phase: materialize instead of preflight */
		batch.phase = TEXTIL_EXT_EXEC_PHASE_MATERIALIZE;
		batch.operation = "checkout";
		batch.repo_root = "/tmp/fake-repo";
		batch.items = &item;
		batch.nr_items = 1;

		/* This must BUG() and abort — should never return */
		textil_ext_execute_takeover_batch(&batch, &err_buf);

		/* If we reach here, the BUG guard is broken */
		die("BUG guard did not fire for non-preflight phase");
	}

	/*
	 * send-checkin-convert: invoke textil_ext_execute_checkin_convert_batch()
	 * with a fake 1-item batch.
	 * Uses TEXTIL_GIT_EXT_ENDPOINT from env (must be set).
	 * Prints executor status, src_paths, and any error message to stdout.
	 */
	if (!strcmp(subcmd, "send-checkin-convert")) {
		struct textil_ext_takeover_batch batch;
		struct textil_ext_takeover_item item;
		struct string_list src_paths = STRING_LIST_INIT_DUP;
		struct strbuf err_buf = STRBUF_INIT;
		enum textil_ext_executor_status st;
		struct strbuf tmp_input = STRBUF_INIT;
		int tmp_fd, i;

		memset(&batch, 0, sizeof(batch));
		memset(&item, 0, sizeof(item));

		/* Create a temp input file for the checkin_convert */
		strbuf_addf(&tmp_input, "%s/cc-input-XXXXXX",
			    getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
		tmp_fd = mkstemp(tmp_input.buf);
		if (tmp_fd >= 0) {
			const char *data = "fake-binary-content-for-test";
			write_in_full(tmp_fd, data, strlen(data));
			close(tmp_fd);
		}

		item.path = xstrdup("test/a.bin");
		item.rule_id = "lfs-takeover";
		item.attr_filter = xstrdup("lfs");
		item.blob_oid = NULL;
		item.input_path = strbuf_detach(&tmp_input, NULL);
		item.is_regular_file = 1;
		item.strict = 1;
		item.capabilities = NULL;
		item.nr_capabilities = 0;

		batch.phase = TEXTIL_EXT_EXEC_PHASE_CHECKIN_CONVERT;
		batch.operation = "checkin";
		batch.repo_root = "/tmp/fake-repo";
		batch.items = &item;
		batch.nr_items = 1;

		st = textil_ext_execute_checkin_convert_batch(&batch, &src_paths,
							      &err_buf);

		switch (st) {
		case TEXTIL_EXT_EXECUTOR_OK:
			printf("status=ok\n");
			break;
		case TEXTIL_EXT_EXECUTOR_REJECTED:
			printf("status=rejected\n");
			break;
		case TEXTIL_EXT_EXECUTOR_NOT_IMPLEMENTED:
			printf("status=not-implemented\n");
			break;
		case TEXTIL_EXT_EXECUTOR_ERROR:
			printf("status=error\n");
			break;
		}
		for (i = 0; i < src_paths.nr; i++)
			printf("src_path=%s\n", src_paths.items[i].string);
		if (err_buf.len)
			printf("message=%s\n", err_buf.buf);

		if (item.input_path)
			unlink(item.input_path);
		free(item.path);
		free(item.attr_filter);
		free(item.input_path);
		string_list_clear(&src_paths, 0);
		strbuf_release(&err_buf);
		return (st != TEXTIL_EXT_EXECUTOR_OK) ? 1 : 0;
	}

	/*
	 * send-checkin-convert-wrong-phase: call textil_ext_execute_checkin_convert_batch()
	 * with phase=PREFLIGHT.  This is a programming error and must
	 * trigger BUG() / exit(99).
	 */
	if (!strcmp(subcmd, "send-checkin-convert-wrong-phase")) {
		struct textil_ext_takeover_batch batch;
		struct textil_ext_takeover_item item;
		struct string_list src_paths = STRING_LIST_INIT_DUP;
		struct strbuf err_buf = STRBUF_INIT;

		memset(&batch, 0, sizeof(batch));
		memset(&item, 0, sizeof(item));

		item.path = xstrdup("test/a.bin");
		item.rule_id = "lfs-takeover";
		item.attr_filter = xstrdup("lfs");
		item.blob_oid = NULL;
		item.input_path = xstrdup("/tmp/fake-input");
		item.is_regular_file = 1;
		item.strict = 1;
		item.capabilities = NULL;
		item.nr_capabilities = 0;

		/* Deliberately wrong phase: preflight instead of checkin_convert */
		batch.phase = TEXTIL_EXT_EXEC_PHASE_PREFLIGHT;
		batch.operation = "checkin";
		batch.repo_root = "/tmp/fake-repo";
		batch.items = &item;
		batch.nr_items = 1;

		/* This must BUG() and abort — should never return */
		textil_ext_execute_checkin_convert_batch(&batch, &src_paths, &err_buf);

		/* If we reach here, the BUG guard is broken */
		die("BUG guard did not fire for non-checkin_convert phase");
	}

	/*
	 * send-materialize-wrong-phase: call textil_ext_execute_materialize_batch()
	 * with phase=PREFLIGHT.  This is a programming error and must
	 * trigger BUG() / exit(99).  Used to verify the materialize-only
	 * API contract (symmetric with send-preflight-wrong-phase).
	 */
	if (!strcmp(subcmd, "send-materialize-wrong-phase")) {
		struct textil_ext_takeover_batch batch;
		struct textil_ext_takeover_item item;
		struct string_list src_paths = STRING_LIST_INIT_DUP;
		struct strbuf err_buf = STRBUF_INIT;

		memset(&batch, 0, sizeof(batch));
		memset(&item, 0, sizeof(item));

		item.path = xstrdup("test/a.bin");
		item.rule_id = "lfs-takeover";
		item.attr_filter = xstrdup("lfs");
		item.blob_oid = xstrdup("aabbccdd00112233445566778899aabbccddeeff");
		item.is_regular_file = 1;
		item.strict = 1;
		item.capabilities = NULL;
		item.nr_capabilities = 0;

		/* Deliberately wrong phase: preflight instead of materialize */
		batch.phase = TEXTIL_EXT_EXEC_PHASE_PREFLIGHT;
		batch.operation = "checkout";
		batch.repo_root = "/tmp/fake-repo";
		batch.items = &item;
		batch.nr_items = 1;

		/* This must BUG() and abort — should never return */
		textil_ext_execute_materialize_batch(&batch, &src_paths, &err_buf);

		/* If we reach here, the BUG guard is broken */
		die("BUG guard did not fire for non-materialize phase");
	}

	die("unknown subcommand: '%s'", subcmd);
}

#endif /* SUPPORTS_SIMPLE_IPC */
