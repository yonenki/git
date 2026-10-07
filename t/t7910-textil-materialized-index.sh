#!/bin/sh

test_description='Textil materialized paths update index stat without clean conversion'

. ./test-lib.sh

test_expect_success 'setup pointer index and materialized worktree file' '
	test_commit initial .gitattributes "*.bin filter=textil-test -text" &&
	cat >pointer <<-EOF &&
	version https://git-lfs.github.com/spec/v1
	oid sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	size 20
	EOF
	pointer_oid=$(git hash-object -w pointer) &&
	git update-index --add --cacheinfo 100644,$pointer_oid,asset.bin &&
	git rev-parse :asset.bin >expect-oid &&
	printf materialized-content >asset.bin &&
	git update-index --skip-worktree asset.bin &&
	cat >clean-filter.sh <<-\EOF &&
	#!/bin/sh
	echo invoked >>clean-filter.log
	cat
	EOF
	chmod +x clean-filter.sh &&
	git config filter.textil-test.clean "\"$PWD/clean-filter.sh\""
'

test_expect_success '--textil-materialized records stat and clears skip-worktree' '
	printf "asset.bin\0" | git update-index --textil-materialized -z --stdin &&
	test "$(git ls-files -v asset.bin | cut -c1)" = H &&
	git rev-parse :asset.bin >actual-oid &&
	test_cmp expect-oid actual-oid &&
	git diff --quiet -- asset.bin &&
	test_path_is_missing clean-filter.log
'

test_expect_success 'later worktree edit follows normal conversion path' '
	printf changed >>asset.bin &&
	test_must_fail git diff --quiet -- asset.bin &&
	test_path_is_file clean-filter.log
'

test_expect_success 'missing index entry fails' '
	printf "missing.bin\0" >paths &&
	test_must_fail git update-index --textil-materialized -z --stdin <paths
'

test_expect_success 'future materialized timestamp still checks equal-size edits' '
	printf original >plain &&
	git add plain &&
	stamp=$(test-tool chmtime --get =+60 plain) &&
	git update-index --textil-materialized plain &&
	printf modified >plain &&
	test-tool chmtime "=$stamp" plain &&
	git diff-files --name-only -- plain >actual &&
	echo plain >expect &&
	test_cmp expect actual
'

test_expect_success 'coarse materialized timestamps retain racy content checks' '
	printf original >coarse &&
	git add coarse &&
	stamp=$(test-tool chmtime --get =+0 coarse) &&
	git update-index --textil-materialized coarse &&
	printf modified >coarse &&
	test-tool chmtime "=$stamp" coarse .git/index &&
	git diff-files --name-only -- coarse >actual &&
	echo coarse >expect &&
	test_cmp expect actual
'

# Capture Git's platform stat fields without invoking a content converter.
# Reset the index stat afterwards so the conditional command must record it.
prepare_conditional_record () {
	rm -f clean-filter.log &&
	git update-index --no-skip-worktree --no-assume-unchanged asset.bin &&
	printf materialized-content >asset.bin &&
	git update-index --textil-materialized asset.bin &&
	git ls-files --debug asset.bin >stat &&
	ctime=$(sed -n "s/^  ctime: \([0-9]*\):\([0-9]*\)$/\1 \2/p" stat) &&
	mtime=$(sed -n "s/^  mtime: \([0-9]*\):\([0-9]*\)$/\1 \2/p" stat) &&
	devino=$(sed -n "s/^  dev: \([0-9]*\).*ino: \([0-9]*\)$/\1 \2/p" stat) &&
	uidgid=$(sed -n "s/^  uid: \([0-9]*\).*gid: \([0-9]*\)$/\1 \2/p" stat) &&
	printf "%s 20 %s %s %s %s\tasset.bin\0" \
		"$pointer_oid" "$mtime" "$ctime" "$devino" "$uidgid" >record &&
	printf "100644 %s\tasset.bin\0" "$pointer_oid" |
		git update-index -z --index-info &&
	git ls-files --debug asset.bin >before-stat
}

test_expect_success 'setup conditional LFS takeover policy' '
	echo "*.bin filter=lfs -text" >.gitattributes &&
	git add .gitattributes &&
	git config filter.lfs.clean "\"$PWD/clean-filter.sh\"" &&
	cat >materialized-policy.json <<-\EOF
	{
	  "version": "v1",
	  "rules": [{
	    "id": "lfs-takeover",
	    "phases": ["checkin_convert"],
	    "selector": {"attr_filter_equals": "lfs", "regular_file_only": true},
	    "action": "takeover",
	    "strict": true,
	    "fallback": "deny",
	    "required_capabilities": ["lfs-checkin-convert"]
	  }]
	}
	EOF
'

record_conditional () {
	TEXTIL_GIT_EXT_POLICY_PATH="$PWD/materialized-policy.json" \
	TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
		git update-index -z --textil-materialized-if-unchanged <record
}

test_expect_success 'conditional materialized stat records without cleaning' '
	prepare_conditional_record &&
	record_conditional &&
	git rev-parse :asset.bin >actual-oid &&
	test_cmp expect-oid actual-oid &&
	git diff --quiet -- asset.bin &&
	test_path_is_missing clean-filter.log
'

test_expect_success 'conditional materialized stat preserves cleared assume-unchanged with ignoreStat' '
	prepare_conditional_record &&
	test_config core.ignoreStat true &&
	git update-index --no-assume-unchanged asset.bin &&
	record_conditional &&
	test "$(git ls-files -v asset.bin | cut -c1)" = H &&
	git diff --quiet -- asset.bin &&
	test_path_is_missing clean-filter.log &&
	printf changed >>asset.bin &&
	test_must_fail git diff --quiet -- asset.bin &&
	test_path_is_file clean-filter.log
'

test_expect_success 'conditional materialized stat skips changed index blob' '
	prepare_conditional_record &&
	other_oid=$(echo other | git hash-object -w --stdin) &&
	git update-index --cacheinfo 100644,$other_oid,asset.bin &&
	git ls-files --debug asset.bin >before-stat &&
	record_conditional &&
	git ls-files --debug asset.bin >after-stat &&
	test_cmp before-stat after-stat &&
	git diff-files --name-only -- asset.bin >actual &&
	echo asset.bin >expect &&
	test_cmp expect actual &&
	test_path_is_missing clean-filter.log
'

test_expect_success 'conditional materialized stat skips rewritten worktree' '
	prepare_conditional_record &&
	printf changed >>asset.bin &&
	record_conditional &&
	git ls-files --debug asset.bin >after-stat &&
	test_cmp before-stat after-stat &&
	git diff-files --name-only -- asset.bin >actual &&
	echo asset.bin >expect &&
	test_cmp expect actual &&
	test_path_is_missing clean-filter.log
'

test_expect_success 'conditional materialized stat keeps skip-worktree' '
	prepare_conditional_record &&
	git update-index --skip-worktree asset.bin &&
	git ls-files --debug asset.bin >before-stat &&
	record_conditional &&
	git ls-files --debug asset.bin >after-stat &&
	test_cmp before-stat after-stat &&
	test "$(git ls-files -v asset.bin | cut -c1)" = S &&
	test_path_is_missing clean-filter.log
'

test_expect_success 'conditional materialized stat keeps assume-unchanged' '
	prepare_conditional_record &&
	git update-index --assume-unchanged asset.bin &&
	git ls-files --debug asset.bin >before-stat &&
	record_conditional &&
	git ls-files --debug asset.bin >after-stat &&
	test_cmp before-stat after-stat &&
	test "$(git ls-files -v asset.bin | cut -c1)" = h &&
	test_path_is_missing clean-filter.log
'

test_expect_success 'conditional materialized stat requires LFS takeover' '
	prepare_conditional_record &&
	git update-index -z --textil-materialized-if-unchanged <record &&
	git ls-files --debug asset.bin >after-stat &&
	test_cmp before-stat after-stat &&
	git diff-files --name-only -- asset.bin >actual &&
	echo asset.bin >expect &&
	test_cmp expect actual &&
	test_path_is_missing clean-filter.log
'

test_expect_success 'conditional materialized stat does not hide ordinary filtered edits' '
	echo "*.bin filter=textil-test -text" >.gitattributes &&
	prepare_conditional_record &&
	record_conditional &&
	git ls-files --debug asset.bin >after-stat &&
	test_cmp before-stat after-stat &&
	git diff-files --name-only -- asset.bin >actual &&
	echo asset.bin >expect &&
	test_cmp expect actual &&
	test_path_is_missing clean-filter.log
'

test_done
