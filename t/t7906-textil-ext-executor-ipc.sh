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

ADMISSION_PACKET_LOG="$TRASH_DIRECTORY/admission-packets.log"

admission_git () {
	env \
		TEXTIL_GIT_EXT_POLICY_PATH="$POLICY_PATH" \
		TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
		TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
		GIT_TRACE_PACKET="$ADMISSION_PACKET_LOG" \
		git -c filter.lfs.process= -c filter.lfs.smudge=cat \
			-c filter.lfs.required=false "$@"
}

expect_admission () {
	grep "> checkout_admission=$1\$" "$ADMISSION_PACKET_LOG" >admissions &&
	test_line_count = "$2" admissions &&
	! grep "> checkout_\\(two_tree\\|verified\\|overwrite\\)=" "$ADMISSION_PACKET_LOG"
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

test_expect_success 'setup initial admission source with a nested LFS target' '
	git init admission-source &&
	(
		cd admission-source &&
		git config filter.lfs.process "" &&
		git config filter.lfs.clean cat &&
		git config filter.lfs.smudge cat &&
		git config filter.lfs.required false &&
		echo "*.bin filter=lfs -text" >.gitattributes &&
		mkdir nested &&
		write_pointer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 9 >target.bin &&
		cp target.bin nested/asset.bin &&
		git add . &&
		git commit -m first &&
		git tag first &&
		write_pointer bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 9 >target.bin &&
		git add target.bin &&
		git commit -m second &&
		git tag second
	)
'

test_expect_success 'initial forced checkout admits only positively absent targets' '
	restart_server admitted-checkout &&
	git clone --local --no-checkout admission-source admission-absent &&
	rm -f "$ADMISSION_PACKET_LOG" &&
	(
		cd admission-absent &&
		admission_git checkout -q -f first &&
		test_path_is_missing target.bin &&
		test_path_is_missing nested/asset.bin &&
		git ls-files -t target.bin nested/asset.bin >actual &&
		printf "S nested/asset.bin\nS target.bin\n" >expect &&
		test_cmp expect actual &&
		expect_admission verified_initial_absence 2 &&
		! grep "> old_blob_oid=" "$ADMISSION_PACKET_LOG"
	)
'

test_expect_success 'initial force separates an existing target from its absent sibling' '
	git clone --local --no-checkout admission-source admission-existing &&
	echo accepted-before-checkout >admission-existing/target.bin &&
	rm -f "$ADMISSION_PACKET_LOG" &&
	(
		cd admission-existing &&
		admission_git checkout -q -f first &&
		printf "materialized-by-textil-batch\n" >expect &&
		test_cmp expect target.bin &&
		test_path_is_missing nested/asset.bin &&
		git ls-files -t target.bin nested/asset.bin >actual &&
		printf "S nested/asset.bin\nH target.bin\n" >expect &&
		test_cmp expect actual &&
		expect_admission materialize 1 &&
		expect_admission verified_initial_absence 1
	)
'

test_expect_success 'initial force directory collision materializes instead of claiming absence' '
	git clone --local --no-checkout admission-source admission-directory &&
	mkdir admission-directory/target.bin &&
	echo untracked >admission-directory/target.bin/contents &&
	rm -f "$ADMISSION_PACKET_LOG" &&
	(
		cd admission-directory &&
		admission_git checkout -q -f first &&
		printf "materialized-by-textil-batch\n" >expect &&
		test_cmp expect target.bin &&
		expect_admission materialize 1 &&
		expect_admission verified_initial_absence 1
	)
'

test_expect_success 'initial force non-directory ancestor is a collision, not absence' '
	git clone --local --no-checkout admission-source admission-ancestor &&
	echo ancestor-content >admission-ancestor/nested &&
	rm -f "$ADMISSION_PACKET_LOG" &&
	(
		cd admission-ancestor &&
		admission_git checkout -q -f first &&
		printf "materialized-by-textil-batch\n" >expect &&
		test_cmp expect nested/asset.bin &&
		test_path_is_missing target.bin &&
		expect_admission materialize 1 &&
		expect_admission verified_initial_absence 1
	)
'

test_expect_success SYMLINKS 'initial force symlink ancestor is never absence or authority over its referent' '
	git clone --local --no-checkout admission-source admission-symlink &&
	mkdir admission-referent &&
	echo keep-referent >admission-referent/asset.bin &&
	ln -s ../admission-referent admission-symlink/nested &&
	rm -f "$ADMISSION_PACKET_LOG" &&
	(
		cd admission-symlink &&
		admission_git checkout -q -f first &&
		printf "materialized-by-textil-batch\n" >expect &&
		test_cmp expect nested/asset.bin &&
		echo keep-referent >expect &&
		test_cmp expect ../admission-referent/asset.bin &&
		expect_admission materialize 1 &&
		expect_admission verified_initial_absence 1
	)
'

test_expect_success POSIXPERM,SANITY 'initial absence metadata error fails before any preflight or writes' '
	git clone --local --no-checkout admission-source admission-permission &&
	mkdir admission-permission/nested &&
	chmod 000 admission-permission/nested &&
	test_when_finished "chmod 755 admission-permission/nested" &&
	rm -f "$ADMISSION_PACKET_LOG" &&
	(
		cd admission-permission &&
		test_expect_code 128 admission_git checkout -q -f first 2>err &&
		grep "cannot stat" err &&
		test_path_is_missing target.bin &&
		! grep "> checkout_admission=" "$ADMISSION_PACKET_LOG"
	)
'

test_expect_success 'ordinary two-tree checkout retains predecessor and verified admission' '
	git clone --local --no-checkout admission-source admission-normal &&
	git -C admission-normal -c filter.lfs.process= -c filter.lfs.smudge=cat \
		-c filter.lfs.required=false checkout first &&
	rm -f "$ADMISSION_PACKET_LOG" &&
	(
		cd admission-normal &&
		git rev-parse first:target.bin >old &&
		admission_git checkout second &&
		expect_admission verified_two_tree 1 &&
		grep "> old_blob_oid=$(cat old)\$" "$ADMISSION_PACKET_LOG" &&
		git ls-files -t target.bin >actual &&
		echo "S target.bin" >expect &&
		test_cmp expect actual
	)
'

test_expect_success 'ordinary dirty checkout rejects without preflight or overwriting user bytes' '
	git clone --local --no-checkout admission-source admission-dirty &&
	git -C admission-dirty -c filter.lfs.process= -c filter.lfs.smudge=cat \
		-c filter.lfs.required=false checkout first &&
	echo user-modification >admission-dirty/target.bin &&
	rm -f "$ADMISSION_PACKET_LOG" &&
	(
		cd admission-dirty &&
		test_expect_code 1 admission_git checkout second 2>err &&
		grep "would be overwritten" err &&
		echo user-modification >expect &&
		test_cmp expect target.bin &&
		test "$(git rev-parse HEAD)" = "$(git rev-parse first)" &&
		! grep "> checkout_admission=" "$ADMISSION_PACKET_LOG"
	)
'

test_expect_success 'force on an indexed target still materializes with its real predecessor' '
	rm -f "$ADMISSION_PACKET_LOG" &&
	(
		cd admission-dirty &&
		git rev-parse first:target.bin >old &&
		admission_git checkout -q -f second &&
		printf "materialized-by-textil-batch\n" >expect &&
		test_cmp expect target.bin &&
		expect_admission materialize 1 &&
		grep "> old_blob_oid=$(cat old)\$" "$ADMISSION_PACKET_LOG" &&
		! grep "> checkout_admission=verified_initial_absence\$" "$ADMISSION_PACKET_LOG"
	)
'

test_expect_success 'initial non-force checkout keeps untracked collision rejection' '
	git clone --local --no-checkout admission-source admission-untracked &&
	echo untracked-user-content >admission-untracked/target.bin &&
	rm -f "$ADMISSION_PACKET_LOG" &&
	(
		cd admission-untracked &&
		test_expect_code 1 admission_git checkout first 2>err &&
		grep "would be overwritten" err &&
		echo untracked-user-content >expect &&
		test_cmp expect target.bin &&
		! grep "> checkout_admission=" "$ADMISSION_PACKET_LOG"
	)
'

test_expect_success 'stock submodule initialization emits initial absence and preserves parent gitlink' '
	git init admission-parent &&
	(
		cd admission-parent &&
		git -c protocol.file.allow=always -c filter.lfs.process= \
			-c filter.lfs.smudge=cat -c filter.lfs.required=false \
			submodule add ../admission-source child &&
		git -C child -c filter.lfs.process= -c filter.lfs.smudge=cat \
			-c filter.lfs.required=false checkout first &&
		git add .gitmodules child &&
		git commit -m child
	) &&
	git clone --local admission-parent admission-parent-clone &&
	rm -f "$ADMISSION_PACKET_LOG" &&
	(
		cd admission-parent-clone &&
		git ls-files --stage child >parent-before &&
		admission_git -c protocol.file.allow=always submodule update --init &&
		git ls-files --stage child >parent-after &&
		test_cmp parent-before parent-after &&
		test_path_is_missing child/target.bin &&
		test_path_is_missing child/nested/asset.bin &&
		git -C child ls-files -t target.bin nested/asset.bin >actual &&
		printf "S nested/asset.bin\nS target.bin\n" >expect &&
		test_cmp expect actual &&
		expect_admission verified_initial_absence 2 &&
		! grep "> old_blob_oid=" "$ADMISSION_PACKET_LOG"
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

test_done
