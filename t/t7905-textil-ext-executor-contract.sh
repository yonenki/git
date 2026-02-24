#!/bin/sh

test_description='textil-ext-executor: batch payload contract (Phase1-7, updated Phase1-8a)'

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

test_expect_success 'setup: create repo with lfs-tracked files' '
	git init executor-repo &&
	(
		cd executor-repo &&
		echo "*.bin filter=lfs diff=lfs merge=lfs -text" >.gitattributes &&
		echo "plain" >file.txt &&
		git add .gitattributes file.txt &&
		git commit -m "base" &&
		git branch -M master main &&
		git checkout -b with-lfs &&
		echo "binary-a" >a.bin &&
		echo "binary-b" >b.bin &&
		echo "binary-c" >c.bin &&
		git add a.bin b.bin c.bin &&
		git commit -m "add lfs files" &&
		git checkout main
	)
'

# === Executor contract: endpoint missing ===

test_expect_success 'executor: takeover fails when endpoint not set' '
	setup_policy "$(pwd)/policy-exec-takeover.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover",
	      "phases": ["preflight"],
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
		cd executor-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-lfs 2>err &&
		grep "TEXTIL_GIT_EXT_ENDPOINT is not set" err
	)
'

test_expect_success 'executor: workspace unchanged after endpoint-missing error' '
	(
		cd executor-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-lfs 2>/dev/null &&
		test_path_is_missing a.bin &&
		test_path_is_missing b.bin &&
		test_path_is_missing c.bin
	)
'

test_expect_success 'executor: HEAD unchanged after endpoint-missing error' '
	(
		cd executor-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-lfs 2>/dev/null &&
		echo main >expect &&
		git symbolic-ref --short HEAD >actual &&
		test_cmp expect actual
	)
'

# === Executor: different takeover rule still fails without endpoint ===

test_expect_success 'executor: different rule also fails without endpoint' '
	setup_policy "$(pwd)/policy-exec-custom-rule.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "custom-lfs-handler",
	      "phases": ["preflight"],
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
		cd executor-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-lfs 2>err &&
		grep "TEXTIL_GIT_EXT_ENDPOINT is not set" err
	)
'

# === Executor: observe/no-match still succeed ===

test_expect_success 'executor: observe policy does not invoke executor' '
	setup_policy "$(pwd)/policy-exec-observe.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-observe",
	      "phases": ["preflight"],
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
		cd executor-repo &&
		run_with_policy git checkout with-lfs &&
		test -f a.bin &&
		test -f b.bin &&
		test -f c.bin &&
		git checkout main
	)
'

test_expect_success 'executor: no-match policy does not invoke executor' '
	setup_policy "$(pwd)/policy-exec-nomatch.json" <<-\EOF &&
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
		cd executor-repo &&
		run_with_policy git checkout with-lfs &&
		test -f a.bin &&
		git checkout main
	)
'

# === Single file batch ===

test_expect_success 'setup: branch with single lfs file' '
	(
		cd executor-repo &&
		git checkout -b with-one-lfs main &&
		echo "single-bin" >single.bin &&
		git add single.bin &&
		git commit -m "add single lfs file" &&
		git checkout main
	)
'

test_expect_success 'executor: single file batch also fails without endpoint' '
	setup_policy "$(pwd)/policy-exec-takeover.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover",
	      "phases": ["preflight"],
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
		cd executor-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-one-lfs 2>err &&
		grep "TEXTIL_GIT_EXT_ENDPOINT is not set" err
	)
'

test_done
