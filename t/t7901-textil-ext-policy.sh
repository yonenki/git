#!/bin/sh

test_description='textil-ext-policy: strict JSON parser and policy loader'

. ./test-lib.sh

# Helper: create a valid policy.v1.json
write_valid_policy () {
	cat >"$1" <<-\EOF
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
	      "required_capabilities": ["lfs-preflight", "lfs-materialize", "lfs-checkin-convert"]
	    }
	  ]
	}
	EOF
}

# === Phase1-3 env contract tests ===

test_expect_success 'no env vars: git operates normally' '
	git init normal-repo &&
	(
		cd normal-repo &&
		unset TEXTIL_GIT_EXT_POLICY_PATH &&
		unset TEXTIL_GIT_EXT_POLICY_VERSION &&
		git status
	)
'

test_expect_success 'only PATH set: fatal error' '
	git init only-path &&
	(
		cd only-path &&
		write_valid_policy ../policy.json &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy.json" \
			git status 2>err &&
		grep "TEXTIL_GIT_EXT_POLICY_PATH.*set but.*TEXTIL_GIT_EXT_POLICY_VERSION.*not" err
	)
'

test_expect_success 'only VERSION set: fatal error' '
	git init only-version &&
	(
		cd only-version &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "TEXTIL_GIT_EXT_POLICY_VERSION.*set but.*TEXTIL_GIT_EXT_POLICY_PATH.*not" err
	)
'

test_expect_success 'version mismatch: fatal error' '
	git init version-mismatch &&
	(
		cd version-mismatch &&
		write_valid_policy ../policy-vm.json &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-vm.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v2 \
			git status 2>err &&
		grep "unsupported policy version.*v2.*expected.*v1" err
	)
'

test_expect_success 'missing file: fatal error' '
	git init missing-file &&
	(
		cd missing-file &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="/nonexistent/policy.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "unable to read policy file.*/nonexistent/policy.json" err
	)
'

test_expect_success 'relative path: fatal error' '
	git init relative-path &&
	(
		cd relative-path &&
		write_valid_policy ../policy-rel.json &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="../policy-rel.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "must be an absolute path" err
	)
'

# === Phase1-4 strict parse tests ===

test_expect_success 'valid policy: git operates normally' '
	git init valid-policy &&
	(
		cd valid-policy &&
		write_valid_policy ../policy-ok.json &&
		env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-ok.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status
	)
'

test_expect_success 'valid policy: trace shows loaded with rule count' '
	git init trace-check &&
	(
		cd trace-check &&
		write_valid_policy ../policy-trace.json &&
		GIT_TRACE_TEXTIL_EXT=1 env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../policy-trace.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>trace_out &&
		grep "policy loaded" trace_out &&
		grep "1 rules" trace_out
	)
'

test_expect_success 'no env: trace shows disabled message' '
	git init trace-disabled &&
	(
		cd trace-disabled &&
		unset TEXTIL_GIT_EXT_POLICY_PATH &&
		unset TEXTIL_GIT_EXT_POLICY_VERSION &&
		GIT_TRACE_TEXTIL_EXT=1 git status 2>trace_out &&
		grep "policy disabled" trace_out
	)
'

test_expect_success 'reject: missing version field' '
	git init reject-no-version &&
	(
		cd reject-no-version &&
		cat >../p.json <<-\EOF &&
		{"rules": [{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "missing required field.*version" err
	)
'

test_expect_success 'reject: wrong version in JSON' '
	git init reject-wrong-ver &&
	(
		cd reject-wrong-ver &&
		cat >../p.json <<-\EOF &&
		{"version":"v99","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "unsupported version.*v99" err
	)
'

test_expect_success 'reject: missing rules field' '
	git init reject-no-rules &&
	(
		cd reject-no-rules &&
		echo "{\"version\":\"v1\"}" >../p.json &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "missing required field.*rules" err
	)
'

test_expect_success 'reject: empty rules array' '
	git init reject-empty-rules &&
	(
		cd reject-empty-rules &&
		echo "{\"version\":\"v1\",\"rules\":[]}" >../p.json &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "rules must not be empty" err
	)
'

test_expect_success 'reject: unknown top-level key' '
	git init reject-unknown-top &&
	(
		cd reject-unknown-top &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","extra":"bad","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "unknown top-level key.*extra" err
	)
'

test_expect_success 'reject: unknown key in rule' '
	git init reject-unknown-rule-key &&
	(
		cd reject-unknown-rule-key &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[],"bonus":"bad"}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "unknown key.*bonus.*in rule" err
	)
'

test_expect_success 'reject: unknown key in selector' '
	git init reject-unknown-sel-key &&
	(
		cd reject-unknown-sel-key &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true,"extra":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "unknown key.*extra.*in selector" err
	)
'

test_expect_success 'reject: missing rule id' '
	git init reject-no-id &&
	(
		cd reject-no-id &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "rule missing required field.*id" err
	)
'

test_expect_success 'reject: empty rule id' '
	git init reject-empty-id &&
	(
		cd reject-empty-id &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "rule id must not be empty" err
	)
'

test_expect_success 'reject: missing phases' '
	git init reject-no-phases &&
	(
		cd reject-no-phases &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "missing required field.*phases" err
	)
'

test_expect_success 'reject: empty phases array' '
	git init reject-empty-phases &&
	(
		cd reject-empty-phases &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":[],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "phases must not be empty" err
	)
'

test_expect_success 'reject: unknown phase string' '
	git init reject-bad-phase &&
	(
		cd reject-bad-phase &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["unknown_phase"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "unknown phase.*unknown_phase" err
	)
'

test_expect_success 'reject: unknown action string' '
	git init reject-bad-action &&
	(
		cd reject-bad-action &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"invalid","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "unknown action.*invalid" err
	)
'

test_expect_success 'reject: unknown fallback string' '
	git init reject-bad-fallback &&
	(
		cd reject-bad-fallback &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"ignore","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "unknown fallback.*ignore" err
	)
'

test_expect_success 'reject: takeover + skip (constraint violation)' '
	git init reject-takeover-skip &&
	(
		cd reject-takeover-skip &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"takeover","strict":true,"fallback":"skip","required_capabilities":["cap1"]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "takeover action requires fallback=deny" err
	)
'

test_expect_success 'reject: missing selector' '
	git init reject-no-selector &&
	(
		cd reject-no-selector &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "missing required field.*selector" err
	)
'

test_expect_success 'reject: missing regular_file_only in selector' '
	git init reject-no-rfo &&
	(
		cd reject-no-rfo &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs"},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "selector missing required field.*regular_file_only" err
	)
'

test_expect_success 'reject: duplicate rule ids' '
	git init reject-dup-ids &&
	(
		cd reject-dup-ids &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[
		  {"id":"same","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]},
		  {"id":"same","phases":["preflight"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}
		]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "duplicate rule id.*same" err
	)
'

test_expect_success 'reject: empty capability string' '
	git init reject-empty-cap &&
	(
		cd reject-empty-cap &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"takeover","strict":true,"fallback":"deny","required_capabilities":["good",""]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "must not be empty" err
	)
'

test_expect_success 'reject: empty attr_filter_equals' '
	git init reject-empty-attr &&
	(
		cd reject-empty-attr &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "attr_filter_equals must not be empty" err
	)
'

test_expect_success 'reject: trailing content after JSON' '
	git init reject-trailing &&
	(
		cd reject-trailing &&
		write_valid_policy ../p.json &&
		echo "extra" >>../p.json &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "unexpected content after JSON" err
	)
'

test_expect_success 'reject: missing required_capabilities field' '
	git init reject-no-caps &&
	(
		cd reject-no-caps &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip"}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "missing required field.*required_capabilities" err
	)
'

test_expect_success 'reject: missing action field' '
	git init reject-no-action &&
	(
		cd reject-no-action &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "missing required field.*action" err
	)
'

test_expect_success 'reject: missing strict field' '
	git init reject-no-strict &&
	(
		cd reject-no-strict &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "missing required field.*strict" err
	)
'

test_expect_success 'reject: missing fallback field' '
	git init reject-no-fallback &&
	(
		cd reject-no-fallback &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "missing required field.*fallback" err
	)
'

# === JSON grammar strictness tests ===

test_expect_success 'reject: missing comma between object keys (envelope)' '
	git init reject-missing-comma-obj &&
	(
		cd reject-missing-comma-obj &&
		printf "{\"version\":\"v1\" \"rules\":[]}" >../p.json &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "expected.*," err
	)
'

test_expect_success 'reject: missing comma in array (phases)' '
	git init reject-missing-comma-arr &&
	(
		cd reject-missing-comma-arr &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize" "checkin_convert"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "expected.*," err
	)
'

test_expect_success 'reject: trailing comma in object (rule)' '
	git init reject-trailing-comma-obj &&
	(
		cd reject-trailing-comma-obj &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[],}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "trailing comma" err
	)
'

test_expect_success 'reject: trailing comma in array (phases)' '
	git init reject-trailing-comma-arr &&
	(
		cd reject-trailing-comma-arr &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize",],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "trailing comma" err
	)
'

test_expect_success 'reject: trailing comma in rules array' '
	git init reject-trailing-comma-rules &&
	(
		cd reject-trailing-comma-rules &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]},]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "trailing comma" err
	)
'

test_expect_success 'reject: trailing comma in selector object' '
	git init reject-trailing-comma-sel &&
	(
		cd reject-trailing-comma-sel &&
		cat >../p.json <<-\EOF &&
		{"version":"v1","rules":[{"id":"r","phases":["materialize"],"selector":{"attr_filter_equals":"lfs","regular_file_only":true,},"action":"observe","strict":false,"fallback":"skip","required_capabilities":[]}]}
		EOF
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "trailing comma" err
	)
'

test_expect_success 'reject: invalid escape sequence in string' '
	git init reject-bad-escape &&
	(
		cd reject-bad-escape &&
		printf "{\"version\":\"v1\",\"rules\":[{\"id\":\"r\\q\",\"phases\":[\"materialize\"],\"selector\":{\"attr_filter_equals\":\"lfs\",\"regular_file_only\":true},\"action\":\"observe\",\"strict\":false,\"fallback\":\"skip\",\"required_capabilities\":[]}]}" >../p.json &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "invalid escape" err
	)
'

test_expect_success 'reject: unescaped control character in string' '
	git init reject-control-char &&
	(
		cd reject-control-char &&
		printf "{\"version\":\"v1\",\"rules\":[{\"id\":\"r\001x\",\"phases\":[\"materialize\"],\"selector\":{\"attr_filter_equals\":\"lfs\",\"regular_file_only\":true},\"action\":\"observe\",\"strict\":false,\"fallback\":\"skip\",\"required_capabilities\":[]}]}" >../p.json &&
		test_must_fail env \
			TEXTIL_GIT_EXT_POLICY_PATH="$(pwd)/../p.json" \
			TEXTIL_GIT_EXT_POLICY_VERSION=v1 \
			git status 2>err &&
		grep "control character" err
	)
'

test_done
