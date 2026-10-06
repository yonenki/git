#!/bin/sh

test_description='textil-ext: checkin durability fence at ODB transaction commit

Inside an ODB transaction (git add, add -u, update-index) checkin
conversions defer their durability and Git sends one durability_fence
before the transaction commits, so before the index can reference the
returned pointers. Outside a transaction each conversion stays immediate.'

. ./test-lib.sh

test-tool textil-ext-executor-server SUPPORTS_SIMPLE_IPC || {
	skip_all='simple IPC not supported on this platform'
	test_done
}

IPC_PATH="$TRASH_DIRECTORY/textil-ext-fence"
LOG="$TRASH_DIRECTORY/fence.log"

stop_executor_server () {
	test-tool textil-ext-executor-server stop-daemon --name="$IPC_PATH" 2>/dev/null
	return 0
}

restart_server () {
	stop_executor_server &&
	rm -f "$LOG" &&
	test-tool textil-ext-executor-server start-daemon \
		--name="$IPC_PATH" --reply-mode="$1" --trace-log="$LOG" &&
	test-tool textil-ext-executor-server is-active --name="$IPC_PATH"
}

ext_git () {
	env \
		TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy.json" \
		TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		git "$@"
}

test_expect_success 'setup' '
	cat >policy.json <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover",
	      "phases": ["checkin_convert"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": true
	      },
	      "action": "takeover",
	      "strict": true,
	      "fallback": "deny",
	      "required_capabilities": ["lfs-checkin-convert"]
	    }
	  ]
	}
	EOF
	git init repo &&
	(
		cd repo &&
		echo "*.bin filter=lfs diff=lfs merge=lfs -text" >.gitattributes &&
		git add .gitattributes &&
		git commit -m base
	)
'

test_expect_success 'git add defers every conversion and fences once' '
	restart_server checkin-deferred &&
	(
		cd repo &&
		for i in 1 2 3; do echo "content $i" >"a$i.bin" || return 1; done &&
		ext_git add a1.bin a2.bin a3.bin &&
		git ls-files --stage a1.bin a2.bin a3.bin >staged &&
		test_line_count = 3 staged
	) &&
	cat >expect <<-\EOF &&
	checkin deferred=1 items=1
	checkin deferred=1 items=1
	checkin deferred=1 items=1
	fence deferred=0 items=3
	EOF
	test_cmp expect "$LOG"
'

test_expect_success 'a large add is fenced in bounded batches' '
	restart_server checkin-deferred &&
	(
		cd repo &&
		for i in 1 2 3 4 5; do echo "bulk $i" >"b$i.bin" || return 1; done &&
		GIT_TEST_TEXTIL_EXT_FENCE_MAX_OIDS=2 ext_git add b1.bin b2.bin b3.bin b4.bin b5.bin
	) &&
	grep "^fence" "$LOG" >fences &&
	cat >expect <<-\EOF &&
	fence deferred=0 items=2
	fence deferred=0 items=2
	fence deferred=0 items=1
	EOF
	test_cmp expect fences
'

test_expect_success 'a failed fence leaves the index unchanged' '
	restart_server checkin-deferred-fence-error &&
	(
		cd repo &&
		git rev-parse :.gitattributes >/dev/null &&
		cp .git/index ../index-before &&
		echo "never staged" >c.bin &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git add c.bin 2>err &&
		test_grep "mock fence failure" err &&
		test_cmp_bin ../index-before .git/index &&
		test_must_fail git rev-parse --verify -q :c.bin
	)
'

test_expect_success 'a conversion outside a transaction stays immediate' '
	restart_server checkin-deferred &&
	(
		cd repo &&
		echo "hashed" >d.bin &&
		ext_git hash-object -w --path=d.bin d.bin
	) &&
	echo "checkin deferred=0 items=1" >expect &&
	test_cmp expect "$LOG"
'

test_expect_success 'cleanup' '
	stop_executor_server
'

test_done
