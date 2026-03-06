#!/bin/sh

test_description='textil-ext-policy: preflight batch in unpack-trees (Phase1-6)'

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

write_pointer () {
	cat <<-EOF
	version https://git-lfs.github.com/spec/v1
	oid sha256:$1
	size $2
	EOF
}

# === Setup ===

test_expect_success 'setup: create repo with two branches' '
	git init preflight-repo &&
	(
		cd preflight-repo &&
		echo "*.bin filter=lfs diff=lfs merge=lfs -text" >.gitattributes &&
		echo "plain" >file.txt &&
		git add .gitattributes file.txt &&
		git commit -m "base" &&
		git branch -M master main &&
		git checkout -b with-lfs &&
		write_pointer 1111111111111111111111111111111111111111111111111111111111111111 11 >a.bin &&
		write_pointer 2222222222222222222222222222222222222222222222222222222222222222 12 >b.bin &&
		write_pointer 3333333333333333333333333333333333333333333333333333333333333333 13 >c.bin &&
		git add a.bin b.bin c.bin &&
		git commit -m "add lfs files" &&
		git checkout main
	)
'

# === Preflight takeover tests ===

test_expect_success 'preflight: takeover dies before any workspace mutation' '
	setup_policy "$(pwd)/policy-pf-takeover.json" <<-\EOF &&
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
		cd preflight-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-lfs 2>err &&
		grep "TEXTIL_GIT_EXT_ENDPOINT is not set" err
	)
'

test_expect_success 'preflight: takeover error mentions endpoint' '
	(
		cd preflight-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-lfs 2>err &&
		grep "TEXTIL_GIT_EXT_ENDPOINT" err
	)
'

test_expect_success 'preflight: workspace is unchanged after preflight failure' '
	(
		cd preflight-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-lfs 2>/dev/null &&
		test_path_is_missing a.bin &&
		test_path_is_missing b.bin &&
		test_path_is_missing c.bin
	)
'

test_expect_success 'preflight: HEAD stays on original branch after failure' '
	(
		cd preflight-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-lfs 2>/dev/null &&
		echo main >expect &&
		git symbolic-ref --short HEAD >actual &&
		test_cmp expect actual
	)
'

# === Preflight observe tests ===

test_expect_success 'preflight: observe policy allows branch checkout' '
	setup_policy "$(pwd)/policy-pf-observe.json" <<-\EOF &&
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
		cd preflight-repo &&
		run_with_policy git checkout with-lfs &&
		test -f a.bin &&
		test -f b.bin &&
		test -f c.bin &&
		git checkout main
	)
'

# === Preflight no-match tests ===

test_expect_success 'preflight: no-match policy allows branch checkout' '
	setup_policy "$(pwd)/policy-pf-nomatch.json" <<-\EOF &&
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
		cd preflight-repo &&
		run_with_policy git checkout with-lfs &&
		test -f a.bin &&
		git checkout main
	)
'

# === Inactive policy ===

test_expect_success 'preflight: no policy allows branch checkout' '
	(
		cd preflight-repo &&
		unset TEXTIL_GIT_EXT_POLICY_PATH &&
		unset TEXTIL_GIT_EXT_POLICY_VERSION &&
		git checkout with-lfs &&
		test -f a.bin &&
		git checkout main
	)
'

# === Non-lfs files unaffected ===

test_expect_success 'setup: branch with only non-lfs files' '
	(
		cd preflight-repo &&
		git checkout -b with-txt &&
		echo "extra" >extra.txt &&
		git add extra.txt &&
		git commit -m "add non-lfs file" &&
		git checkout main
	)
'

test_expect_success 'preflight: takeover does not affect non-lfs branch' '
	setup_policy "$(pwd)/policy-pf-takeover2.json" <<-\EOF &&
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
		cd preflight-repo &&
		run_with_policy git checkout with-txt &&
		test -f extra.txt &&
		git checkout main
	)
'

# === Parallel-checkout + preflight ===

test_expect_success 'preflight: takeover dies before parallel-checkout starts' '
	setup_policy "$(pwd)/policy-pf-pc-takeover.json" <<-\EOF &&
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
		cd preflight-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			GIT_TEST_CHECKOUT_WORKERS=2 \
			git checkout with-lfs 2>err &&
		grep "TEXTIL_GIT_EXT_ENDPOINT is not set" err &&
		test_path_is_missing a.bin
	)
'

# === Materialize-only rule does not trigger preflight ===

test_expect_success 'preflight: materialize-only rule does not trigger preflight die' '
	setup_policy "$(pwd)/policy-pf-mat-only.json" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover-mat",
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
		cd preflight-repo &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-lfs 2>err &&
		grep "TEXTIL_GIT_EXT_ENDPOINT is not set" err &&
		! grep "preflight" err &&
		echo with-lfs >expect &&
		git branch --show-current >actual &&
		test_cmp expect actual
	)
'

test_done
