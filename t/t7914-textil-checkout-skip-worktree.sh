#!/bin/sh

test_description='native checkout must not hide a failed projected replacement'

. ./test-lib.sh

prepare_replacement () {
	git init "$1" &&
	(
		cd "$1" &&
		mkdir images &&
		test_commit old images/runner.exe old &&
		test_commit new images/runner.exe new &&
		git checkout old &&
		git update-index --skip-worktree images/runner.exe
	)
}

assert_failed_replacement () {
	grep "unable to unlink old.*runner.exe" err &&
	test "$(git rev-parse HEAD)" = "$(git rev-parse new)" &&
	git show old:images/runner.exe >expect-content &&
	test_cmp expect-content images/runner.exe &&
	git rev-parse new:images/runner.exe >expect-oid &&
	git rev-parse :images/runner.exe >actual-oid &&
	test_cmp expect-oid actual-oid &&
	echo "H images/runner.exe" >expect-tag &&
	git ls-files -t images/runner.exe >actual-tag &&
	test_cmp expect-tag actual-tag &&
	echo " M images/runner.exe" >expect-status &&
	git status --porcelain --untracked-files=no >actual-status &&
	test_cmp expect-status actual-status
}

test_expect_success MINGW 'mapped old skip-worktree entry reports Modified after unlink failure' '
	prepare_replacement mapped &&
	(
		cd mapped &&
		GIT_TEST_LEGACY_DELETE=1 test-tool run-command mapped \
			images/runner.exe git checkout new 2>err &&
		assert_failed_replacement
	)
'

test_expect_success SANITY 'unreplaceable old skip-worktree entry reports Modified after unlink failure' '
	prepare_replacement unreplaceable &&
	test_when_finished "chmod u+w unreplaceable/images" &&
	(
		cd unreplaceable &&
		chmod a-w images &&
		git checkout new 2>err &&
		assert_failed_replacement
	)
'

test_expect_success 'successful native replacement preserves inherited skip-worktree like stock Git' '
	prepare_replacement successful &&
	(
		cd successful &&
		git checkout new &&
		git show new:images/runner.exe >expect-content &&
		test_cmp expect-content images/runner.exe &&
		echo "S images/runner.exe" >expect-tag &&
		git ls-files -t images/runner.exe >actual-tag &&
		test_cmp expect-tag actual-tag &&
		git status --porcelain --untracked-files=no >actual-status &&
		test_must_be_empty actual-status
	)
'

test_expect_success 'successful parallel replacement preserves inherited skip-worktree' '
	prepare_replacement parallel &&
	(
		cd parallel &&
		git -c checkout.workers=2 -c checkout.thresholdForParallelism=0 checkout new &&
		git show new:images/runner.exe >expect-content &&
		test_cmp expect-content images/runner.exe &&
		echo "S images/runner.exe" >expect-tag &&
		git ls-files -t images/runner.exe >actual-tag &&
		test_cmp expect-tag actual-tag &&
		git status --porcelain --untracked-files=no >actual-status &&
		test_must_be_empty actual-status
	)
'

test_expect_success 'successful delayed replacement preserves inherited skip-worktree' '
	git init delayed &&
	(
		cd delayed &&
		git config filter.delayed.process \
			"test-tool rot13-filter --always-delay --log=filter.log clean smudge delay" &&
		git config filter.delayed.required true &&
		echo "images/runner.exe filter=delayed" >.gitattributes &&
		git add .gitattributes &&
		mkdir images &&
		test_commit old images/runner.exe old &&
		test_commit new images/runner.exe new &&
		git checkout old &&
		git update-index --skip-worktree images/runner.exe &&
		git checkout new &&
		grep "\[DELAYED\]" filter.log &&
		echo new >expect-content &&
		test_cmp expect-content images/runner.exe &&
		echo "S images/runner.exe" >expect-tag &&
		git ls-files -t images/runner.exe >actual-tag &&
		test_cmp expect-tag actual-tag &&
		git status --porcelain --untracked-files=no >actual-status &&
		test_must_be_empty actual-status
	)
'

test_expect_success 'sparse exclusions retain skip-worktree and do not materialize replacements' '
	prepare_replacement sparse &&
	(
		cd sparse &&
		git sparse-checkout set --no-cone /other &&
		git checkout new &&
		test_path_is_missing images/runner.exe &&
		echo "S images/runner.exe" >expect-tag &&
		git ls-files -t images/runner.exe >actual-tag &&
		test_cmp expect-tag actual-tag &&
		git status --porcelain --untracked-files=no >actual-status &&
		test_must_be_empty actual-status
	)
'

test_done
