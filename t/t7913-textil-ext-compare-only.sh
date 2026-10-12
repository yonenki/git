#!/bin/sh

test_description='textil-ext: only explicitly compare-only conversions may return unknown'

. ./test-lib.sh

test-tool textil-ext-executor-server SUPPORTS_SIMPLE_IPC || {
	skip_all='simple IPC not supported on this platform'
	test_done
}

IPC_PATH="$TRASH_DIRECTORY/textil-compare-only"
ENDPOINT="$IPC_PATH"

stop_server () {
	test-tool textil-ext-executor-server stop-daemon --name="$IPC_PATH" 2>/dev/null
	return 0
}

restart_server () {
	stop_server &&
	test-tool textil-ext-executor-server start-daemon --name="$IPC_PATH" --reply-mode="$1" &&
	test-tool textil-ext-executor-server is-active --name="$IPC_PATH"
}

ext_git () {
	env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy.json" \
		TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$ENDPOINT" git "$@"
}

ext_must_fail () {
	test_must_fail env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy.json" \
		TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$ENDPOINT" git "$@"
}

prepare_repo () {
	git clone -q seed "$1" &&
	(cd "$1" && test-tool chmtime =-60 file.txt && git update-index --refresh)
}

# Every fail-closed test runs with both an unset endpoint and a stopped server.
# Check the conversion diagnostic as well as the unchanged staged identity.
assert_closed () {
	git ls-files --stage file.txt >before &&
	for ENDPOINT in "" "$IPC_PATH"
	do
		if test -n "$STDIN_INPUT"
		then
			ext_must_fail "$@" <"$STDIN_INPUT" >out 2>err
		else
			ext_must_fail "$@" >out 2>err
		fi &&
		test_grep "textil-ext: checkin_convert failed" err &&
		git ls-files --stage file.txt >after &&
		test_cmp before after || return 1
	done
}

test_expect_success 'setup content-preserving takeover and stock commits' '
	test_atexit stop_server &&
	cat >policy.json <<-\EOF &&
	{"version":"v1","rules":[{"id":"compare","phases":["checkin_convert"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"takeover","strict":true,"fallback":"deny","required_capabilities":["lfs-checkin-convert"]}]}
	EOF
	git init seed &&
	(
		cd seed &&
		echo "*.txt filter=lfs" >.gitattributes &&
		printf "one\ntwo\nthree\n" >file.txt &&
		git add . && git commit -m base &&
		printf "one\nchanged\nthree\n" >file.txt &&
		git diff --full-index >../change.patch &&
		git checkout -- file.txt &&
		git checkout -b merge-side &&
		printf "one\nside\nthree\n" >file.txt &&
		git commit -am side &&
		git checkout -b merge-main HEAD~1 &&
		printf "one\nmain\nthree\n" >file.txt &&
		git commit -am main &&
		git checkout -b delete-side HEAD~1 &&
		git rm file.txt && git commit -m delete &&
		git checkout -b base HEAD~1
	)
'

for operation in renormalize info-only dry-run
 do
	case "$operation" in
	renormalize) args="add --renormalize file.txt" ;;
	info-only) args="update-index --info-only file.txt" ;;
	dry-run) args="add -n file.txt" ;;
	esac
	test_expect_success "$operation cannot stage substitute content" '
		prepare_repo "$operation" &&
		(cd "$operation" && echo modified >>file.txt && assert_closed $args)
	'
 done

for mode in file stdin stdin-paths sized-stdin
 do
	for context in ordinary index-context
	do
		if test "$mode" = sized-stdin && test "$context" = ordinary
		then
			continue
		fi
		test_expect_success "hash-object $mode $context fails closed without writing" '
			prepare_repo "hash-$mode-$context" &&
			(
				cd "hash-$mode-$context" &&
				context_arg= &&
				if test "$context" = index-context
				then context_arg=--textil-index-context
				fi &&
				case "$mode" in
				file) assert_closed hash-object $context_arg file.txt ;;
				stdin) STDIN_INPUT=file.txt assert_closed hash-object $context_arg --path=file.txt --stdin ;;
				stdin-paths) echo file.txt >paths && STDIN_INPUT=paths assert_closed hash-object $context_arg --stdin-paths ;;
				sized-stdin) STDIN_INPUT=file.txt assert_closed hash-object $context_arg --path=file.txt --stdin --textil-stdin-size=14 ;;
				esac
			)
		'
	done
 done

test_expect_success 'plain apply conversion fails closed; canonical index patches remain stock-equivalent offline' '
	prepare_repo apply-plain &&
	(cd apply-plain && assert_closed apply ../change.patch) &&
	for option in --index --cached --3way
	do
		prepare_repo "stock-$option" &&
		(cd "stock-$option" && git apply "$option" ../change.patch &&
			git show :file.txt >../stock-staged) &&
		case_nr=0 &&
		for ENDPOINT in "" "$IPC_PATH"
		do
			case_nr=$((case_nr + 1)) &&
			prepare_repo "canonical-$option-$case_nr" &&
			(
				cd "canonical-$option-$case_nr" &&
				ext_git apply "$option" ../change.patch &&
				git show :file.txt >../actual-staged
			) &&
			test_cmp stock-staged actual-staged &&
			test_cmp "stock-$option/file.txt" "canonical-$option-$case_nr/file.txt" ||
				return 1
		done || return 1
	done
'

for strategy in ort recursive
 do
	test_expect_success "merge $strategy renormalization content fails closed" '
		prepare_repo "merge-$strategy" &&
		(
			cd "merge-$strategy" && git checkout merge-main &&
			assert_closed merge-tree --write-tree -Xrenormalize origin/merge-main origin/merge-side &&
			test_must_be_empty out &&
			assert_closed merge -s "$strategy" -Xrenormalize origin/merge-side
		)
	'
 done

test_expect_success 'merge-ort blob_unchanged cannot resolve modify/delete with unknown content' '
	prepare_repo merge-unchanged &&
	(cd merge-unchanged && git checkout merge-main &&
		assert_closed merge-tree --write-tree -Xrenormalize origin/merge-main origin/delete-side &&
		test_must_be_empty out &&
		assert_closed merge -Xrenormalize origin/delete-side)
'

test_expect_success 'add -p fails before staging a patch made from substitute content' '
	prepare_repo interactive &&
	(
		cd interactive && echo changed >>file.txt &&
		printf "y\ny\n" >answers &&
		assert_closed add -p file.txt <answers
	)
'

for command in "diff --patch" "diff --stat" "blame file.txt"
 do
	test_expect_success "$command content fails closed" '
		prepare_repo "content-$test_count" &&
		(cd "content-$test_count" && echo changed >>file.txt && assert_closed $command)
	'
 done

test_expect_success 'combined working-tree diff content fails closed' '
	prepare_repo combined &&
	(
		cd combined && git checkout merge-main &&
		test_must_fail git merge origin/merge-side &&
		assert_closed diff --cc
	)
'

test_expect_success 'empty committed takeover becomes modified while offline and stays visible after restart' '
	restart_server checkin-content &&
	git init empty &&
	(
		cd empty && echo "*.txt filter=lfs" >.gitattributes &&
		>file.txt && ext_git add . && git commit -m empty &&
		echo changed >file.txt && stop_server &&
		for ENDPOINT in "" "$IPC_PATH"
		do
			ext_git status --porcelain >status &&
			test_grep " M file.txt" status &&
			ext_git diff-files --raw >raw &&
			test_grep "file.txt" raw &&
			ext_git diff --raw >diff &&
			test_grep "file.txt" diff || return 1
		done &&
		restart_server checkin-content &&
		ext_git diff-files --raw >restarted && test_grep "file.txt" restarted
	)
'

test_expect_success 'status and raw diff remain usable offline; patch content does not' '
	prepare_repo display &&
	(
		cd display && echo changed >>file.txt && stop_server &&
		for ENDPOINT in "" "$IPC_PATH"
		do
			ext_git status --porcelain >status && test_grep " M file.txt" status &&
			ext_git diff --raw >raw && test_grep "file.txt" raw &&
			ext_git diff --name-only >names && test_grep "^file.txt$" names &&
			ext_must_fail diff --patch >patch 2>err &&
			test_grep "textil-ext: checkin_convert failed" err || return 1
		done
	)
'

test_expect_success 'executor status distinguishes absence, transport, rejection, error and invalid reply' '
	stop_server &&
	for state in endpoint-unset connect-failed rejected error invalid
	do
		case "$state" in
		endpoint-unset) endpoint= ;;
		connect-failed) endpoint="$IPC_PATH" ;;
		rejected|error) restart_server "$state" && endpoint="$IPC_PATH" ;;
		invalid) restart_server invalid-pkt && endpoint="$IPC_PATH" ;;
		esac &&
		test_must_fail env TEXTIL_GIT_EXT_ENDPOINT="$endpoint" \
			test-tool textil-ext-executor-server send-checkin-convert >out &&
		test_grep "^status=$state$" out || return 1
	done &&
	prepare_repo rejected-display &&
	(
		cd rejected-display && printf "ONE\ntwo\nthree\n" >file.txt &&
		for mode in rejected error invalid-pkt rejected-connect-message error-endpoint-message
		do
			restart_server "$mode" && ENDPOINT="$IPC_PATH" &&
			ext_must_fail status --porcelain >out 2>err || return 1
		done
	)
'

test_expect_success 'patch-id worktree oid fails closed, including header-only identity' '
	prepare_repo patch-id &&
	(
		cd patch-id && echo changed >>file.txt && stop_server &&
		for ENDPOINT in "" "$IPC_PATH"
		do
			test_must_fail env TEXTIL_GIT_EXT_POLICY_PATH="$TRASH_DIRECTORY/policy.json" \
				TEXTIL_GIT_EXT_POLICY_VERSION=v1 TEXTIL_GIT_EXT_ENDPOINT="$ENDPOINT" \
				test-tool textil-ext-executor-server worktree-patch-id --path=file.txt >out 2>err &&
			test_grep "textil-ext: checkin_convert failed" err || return 1
		done
	)
'

test_expect_success 'submodule summary omits an unknown regular-file replacement' '
	prepare_repo summary &&
	(
		cd summary && git clone -q ../seed module.txt &&
		git add module.txt && git commit -m submodule &&
		mv module.txt saved-module &&
		echo replacement >module.txt && stop_server &&
		for ENDPOINT in "" "$IPC_PATH"
		do
			ext_git submodule summary -- module.txt >summary &&
			test_must_be_empty summary || return 1
		done
	)
'

test_expect_success 'difftool does not reuse unknown worktree content' '
	prepare_repo difftool &&
	(
		cd difftool && echo changed >>file.txt && stop_server &&
		for ENDPOINT in "" "$IPC_PATH"
		do
			ext_must_fail difftool --dir-diff --no-prompt --extcmd=true -- file.txt >out 2>err &&
			test_grep "could not write.*file.txt" err || return 1
		done
	)
'

test_expect_success 'unknown external diff and per-file difftool do not report hash errors' '
	prepare_repo external &&
	(
		cd external && echo changed >>file.txt && stop_server &&
		for ENDPOINT in "" "$IPC_PATH"
		do
			GIT_EXTERNAL_DIFF=true ext_git diff >out 2>err &&
			test_must_be_empty err &&
			ext_git difftool --no-prompt --extcmd=true -- file.txt >out 2>err &&
			test_must_be_empty err || return 1
		done
	)
'

test_expect_success 'unknown binary size is not cached for later content diff' '
	prepare_repo binary-stat &&
	(
		cd binary-stat && echo "*.txt diff=binary" >>.gitattributes &&
		git config diff.binary.binary true &&
		printf "ONE\ntwo\nthree\n" >file.txt && stop_server &&
		assert_closed diff --stat
	)
'

test_expect_success SANITY 'ordinary unreadable content is not an unavailable comparison' '
	prepare_repo unreadable &&
	(
		cd unreadable &&
		echo ordinary >ordinary && git add ordinary && git commit -m ordinary &&
		echo changed >>ordinary &&
		test_when_finished "chmod +r ordinary" &&
		chmod -r ordinary &&
		test_must_fail git diff --patch >out 2>err &&
		test_grep "cannot hash ordinary" err
	)
'

test_expect_success MINGW 'ordinary sharing-denied read is not an unavailable comparison' '
	prepare_repo sharing-denied &&
	(
		cd sharing-denied &&
		echo ordinary >ordinary && git add ordinary && git commit -m ordinary &&
		echo changed >>ordinary &&
		cat >locked-diff.ps1 <<-\EOF &&
		$stream = [System.IO.File]::Open("ordinary", "Open", "Read", "None")
		try {
			& $env:TEXTIL_TEST_GIT diff --patch
			$result = $LASTEXITCODE
		} finally {
			$stream.Dispose()
		}
		exit $result
		EOF
		TEXTIL_TEST_GIT="$(cygpath -am "$GIT_BUILD_DIR/git.exe")" \
			test_expect_code 128 powershell.exe -NoProfile -ExecutionPolicy Bypass \
			-File ./locked-diff.ps1 >out 2>err &&
		test_grep "cannot hash ordinary" err
	)
'

test_expect_success MINGW 'ordinary submodule replacement read failure retains stock summary fall-through' '
	prepare_repo summary-denied &&
	(
		cd summary-denied && git clone -q ../seed module &&
		git add module && git commit -m submodule &&
		mv module saved-module && echo replacement >module &&
		cat >locked-summary.ps1 <<-\EOF &&
		$stream = [System.IO.File]::Open("module", "Open", "Read", "None")
		try {
			& $env:TEXTIL_TEST_GIT submodule summary -- module
			$result = $LASTEXITCODE
		} finally {
			$stream.Dispose()
		}
		exit $result
		EOF
		TEXTIL_TEST_GIT="$(cygpath -am "$GIT_BUILD_DIR/git.exe")" \
			powershell.exe -NoProfile -ExecutionPolicy Bypass \
			-File ./locked-summary.ps1 >out 2>err &&
		test_grep "couldn.t hash object from .module." err &&
		test_grep "module" out
	)
'

test_expect_success 'early durability fence failure is distinct from conversion unavailability' '
	prepare_repo early-fence &&
	restart_server checkin-deferred-fence-error &&
	(
		cd early-fence && echo changed >>file.txt && ENDPOINT="$IPC_PATH" &&
		git ls-files --stage >before &&
		GIT_TEST_TEXTIL_EXT_FENCE_MAX_OIDS=1 ext_must_fail add file.txt >out 2>err &&
		test_grep "early durability fence failed" err &&
		git ls-files --stage >after && test_cmp before after
	)
'

test_expect_success 'closed dry-run and notes resolution; replace path=NULL remains outside takeover' '
	prepare_repo identity &&
	stop_server &&
	(
		cd identity && echo changed >>file.txt &&
		assert_closed add -n file.txt &&
		git notes add -m base HEAD &&
		git update-ref refs/notes/other refs/notes/commits &&
		git notes add -f -m ours HEAD &&
		git notes --ref=other add -f -m theirs HEAD &&
		test_must_fail git notes merge other &&
		note=$(git rev-parse HEAD) &&
		echo resolved >.git/NOTES_MERGE_WORKTREE/$note &&
		echo "* filter=lfs" >.git/info/attributes &&
		git rev-parse refs/notes/commits >before &&
		for ENDPOINT in "" "$IPC_PATH"
		do
			ext_must_fail notes merge --commit >out 2>err &&
			test_grep "textil-ext: checkin_convert failed" err &&
			git rev-parse refs/notes/commits >after &&
			test_cmp before after || return 1
		done &&
		write_script replace-editor <<-\EOF &&
		echo replacement >"$1"
		EOF
		blob=$(git rev-parse HEAD:file.txt) &&
		GIT_EDITOR="\"$PWD/replace-editor\"" ext_git replace --edit "$blob" &&
		git cat-file blob "$blob" >replaced &&
		echo replacement >expect &&
		test_cmp expect replaced
	)
'

test_done
