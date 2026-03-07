#!/bin/sh

test_description='textil-ext-policy: hook point integration (entry/convert)

Tests are organized in three layers:
  Layer 1: Implemented functionality (materialize via IPC executor)
  Layer 2: Unimplemented boundary (checkin_convert fail-fast guard)
  Layer 3: Purity regression (no hook/filter management, IPC delegation)
'

. ./test-lib.sh

# Helper: write policy to absolute path and export env
setup_policy () {
	cat >"$1" &&
	POLICY_PATH="$1"
}

run_with_policy () {
	env \
		TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
		TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
		"$@"
}

# === Setup ===

test_expect_success 'setup: create repo with lfs-tracked file' '
	git init hook-repo &&
	(
		cd hook-repo &&
		echo "*.bin filter=lfs diff=lfs merge=lfs -text" >.gitattributes &&
		echo "initial" >file.txt &&
		echo "binary-data" >file.bin &&
		git add .gitattributes file.txt file.bin &&
		git commit -m "initial"
	)
'

# === IPC server for materialize tests ===

if test-tool textil-ext-executor-server SUPPORTS_SIMPLE_IPC
then
	test_set_prereq SIMPLE_IPC
fi

IPC_PATH="$TRASH_DIRECTORY/textil-hooks-test"

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

# === Checkout (entry.c) tests ===

test_expect_success SIMPLE_IPC 'checkout: takeover materializes via executor' '
	test_atexit stop_executor_server &&
	restart_server materialize-checkout &&
	setup_policy "$(pwd)/policy-takeover.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover",
	      "phases": ["materialize"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": true
	      },
	      "action": "takeover",
	      "strict": true,
	      "fallback": "deny",
	      "required_capabilities": ["lfs-smudge"]
	    }
	  ]
	}
	EOF
	(
		cd hook-repo &&
		rm -f file.bin &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout -- file.bin &&
		test -f file.bin &&
		grep "materialized-by-textil" file.bin
	)
'

test_expect_success 'checkout: observe policy allows checkout' '
	setup_policy "$(pwd)/policy-observe.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-observe",
	      "phases": ["materialize"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": true
	      },
	      "action": "observe",
	      "strict": false,
	      "fallback": "skip",
	      "required_capabilities": []
	    }
	  ]
	}
	EOF
	(
		cd hook-repo &&
		rm -f file.bin &&
		run_with_policy git checkout -- file.bin &&
		test -f file.bin
	)
'

test_expect_success 'checkout: no-match policy allows checkout' '
	setup_policy "$(pwd)/policy-nomatch.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "other-rule",
	      "phases": ["preflight"],
	      "selector": {
	        "attr_filter_equals": "other",
	        "regular_file_only": true
	      },
	      "action": "observe",
	      "strict": false,
	      "fallback": "skip",
	      "required_capabilities": []
	    }
	  ]
	}
	EOF
	(
		cd hook-repo &&
		rm -f file.bin &&
		run_with_policy git checkout -- file.bin &&
		test -f file.bin
	)
'

test_expect_success 'checkout: no policy (inactive) allows checkout' '
	(
		cd hook-repo &&
		rm -f file.bin &&
		unset TEXTIL_GIT_EXT_POLICY_PATH &&
		unset TEXTIL_GIT_EXT_POLICY_VERSION &&
		git checkout -- file.bin &&
		test -f file.bin
	)
'

test_expect_success 'checkout: takeover does not affect non-lfs files' '
	setup_policy "$(pwd)/policy-takeover2.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover",
	      "phases": ["materialize"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": true
	      },
	      "action": "takeover",
	      "strict": true,
	      "fallback": "deny",
	      "required_capabilities": ["lfs-smudge"]
	    }
	  ]
	}
	EOF
	(
		cd hook-repo &&
		rm -f file.txt &&
		run_with_policy git checkout -- file.txt &&
		test -f file.txt
	)
'

# === Checkin (convert.c) tests ===
#
# Phase2-3b: materialize-only policy (no checkin_convert phase).
# Backend policy provider does not emit checkin_convert in this phase.
# checkin_convert takeover → Phase2-4.

test_expect_success 'checkin: materialize-only policy allows git add' '
	setup_policy "$(pwd)/policy-checkin-matonly.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover",
	      "phases": ["materialize"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": true
	      },
	      "action": "takeover",
	      "strict": true,
	      "fallback": "deny",
	      "required_capabilities": ["lfs-smudge"]
	    }
	  ]
	}
	EOF
	(
		cd hook-repo &&
		echo "modified-bin" >file.bin &&
		run_with_policy git add file.bin
	)
'

test_expect_success SIMPLE_IPC 'checkin: checkin_convert takeover via executor' '
	restart_server checkin-convert-checkin &&
	setup_policy "$(pwd)/policy-checkin-takeover-guard.json" <<-\EOF &&
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
	      "required_capabilities": ["lfs-clean"]
	    }
	  ]
	}
	EOF
	(
		cd hook-repo &&
		echo "modified-bin-guard" >file.bin &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git add file.bin &&
		git diff --cached --name-only | grep file.bin
	)
'

test_expect_success SIMPLE_IPC 'checkin: checkin_convert works in linked worktree' '
	restart_server checkin-convert-checkin &&
	setup_policy "$(pwd)/policy-checkin-worktree.json" <<-\EOF &&
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
	      "required_capabilities": ["lfs-clean"]
	    }
	  ]
	}
	EOF
	(
		cd hook-repo &&
		git worktree add ../hook-repo-wt HEAD &&
		cd ../hook-repo-wt &&
		echo "worktree-bin-data" >file.bin &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git add file.bin &&
		git diff --cached --name-only | grep file.bin
	) &&
	(
		cd hook-repo &&
		git worktree remove --force ../hook-repo-wt
	)
'

test_expect_success 'checkin: observe policy allows git add' '
	setup_policy "$(pwd)/policy-checkin-observe.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-observe",
	      "phases": ["checkin_convert"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": true
	      },
	      "action": "observe",
	      "strict": false,
	      "fallback": "skip",
	      "required_capabilities": []
	    }
	  ]
	}
	EOF
	(
		cd hook-repo &&
		echo "modified-bin-obs" >file.bin &&
		run_with_policy git add file.bin
	)
'

test_expect_success 'checkin: no-match policy allows git add' '
	setup_policy "$(pwd)/policy-checkin-nomatch.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "other-rule",
	      "phases": ["preflight"],
	      "selector": {
	        "attr_filter_equals": "other",
	        "regular_file_only": true
	      },
	      "action": "observe",
	      "strict": false,
	      "fallback": "skip",
	      "required_capabilities": []
	    }
	  ]
	}
	EOF
	(
		cd hook-repo &&
		echo "modified-bin-nm" >file.bin &&
		run_with_policy git add file.bin
	)
'

test_expect_success 'checkin: materialize takeover does not affect non-lfs on add' '
	setup_policy "$(pwd)/policy-checkin-matonly2.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover",
	      "phases": ["materialize"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": true
	      },
	      "action": "takeover",
	      "strict": true,
	      "fallback": "deny",
	      "required_capabilities": ["lfs-smudge"]
	    }
	  ]
	}
	EOF
	(
		cd hook-repo &&
		echo "modified-txt" >file.txt &&
		run_with_policy git add file.txt
	)
'

# === Parallel-checkout (parallel-checkout.c) tests ===

test_expect_success 'setup: create repo with multiple lfs-tracked files' '
	git init pc-repo &&
	(
		cd pc-repo &&
		echo "*.bin filter=lfs diff=lfs merge=lfs -text" >.gitattributes &&
		echo "data-a" >a.bin &&
		echo "data-b" >b.bin &&
		echo "data-c" >c.bin &&
		echo "plain" >file.txt &&
		git add .gitattributes a.bin b.bin c.bin file.txt &&
		git commit -m "initial"
	)
'

test_expect_success SIMPLE_IPC 'parallel-checkout: takeover materializes under parallel workers' '
	restart_server materialize-checkout &&
	setup_policy "$(pwd)/policy-pc-takeover.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover",
	      "phases": ["materialize"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": true
	      },
	      "action": "takeover",
	      "strict": true,
	      "fallback": "deny",
	      "required_capabilities": ["lfs-smudge"]
	    }
	  ]
	}
	EOF
	(
		cd pc-repo &&
		rm -f a.bin b.bin c.bin &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			GIT_TEST_CHECKOUT_WORKERS=2 \
			git checkout -- a.bin b.bin c.bin &&
		test -f a.bin &&
		test -f b.bin &&
		test -f c.bin &&
		grep "materialized-by-textil" a.bin
	)
'

test_expect_success 'parallel-checkout: observe policy allows parallel checkout' '
	setup_policy "$(pwd)/policy-pc-observe.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-observe",
	      "phases": ["materialize"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": true
	      },
	      "action": "observe",
	      "strict": false,
	      "fallback": "skip",
	      "required_capabilities": []
	    }
	  ]
	}
	EOF
	(
		cd pc-repo &&
		rm -f a.bin b.bin c.bin &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			GIT_TEST_CHECKOUT_WORKERS=2 \
			git checkout -- a.bin b.bin c.bin &&
		test -f a.bin &&
		test -f b.bin &&
		test -f c.bin
	)
'

test_done
