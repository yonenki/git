#!/bin/sh

test_description='textil-ext: checkin_convert canonicalization for status/diff

Verifies that the checkin_convert takeover fires during status/diff
canonicalization (convert_to_git called from diff_populate_filespec),
not only during CONV_WRITE_OBJECT (git add).  This ensures that
"git status" shows a clean working tree when the ext produces the
same pointer content as what is stored in the index.'

. ./test-lib.sh

test-tool textil-ext-executor-server SUPPORTS_SIMPLE_IPC || {
	skip_all='simple IPC not supported on this platform'
	test_done
}

IPC_PATH="$TRASH_DIRECTORY/textil-ext-canon"

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

# === Setup ===

test_expect_success 'setup: policy for checkin_convert takeover' '
	setup_policy "$(pwd)/policy-canon.json" <<-\EOF
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

test_expect_success 'setup: create repo with pointer in index' '
	restart_server checkin-convert-checkin &&
	git init canon-repo &&
	(
		cd canon-repo &&
		echo "*.bin filter=lfs diff=lfs merge=lfs -text" >.gitattributes &&
		echo "plain" >file.txt &&
		git add .gitattributes file.txt &&
		git commit -m "base" &&

		# Stage a.bin via checkin_convert takeover (writes pointer)
		echo "binary-content-a" >a.bin &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-canon.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git add a.bin &&

		# Verify pointer is in index
		git show :a.bin >../staged-verify &&
		grep "version https://git-lfs.github.com/spec/v1" ../staged-verify &&

		git commit -m "add lfs-tracked file via ext" &&

		# Force later status runs to re-compare content instead of
		# trusting the cached stat tuple from the commit.
		test-tool chmtime =+1 a.bin
	)
'

# === Core canonicalization tests ===

test_expect_success 'git status: clean after checkout with checkin_convert active' '
	restart_server checkin-convert-checkin &&
	(
		cd canon-repo &&
		# Working tree has real content; index has pointer.
		# Without the src&&dst gate fix, git status would show
		# a.bin as modified because canonicalization via
		# diff_populate_filespec would not fire checkin_convert.
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-canon.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git status --porcelain >../status-out &&
		test_must_be_empty ../status-out
	)
'

test_expect_success 'git diff: no diff with checkin_convert active' '
	restart_server checkin-convert-checkin &&
	(
		cd canon-repo &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-canon.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git diff >../diff-out &&
		test_must_be_empty ../diff-out
	)
'

test_expect_success 'git status: modified shown WITHOUT ext env (control)' '
	(
		cd canon-repo &&
		# Without ext env, checkin_convert does not fire, so
		# working tree content differs from index pointer.
		git status --porcelain >../status-no-ext &&
		grep "M.*a.bin" ../status-no-ext
	)
'

test_expect_success 'git status: dirty fallback when controller is unavailable' '
	stop_executor_server &&
	(
		cd canon-repo &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-canon.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git status --porcelain >../status-no-controller &&
		grep "M.*a.bin" ../status-no-controller
	)
'

test_expect_success 'git add: still fails closed when controller is unavailable' '
	(
		cd canon-repo &&
		echo "new-binary" >missing.bin &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-canon.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git add missing.bin 2>../add-no-controller.err &&
		grep "failed to connect to endpoint" ../add-no-controller.err
	)
'

test_expect_success 'git diff --cached: no diff (index unchanged)' '
	restart_server checkin-convert-checkin &&
	(
		cd canon-repo &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-canon.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			TEXTIL_GIT_EXT_ENDPOINT="$IPC_PATH" \
			git diff --cached >../cached-out &&
		test_must_be_empty ../cached-out
	)
'

test_expect_success 'cleanup: stop test helper server' '
	stop_executor_server
'

# === Real backend controller path (requires harness binary) ===

# Resolve harness binary relative to the git source tree
HARNESS_BIN="$TEST_DIRECTORY/../../textil-backend/target/debug/textil-git-ext-harness"

if test -x "$HARNESS_BIN" && command -v python3 >/dev/null 2>&1
then
	test_set_prereq REAL_BACKEND
fi

stop_real_controller () {
	if test -n "$REAL_CONTROLLER_PID"
	then
		kill "$REAL_CONTROLLER_PID" 2>/dev/null
		wait "$REAL_CONTROLLER_PID" 2>/dev/null
		REAL_CONTROLLER_PID=""
	fi
}

start_real_controller () {
	"$HARNESS_BIN" serve --endpoint "$REAL_ENDPOINT" >/dev/null 2>&1 &
	REAL_CONTROLLER_PID=$!
	sleep 0.5
}

test_expect_success REAL_BACKEND 'real-backend: setup repo with LFS content via controller' '
	git init real-repo &&
	(
		cd real-repo &&
		echo "*.bin filter=lfs diff=lfs merge=lfs -text" >.gitattributes &&
		echo "/.textil/" >.gitignore &&
		echo "plain" >file.txt &&
		git add .gitattributes .gitignore file.txt &&
		git commit -m "base"
	) &&

	# Prepare policy + endpoint via harness
	# Use /tmp for the socket to avoid Unix socket path length limit (~108 chars)
	REAL_ENDPOINT="$(mktemp -u /tmp/textil-test-ctrl-XXXXXX.sock)" &&
	REAL_HARNESS_JSON="$("$HARNESS_BIN" prepare \
		--project-root "$(pwd)/real-repo" \
		--endpoint "$REAL_ENDPOINT" \
		--mode standard 2>/dev/null)" &&
	REAL_POLICY_PATH="$(printf "%s" "$REAL_HARNESS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[\"policy_path\"])")" &&
	REAL_POLICY_VERSION="$(printf "%s" "$REAL_HARNESS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)[\"policy_version\"])")" &&

	# Start real controller (in helper function to avoid &&-chain break)
	start_real_controller &&

	# Add LFS file via real checkin_convert
	(
		cd real-repo &&
		echo "binary-data-for-real-backend" >real.bin &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$REAL_POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION="$REAL_POLICY_VERSION" \
			TEXTIL_GIT_EXT_ENDPOINT="$REAL_ENDPOINT" \
			git add real.bin &&

		# Verify pointer in index
		git show :real.bin >../real-staged &&
		grep "version https://git-lfs.github.com/spec/v1" ../real-staged &&
		git commit -m "add real.bin via real backend"
	)
'

test_expect_success REAL_BACKEND 'real-backend: git status clean (canonicalization via real controller)' '
	(
		cd real-repo &&
		# This exercises the actual input_path reading in the backend.
		# With the absolute-path fix, the backend can resolve the
		# temp file regardless of CWD.
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$REAL_POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION="$REAL_POLICY_VERSION" \
			TEXTIL_GIT_EXT_ENDPOINT="$REAL_ENDPOINT" \
			git status --porcelain >../real-status-out &&
		test_must_be_empty ../real-status-out
	)
'

test_expect_success REAL_BACKEND 'real-backend: git diff empty (canonicalization via real controller)' '
	(
		cd real-repo &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$REAL_POLICY_PATH" \
			TEXTIL_GIT_EXT_POLICY_VERSION="$REAL_POLICY_VERSION" \
			TEXTIL_GIT_EXT_ENDPOINT="$REAL_ENDPOINT" \
			git diff >../real-diff-out &&
		test_must_be_empty ../real-diff-out
	)
'

test_expect_success REAL_BACKEND 'real-backend: cleanup controller' '
	stop_real_controller
'

test_done
