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

test_done
