#!/bin/sh

test_description='textil-ext-executor: source pointers enter preflight only'

. ./test-lib.sh

test-tool textil-ext-executor-server SUPPORTS_SIMPLE_IPC || {
	skip_all='simple IPC not supported on this platform'
	test_done
}

IPC_PATH="$TRASH_DIRECTORY/textil-source-preflight"
POLICY_PATH="$TRASH_DIRECTORY/source-policy.json"
TRACE_LOG="$TRASH_DIRECTORY/requests.ndjson"
PACKET_LOG="$TRASH_DIRECTORY/packets.log"

stop_executor_server () {
	test-tool textil-ext-executor-server stop-daemon --name="$IPC_PATH" 2>/dev/null
	return 0
}

run_with_policy () {
	env \
		TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
		TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		GIT_TRACE_PACKET="$PACKET_LOG" \
		"$@"
}

test_expect_success 'setup mixed source/LFS policy and request-capture server' '
	cat >"$POLICY_PATH" <<-\EOF &&
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "p4-takeover",
	      "phases": ["preflight"],
	      "selector": {"attr_filter_equals": "p4", "regular_file_only": true},
	      "action": "takeover", "strict": true, "fallback": "deny",
	      "required_capabilities": ["source-preflight"]
	    },
	    {
	      "id": "svn-takeover",
	      "phases": ["preflight"],
	      "selector": {"attr_filter_equals": "svn", "regular_file_only": true},
	      "action": "takeover", "strict": true, "fallback": "deny",
	      "required_capabilities": ["source-preflight"]
	    },
	    {
	      "id": "lfs-takeover",
	      "phases": ["preflight", "materialize"],
	      "selector": {"attr_filter_equals": "lfs", "regular_file_only": true},
	      "action": "takeover", "strict": true, "fallback": "deny",
	      "required_capabilities": ["lfs-smudge"]
	    }
	  ]
	}
	EOF
	test_atexit stop_executor_server &&
	test-tool textil-ext-executor-server start-daemon \
		--name="$IPC_PATH" --reply-mode=batch-checkout --trace-log="$TRACE_LOG" &&
	test-tool textil-ext-executor-server is-active --name="$IPC_PATH"
'

test_expect_success 'checkout mixed source pointers and non-pointers' '
	git init source-repo &&
	(
		cd source-repo &&
		cat >.gitattributes <<-\EOF &&
		*.p4 filter=p4 -text
		*.svn filter=svn -text
		*.bin filter=lfs -text
		EOF
		git add .gitattributes &&
		git commit -m base &&
		git branch -M master main &&
		git checkout -b pointers &&
		cat >pointer.p4 <<-\EOF &&
		version https://textil.dev/spec/perforce-pointer/v1
		oid p4-md5:11111111111111111111111111111111
		size 11
		EOF
		cat >pointer.svn <<-\EOF &&
		version https://textil.dev/spec/subversion-pointer/v1
		oid svn-md5:22222222222222222222222222222222
		size 12
		representation regular
		EOF
		cat >pointer.bin <<-\EOF &&
		version https://git-lfs.github.com/spec/v1
		oid sha256:3333333333333333333333333333333333333333333333333333333333333333
		size 13
		EOF
		echo ordinary >plain.p4 &&
		cp pointer.svn wrong-provider.p4 &&
		prefix="version https://textil.dev/spec/perforce-pointer/" &&
		printf "%s%0*d" "$prefix" "$((1024 - ${#prefix}))" 0 >boundary.p4 &&
		cp boundary.p4 oversized.p4 &&
		printf x >>oversized.p4 &&
		git add *.p4 *.svn *.bin &&
		git commit -m pointers &&
		git checkout main &&
		git config filter.p4.smudge "echo p4-smudged; cat >/dev/null" &&
		git config filter.svn.smudge "echo svn-smudged; cat >/dev/null" &&
		run_with_policy git checkout pointers
	)
'

test_expect_success 'p4 pointer appears once in preflight with its rule and filter' '
	grep "> path=pointer.p4$" "$PACKET_LOG" >p4-requests &&
	test_line_count = 1 p4-requests &&
	grep "> rule_id=p4-takeover$" "$PACKET_LOG" &&
	grep "> attr_filter=p4$" "$PACKET_LOG"
'

test_expect_success 'svn pointer appears once in preflight with its rule and filter' '
	grep "> path=pointer.svn$" "$PACKET_LOG" >svn-requests &&
	test_line_count = 1 svn-requests &&
	grep "> rule_id=svn-takeover$" "$PACKET_LOG" &&
	grep "> attr_filter=svn$" "$PACKET_LOG"
'

test_expect_success '1024-byte source prefix is selected without validating its body' '
	grep "> path=boundary.p4$" "$PACKET_LOG" >boundary-requests &&
	test_line_count = 1 boundary-requests
'

test_expect_success 'non-pointer, wrong-provider and oversized p4 blobs are not batched' '
	! grep "> path=plain.p4$" "$PACKET_LOG" &&
	! grep "> path=wrong-provider.p4$" "$PACKET_LOG" &&
	! grep "> path=oversized.p4$" "$PACKET_LOG"
'

test_expect_success 'preflight has four items; materialize still has only LFS' '
	cat >expect <<-\EOF &&
	{"seq":0,"phase":"preflight","items":4,"repo_root_present":true}
	{"seq":1,"phase":"materialize","items":1,"repo_root_present":true}
	EOF
	test_cmp expect "$TRACE_LOG" &&
	grep "> path=pointer.bin$" "$PACKET_LOG" >lfs-requests &&
	test_line_count = 2 lfs-requests &&
	echo materialized-by-textil-batch >expect-lfs &&
	test_cmp expect-lfs source-repo/pointer.bin
'

test_expect_success 'materialize dispositions use the existing source smudge filters' '
	echo p4-smudged >expect-p4 &&
	echo svn-smudged >expect-svn &&
	test_cmp expect-p4 source-repo/pointer.p4 &&
	test_cmp expect-svn source-repo/pointer.svn &&
	test_cmp expect-p4 source-repo/boundary.p4 &&
	test_cmp expect-p4 source-repo/plain.p4 &&
	test_cmp expect-p4 source-repo/wrong-provider.p4 &&
	test_cmp expect-p4 source-repo/oversized.p4
'

test_done
