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

# Helper: write policy to absolute path and export env
setup_policy () {
	cat >"$1" &&
	POLICY_PATH="$1"
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
		echo "binary-a" >a.bin &&
		echo "binary-b" >b.bin &&
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

test_expect_success 'key-order: ok with optional message accepted' '
	restart_server ok-with-message &&
	(
		cd executor-ipc-repo &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs &&
		test -f a.bin &&
		git checkout main
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

# === Oversized reply rejection ===

test_expect_success 'strict parser: oversized reply rejected before parsing' '
	restart_server oversized &&
	(
		cd executor-ipc-repo &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git checkout with-lfs 2>err &&
		grep "reply too large" err
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
		printf "binary-data" >"$LF_NAME" &&
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

test_expect_success 'checkin_convert-ok: executor parses delim-separated src_paths' '
	restart_server checkin-convert-checkin &&
	TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
	test-tool textil-ext-executor-server send-checkin-convert \
		--name="$IPC_PATH" >out &&
	grep "^status=ok$" out
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

test_done
