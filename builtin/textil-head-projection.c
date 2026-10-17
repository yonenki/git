#define USE_THE_REPOSITORY_VARIABLE
#include "builtin.h"
#include "attr.h"
#include "config.h"
#include "gettext.h"
#include "hex.h"
#include "object-name.h"
#include "odb.h"
#include "parse-options.h"
#include "pathspec.h"
#include "refs.h"
#include "replace-object.h"
#include "tree.h"

static const char * const textil_head_projection_usage[] = {
	N_("git textil-head-projection (--identity-only | --describe [--target=<object-oid>])"),
	NULL
};

static int compare_replacements(const void *va, const void *vb)
{
	const struct replace_object *a = *(const struct replace_object * const *)va;
	const struct replace_object *b = *(const struct replace_object * const *)vb;

	return oidcmp(&a->original.oid, &b->original.oid);
}

/* Git's process-local map is initialized once and reused by every ODB read. */
static void capture_replacements(struct repository *repo,
				 struct git_hash_ctx *context)
{
	struct replace_object **entries, *entry;
	struct oidmap_iter iter;
	size_t nr, i = 0;
	char count[32];

	git_hash_update(context, repo->hash_algo->name,
			strlen(repo->hash_algo->name) + 1);
	if (!replace_refs_enabled(repo)) {
		git_hash_update(context, "replacement-disabled",
				sizeof("replacement-disabled"));
		return;
	}
	git_hash_update(context, "replacement-enabled", sizeof("replacement-enabled"));
	git_hash_update(context, ref_namespace[NAMESPACE_REPLACE].ref,
			strlen(ref_namespace[NAMESPACE_REPLACE].ref) + 1);
	prepare_replace_object(repo);
	nr = oidmap_get_size(&repo->objects->replace_map);
	xsnprintf(count, sizeof(count), "%"PRIuMAX, (uintmax_t)nr);
	git_hash_update(context, count, strlen(count) + 1);
	if (!nr)
		return;
	ALLOC_ARRAY(entries, nr);
	oidmap_iter_init(&repo->objects->replace_map, &iter);
	while ((entry = oidmap_iter_next(&iter)))
		entries[i++] = entry;
	QSORT(entries, nr, compare_replacements);
	for (i = 0; i < nr; i++) {
		git_hash_update(context, entries[i]->original.oid.hash,
				repo->hash_algo->rawsz);
		git_hash_update(context, entries[i]->replacement.hash,
				repo->hash_algo->rawsz);
	}
	free(entries);
}

static struct tree *head_tree(struct repository *repo)
{
	struct object_id head;
	int flags = 0;
	const char *target = refs_resolve_ref_unsafe(get_main_ref_store(repo),
						   "HEAD", 0, &head, &flags);
	struct tree *tree;

	if (!target || (flags & REF_ISBROKEN))
		die(_("unable to resolve HEAD"));
	if (is_null_oid(&head)) {
		if ((flags & REF_ISSYMREF) && starts_with(target, "refs/heads/"))
			return NULL;
		die(_("HEAD does not name a valid object"));
	}
	tree = repo_parse_tree_indirect(repo, &head);
	if (!tree)
		die(_("HEAD does not name a valid tree"));
	return tree;
}

static struct tree *resolved_target_tree(struct repository *repo,
					const char *target)
{
	struct object_id oid;
	struct tree *tree;

	if (strlen(target) != repo->hash_algo->hexsz ||
	    get_oid_hex_algop(target, &oid, repo->hash_algo))
		die(_("projection target must be a full object ID"));
	tree = repo_parse_tree_indirect(repo, &oid);
	if (!tree)
		die(_("projection target does not name a valid tree"));
	return tree;
}

struct projection_description {
	struct repository *repo;
	struct attr_check *check;
	struct strbuf path;
};

static const char *attribute_value(const char *value)
{
	if (ATTR_TRUE(value))
		return "set";
	if (ATTR_FALSE(value))
		return "unset";
	if (ATTR_UNSET(value))
		return "unspecified";
	return value;
}

static int describe_entry(const struct object_id *oid, struct strbuf *base,
			  const char *pathname, unsigned mode, void *data)
{
	struct projection_description *description = data;
	const struct object_id *effective = oid;
	const char *filter = "unspecified", *lockable = "unspecified";
	enum object_type type = object_type(mode);

	if (type == OBJ_TREE)
		return READ_TREE_RECURSIVE;
	strbuf_reset(&description->path);
	strbuf_addbuf(&description->path, base);
	strbuf_addstr(&description->path, pathname);
	if (type == OBJ_BLOB) {
		git_check_attr(description->repo->index, description->path.buf,
			       description->check);
		filter = attribute_value(description->check->items[0].value);
		lockable = attribute_value(description->check->items[1].value);
		if (S_ISREG(mode))
			effective = lookup_replace_object(description->repo, oid);
	}
	printf("entry%c%06o%c%s%c%s%c%s%c%s%c%s%c%s%c", 0, mode, 0,
	       type_name(type), 0, oid_to_hex(oid), 0, description->path.buf, 0,
	       filter, 0, lockable, 0,
	       oideq(oid, effective) ? "" : oid_to_hex(effective), 0);
	return 0;
}

int cmd_textil_head_projection(int argc, const char **argv, const char *prefix,
			       struct repository *repo)
{
	enum { MODE_UNSET, MODE_IDENTITY, MODE_DESCRIBE } mode = MODE_UNSET;
	const char *target = NULL;
	struct option options[] = {
		OPT_CMDMODE(0, "identity-only", &mode,
			    N_("emit only the frozen HEAD source identity"), MODE_IDENTITY),
		OPT_CMDMODE(0, "describe", &mode,
			    N_("describe HEAD leaves using the frozen source"), MODE_DESCRIBE),
		OPT_STRING(0, "target", &target, N_("object-oid"),
			   N_("describe an already resolved immutable target instead of HEAD")),
		OPT_END()
	};
	struct git_hash_ctx context;
	struct object_id context_oid;
	struct tree *tree;
	struct pathspec pathspec = { 0 };
	struct projection_description description = {
		.repo = repo,
		.path = STRBUF_INIT,
	};
	int ret = 0;

	/* This reader must not fetch or write a missing promisor object. */
	fetch_if_missing = 0;
	repo_config(repo, git_default_config, NULL);
	argc = parse_options(argc, argv, prefix, options,
			     textil_head_projection_usage, 0);
	if (argc || mode == MODE_UNSET)
		usage_with_options(textil_head_projection_usage, options);
	if (target && mode != MODE_DESCRIBE)
		usage_with_options(textil_head_projection_usage, options);

	git_hash_init(&context, &hash_algos[GIT_HASH_SHA256]);
	git_hash_update(&context, "textil-head-projection", sizeof("textil-head-projection"));
	capture_replacements(repo, &context);
	tree = target ? resolved_target_tree(repo, target) : head_tree(repo);
	description.check = attr_check_initl("filter", "lockable", NULL);
	git_attr_capture_source(description.check, tree ? &tree->object.oid : NULL,
				&context);
	git_hash_final_oid(&context_oid, &context);
	printf("source%c%s%c%s%c", 0, tree ? oid_to_hex(&tree->object.oid) : "", 0,
	       oid_to_hex(&context_oid), 0);
	if (mode == MODE_DESCRIBE && tree)
		ret = !!read_tree(repo, tree, &pathspec, describe_entry, &description);
	if (!ret)
		printf("end%c", 0);
	attr_check_free(description.check);
	strbuf_release(&description.path);
	return ret;
}
