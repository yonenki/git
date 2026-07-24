#!/bin/sh

test_description='textil-ext: merge conflict keeps LFS stages for checkout --to flows'

. ./test-lib.sh

test-tool textil-ext-executor-server SUPPORTS_SIMPLE_IPC || {
	skip_all='simple IPC not supported on this platform'
	test_done
}

IPC_PATH="$TRASH_DIRECTORY/textil-merge-stage-test"

stop_executor_server () {
	test-tool textil-ext-executor-server stop-daemon --name="$IPC_PATH" 2>/dev/null
	return 0
}

restart_server () {
	stop_executor_server &&
	test-tool textil-ext-executor-server start-daemon \
		--name="$IPC_PATH" --reply-mode="$1" &&
	test-tool textil-ext-executor-server is-active \
		--name="$IPC_PATH"
}

setup_policy () {
	cat >"$1" &&
	POLICY_PATH="$1"
}

write_pointer () {
	cat <<-EOF
	version https://git-lfs.github.com/spec/v1
	oid sha256:$1
	size $2
	EOF
}

test_expect_success 'setup: create repo with conflicting LFS pointer commits' '
	git init merge-stage-repo &&
	(
		cd merge-stage-repo &&
		echo "checkout_to.bin filter=lfs diff=lfs merge=lfs -text" >.gitattributes &&
		write_pointer 0000000000000000000000000000000000000000000000000000000000000000 10 >checkout_to.bin &&
		git add .gitattributes checkout_to.bin &&
		git commit -m "base pointer" &&
		git branch -M master main &&
		git checkout -b ours &&
		write_pointer 1111111111111111111111111111111111111111111111111111111111111111 11 >checkout_to.bin &&
		git add checkout_to.bin &&
		git commit -m "ours pointer" &&
		git checkout main &&
		git checkout -b theirs &&
		write_pointer 2222222222222222222222222222222222222222222222222222222222222222 12 >checkout_to.bin &&
		git add checkout_to.bin &&
		git commit -m "theirs pointer" &&
		git checkout ours
	)
'

test_expect_success 'setup: materialize-only takeover policy' '
	setup_policy "$(pwd)/policy-merge-materialize.json" <<-\EOF
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-materialize",
	      "phases": ["materialize"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": true
	      },
	      "action": "takeover",
	      "strict": true,
	      "fallback": "deny",
	      "required_capabilities": ["lfs-materialize"]
	    }
	  ]
	}
	EOF
'

test_expect_success 'merge conflict: synthesized non-pointer result bypasses takeover and keeps stages' '
	test_atexit stop_executor_server &&
	restart_server materialize-rejected &&
	(
		cd merge-stage-repo &&
		rm -f controller-trace.jsonl &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			TEXTIL_GIT_EXT_TRACE_FILE="$PWD/controller-trace.jsonl" \
			TEXTIL_GIT_EXT_OPERATION_ID=merge-conflict \
			git merge theirs >out 2>err &&
		test_path_is_missing controller-trace.jsonl &&
		! grep "textil-ext.*takeover" err &&
		! grep "invalid LFS pointer" err &&
		cat >expect-stages <<-\EOF &&
		1 checkout_to.bin
		2 checkout_to.bin
		3 checkout_to.bin
		EOF
		git ls-files -u --format="%(stage) %(path)" >actual-stages &&
		test_cmp expect-stages actual-stages &&
		git cat-file -p :1:checkout_to.bin >base-stage &&
		git cat-file -p :2:checkout_to.bin >ours-stage &&
		git cat-file -p :3:checkout_to.bin >theirs-stage &&
		grep "oid sha256:0000000000000000000000000000000000000000000000000000000000000000" base-stage &&
		grep "oid sha256:1111111111111111111111111111111111111111111111111111111111111111" ours-stage &&
		grep "oid sha256:2222222222222222222222222222222222222222222222222222222222222222" theirs-stage
	)
'

test_done
