#!/bin/sh

test_description='frozen HEAD projection source and attribute authority'

. ./test-lib.sh

context_of () {
	nul_to_q <"$1" | cut -dQ -f3
}

expect_header () {
	context=$(context_of "$1") &&
	printf "source\000%s\000%s\000" "$(git rev-parse HEAD^{tree})" "$context"
}

expect_leaf () {
	printf "entry\000%s\000%s\000%s\000%s\000%s\000%s\000%s\000" "$@"
}

setup_leaf () {
	test_create_repo "$1" &&
	(
		cd "$1" &&
		git config core.ignorecase false &&
		printf "ordinary content\n" >asset.uasset &&
		git add asset.uasset &&
		git commit -m leaf
	)
}

expect_one_leaf () {
	expect_header "$1" &&
	expect_leaf 100644 blob "$(git rev-parse HEAD:asset.uasset)" \
		asset.uasset "$2" "$3" "$4" &&
	printf "end\000"
}

test_expect_success 'unborn source has no entries; malformed HEAD is not unborn' '
	test_create_repo unborn &&
	(
		cd unborn &&
		git textil-head-projection --identity-only >identity &&
		git textil-head-projection --describe >describe &&
		context=$(context_of identity) &&
		test ${#context} = 64 &&
		printf "%s\n" "$context" | grep "^[0-9a-f]*$" &&
		printf "source\000\000%s\000end\000" "$context" >expect &&
		test_cmp_bin expect identity &&
		test_cmp_bin identity describe &&
		test_must_fail git textil-head-projection --describe extra &&
		test_must_fail git textil-head-projection --describe --target=HEAD &&
		test_must_fail git textil-head-projection --identity-only --describe &&
		printf "not-a-ref\n" >.git/HEAD &&
		test_must_fail git --git-dir=.git textil-head-projection --identity-only
	)
'

test_expect_success 'resolved target skips HEAD but still consumes current mutable policy' '
	setup_leaf target &&
	(
		cd target &&
		target=$(git rev-parse HEAD) &&
		tree=$(git rev-parse HEAD^{tree}) &&
		blob=$(git rev-parse HEAD:asset.uasset) &&
		printf "*.uasset filter=lfs lockable\n" >.git/info/attributes &&
		git textil-head-projection --describe >initial &&
		printf "ref: refs/heads/no-current-head\n" >.git/HEAD &&
		git textil-head-projection --describe --target="$target" >describe &&
		test_cmp_bin initial describe &&
		test_must_fail git textil-head-projection --identity-only --target="$target" &&
		test_must_fail git textil-head-projection --describe --target="${target%?}" &&
		test_must_fail git textil-head-projection --describe --target="$blob" &&
		printf "*.uasset -filter -lockable\n" >.git/info/attributes &&
		git textil-head-projection --describe --target="$target" >changed &&
		! test_cmp_bin initial changed &&
		{
			printf "source\000%s\000%s\000" "$tree" "$(context_of changed)" &&
			expect_leaf 100644 blob "$blob" asset.uasset unset unset "" &&
			printf "end\000"
		} >expect &&
		test_cmp_bin expect changed &&
		path=$(echo "$target" | sed "s|^\(..\)|.git/objects/\1/|") &&
		rm "$path" &&
		test_must_fail git textil-head-projection --describe --target="$target"
	)
'

test_expect_success 'same HEAD info attributes and missing versus empty invalidate context' '
	setup_leaf info &&
	(
		cd info &&
		git textil-head-projection --identity-only >missing &&
		: >.git/info/attributes &&
		git textil-head-projection --identity-only >empty &&
		! test_cmp_bin missing empty &&
		printf "*.uasset filter=lfs lockable\n" >.git/info/attributes &&
		git textil-head-projection --identity-only >identity &&
		git textil-head-projection --describe >describe &&
		expect_one_leaf identity lfs set "" >expect &&
		test_cmp_bin expect describe &&
		printf "*.uasset -filter -lockable\n" >.git/info/attributes &&
		git textil-head-projection --identity-only >changed &&
		! test_cmp_bin identity changed &&
		git textil-head-projection --describe >describe &&
		expect_one_leaf changed unset unset "" >expect &&
		test_cmp_bin expect describe
	)
'

test_expect_success 'global path selection matters but unrelated config does not' '
	setup_leaf global &&
	(
		cd global &&
		printf "*.uasset filter=lfs\n" >first &&
		cp first second &&
		git config core.attributesFile "$PWD/first" &&
		git textil-head-projection --identity-only >identity &&
		git -c advice.statusHints=false textil-head-projection --identity-only >unrelated &&
		test_cmp_bin identity unrelated &&
		git textil-head-projection --describe >describe &&
		expect_one_leaf identity lfs unspecified "" >expect &&
		test_cmp_bin expect describe &&
		git config core.attributesFile "$PWD/second" &&
		git textil-head-projection --identity-only >selected &&
		! test_cmp_bin identity selected
	)
'

test_expect_success 'effective ignorecase controls matching and context in both directions' '
	setup_leaf case-policy &&
	(
		cd case-policy &&
		printf "*.UASSET filter=lfs lockable\n" >.git/info/attributes &&
		git textil-head-projection --identity-only >sensitive &&
		git textil-head-projection --describe >describe &&
		expect_one_leaf sensitive unspecified unspecified "" >expect &&
		test_cmp_bin expect describe &&
		git config core.ignorecase true &&
		git textil-head-projection --identity-only >folded &&
		! test_cmp_bin sensitive folded &&
		git textil-head-projection --describe >describe &&
		expect_one_leaf folded lfs set "" >expect &&
		test_cmp_bin expect describe &&
		git config core.ignorecase false &&
		git textil-head-projection --identity-only >restored &&
		test_cmp_bin sensitive restored &&
		git textil-head-projection --describe >describe &&
		expect_one_leaf restored unspecified unspecified "" >expect &&
		test_cmp_bin expect describe
	)
'

test_expect_success 'linked worktree uses common info attributes and pinned tree, not worktree attrs' '
	setup_leaf common &&
	(
		cd common &&
		printf "*.uasset filter=lfs\n" >.git/info/attributes &&
		git worktree add --detach ../linked HEAD &&
		git -C ../linked textil-head-projection --identity-only >identity &&
		git -C ../linked textil-head-projection --describe >describe &&
		expect_one_leaf identity lfs unspecified "" >expect &&
		test_cmp_bin expect describe &&
		printf "*.uasset -filter\n" >../linked/.gitattributes &&
		git -C ../linked textil-head-projection --describe >describe &&
		test_cmp_bin expect describe &&
		printf "*.uasset filter=p4\n" >.git/info/attributes &&
		git -C ../linked textil-head-projection --identity-only >changed &&
		! test_cmp_bin identity changed &&
		git -C ../linked textil-head-projection --describe >describe &&
		expect_one_leaf changed p4 unspecified "" >expect &&
		test_cmp_bin expect describe
	)
'

test_expect_success 'tree attributes use pinned nested source instead of worktree or index' '
	setup_leaf tree-attrs &&
	(
		cd tree-attrs &&
		mkdir nested &&
		printf "*.uasset filter=lfs\n" >.gitattributes &&
		printf "*.uasset filter=p4 lockable\n" >nested/.gitattributes &&
		cp asset.uasset nested/asset.uasset &&
		git add .gitattributes nested &&
		git commit -m attributes &&
		printf "*.uasset -filter\n" >.gitattributes &&
		printf "*.uasset -lockable\n" >nested/.gitattributes &&
		git add .gitattributes nested/.gitattributes &&
		git textil-head-projection --identity-only >identity &&
		git textil-head-projection --describe >describe &&
		{
			expect_header identity &&
			expect_leaf 100644 blob "$(git rev-parse HEAD:.gitattributes)" .gitattributes unspecified unspecified "" &&
			expect_leaf 100644 blob "$(git rev-parse HEAD:asset.uasset)" asset.uasset lfs unspecified "" &&
			expect_leaf 100644 blob "$(git rev-parse HEAD:nested/.gitattributes)" nested/.gitattributes unspecified unspecified "" &&
			expect_leaf 100644 blob "$(git rev-parse HEAD:nested/asset.uasset)" nested/asset.uasset p4 set "" &&
			printf "end\000"
		} >expect &&
		test_cmp_bin expect describe &&
		oid=$(git rev-parse HEAD:.gitattributes) &&
		path=$(echo "$oid" | sed "s|^\(..\)|.git/objects/\1/|") &&
		rm "$path" &&
		test_must_fail git textil-head-projection --describe
	)
'

test_expect_success 'non-blob attributes paths keep stock unspecified semantics' '
	setup_leaf nonblob-attrs &&
	(
		cd nonblob-attrs &&
		mkdir .gitattributes &&
		echo ignored >.gitattributes/contents &&
		git add .gitattributes &&
		git commit -m directory-attributes &&
		git textil-head-projection --describe >directory &&
		nul_to_q <directory >actual &&
		grep "Qasset.uassetQunspecifiedQunspecifiedQQ" actual &&
		git rm -r .gitattributes &&
		git update-index --add --cacheinfo 160000,$(git rev-parse HEAD),.gitattributes &&
		git commit -m gitlink-attributes &&
		git textil-head-projection --identity-only >identity &&
		git textil-head-projection --describe >gitlink &&
		{
			expect_header identity &&
			expect_leaf 160000 commit "$(git rev-parse HEAD:.gitattributes)" .gitattributes unspecified unspecified "" &&
			expect_leaf 100644 blob "$(git rev-parse HEAD:asset.uasset)" asset.uasset unspecified unspecified "" &&
			printf "end\000"
		} >expect &&
		test_cmp_bin expect gitlink
	)
'

test_expect_success 'all leaves preserve newline paths and gitlinks without probing blob bodies' '
	setup_leaf leaves &&
	(
		cd leaves &&
		name="line
break" &&
		blob=$(printf "newline\n" | git hash-object -w --stdin) &&
		{
			printf "100644 blob %s\tasset.uasset\000" "$(git rev-parse HEAD:asset.uasset)" &&
			printf "160000 commit %s\tchild\000" "$(git rev-parse HEAD)" &&
			printf "100644 blob %s\t%s\000" "$blob" "$name"
		} >tree-input &&
		tree=$(git mktree -z <tree-input) &&
		commit=$(git commit-tree "$tree" -p HEAD -m leaves) &&
		git update-ref HEAD "$commit" &&
		git textil-head-projection --identity-only >identity &&
		git textil-head-projection --describe >describe &&
		{
			expect_header identity &&
			expect_leaf 100644 blob "$(git rev-parse HEAD:asset.uasset)" asset.uasset unspecified unspecified "" &&
			expect_leaf 160000 commit "$(git rev-parse HEAD:child)" child unspecified unspecified "" &&
			expect_leaf 100644 blob "$(git rev-parse "HEAD:$name")" "$name" unspecified unspecified "" &&
			printf "end\000"
		} >expect &&
		test_cmp_bin expect describe &&
		oid=$(git rev-parse HEAD:asset.uasset) &&
		path=$(echo "$oid" | sed "s|^\(..\)|.git/objects/\1/|") &&
		rm "$path" &&
		git textil-head-projection --describe >describe &&
		test_cmp_bin expect describe &&
		tree=$(git rev-parse HEAD^{tree}) &&
		path=$(echo "$tree" | sed "s|^\(..\)|.git/objects/\1/|") &&
		rm "$path" &&
		test_must_fail git textil-head-projection --identity-only
	)
'

test_expect_success SYMLINKS 'symlink metadata passes through without replacement binding' '
	setup_leaf symlinks &&
	(
		cd symlinks &&
		ln -s asset.uasset link &&
		git add link &&
		git commit -m symlink &&
		git textil-head-projection --identity-only >identity &&
		git textil-head-projection --describe >describe &&
		{
			expect_header identity &&
			expect_leaf 100644 blob "$(git rev-parse HEAD:asset.uasset)" asset.uasset unspecified unspecified "" &&
			expect_leaf 120000 blob "$(git rev-parse HEAD:link)" link unspecified unspecified "" &&
			printf "end\000"
		} >expect &&
		test_cmp_bin expect describe
	)
'

test_expect_success 'effective binding survives a later live replacement update and raw read' '
	setup_leaf binding &&
	(
		cd binding &&
		# Both replacements are valid, equal-length pointer blobs for either object format.
		printf "version https://git-lfs.github.com/spec/v1\noid sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nsize 7\n" >old &&
		printf "version https://git-lfs.github.com/spec/v1\noid sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsize 7\n" >new &&
		printf "version https://git-lfs.github.com/spec/v1\noid sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\nsize 7\n" >asset.uasset &&
		git add asset.uasset &&
		git commit -m pointer &&
		original=$(git rev-parse HEAD:asset.uasset) &&
		old_oid=$(git hash-object -w old) &&
		new_oid=$(git hash-object -w new) &&
		git update-ref refs/replace/$original $old_oid &&
		printf "*.uasset filter=lfs\n" >.git/info/attributes &&
		git textil-head-projection --identity-only >identity &&
		git textil-head-projection --describe >describe &&
		expect_one_leaf identity lfs unspecified "$old_oid" >expect &&
		test_cmp_bin expect describe &&
		git update-ref refs/replace/$original $new_oid &&
		git --no-replace-objects cat-file blob $old_oid >raw &&
		test_cmp old raw &&
		git textil-head-projection --identity-only >changed &&
		! test_cmp_bin identity changed &&
		git textil-head-projection --describe >describe &&
		expect_one_leaf changed lfs unspecified "$new_oid" >expect &&
		test_cmp_bin expect describe &&
		git -c core.useReplaceRefs=false textil-head-projection --describe >disabled &&
		git -c core.useReplaceRefs=false textil-head-projection --identity-only >disabled-id &&
		expect_one_leaf disabled-id lfs unspecified "" >expect &&
		test_cmp_bin expect disabled &&
		! test_cmp_bin changed disabled-id &&
		git update-ref refs/replace/$original $old_oid &&
		git textil-head-projection --identity-only >restored &&
		test_cmp_bin identity restored
	)
'

test_expect_success PIPE 'describe reuses consumed global frame after an external edit during capture' '
	setup_leaf frozen-frame &&
	(
		cd frozen-frame &&
		printf "*.uasset filter=lfs\n" >global-attrs &&
		git config core.attributesFile "$PWD/global-attrs" &&
		printf "*.uasset lockable\n" >.git/info/attributes &&
		git textil-head-projection --identity-only >identity &&
		rm .git/info/attributes &&
		mkfifo .git/info/attributes
	) &&
	{
	(
		cd frozen-frame &&
		git textil-head-projection --describe >describe
	) &
	pid=$! &&
	(
		cd frozen-frame &&
		# Opening the FIFO rendezvous occurs after the global frame was consumed.
		{
			printf "*.uasset filter=p4\n" >global-attrs &&
			printf "*.uasset lockable\n"
		} >.git/info/attributes
	) &&
	wait $pid &&
	(
		cd frozen-frame &&
		rm .git/info/attributes &&
		printf "*.uasset lockable\n" >.git/info/attributes &&
		expect_one_leaf identity lfs set "" >expect &&
		test_cmp_bin expect describe &&
		git textil-head-projection --identity-only >changed &&
		! test_cmp_bin identity changed
	)
	}
'

test_expect_success PIPE 'replacement map stays frozen while the live ref changes during capture' '
	setup_leaf frozen-map &&
	(
		cd frozen-map &&
		printf "version https://git-lfs.github.com/spec/v1\noid sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nsize 7\n" >old &&
		printf "version https://git-lfs.github.com/spec/v1\noid sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nsize 7\n" >new &&
		printf "version https://git-lfs.github.com/spec/v1\noid sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\nsize 7\n" >asset.uasset &&
		git add asset.uasset &&
		git commit -m pointer &&
		original=$(git rev-parse HEAD:asset.uasset) &&
		old_oid=$(git hash-object -w old) &&
		new_oid=$(git hash-object -w new) &&
		git update-ref refs/replace/$original $old_oid &&
		printf "*.uasset filter=lfs\n" >.git/info/attributes &&
		git textil-head-projection --identity-only >identity &&
		rm .git/info/attributes &&
		mkfifo .git/info/attributes
	) &&
	{
	(
		cd frozen-map &&
		git textil-head-projection --describe >describe
	) &
	pid=$! &&
	(
		cd frozen-map &&
		original=$(git rev-parse HEAD:asset.uasset) &&
		new_oid=$(git hash-object new) &&
		{
			git update-ref refs/replace/$original $new_oid &&
			printf "*.uasset filter=lfs\n"
		} >.git/info/attributes
	) &&
	wait $pid &&
	(
		cd frozen-map &&
		rm .git/info/attributes &&
		printf "*.uasset filter=lfs\n" >.git/info/attributes &&
		old_oid=$(git hash-object old) &&
		expect_one_leaf identity lfs unspecified "$old_oid" >expect &&
		test_cmp_bin expect describe &&
		git --no-replace-objects cat-file blob "$old_oid" >raw &&
		test_cmp old raw &&
		git textil-head-projection --identity-only >changed &&
		! test_cmp_bin identity changed
	)
	}
'

test_done
