#ifndef ENTRY_H
#define ENTRY_H

#include "convert.h"

struct cache_entry;
struct index_state;

struct checkout {
	struct index_state *istate;
	const char *base_dir;
	int base_dir_len;
	const char *super_prefix;
	struct delayed_checkout *delayed_checkout;
	/*
	 * Textil: entries of the index this checkout started from that it
	 * replaces, consulted only with textil_records_index (see
	 * textil_checkout_replaced_mtime()).
	 */
	struct index_state *textil_previous_index;
	struct checkout_metadata meta;
	unsigned force:1,
		 quiet:1,
		 not_new:1,
		 clone:1,
		 refresh_cache:1,
		 /*
		  * Textil: on success, written outputs' stat data is recorded in
		  * the repository's on-disk index (see
		  * textil_index_is_repository_index()).
		  */
		 textil_records_index:1;
};
#define CHECKOUT_INIT { .base_dir = "" }

/*
 * Textil: when the previous index has a stage-0 entry for ce's path that
 * records a different object, store that entry's mtime second in *sec and
 * return 1. A new output must not take that second: if the index is never
 * written, a same-size output would stat-match the stale entry.
 */
int textil_checkout_replaced_mtime(const struct checkout *state,
				   const struct cache_entry *ce, uint32_t *sec);

#define TEMPORARY_FILENAME_LENGTH 25
/*
 * Write the contents from ce out to the working tree.
 *
 * When topath[] is not NULL, instead of writing to the working tree
 * file named by ce, a temporary file is created by this function and
 * its name is returned in topath[], which must be able to hold at
 * least TEMPORARY_FILENAME_LENGTH bytes long.
 *
 * With checkout_entry_ca(), callers can optionally pass a preloaded
 * conv_attrs struct (to avoid reloading it), when ce refers to a
 * regular file. If ca is NULL, the attributes will be loaded
 * internally when (and if) needed.
 */
int checkout_entry_ca(struct cache_entry *ce, struct conv_attrs *ca,
		      const struct checkout *state, char *topath,
		      int *nr_checkouts);
static inline int checkout_entry(struct cache_entry *ce,
				 const struct checkout *state, char *topath,
				 int *nr_checkouts)
{
	return checkout_entry_ca(ce, NULL, state, topath, nr_checkouts);
}

void enable_delayed_checkout(struct checkout *state);
int finish_delayed_checkout(struct checkout *state, int show_progress);

/*
 * Unlink the last component and schedule the leading directories for
 * removal, such that empty directories get removed.
 *
 * The "super_prefix" is either NULL, or the "--super-prefix" passed
 * down from "read-tree" et al.
 */
void unlink_entry(const struct cache_entry *ce, const char *super_prefix);

void *read_blob_entry(const struct cache_entry *ce, size_t *size);
int fstat_checkout_output(int fd, const struct checkout *state, struct stat *st);
void update_ce_after_write(const struct checkout *state, struct cache_entry *ce,
			   struct stat *st);

/*
 * Calls the correct function out of {unlink,rmdir}_or_warn based on
 * the supplied file mode.
 */
int remove_or_warn(unsigned int mode, const char *path);

#endif /* ENTRY_H */
