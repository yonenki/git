/*
 * Copyright (c) 2011, Google Inc.
 */

#include "git-compat-util.h"
#include "convert.h"
#include "environment.h"
#include "repository.h"
#include "odb.h"
#include "odb/source.h"
#include "odb/streaming.h"
#include "replace-object.h"
#include "object-file.h"
#include "object-file-convert.h"
#include "hex.h"

#define FILTER_BUFFER (1024*16)

/*****************************************************************
 *
 * Filtered stream
 *
 *****************************************************************/

struct odb_filtered_read_stream {
	struct odb_read_stream base;
	struct odb_read_stream *upstream;
	struct stream_filter *filter;
	char ibuf[FILTER_BUFFER];
	char obuf[FILTER_BUFFER];
	int i_end, i_ptr;
	int o_end, o_ptr;
	int input_finished;
};

static int close_istream_filtered(struct odb_read_stream *_fs)
{
	struct odb_filtered_read_stream *fs = (struct odb_filtered_read_stream *)_fs;
	free_stream_filter(fs->filter);
	return odb_read_stream_close(fs->upstream);
}

static ssize_t read_istream_filtered(struct odb_read_stream *_fs, char *buf,
				     size_t sz)
{
	struct odb_filtered_read_stream *fs = (struct odb_filtered_read_stream *)_fs;
	size_t filled = 0;

	while (sz) {
		/* do we already have filtered output? */
		if (fs->o_ptr < fs->o_end) {
			size_t to_move = fs->o_end - fs->o_ptr;
			if (sz < to_move)
				to_move = sz;
			memcpy(buf + filled, fs->obuf + fs->o_ptr, to_move);
			fs->o_ptr += to_move;
			sz -= to_move;
			filled += to_move;
			continue;
		}
		fs->o_end = fs->o_ptr = 0;

		/* do we have anything to feed the filter with? */
		if (fs->i_ptr < fs->i_end) {
			size_t to_feed = fs->i_end - fs->i_ptr;
			size_t to_receive = FILTER_BUFFER;
			if (stream_filter(fs->filter,
					  fs->ibuf + fs->i_ptr, &to_feed,
					  fs->obuf, &to_receive))
				return -1;
			fs->i_ptr = fs->i_end - to_feed;
			fs->o_end = FILTER_BUFFER - to_receive;
			continue;
		}

		/* tell the filter to drain upon no more input */
		if (fs->input_finished) {
			size_t to_receive = FILTER_BUFFER;
			if (stream_filter(fs->filter,
					  NULL, NULL,
					  fs->obuf, &to_receive))
				return -1;
			fs->o_end = FILTER_BUFFER - to_receive;
			if (!fs->o_end)
				break;
			continue;
		}
		fs->i_end = fs->i_ptr = 0;

		/* refill the input from the upstream */
		if (!fs->input_finished) {
			fs->i_end = odb_read_stream_read(fs->upstream, fs->ibuf, FILTER_BUFFER);
			if (fs->i_end < 0)
				return -1;
			if (fs->i_end)
				continue;
		}
		fs->input_finished = 1;
	}
	return filled;
}

static struct odb_read_stream *attach_stream_filter(struct odb_read_stream *st,
						    struct stream_filter *filter)
{
	struct odb_filtered_read_stream *fs;

	CALLOC_ARRAY(fs, 1);
	fs->base.close = close_istream_filtered;
	fs->base.read = read_istream_filtered;
	fs->upstream = st;
	fs->filter = filter;
	fs->base.size = -1; /* unknown */
	fs->base.type = st->type;

	return &fs->base;
}

void odb_inflate_reader_init(struct odb_inflate_reader *reader, int fd,
			     off_t offset, off_t end)
{
	memset(reader, 0, sizeof(*reader));
	reader->fd = fd;
	reader->pos = offset;
	reader->end = end;
	reader->status = Z_OK;
	git_inflate_init(&reader->z);
}

ssize_t odb_inflate_reader_read(struct odb_inflate_reader *reader, void *buf,
				size_t len)
{
	size_t total = 0;

	if (!len || reader->status == Z_STREAM_END)
		return 0;
	if (reader->status != Z_OK)
		return -1;
	while (total < len) {
		size_t before_in, before_out;
		int status;

		if (!reader->z.avail_in && reader->pos < reader->end) {
			size_t n = sizeof(reader->input);
			if ((uintmax_t)(reader->end - reader->pos) < n)
				n = reader->end - reader->pos;
			if (pread_in_full(reader->fd, reader->input, n, reader->pos) != (ssize_t)n)
				goto bad;
			reader->pos += n;
			reader->z.next_in = reader->input;
			reader->z.avail_in = n;
		}
		reader->z.next_out = (unsigned char *)buf + total;
		reader->z.avail_out = len - total;
		before_in = reader->z.avail_in;
		before_out = reader->z.avail_out;
		status = git_inflate(&reader->z, Z_NO_FLUSH);
		total += before_out - reader->z.avail_out;
		if (status == Z_STREAM_END) {
			reader->status = status;
			return total;
		}
		if ((status != Z_OK && status != Z_BUF_ERROR) ||
		    (before_in == reader->z.avail_in &&
		     before_out == reader->z.avail_out))
			goto bad;
	}
	return total;
bad:
	reader->status = Z_DATA_ERROR;
	return -1;
}

void odb_inflate_reader_release(struct odb_inflate_reader *reader)
{
	git_inflate_end(&reader->z);
}

/*****************************************************************************
 * static helpers variables and functions for users of streaming interface
 *****************************************************************************/

static int istream_source(struct odb_read_stream **out,
			  struct object_database *odb,
			  const struct object_id *oid, unsigned flags)
{
	struct odb_source *source;
	struct object_info oi = OBJECT_INFO_INIT;

	if (!odb_source_read_object_stream(out, odb->inmemory_objects, oid))
		return 0;
	odb_prepare_alternates(odb);
	for (source = odb->sources; source; source = source->next)
		if (!odb_source_read_object_stream(out, source, oid))
			return 0;

	/*
	 * Retain ODB reprepare, alternates, promisor and corruption handling,
	 * but request discovery only. Never retry with oi.contentp: that used
	 * to silently turn a streaming read into a full incore allocation.
	 */
	if (odb_read_object_info_extended(odb, oid, &oi, flags))
		return -1;
	if (!odb_source_read_object_stream(out, odb->inmemory_objects, oid))
		return 0;
	for (source = odb->sources; source; source = source->next)
		if (!odb_source_read_object_stream(out, source, oid))
			return 0;
	return -1;
}

/****************************************************************
 * Users of streaming interface
 ****************************************************************/

int odb_read_stream_close(struct odb_read_stream *st)
{
	int r = st->close(st);
	free(st);
	return r;
}

ssize_t odb_read_stream_read(struct odb_read_stream *st, void *buf, size_t sz)
{
	return st->read(st, buf, sz);
}

static struct odb_read_stream *open_istream_raw(struct object_database *odb,
					       const struct object_id *oid, unsigned flags)
{
	struct odb_read_stream *st;
	struct object_id storage_oid;

	if (repo_oid_to_algop(odb->repo, oid, odb->repo->hash_algo, &storage_oid) ||
	    istream_source(&st, odb, &storage_oid, flags))
		return NULL;
	return st;
}

struct odb_read_stream *odb_read_stream_open_raw(struct object_database *odb,
						 const struct object_id *oid)
{
	return open_istream_raw(odb, oid, 0);
}

struct odb_read_stream *odb_read_stream_open(struct object_database *odb,
					     const struct object_id *oid,
					     struct stream_filter *filter)
{
	const struct object_id *real = lookup_replace_object(odb->repo, oid);
	struct odb_read_stream *st = open_istream_raw(odb, real, OBJECT_INFO_DIE_IF_CORRUPT);

	if (!st)
		return NULL;

	if (filter) {
		/* Add "&& !is_null_stream_filter(filter)" for performance */
		struct odb_read_stream *nst = attach_stream_filter(st, filter);
		if (!nst) {
			odb_read_stream_close(st);
			return NULL;
		}
		st = nst;
	}

	return st;
}

ssize_t odb_write_stream_read(struct odb_write_stream *st, void *buf, size_t sz)
{
	return st->read(st, buf, sz);
}

void odb_write_stream_release(struct odb_write_stream *st)
{
	free(st->data);
}

int odb_stream_blob_to_fd(struct object_database *odb,
			  int fd,
			  const struct object_id *oid,
			  struct stream_filter *filter,
			  int can_seek)
{
	struct odb_read_stream *st;
	ssize_t kept = 0;
	int result = -1;
	struct git_hash_ctx hash;
	struct object_id actual;
	const struct object_id *real = lookup_replace_object(odb->repo, oid);
	const struct git_hash_algo *algo = &hash_algos[real->algo];
	char header[MAX_HEADER_LEN];

	st = odb_read_stream_open(odb, oid, filter);
	if (!st) {
		if (filter)
			free_stream_filter(filter);
		return result;
	}
	if (st->type != OBJ_BLOB)
		goto close_and_exit;
	if (!filter) {
		int header_len = format_object_header(header, sizeof(header),
						      OBJ_BLOB, st->size);
		algo->init_fn(&hash);
		git_hash_update(&hash, header, header_len);
	}
	for (;;) {
		char buf[1024 * 16];
		ssize_t wrote, holeto;
		ssize_t readlen = odb_read_stream_read(st, buf, sizeof(buf));

		if (readlen < 0)
			goto close_and_exit;
		if (!readlen)
			break;
		if (!filter)
			git_hash_update(&hash, buf, readlen);
		if (can_seek && sizeof(buf) == readlen) {
			for (holeto = 0; holeto < readlen; holeto++)
				if (buf[holeto])
					break;
			if (readlen == holeto) {
				kept += holeto;
				continue;
			}
		}

		if (kept && lseek(fd, kept, SEEK_CUR) == (off_t) -1)
			goto close_and_exit;
		else
			kept = 0;
		wrote = write_in_full(fd, buf, readlen);

		if (wrote < 0)
			goto close_and_exit;
	}
	if (kept && (lseek(fd, kept - 1, SEEK_CUR) == (off_t) -1 ||
		     xwrite(fd, "", 1) != 1))
		goto close_and_exit;
	if (!filter) {
		git_hash_final_oid(&actual, &hash);
		if (!oideq(&actual, real)) {
			error("blob %s has incorrect object hash", oid_to_hex(real));
			goto close_and_exit;
		}
	}
	result = 0;

 close_and_exit:
	odb_read_stream_close(st);
	return result;
}

struct read_object_fd_data {
	int fd;
	size_t remaining;
};

static ssize_t read_object_fd(struct odb_write_stream *stream,
			      unsigned char *buf, size_t len)
{
	struct read_object_fd_data *data = stream->data;
	ssize_t read_result;
	size_t count;

	if (stream->is_finished)
		return 0;

	count = data->remaining < len ? data->remaining : len;
	read_result = read_in_full(data->fd, buf, count);
	if (read_result < 0 || (size_t)read_result != count)
		return -1;

	data->remaining -= count;
	if (!data->remaining)
		stream->is_finished = 1;

	return read_result;
}

void odb_write_stream_from_fd(struct odb_write_stream *stream, int fd,
			      size_t size)
{
	struct read_object_fd_data *data;

	CALLOC_ARRAY(data, 1);
	data->fd = fd;
	data->remaining = size;

	stream->data = data;
	stream->read = read_object_fd;
	stream->is_finished = 0;
}
