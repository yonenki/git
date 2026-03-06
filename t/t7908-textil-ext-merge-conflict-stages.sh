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

test_expect_success 'merge conflict: non-pointer merge result keeps stage 2/3 entries' '
	test_atexit stop_executor_server &&
	restart_server materialize-checkout &&
	(
		cd merge-stage-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git merge theirs >out 2>err &&
		! grep "invalid LFS pointer" err &&
		git ls-files -u >unmerged &&
		test_file_not_empty unmerged &&
		grep "checkout_to.bin" unmerged &&
		git cat-file -p :2:checkout_to.bin >ours-stage &&
		git cat-file -p :3:checkout_to.bin >theirs-stage &&
		grep "oid sha256:1111111111111111111111111111111111111111111111111111111111111111" ours-stage &&
		grep "oid sha256:2222222222222222222222222222222222222222222222222222222222222222" theirs-stage
	)
'

test_done
