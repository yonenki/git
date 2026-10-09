#!/bin/sh

test_description='textil-ext-executor: pkt-line v1 IPC transport via simple-ipc (Phase1-8c)'

. ./test-lib.sh

test-tool textil-ext-executor-server SUPPORTS_SIMPLE_IPC || {
	skip_all='simple IPC not supported on this platform'
	test_done
}

# Helper: socket path scoped to test directory
IPC_PATH="$TRASH_DIRECTORY/textil-executor-test"

stop_executor_server () {
	test-tool textil-ext-executor-server stop-daemon --name="$IPC_PATH" 2>/dev/null
	return 0
}

# Helper: restart server with a given reply mode
restart_server () {
	stop_executor_server &&
	test-tool textil-ext-executor-server start-daemon \
		--name="$IPC_PATH" --reply-mode="$1" &&
	test-tool textil-ext-executor-server is-active \
		--name="$IPC_PATH"
}

restart_server_with_trace () {
	stop_executor_server &&
	test-tool textil-ext-executor-server start-daemon \
		--name="$IPC_PATH" --reply-mode="$1" --trace-log="$2" &&
	test-tool textil-ext-executor-server is-active \
		--name="$IPC_PATH"
}

# Helper: write policy to absolute path and export env
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

# === Setup ===

test_expect_success 'setup: create repo with lfs-tracked files' '
	git init executor-ipc-repo &&
	(
		cd executor-ipc-repo &&
		echo "*.bin filter=lfs diff=lfs merge=lfs -text" >.gitattributes &&
		echo "plain" >file.txt &&
		git add .gitattributes file.txt &&
		git commit -m "base" &&
		git branch -M master main &&
		git checkout -b with-lfs &&
		write_pointer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 9 >a.bin &&
		write_pointer bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 9 >b.bin &&
		git add a.bin b.bin &&
		git commit -m "add lfs files" &&
		git checkout main
	)
'

test_expect_success 'setup: policy for lfs takeover' '
	setup_policy "$(pwd)/policy-ipc-takeover.json" <<-\EOF
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
'

# === Endpoint env contract ===

test_expect_success 'endpoint missing: error when TEXTIL_GIT_EXT_ENDPOINT unset' '
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-lfs 2>err &&
		grep "TEXTIL_GIT_EXT_ENDPOINT is not set" err
	)
'

test_expect_success 'endpoint empty: error when TEXTIL_GIT_EXT_ENDPOINT is empty' '
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="" \
			git checkout with-lfs 2>err &&
		grep "TEXTIL_GIT_EXT_ENDPOINT is not set" err
	)
'

# === Unreachable endpoint ===

test_expect_success 'unreachable endpoint: error when server not running' '
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH-nonexistent" \
			git checkout with-lfs 2>err &&
		grep "failed to connect to endpoint" err
	)
'

# === IPC ok reply ===

test_expect_success 'ok reply: checkout succeeds with ok server' '
	test_atexit stop_executor_server &&
	restart_server ok &&
	(
		cd executor-ipc-repo &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs &&
		test -f a.bin &&
		test -f b.bin &&
		git checkout main
	)
'

# === IPC rejected reply ===

test_expect_success 'rejected reply: checkout fails with rejected server' '
	restart_server rejected &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "takeover rejected" err &&
		grep "mock rejection" err
	)
'

# === IPC error reply ===

test_expect_success 'error reply: checkout fails with error server' '
	restart_server error &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "takeover error" err &&
		grep "mock error" err
	)
'

# === Invalid pkt-line reply ===

test_expect_success 'invalid-pkt reply: checkout fails gracefully' '
	restart_server invalid-pkt &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "invalid response" err
	)
'

# === Payload verification (validate-request mode) ===

test_expect_success 'validate-request: server validates pkt-line request and returns ok' '
	restart_server validate-request &&
	(
		cd executor-ipc-repo &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs &&
		test -f a.bin &&
		test -f b.bin &&
		git checkout main
	)
'

test_expect_success 'validate-request: materialize command-phase pairing accepted' '
	restart_server validate-request-materialize &&
	env \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-materialize \
			--name="$IPC_PATH" >out &&
	grep "^status=ok$" out
'

# === Workspace invariant: failed IPC does not mutate workspace ===

test_expect_success 'workspace unchanged after rejected IPC' '
	restart_server rejected &&
	(
		cd executor-ipc-repo &&
		git checkout main &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>/dev/null &&
		test_path_is_missing a.bin &&
		test_path_is_missing b.bin &&
		echo main >expect &&
		git symbolic-ref --short HEAD >actual &&
		test_cmp expect actual
	)
'

# === Observe policy does not trigger IPC ===

test_expect_success 'observe policy: no IPC needed, checkout succeeds without endpoint' '
	setup_policy "$(pwd)/policy-ipc-observe.json" <<-\EOF &&
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
		cd executor-ipc-repo &&
		git checkout main &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git checkout with-lfs &&
		test -f a.bin &&
		git checkout main
	)
'

# === Strict parser rejection tests ===
# Re-set policy to takeover (observe test changed POLICY_PATH)

test_expect_success 'setup: restore takeover policy for strict parser tests' '
	POLICY_PATH="$(pwd)/policy-ipc-takeover.json"
'

test_expect_success 'strict parser: trailing data after flush rejected' '
	restart_server trailing-after-flush &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "invalid response" err
	)
'

test_expect_success 'strict parser: invalid status value rejected' '
	restart_server invalid-status &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "invalid response" err
	)
'

test_expect_success 'strict parser: missing status line rejected' '
	restart_server missing-status &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "invalid response" err
	)
'

test_expect_success 'strict parser: missing flush terminator rejected' '
	restart_server no-flush &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "invalid response" err
	)
'

test_expect_success 'strict parser: rejected without message rejected' '
	restart_server missing-message &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "invalid response" err
	)
'

# === Key-order independence test ===

test_expect_success 'key-order: message before status accepted (rejected reply)' '
	restart_server reordered &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "takeover rejected" err &&
		grep "reordered rejection" err
	)
'


# === Control char rejection ===

test_expect_success 'strict parser: control char in value rejected' '
	restart_server control-char &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "invalid response" err
	)
'

# === Unknown key rejection ===

test_expect_success 'strict parser: unknown key in response rejected' '
	restart_server unknown-key &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "invalid response" err
	)
'

# === Large malformed reply rejection ===

test_expect_success 'strict parser: large malformed reply is rejected structurally' '
	restart_server large-invalid-pkt &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "invalid response" err
	)
'

# === Duplicate key rejection ===

test_expect_success 'strict parser: duplicate key in response rejected' '
	restart_server duplicate-key &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "invalid response" err
	)
'

# === Request-side value validation ===

test_expect_success 'request validation: LF in path rejects before IPC' '
	restart_server ok &&
	git init lf-path-repo &&
	(
		cd lf-path-repo &&
		echo "* filter=lfs diff=lfs merge=lfs -text" >.gitattributes &&
		echo "plain" >file.txt &&
		git add .gitattributes file.txt &&
		git commit -m "base" &&
		git branch -M master main &&
		git checkout -b with-lf-path &&
		LF_NAME=$(printf "bad\nfile.bin") &&
		write_pointer cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc 11 >"$LF_NAME" &&
		git add -A &&
		git commit -m "add file with LF in path" &&
		git checkout main &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lf-path 2>err &&
		grep "forbidden character" err
	)
'

# === Materialize phase E2E tests ===

test_expect_success 'materialize-ok: executor parses delim-separated src_paths' '
	restart_server materialize-ok &&
	TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
	test-tool textil-ext-executor-server send-materialize \
		--name="$IPC_PATH" >out &&
	grep "^status=ok$" out
'

test_expect_success 'materialize-rejected: executor reports rejected status' '
	restart_server materialize-rejected &&
	test_must_fail env \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-materialize \
			--name="$IPC_PATH" >out &&
	grep "^status=rejected$" out
'

test_expect_success 'materialize-src-path-relative: C-side validates absolute path' '
	restart_server materialize-src-path-relative &&
	test_must_fail env \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-materialize \
			--name="$IPC_PATH" >out &&
	grep "^status=error$" out
'

test_expect_success MINGW 'materialize-src-path-windows-verbatim: C-side accepts verbatim drive path' '
	restart_server materialize-src-path-windows-verbatim &&
	env \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-materialize \
			--name="$IPC_PATH" >out &&
	grep "^status=ok$" out &&
	grep "^src_path=\\\\\\\\?\\\\C:\\\\textil\\\\materialize\\\\aa\\\\bb\\\\aabb1234.bin$" out
'

test_expect_success MINGW 'materialize-src-path-windows-unc: C-side accepts UNC path' '
	restart_server materialize-src-path-windows-unc &&
	env \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-materialize \
			--name="$IPC_PATH" >out &&
	grep "^status=ok$" out &&
	grep "^src_path=\\\\\\\\server\\\\share\\\\textil\\\\materialize\\\\aa\\\\bb\\\\aabb1234.bin$" out
'

test_expect_success 'materialize-ok-without-src-path: ok with zero src_paths is invalid' '
	restart_server materialize-ok-without-src-path &&
	test_must_fail env \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-materialize \
			--name="$IPC_PATH" >out &&
	grep "^status=error$" out
'

test_expect_success 'materialize-ok-with-message: message forbidden for materialize ok' '
	restart_server materialize-ok-with-message &&
	test_must_fail env \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-materialize \
			--name="$IPC_PATH" >out &&
	grep "^status=error$" out
'

test_expect_success 'materialize-src-path-with-status-error: delim after non-ok is rejected' '
	restart_server materialize-src-path-with-status-error &&
	test_must_fail env \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-materialize \
			--name="$IPC_PATH" >out &&
	grep "^status=error$" out
'

# === Materialize src_path count mismatch ===

test_expect_success 'materialize-count-mismatch: src_path count != batch items is ERROR' '
	restart_server materialize-count-mismatch &&
	test_must_fail env \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-materialize \
			--name="$IPC_PATH" >out &&
	grep "^status=error$" out
'

# === Preflight API contract (BUG guard) ===

test_expect_success 'preflight API: materialize phase triggers BUG' '
	test_expect_code 99 \
		test-tool textil-ext-executor-server \
			send-preflight-wrong-phase 2>err &&
	grep "BUG:" err &&
	grep "non-preflight phase" err
'

test_expect_success 'materialize API: preflight phase triggers BUG' '
	test_expect_code 99 \
		test-tool textil-ext-executor-server \
			send-materialize-wrong-phase 2>err &&
	grep "BUG:" err &&
	grep "non-materialize phase" err
'

# === Materialize E2E checkout ===

test_expect_success 'setup: policy for lfs materialize takeover' '
	setup_policy "$(pwd)/policy-ipc-mat-takeover.json" <<-\EOF
	{
	  "version": "v1",
	  "rules": [
	    {
	      "id": "lfs-takeover",
	      "phases": ["preflight", "materialize"],
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
'

test_expect_success 'new-path admission: switch overwrites an ignored target with committed content' '
	restart_server admitted-checkout &&
	git init ignored-target-repo &&
	(
		cd ignored-target-repo &&
		git config filter.lfs.process "" &&
		git config filter.lfs.clean cat &&
		git config filter.lfs.smudge cat &&
		git config filter.lfs.required false &&
		echo "*.bin filter=lfs -text" >.gitattributes &&
		echo "target.bin" >.gitignore &&
		git add .gitattributes .gitignore &&
		git commit -m base &&
		git branch -M main &&
		git switch -c target &&
		write_pointer d30530669c8334ddc14204eacfcdd9e73ac8eccdc8ca6ff1cc8b3060fa8b29c3 29 >target.bin &&
		git add -f target.bin &&
		git commit -m target &&
		git switch main &&
		echo "ignored worktree content" >target.bin &&
		printf "materialized-by-textil-batch\n" >expect &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-ipc-mat-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git switch target &&
		test_cmp expect target.bin
	)
'


test_expect_success 'materialize E2E: checkout writes src_path content to file' '
	restart_server materialize-checkout &&
	(
		cd executor-ipc-repo &&
		git checkout -f main &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-ipc-mat-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs &&
		test -f a.bin &&
		test -f b.bin &&
		grep "materialized-by-textil" a.bin &&
		grep "materialized-by-textil" b.bin
	)
'

test_expect_success 'materialize E2E: parallel checkout writes src_path content' '
	restart_server materialize-checkout &&
	(
		cd executor-ipc-repo &&
		git checkout -f main &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-ipc-mat-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			GIT_TEST_CHECKOUT_WORKERS=2 \
			git checkout with-lfs &&
		test -f a.bin &&
		test -f b.bin &&
		grep "materialized-by-textil" a.bin &&
		grep "materialized-by-textil" b.bin
	)
'

test_expect_success 'materialize E2E: path checkout fallback includes repo_root' '
	trace_log="$(pwd)/path-checkout-materialize-trace.ndjson" &&
	rm -f "$trace_log" &&
	test_when_finished stop_executor_server &&
	restart_server_with_trace batch-checkout "$trace_log" &&
	(
		cd executor-ipc-repo &&
		git checkout -f main &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-ipc-mat-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs -- a.bin &&
		test -f a.bin &&
		grep "materialized-by-textil-batch" a.bin
	) &&
	grep "\"phase\":\"materialize\"" "$trace_log" &&
	grep "\"items\":1" "$trace_log" &&
	grep "\"repo_root_present\":true" "$trace_log"
'
# === Checkin convert phase tests ===

test_expect_success 'setup: policy for lfs checkin_convert takeover' '
	setup_policy "$(pwd)/policy-ipc-cc-takeover.json" <<-\EOF
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
'

test_expect_success 'checkin_convert-ok: executor parses inline hex pointers' '
	restart_server checkin-convert-checkin &&
	TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
	test-tool textil-ext-executor-server send-checkin-convert \
		--name="$IPC_PATH" >out &&
	grep "^status=ok$" out &&
	grep "^pointer=76657273696f6e20" out
'

test_expect_success 'checkin_convert-bad-pointer: odd/non-hex pointer is invalid response' '
	for mode in checkin-convert-bad-pointer checkin-convert-non-hex-pointer
	do
		restart_server "$mode" &&
		test_must_fail env TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			test-tool textil-ext-executor-server send-checkin-convert \
				--name="$IPC_PATH" >out &&
		grep "^status=error$" out &&
		grep "invalid response" out || return 1
	done
'

test_expect_success 'checkin_convert-rejected: executor reports rejected status' '
	restart_server rejected &&
	test_must_fail env \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-checkin-convert \
			--name="$IPC_PATH" >out &&
	grep "^status=rejected$" out
'

test_expect_success 'validate-request-checkin-convert: command-phase pairing accepted' '
	restart_server validate-request-checkin-convert &&
	env \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-checkin-convert \
			--name="$IPC_PATH" >out &&
	grep "^status=ok$" out
'

# === Checkin convert API contract (BUG guard) ===

test_expect_success 'checkin_convert API: preflight phase triggers BUG' '
	test_expect_code 99 \
		test-tool textil-ext-executor-server \
			send-checkin-convert-wrong-phase 2>err &&
	grep "BUG:" err &&
	grep "non-checkin_convert phase" err
'

# === Checkin convert E2E ===

test_expect_success 'checkin_convert E2E: git add writes LFS pointer via executor' '
	restart_server checkin-convert-checkin &&
	(
		cd executor-ipc-repo &&
		rm -f .git/index.lock &&
		git checkout -f main &&
		echo "new-binary-content" >new.bin &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-ipc-cc-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git add new.bin &&
		git diff --cached --name-only | grep new.bin &&
		git show :new.bin >staged-content &&
		grep "version https://git-lfs.github.com/spec/v1" staged-content &&
		grep "oid sha256:" staged-content &&
		grep "size 42" staged-content
	)
'

test_expect_success 'extension repositories use filter-process for add, path checkout and checkout waves' '
	git init extension-fallback-repo &&
	(
		cd extension-fallback-repo &&
		git config filter.lfs.process "test-tool rot13-filter --log=filter.log clean smudge" &&
		git config filter.lfs.required true &&
		git config lfs.extension.example.clean "ignored-by-native-Git" &&
		echo "*.bin filter=lfs -text" >.gitattributes &&
		git add .gitattributes &&
		git commit -m base &&
		git branch -M main &&
		git checkout -b with-content &&
		echo "native extension fallback" >asset.bin &&
		cp asset.bin original &&
		tr "[A-Za-z]" "[N-ZA-Mn-za-m]" <original >encoded &&
		env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-cc-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH-unreachable" \
			git add asset.bin &&
		git show :asset.bin >actual &&
		test_cmp encoded actual &&
		git commit -m content &&
		rm asset.bin &&
		env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-mat-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH-unreachable" \
			git checkout -- asset.bin &&
		test_cmp original asset.bin &&
		git checkout main &&
		env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-mat-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH-unreachable" \
			git checkout with-content &&
		test_cmp original asset.bin
	)
'

test_expect_success 'any extension config key declines native checkin, including valueless keys and -c' '
	(
		cd extension-fallback-repo &&
		git config --remove-section lfs.extension.example &&
		echo "command scope extension" >command.bin &&
		env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-cc-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH-unreachable" \
			git -c lfs.extension.command.priority= add command.bin &&
		tr "[A-Za-z]" "[N-ZA-Mn-za-m]" <command.bin >encoded &&
		git show :command.bin >actual &&
		test_cmp encoded actual &&
		cat >>.git/config <<-\EOF &&
		[lfs "extension.bare"]
			priority
		EOF
		echo "bare extension key" >bare.bin &&
		env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-cc-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH-unreachable" \
			git add bare.bin &&
		tr "[A-Za-z]" "[N-ZA-Mn-za-m]" <bare.bin >encoded &&
		git show :bare.bin >actual &&
		test_cmp encoded actual
	)
'

test_expect_success 'extension pointers are not admitted to native materialize without extension config' '
	(
		cd extension-fallback-repo &&
		git config --remove-section lfs.extension.bare &&
		{
			echo "version https://git-lfs.github.com/spec/v1" &&
			echo "ext-0-example sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" &&
			echo "oid sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" &&
			echo "size 4"
		} >extension.bin &&
		git -c filter.lfs.process= -c filter.lfs.required=false add extension.bin &&
		tr "[A-Za-z]" "[N-ZA-Mn-za-m]" <extension.bin >expected &&
		rm extension.bin &&
		env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-mat-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH-unreachable" \
			git checkout -- extension.bin &&
		test_cmp expected extension.bin
	)
'

test_expect_success 'priority-only worktree .lfsconfig declines native add and checkout without Git extension keys' '
	(
		cd extension-fallback-repo &&
		test_must_fail git config --get-regexp "^lfs\\.extension\\." &&
		cat >.lfsconfig <<-\EOF &&
		[lfs "extension.priority-only"]
			priority = 10
		EOF
		echo "priority only lower source" >priority.bin &&
		cp priority.bin original &&
		tr "[A-Za-z]" "[N-ZA-Mn-za-m]" <original >encoded &&
		env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-cc-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH-unreachable" \
			git add priority.bin &&
		git show :priority.bin >actual &&
		test_cmp encoded actual &&
		rm priority.bin &&
		env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-mat-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH-unreachable" \
			git checkout -- priority.bin &&
		test_cmp original priority.bin
	)
'

test_expect_success 'malformed .lfsconfig warns and drops partial safe priorities before native takeover' '
	restart_server checkin-convert-checkin &&
	(
		cd extension-fallback-repo &&
		printf "[lfs \"extension.partial\"]\npriority=10\n[broken\n" >.lfsconfig &&
		echo "malformed lower source" >malformed.bin &&
		env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-cc-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git add malformed.bin 2>err &&
		grep "ignoring malformed .lfsconfig" err &&
		git show :malformed.bin >actual &&
		grep "version https://git-lfs.github.com/spec/v1" actual
	)
'

test_expect_success 'unsafe .lfsconfig extension commands alone do not disable native takeover' '
	restart_server checkin-convert-checkin &&
	(
		cd extension-fallback-repo &&
		cat >.lfsconfig <<-\EOF &&
		[lfs "extension.untrusted"]
			clean = never-trusted
			smudge = never-trusted
		EOF
		echo "unsafe lower commands" >unsafe.bin &&
		env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-cc-takeover.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git add unsafe.bin &&
		git show :unsafe.bin >actual &&
		grep "version https://git-lfs.github.com/spec/v1" actual
	)
'

# === Count-independent replies and byte-bounded checkout requests ===

make_batched_checkout_repo () {
	git init "$1" &&
	(
		cd "$1" &&
		git config checkout.workers 1 &&
		echo "*.bin filter=lfs -text" >.gitattributes &&
		echo main >control.txt &&
		git add .gitattributes control.txt &&
		git commit -m base &&
		git branch -M main &&
		git checkout -b with-lfs &&
		echo target >control.txt &&
		git add control.txt &&
		write_pointer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 9 >pointer &&
		blob=$(git hash-object -w pointer) &&
		test_seq 1 "$2" >numbers &&
		while read -r number
		do
			printf "100644 %s\tassets/file%05d.bin\n" "$blob" "$number" ||
			return 1
		done <numbers >index-info &&
		git update-index --index-info <index-info &&
		git commit -m "many LFS pointers" &&
		git checkout -f main &&
		rm pointer numbers index-info
	)
}

check_batch_trace () {
	max_bytes=$1 &&
	expected_items=$2 &&
	preflight_items=0 &&
	materialize_items=0 &&
	while read -r line
	do
		bytes=${line#*\"request_bytes\":} &&
		bytes=${bytes%%,*} &&
		items=${line#*\"items\":} &&
		items=${items%%,*} &&
		test "$bytes" -le "$max_bytes" || return 1
		case "$line" in
		*\"phase\":\"preflight\"*)
			preflight_items=$((preflight_items + items))
			;;
		*\"phase\":\"materialize\"*)
			materialize_items=$((materialize_items + items))
			;;
		*) return 1 ;;
		esac
	done <"$3" &&
	test "$preflight_items" = "$expected_items" &&
	test "$materialize_items" = "$expected_items"
}

test_expect_success 'setup: both-phase policy for large and sliced checkout' '
	cat >policy-ipc-batched-checkout.json <<-\EOF
	{
	  "version": "v1",
	  "rules": [{
	    "id": "lfs-takeover",
	    "phases": ["preflight", "materialize"],
	    "selector": {"attr_filter_equals": "lfs", "regular_file_only": true},
	    "action": "takeover",
	    "strict": true,
	    "fallback": "deny",
	    "required_capabilities": ["lfs-preflight", "lfs-materialize"]
	  }]
	}
	EOF
'

test_expect_success '1000 and 10000 LFS entries accept large replies without extra round trips' '
	for count in 1000 10000
	do
		make_batched_checkout_repo "large-checkout-$count" "$count" &&
		trace_log="$TRASH_DIRECTORY/large-checkout-$count.ndjson" &&
		test_when_finished stop_executor_server &&
		TMPDIR="$TRASH_DIRECTORY" restart_server_with_trace ordered-batch-checkout "$trace_log" &&
		(
			cd "large-checkout-$count" &&
			env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-batched-checkout.json" \
				TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
				GIT_TEST_CHECKOUT_WORKERS=1 git checkout with-lfs &&
			test-tool textil-ext-executor-server verify-checkout --items="$count" &&
			echo target >expected-control &&
			test_cmp expected-control control.txt &&
			git rev-parse HEAD >actual-head &&
			git rev-parse with-lfs >expected-head &&
			test_cmp expected-head actual-head
		) &&
		test_line_count = 2 "$trace_log" &&
		check_batch_trace 8388608 "$count" "$trace_log" || return 1
	done
'

test_expect_success 'byte-bounded slices preserve every materialize result in request order' '
	make_batched_checkout_repo sliced-checkout 40 &&
	trace_log="$TRASH_DIRECTORY/sliced-checkout.ndjson" &&
	test_when_finished stop_executor_server &&
	TMPDIR="$TRASH_DIRECTORY" restart_server_with_trace ordered-batch-checkout "$trace_log" &&
	(
		cd sliced-checkout &&
		env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-batched-checkout.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			GIT_TEST_CHECKOUT_WORKERS=1 GIT_TEST_TEXTIL_EXT_MAX_REQUEST_BYTES=1024 \
			git checkout with-lfs &&
		test-tool textil-ext-executor-server verify-checkout --items=40
	) &&
	grep "\"phase\":\"preflight\"" "$trace_log" >preflight-slices &&
	grep "\"phase\":\"materialize\"" "$trace_log" >materialize-slices &&
	test_line_count -gt 1 preflight-slices &&
	test_line_count -gt 1 materialize-slices &&
	check_batch_trace 1024 40 "$trace_log"
'

test_expect_success 'later preflight or materialize slice failure precedes all checkout mutation' '
	for phase in preflight materialize
	do
		make_batched_checkout_repo "failed-$phase-slice" 40 &&
		trace_log="$TRASH_DIRECTORY/failed-$phase-slice.ndjson" &&
		test_when_finished stop_executor_server &&
		TMPDIR="$TRASH_DIRECTORY" restart_server_with_trace "later-$phase-error" "$trace_log" &&
		(
			cd "failed-$phase-slice" &&
			echo "keep untracked bytes" >local-note.txt &&
			cp local-note.txt expected-note &&
			cp control.txt expected-control &&
			git status --porcelain --untracked-files=no >before-tracked &&
			git rev-parse HEAD >before-head &&
			cp .git/index before-index &&
			test_must_fail env \
				TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy-ipc-batched-checkout.json" \
				TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
				GIT_TEST_CHECKOUT_WORKERS=1 GIT_TEST_TEXTIL_EXT_MAX_REQUEST_BYTES=1024 \
				git checkout with-lfs 2>err &&
			grep "later $phase slice failed" err &&
			test_cmp before-index .git/index &&
			git rev-parse HEAD >after-head &&
			test_cmp before-head after-head &&
			test_cmp expected-control control.txt &&
			test_cmp expected-note local-note.txt &&
			test_path_is_missing assets &&
			git status --porcelain --untracked-files=no >after-tracked &&
			test_cmp before-tracked after-tracked
		) &&
		grep "\"phase\":\"$phase\"" "$trace_log" >failed-phase-slices &&
		test_line_count = 2 failed-phase-slices &&
		if test "$phase" = preflight
		then
			! grep "\"phase\":\"materialize\"" "$trace_log"
		fi || return 1
	done
'

test_expect_success 'too-small request budgets reject headers and singleton items explicitly' '
	restart_server ok &&
	test_when_finished stop_executor_server &&
	test_must_fail env TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		GIT_TEST_TEXTIL_EXT_MAX_REQUEST_BYTES=0 \
		test-tool textil-ext-executor-server send-preflight \
			--repo-root=/r --operation=x --path=asset.bin >out &&
	grep "request header exceeds 0 byte budget" out &&
	test_must_fail env TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		GIT_TEST_TEXTIL_EXT_MAX_REQUEST_BYTES=160 \
		test-tool textil-ext-executor-server send-preflight \
			--repo-root=/r --operation=x --path=asset.bin >out &&
	grep "request item '\''asset.bin'\'' exceeds 160 byte budget" out
'

test_expect_success 'aggregate cap removal retains exact message and source-path byte bounds' '
	test_when_finished stop_executor_server &&
	restart_server message-max &&
	test_must_fail env TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-preflight --path=asset.bin >out &&
	grep "takeover error:" out &&
	restart_server message-too-long &&
	test_must_fail env TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-preflight --path=asset.bin >out &&
	grep "invalid response" out &&
	restart_server materialize-src-path-max &&
	env TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-materialize >out &&
	grep "^status=ok$" out &&
	restart_server materialize-src-path-too-long &&
	test_must_fail env TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		test-tool textil-ext-executor-server send-materialize >out &&
	grep "invalid response" out
'

test_done
