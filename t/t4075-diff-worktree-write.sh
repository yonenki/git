#!/bin/sh

test_description='diff content conversion does not prevent concurrent worktree writes'

. ./test-lib.sh

test_expect_success 'worktree remains writable during diff clean conversion' '
	test_commit base file.txt original &&
	echo "file.txt filter=editing" >.gitattributes &&
	write_script clean-filter <<-\EOF &&
	cat >captured
	count=0
	test ! -f count || read count <count
	count=$((count + 1))
	echo "$count" >count
	if test "$count" -ge 2
	then
		printf "editor replacement\n" >file.txt || exit 1
	fi
	cat captured
	EOF
	git config filter.editing.clean "./clean-filter" &&
	git config filter.editing.required true &&
	echo "edited content" >file.txt &&
	git -c diff.autoRefreshIndex=false diff -- file.txt >actual &&
	test "$(cat count)" -ge 2 &&
	echo "editor replacement" >expect &&
	test_cmp expect file.txt &&
	grep "^+edited content$" actual &&
	git show :file.txt >index &&
	echo original >expect &&
	test_cmp expect index
'

test_done
