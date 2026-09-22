/*
 * patch-delta.c:
 * recreate a buffer from a source and the delta produced by diff-delta.c
 *
 * (C) 2005 Nicolas Pitre <nico@fluxnic.net>
 *
 * This code is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */

#include "git-compat-util.h"
#include "delta.h"
#include "odb/streaming.h"

static int parse_delta_copy(unsigned char cmd, const unsigned char **datap,
			    const unsigned char *top, size_t *offset, size_t *size)
{
	const unsigned char *data = *datap;
	*offset = *size = 0;
#define PARSE_CP_PARAM(bit, var, shift) do { \
	if (cmd & (bit)) { \
		if (data >= top) \
			return -1; \
		*(var) |= (size_t)*data++ << (shift); \
	} } while (0)
	PARSE_CP_PARAM(0x01, offset, 0);
	PARSE_CP_PARAM(0x02, offset, 8);
	PARSE_CP_PARAM(0x04, offset, 16);
	PARSE_CP_PARAM(0x08, offset, 24);
	PARSE_CP_PARAM(0x10, size, 0);
	PARSE_CP_PARAM(0x20, size, 8);
	PARSE_CP_PARAM(0x40, size, 16);
#undef PARSE_CP_PARAM
	if (!*size)
		*size = 0x10000;
	*datap = data;
	return 0;
}

static int delta_copy_fits(size_t offset, size_t size, size_t base_size,
			   size_t remaining)
{
	return offset <= base_size && size <= base_size - offset &&
		size <= remaining;
}

void *patch_delta(const void *src_buf, size_t src_size,
		  const void *delta_buf, size_t delta_size,
		  size_t *dst_size)
{
	const unsigned char *data, *top;
	unsigned char *dst_buf, *out, cmd;
	size_t size;

	if (delta_size < DELTA_SIZE_MIN)
		return NULL;

	data = delta_buf;
	top = (const unsigned char *) delta_buf + delta_size;

	/* make sure the orig file size matches what we expect */
	size = get_delta_hdr_size(&data, top);
	if (size != src_size)
		return NULL;

	/* now the result size */
	size = get_delta_hdr_size(&data, top);
	dst_buf = xmallocz(size);

	out = dst_buf;
	while (data < top) {
		cmd = *data++;
		if (cmd & 0x80) {
			size_t cp_off, cp_size;
			if (parse_delta_copy(cmd, &data, top, &cp_off, &cp_size) ||
			    !delta_copy_fits(cp_off, cp_size, src_size, size))
				goto bad_length;
			memcpy(out, (char *) src_buf + cp_off, cp_size);
			out += cp_size;
			size -= cp_size;
		} else if (cmd) {
			if (cmd > size || cmd > top - data)
				goto bad_length;
			memcpy(out, data, cmd);
			out += cmd;
			data += cmd;
			size -= cmd;
		} else {
			/*
			 * cmd == 0 is reserved for future encoding
			 * extensions. In the mean time we must fail when
			 * encountering them (might be data corruption).
			 */
			error("unexpected delta opcode 0");
			goto bad;
		}
	}

	/* sanity check */
	if (data != top || size != 0) {
		bad_length:
		error("delta replay has gone wild");
		bad:
		free(dst_buf);
		return NULL;
	}

	*dst_size = out - dst_buf;
	return dst_buf;
}

struct delta_stream_reader {
	struct odb_read_stream *stream;
	size_t pos, len, remaining;
	unsigned char buffer[16384];
};

static int read_delta_bytes(struct delta_stream_reader *reader, void *buf, size_t len)
{
	unsigned char *out = buf;

	if (len > reader->remaining)
		return -1;
	while (len) {
		size_t n;

		if (reader->pos == reader->len) {
			ssize_t read;
			n = reader->remaining < sizeof(reader->buffer) ?
				reader->remaining : sizeof(reader->buffer);
			read = odb_read_stream_read(reader->stream, reader->buffer, n);
			if (read <= 0)
				return -1;
			reader->pos = 0;
			reader->len = read;
		}
		n = reader->len - reader->pos;
		if (n > len)
			n = len;
		memcpy(out, reader->buffer + reader->pos, n);
		reader->pos += n;
		reader->remaining -= n;
		out += n;
		len -= n;
	}
	return 0;
}

static int read_delta_size(struct delta_stream_reader *reader, size_t *size)
{
	unsigned char header[(bitsizeof(size_t) + 6) / 7];
	const unsigned char *data = header;
	size_t n;

	for (n = 0; n < sizeof(header); n++) {
		if (read_delta_bytes(reader, header + n, 1) ||
		    (size_t)(header[n] & 0x7f) > (SIZE_MAX >> (n * 7)))
			return -1;
		if (!(header[n] & 0x80)) {
			*size = get_delta_hdr_size(&data, header + n + 1);
			return 0;
		}
	}
	return -1;
}

enum patch_delta_result patch_delta_to_file(int base_fd, size_t base_size,
			struct odb_read_stream *delta, int result_fd,
			size_t *result_size)
{
	struct delta_stream_reader reader = {
		.stream = delta,
		.remaining = delta->size,
	};
	unsigned char buffer[16384], extra;
	size_t source_size, remaining;

	if (delta->size < DELTA_SIZE_MIN ||
	    read_delta_size(&reader, &source_size) ||
	    source_size != base_size ||
	    read_delta_size(&reader, result_size))
		goto bad_length;
	remaining = *result_size;
	while (reader.remaining) {
		unsigned char cmd;

		if (read_delta_bytes(&reader, &cmd, 1))
			goto bad_length;
		if (cmd & 0x80) {
			unsigned char params[7];
			const unsigned char *data = params;
			size_t n = 0, offset, size;

			for (unsigned bit = 1; bit <= 0x40; bit <<= 1)
				if (cmd & bit) {
					if (read_delta_bytes(&reader, params + n, 1))
						goto bad_length;
					n++;
				}
			if (parse_delta_copy(cmd, &data, params + n, &offset, &size) ||
			    !delta_copy_fits(offset, size, base_size, remaining))
				goto bad_length;
			remaining -= size;
			while (size) {
				n = size < sizeof(buffer) ? size : sizeof(buffer);
				if (pread_in_full(base_fd, buffer, n, offset) != (ssize_t)n ||
				    write_in_full(result_fd, buffer, n) != (ssize_t)n) {
					error_errno("unable to copy delta base");
					return PATCH_DELTA_IO;
				}
				offset += n;
				size -= n;
			}
		} else if (cmd) {
			if (cmd > remaining || read_delta_bytes(&reader, buffer, cmd))
				goto bad_length;
			if (write_in_full(result_fd, buffer, cmd) != cmd) {
				error_errno("unable to write delta literal");
				return PATCH_DELTA_IO;
			}
			remaining -= cmd;
		} else {
			error("unexpected delta opcode 0");
			return PATCH_DELTA_INVALID;
		}
	}
	if (remaining || odb_read_stream_read(delta, &extra, 1) != 0)
		goto bad_length;
	return PATCH_DELTA_OK;

bad_length:
	error("delta replay has gone wild");
	return PATCH_DELTA_INVALID;
}
