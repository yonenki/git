#!/bin/sh

test_description='textil-ext-policy: rule evaluator'

. ./test-lib.sh

# Helper to run evaluator via test-tool
eval_policy () {
	env \
		TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
		TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
		test-tool textil-ext-policy evaluate "$@"
}

is_active () {
	env \
		TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
		TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
		test-tool textil-ext-policy is-active
}

rule_count () {
	env \
		TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
		TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
		test-tool textil-ext-policy rule-count
}

# --- Setup: single-rule policy (LFS takeover) ---

test_expect_success 'setup: single-rule LFS takeover policy' '
	git init eval-repo &&
	cat >policy-single.json <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover",
	      "phases": ["materialize", "checkin_convert"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": true
	      },
	      "action": "takeover",
	      "strict": true,
	      "fallback": "deny",
	      "required_capabilities": ["lfs-smudge", "lfs-clean"]
	    }
	  ]
	}
	EOF
	POLICY_PATH="$(pwd)/policy-single.json"
'

test_expect_success 'is-active returns 1 for valid policy' '
	is_active >out &&
	grep "active=1" out
'

test_expect_success 'rule-count returns correct number' '
	rule_count >out &&
	grep "rules=1" out
'

test_expect_success 'match: materialize + lfs + regular file' '
	eval_policy materialize lfs 1 >out &&
	grep "matched=1" out &&
	grep "rule_id=lfs-takeover" out &&
	grep "action=takeover" out &&
	grep "fallback=deny" out &&
	grep "strict=1" out &&
	grep "capabilities=lfs-smudge,lfs-clean" out
'

test_expect_success 'match: checkin_convert + lfs + regular file' '
	eval_policy checkin_convert lfs 1 >out &&
	grep "matched=1" out &&
	grep "rule_id=lfs-takeover" out
'

test_expect_success 'no match: phase not in rule (preflight)' '
	eval_policy preflight lfs 1 >out &&
	grep "matched=0" out &&
	grep "action=observe" out &&
	grep "fallback=skip" out
'

test_expect_success 'no match: attr_filter mismatch' '
	eval_policy materialize git-annex 1 >out &&
	grep "matched=0" out &&
	grep "action=observe" out
'

test_expect_success 'no match: attr_filter=NULL (no filter set)' '
	eval_policy materialize - 1 >out &&
	grep "matched=0" out
'

test_expect_success 'no match: regular_file_only=true but not regular file' '
	eval_policy materialize lfs 0 >out &&
	grep "matched=0" out &&
	grep "action=observe" out
'

# --- Setup: multi-rule policy (first-match wins) ---

test_expect_success 'setup: multi-rule policy' '
	cat >policy-multi.json <<-\EOF &&
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
	    },
	    {
	      "id": "lfs-observe",
	      "phases": ["materialize", "preflight"],
	      "selector": {
	        "attr_filter_equals": "lfs",
	        "regular_file_only": false
	      },
	      "action": "observe",
	      "strict": false,
	      "fallback": "skip",
	      "required_capabilities": []
	    },
	    {
	      "id": "catch-all-preflight",
	      "phases": ["preflight"],
	      "selector": {
	        "regular_file_only": false
	      },
	      "action": "observe",
	      "strict": false,
	      "fallback": "skip",
	      "required_capabilities": []
	    }
	  ]
	}
	EOF
	POLICY_PATH="$(pwd)/policy-multi.json"
'

test_expect_success 'first-match wins: lfs-takeover before lfs-observe' '
	eval_policy materialize lfs 1 >out &&
	grep "matched=1" out &&
	grep "rule_id=lfs-takeover" out &&
	grep "action=takeover" out
'

test_expect_success 'second rule matches when first does not (symlink)' '
	eval_policy materialize lfs 0 >out &&
	grep "matched=1" out &&
	grep "rule_id=lfs-observe" out &&
	grep "action=observe" out
'

test_expect_success 'third rule: catch-all for preflight with no filter' '
	eval_policy preflight - 1 >out &&
	grep "matched=1" out &&
	grep "rule_id=catch-all-preflight" out
'

test_expect_success 'second rule matches preflight + lfs (before catch-all)' '
	eval_policy preflight lfs 1 >out &&
	grep "matched=1" out &&
	grep "rule_id=lfs-observe" out
'

test_expect_success 'no match: checkin_convert not in any rule' '
	eval_policy checkin_convert - 1 >out &&
	grep "matched=0" out &&
	grep "action=observe" out &&
	grep "fallback=skip" out
'

# --- Setup: selector without attr_filter_equals (matches any) ---

test_expect_success 'setup: no attr_filter_equals selector' '
	cat >policy-noattr.json <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "all-files",
	      "phases": ["materialize"],
	      "selector": {
	        "regular_file_only": false
	      },
	      "action": "observe",
	      "strict": false,
	      "fallback": "skip",
	      "required_capabilities": []
	    }
	  ]
	}
	EOF
	POLICY_PATH="$(pwd)/policy-noattr.json"
'

test_expect_success 'no attr_filter_equals: matches any filter value' '
	eval_policy materialize lfs 1 >out &&
	grep "matched=1" out &&
	grep "rule_id=all-files" out
'

test_expect_success 'no attr_filter_equals: matches NULL filter' '
	eval_policy materialize - 0 >out &&
	grep "matched=1" out &&
	grep "rule_id=all-files" out
'

# --- Trace output ---

test_expect_success 'trace: match shows rule id and action' '
	POLICY_PATH="$(pwd)/policy-single.json" &&
	GIT_TRACE_TEXTIL_EXT=1 eval_policy materialize lfs 1 2>trace &&
	grep "rule.*lfs-takeover.*matched" trace &&
	grep "takeover" trace
'

test_expect_success 'trace: no match shows default' '
	POLICY_PATH="$(pwd)/policy-single.json" &&
	GIT_TRACE_TEXTIL_EXT=1 eval_policy preflight - 1 2>trace &&
	grep "no rule matched" trace
'

test_done
