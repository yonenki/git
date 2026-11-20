#!/bin/sh

test_description='textil-ext: checkout_file says whether its output will be recorded

A placeholder controller may only adjust the timestamp of an output whose stat
data Git will record in the repository index on success (output_index=recorded).
Outputs of worktree-only restores, --temp checkouts and alternate indexes are
unrecorded. A recorded output that replaces an entry for a different object
also carries that entry'"'"'s mtime second (output_replaced_mtime_sec).'

. ./test-lib.sh

# Git sends checkout_file only on native Windows with simple IPC.
if ! test_have_prereq MINGW
then
	skip_all='skipping Windows-specific tests'
	test_done
fi

test-tool textil-ext-executor-server SUPPORTS_SIMPLE_IPC || {
	skip_all='simple IPC not supported on this platform'
	test_done
}

IPC_PATH="$TRASH_DIRECTORY/textil-output-index"
PACKETS="$TRASH_DIRECTORY/packets.log"
POLICY_PATH="$TRASH_DIRECTORY/policy.json"

write_pointer () {
	printf "version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %s\n" "$1" "$2"
}

# Run Git with the placeholder controller double and record its requests.
placeholder_git () {
	rm -f "$PACKETS" &&
	env \
		TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
		TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		GIT_TRACE_PACKET="$PACKETS" \
		git "$@"
}

# The output_index of every checkout_file request, in request order.
expect_output_index () {
	printf "%s\n" "$@" >expect &&
	sed -n "s/.*> output_index=//p" "$PACKETS" >actual &&
	test_cmp expect actual
}

# The output_replaced_mtime_sec of the requests, in order; none without args.
expect_replaced_mtime () {
	if test $# = 0
	then
		! grep "> output_replaced_mtime_sec=" "$PACKETS"
	else
		printf "%s\n" "$@" >expect &&
		sed -n "s/.*> output_replaced_mtime_sec=//p" "$PACKETS" >actual &&
		test_cmp expect actual
	fi
}

# The mtime second the index records for a path.
indexed_mtime () {
	git ls-files --debug "$1" >debug &&
	sed -n "s/^  mtime: \([0-9]*\):.*/\1/p" debug
}

test_expect_success 'setup' '
	test-tool textil-ext-executor-server start-daemon \
		--name="$IPC_PATH" --reply-mode=placeholder-checkout &&
	test-tool textil-ext-executor-server is-active --name="$IPC_PATH" &&
	cat >"$POLICY_PATH" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover",
	      "phases": ["preflight", "materialize"],
	      "selector": { "attr_filter_equals": "lfs", "regular_file_only": true },
	      "action": "takeover",
	      "strict": true,
	      "fallback": "deny",
	      "required_capabilities": ["lfs-smudge"]
	    }
	  ]
	}
	EOF
	git init repo &&
	(
		cd repo &&
		# No filter.lfs driver: the takeover entries stay eligible for
		# parallel checkout (a configured driver, even an empty one,
		# keeps them sequential).
		echo "*.bin filter=lfs -text" >.gitattributes &&
		mkdir dir &&
		write_pointer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 9 >dir/a.bin &&
		write_pointer bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 9 >dir/b.bin &&
		git add . &&
		git commit -m first &&
		git branch -M main &&
		git switch -c second &&
		write_pointer cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc 9 >dir/a.bin &&
		git commit -am second &&
		git switch -c third main &&
		write_pointer dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd 9 >dir/c.bin &&
		git add dir/c.bin &&
		git commit -m third &&
		git switch main
	)
'

# The controller double leaves each placeholder output as the empty file Git
# created, so its index entry (size 0, non-empty blob) is never stat-clean.
# Plain Git (no policy) restores real bytes before the next recorded command.
test_expect_success 'switch records its outputs and the replaced mtime' '
	(
		cd repo &&
		old=$(indexed_mtime dir/a.bin) &&
		placeholder_git switch second &&
		expect_output_index recorded &&
		expect_replaced_mtime "$old" &&
		git checkout -q -f main
	)
'

test_expect_success 'parallel switch records its outputs and the replaced mtime' '
	(
		cd repo &&
		old=$(indexed_mtime dir/a.bin) &&
		placeholder_git -c checkout.workers=2 \
			-c checkout.thresholdForParallelism=0 switch second &&
		expect_output_index recorded &&
		expect_replaced_mtime "$old" &&
		git checkout -q -f main
	)
'

test_expect_success 'a new path has no replaced mtime' '
	(
		cd repo &&
		placeholder_git switch third &&
		expect_output_index recorded &&
		expect_replaced_mtime &&
		git checkout -q -f main
	)
'

test_expect_success 'reset --hard and read-tree -u record their outputs' '
	(
		cd repo &&
		rm dir/a.bin &&
		placeholder_git reset --hard &&
		expect_output_index recorded &&
		expect_replaced_mtime &&
		git reset -q --hard &&
		rm dir/a.bin &&
		placeholder_git read-tree --reset -u HEAD &&
		expect_output_index recorded &&
		expect_replaced_mtime &&
		git reset -q --hard
	)
'

test_expect_success 'read-tree -u into an alternate index output is unrecorded' '
	(
		cd repo &&
		rm dir/a.bin &&
		placeholder_git read-tree --reset -u --index-output=../alternate-index HEAD &&
		expect_output_index unrecorded &&
		expect_replaced_mtime &&
		git reset -q --hard
	)
'

test_expect_success 'path checkouts that write the index record their outputs' '
	(
		cd repo &&
		rm dir/a.bin &&
		placeholder_git restore dir/a.bin &&
		expect_output_index recorded &&
		expect_replaced_mtime &&
		git reset -q --hard &&
		old=$(indexed_mtime dir/a.bin) &&
		placeholder_git checkout second -- dir/a.bin &&
		expect_output_index recorded &&
		expect_replaced_mtime "$old" &&
		git reset -q --hard &&
		git checkout second -- dir/a.bin &&
		old=$(indexed_mtime dir/a.bin) &&
		placeholder_git restore --source=main --staged --worktree dir/a.bin &&
		expect_output_index recorded &&
		expect_replaced_mtime "$old" &&
		git diff --cached --exit-code &&
		git reset -q --hard
	)
'

test_expect_success 'worktree-only restore from another tree is unrecorded' '
	(
		cd repo &&
		placeholder_git restore --source=second --worktree dir/a.bin &&
		expect_output_index unrecorded &&
		expect_replaced_mtime &&
		git reset -q --hard
	)
'

test_expect_success 'checkout-index records only an index-updating checkout' '
	(
		cd repo &&
		placeholder_git checkout-index --temp dir/a.bin >temp &&
		expect_output_index unrecorded &&
		rm "$(cut -f1 temp)" &&
		rm dir/a.bin &&
		placeholder_git checkout-index dir/a.bin &&
		expect_output_index unrecorded &&
		rm dir/a.bin &&
		placeholder_git checkout-index -u dir/a.bin &&
		expect_output_index recorded &&
		git reset -q --hard
	)
'

test_expect_success 'checkout-index into GIT_INDEX_FILE is unrecorded' '
	(
		cd repo &&
		cp .git/index ../other-index &&
		rm dir/a.bin &&
		GIT_INDEX_FILE="$TRASH_DIRECTORY/other-index" &&
		export GIT_INDEX_FILE &&
		placeholder_git checkout-index -u dir/a.bin &&
		expect_output_index unrecorded
	) &&
	git -C repo reset -q --hard
'

# A path checkout below the parallelism threshold still writes takeovers in
# this process, inside checkout_worktree()'s fscache window. The stat it
# records must be the published file's, not the directory listing cached
# before the old files were removed.
test_expect_success 'in-process parallel path checkout stats new outputs' '
	(
		cd repo &&
		git reset --hard &&
		rm dir/a.bin dir/b.bin &&
		placeholder_git -c core.fscache=true -c checkout.workers=2 \
			-c checkout.thresholdForParallelism=1000 \
			restore dir/a.bin dir/b.bin &&
		expect_output_index recorded recorded &&
		git ls-files --debug dir/a.bin dir/b.bin >debug &&
		grep "size: 0" debug >sizes &&
		test_line_count = 2 sizes
	)
'

test_expect_success 'in-process parallel path checkout stats replaced outputs' '
	(
		cd repo &&
		echo "an older and longer worktree file" >dir/a.bin &&
		echo "an older and longer worktree file" >dir/b.bin &&
		placeholder_git -c core.fscache=true -c checkout.workers=2 \
			-c checkout.thresholdForParallelism=1000 \
			restore dir/a.bin dir/b.bin &&
		expect_output_index recorded recorded &&
		test_must_be_empty dir/a.bin &&
		test_must_be_empty dir/b.bin &&
		git ls-files --debug dir/a.bin dir/b.bin >debug &&
		grep "size: 0" debug >sizes &&
		test_line_count = 2 sizes
	)
'

test_expect_success 'cleanup' '
	test-tool textil-ext-executor-server stop-daemon --name="$IPC_PATH"
'

test_done
