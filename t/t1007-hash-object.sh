#!/bin/sh

test_description="git hash-object"

. ./test-lib.sh

echo_without_newline() {
	printf '%s' "$*"
}

test_blob_does_not_exist() {
	test_expect_success 'blob does not exist in database' "
		test_must_fail git cat-file blob $1
	"
}

test_blob_exists() {
	test_expect_success 'blob exists in database' "
		git cat-file blob $1
	"
}

hello_content="Hello World"
example_content="This is an example"

setup_repo() {
	echo_without_newline "$hello_content" > hello
	echo_without_newline "$example_content" > example
}

test_repo=test
push_repo() {
	git init --quiet $test_repo
	cd $test_repo

	setup_repo
}

pop_repo() {
	cd ..
	rm -rf $test_repo
}

test_expect_success 'setup' '
	setup_repo &&
	test_oid_cache <<-EOF
	hello sha1:5e1c309dae7f45e0f39b1bf3ac3cd9db12e7d689
	hello sha256:1e3b6c04d2eeb2b3e45c8a330445404c0b7cc7b257e2b097167d26f5230090c4

	example sha1:ddd3f836d3e3fbb7ae289aa9ae83536f76956399
	example sha256:b44fe1fe65589848253737db859bd490453510719d7424daab03daf0767b85ae

	large5GB sha1:0be2be10a4c8764f32c4bf372a98edc731a4b204
	large5GB sha256:dc18ca621300c8d3cfa505a275641ebab00de189859e022a975056882d313e64
	EOF
'

# Argument checking

test_expect_success "multiple '--stdin's are rejected" '
	echo example | test_must_fail git hash-object --stdin --stdin
'

test_expect_success "Can't use --stdin and --stdin-paths together" '
	echo example | test_must_fail git hash-object --stdin --stdin-paths &&
	echo example | test_must_fail git hash-object --stdin-paths --stdin
'

test_expect_success "Can't pass filenames as arguments with --stdin-paths" '
	echo example | test_must_fail git hash-object --stdin-paths hello
'

test_expect_success "Can't use --path with --stdin-paths" '
	echo example | test_must_fail git hash-object --stdin-paths --path=foo
'

test_expect_success "Can't use --path with --no-filters" '
	test_must_fail git hash-object --no-filters --path=foo
'

# Behavior

push_repo

test_expect_success 'hash a file' '
	test "$(test_oid hello)" = $(git hash-object hello)
'

test_blob_does_not_exist "$(test_oid hello)"

test_expect_success 'hash from stdin' '
	test "$(test_oid example)" = $(git hash-object --stdin < example)
'

test_blob_does_not_exist "$(test_oid example)"

test_expect_success 'hash a file and write to database' '
	test "$(test_oid hello)" = $(git hash-object -w hello)
'

test_blob_exists "$(test_oid hello)"

test_expect_success 'git hash-object --stdin file1 <file0 first operates on file0, then file1' '
	echo foo > file1 &&
	obname0=$(echo bar | git hash-object --stdin) &&
	obname1=$(git hash-object file1) &&
	obname0new=$(echo bar | git hash-object --stdin file1 | sed -n -e 1p) &&
	obname1new=$(echo bar | git hash-object --stdin file1 | sed -n -e 2p) &&
	test "$obname0" = "$obname0new" &&
	test "$obname1" = "$obname1new"
'

test_expect_success 'set up crlf tests' '
	echo fooQ | tr Q "\\015" >file0 &&
	cp file0 file1 &&
	echo "file0 -crlf" >.gitattributes &&
	echo "file1 crlf" >>.gitattributes &&
	git config core.autocrlf true &&
	file0_sha=$(git hash-object file0) &&
	file1_sha=$(git hash-object file1) &&
	test "$file0_sha" != "$file1_sha"
'

test_expect_success 'check that appropriate filter is invoke when --path is used' '
	path1_sha=$(git hash-object --path=file1 file0) &&
	path0_sha=$(git hash-object --path=file0 file1) &&
	test "$file0_sha" = "$path0_sha" &&
	test "$file1_sha" = "$path1_sha" &&
	path1_sha=$(git hash-object --path=file1 --stdin <file0) &&
	path0_sha=$(git hash-object --path=file0 --stdin <file1) &&
	test "$file0_sha" = "$path0_sha" &&
	test "$file1_sha" = "$path1_sha"
'

test_expect_success 'gitattributes also work in a subdirectory' '
	mkdir subdir &&
	(
		cd subdir &&
		subdir_sha0=$(git hash-object ../file0) &&
		subdir_sha1=$(git hash-object ../file1) &&
		test "$file0_sha" = "$subdir_sha0" &&
		test "$file1_sha" = "$subdir_sha1"
	)
'

test_expect_success '--path works in a subdirectory' '
	(
		cd subdir &&
		path1_sha=$(git hash-object --path=../file1 ../file0) &&
		path0_sha=$(git hash-object --path=../file0 ../file1) &&
		test "$file0_sha" = "$path0_sha" &&
		test "$file1_sha" = "$path1_sha"
	)
'

test_expect_success 'check that --no-filters option works' '
	nofilters_file1=$(git hash-object --no-filters file1) &&
	test "$file0_sha" = "$nofilters_file1" &&
	nofilters_file1=$(git hash-object --stdin <file1) &&
	test "$file0_sha" = "$nofilters_file1"
'

test_expect_success 'check that --no-filters option works with --stdin-paths' '
	nofilters_file1=$(echo "file1" | git hash-object --stdin-paths --no-filters) &&
	test "$file0_sha" = "$nofilters_file1"
'

pop_repo

for args in "-w --stdin" "--stdin -w"; do
	push_repo

	test_expect_success "hash from stdin and write to database ($args)" '
		test "$(test_oid example)" = $(git hash-object $args < example)
	'

	test_blob_exists "$(test_oid example)"

	pop_repo
done

filenames="hello
example"

oids="$(test_oid hello)
$(test_oid example)"

test_expect_success "hash two files with names on stdin" '
	test "$oids" = "$(echo_without_newline "$filenames" | git hash-object --stdin-paths)"
'

for args in "-w --stdin-paths" "--stdin-paths -w"; do
	push_repo

	test_expect_success "hash two files with names on stdin and write to database ($args)" '
		test "$oids" = "$(echo_without_newline "$filenames" | git hash-object $args)"
	'

	test_blob_exists "$(test_oid hello)"
	test_blob_exists "$(test_oid example)"

	pop_repo
done

test_expect_success 'too-short tree' '
	echo abc >malformed-tree &&
	test_must_fail git hash-object -t tree malformed-tree 2>err &&
	grep "too-short tree object" err
'

test_expect_success PERL_TEST_HELPERS 'malformed mode in tree' '
	hex_oid=$(echo foo | git hash-object --stdin -w) &&
	bin_oid=$(echo $hex_oid | hex2oct) &&
	printf "9100644 \0$bin_oid" >tree-with-malformed-mode &&
	test_must_fail git hash-object -t tree tree-with-malformed-mode 2>err &&
	grep "malformed mode in tree entry" err
'

test_expect_success PERL_TEST_HELPERS 'empty filename in tree' '
	hex_oid=$(echo foo | git hash-object --stdin -w) &&
	bin_oid=$(echo $hex_oid | hex2oct) &&
	printf "100644 \0$bin_oid" >tree-with-empty-filename &&
	test_must_fail git hash-object -t tree tree-with-empty-filename 2>err &&
	grep "empty filename in tree entry" err
'

test_expect_success PERL_TEST_HELPERS 'duplicate filename in tree' '
	hex_oid=$(echo foo | git hash-object --stdin -w) &&
	bin_oid=$(echo $hex_oid | hex2oct) &&
	{
		printf "100644 file\0$bin_oid" &&
		printf "100644 file\0$bin_oid"
	} >tree-with-duplicate-filename &&
	test_must_fail git hash-object -t tree tree-with-duplicate-filename 2>err &&
	grep "duplicateEntries" err
'

test_expect_success 'corrupt commit' '
	test_must_fail git hash-object -t commit --stdin </dev/null
'

test_expect_success 'corrupt tag' '
	test_must_fail git hash-object -t tag --stdin </dev/null
'

test_expect_success 'hash-object complains about bogus type name' '
	test_must_fail git hash-object -t bogus --stdin </dev/null
'

test_expect_success 'hash-object complains about truncated type name' '
	test_must_fail git hash-object -t bl --stdin </dev/null
'

test_expect_success '--literally complains about non-standard types' '
	test_must_fail git hash-object -t bogus --literally --stdin
'

test_expect_success '--stdin outside of repository (uses default hash)' '
	nongit git hash-object --stdin <hello >actual &&
	echo "$(test_oid --hash=builtin hello)" >expect &&
	test_cmp expect actual
'

test_expect_success 'index-context hashing agrees with add/status for legacy CRLF text=auto' '
	test_create_repo index-context &&
	(
		cd index-context &&
		git config core.autocrlf false &&
		git config core.safecrlf false &&
		printf "* text=auto\n" >.gitattributes &&
		printf "old\r\n" >"legacy \"quoted\".txt" &&
		legacy=$(git hash-object -w --no-filters "legacy \"quoted\".txt") &&
		git update-index --add --cacheinfo 100644 "$legacy" "legacy \"quoted\".txt" &&
		printf "normal\n" >normal.txt &&
		git add .gitattributes normal.txt &&
		git commit -m initial &&
		cp .git/index index-before &&
		git ls-files -- "legacy \"quoted\".txt" normal.txt >paths &&
		{
			echo "$legacy" &&
			git rev-parse :normal.txt
		} >expect &&
		git hash-object --textil-index-context --stdin-paths <paths >actual &&
		test_cmp expect actual &&
		git hash-object --textil-index-context --path="legacy \"quoted\".txt" \
			--stdin --textil-stdin-size=5 <"legacy \"quoted\".txt" >actual &&
		echo "$legacy" >expect &&
		test_cmp expect actual &&
		test_cmp index-before .git/index &&
		git status --porcelain -- "legacy \"quoted\".txt" normal.txt >actual &&
		test_must_be_empty actual &&
		printf "new\r\n" >>"legacy \"quoted\".txt" &&
		git hash-object --textil-index-context "legacy \"quoted\".txt" >expect &&
		git hash-object --textil-index-context --path="legacy \"quoted\".txt" \
			--stdin --textil-stdin-size=10 <"legacy \"quoted\".txt" >actual &&
		test_cmp expect actual &&
		git add "legacy \"quoted\".txt" &&
		git rev-parse ":legacy \"quoted\".txt" >actual &&
		test_cmp expect actual &&
		git diff --exit-code -- "legacy \"quoted\".txt"
	)
'

test_expect_success 'known-size input uses ordinary Git clean conversion' '
	test_create_repo size-conversion &&
	(
		cd size-conversion &&
		git config core.autocrlf false &&
		git config core.safecrlf false &&
		echo "normal.txt text=auto" >.gitattributes &&
		printf "old\n" >normal.txt &&
		git add .gitattributes normal.txt &&
		printf "new\r\n" >normal.txt &&
		git hash-object --no-filters normal.txt >raw &&
		git hash-object --textil-index-context --path=normal.txt \
			--stdin --textil-stdin-size=5 <normal.txt >actual &&
		! test_cmp raw actual &&
		git add normal.txt &&
		git rev-parse :normal.txt >expect &&
		test_cmp expect actual &&
		git diff --exit-code -- normal.txt &&
		for size in 4 6
		do
			test_must_fail git hash-object --textil-index-context --path=normal.txt \
				--stdin --textil-stdin-size=$size <normal.txt >actual 2>err &&
			test_must_be_empty actual &&
			grep "input size does not match" err || return 1
		done
	)
'

test_expect_success 'known-size unconverted input hashes empty and nonempty streams without writing' '
	test_create_repo size-stream &&
	(
		cd size-stream &&
		echo "* -text" >.gitattributes &&
		git hash-object --stdin </dev/null >expect &&
		git hash-object --textil-index-context --path=plain --stdin \
			--textil-stdin-size=0 </dev/null >actual &&
		test_cmp expect actual &&
		printf "stream\r\n" >input &&
		git hash-object --no-filters input >expect &&
		cat input | git hash-object --textil-index-context --path=plain \
			--stdin --textil-stdin-size=8 >actual &&
		test_cmp expect actual &&
		test_must_fail git cat-file -e "$(cat actual)"
	)
'

test_expect_success 'known-size unconverted input rejects short and extra data before printing' '
	(
		cd size-stream &&
		printf "stream\r\n" >input &&
		for size in 0 7 9
		do
			cat input | test_must_fail git hash-object --textil-index-context \
				--path=plain --stdin --textil-stdin-size=$size >actual 2>err &&
			test_must_be_empty actual &&
			grep "Unable to hash plain" err || return 1
		done &&
		test_must_fail git hash-object --textil-index-context --path=plain \
			--stdin --textil-stdin-size=1 </dev/null >actual 2>err &&
		test_must_be_empty actual
	)
'

test_expect_success 'index-context input options reject incompatible modes and malformed sizes' '
	(
		cd size-stream &&
		for args in \
			"--textil-index-context -w plain" \
			"--textil-index-context -t tree --stdin" \
			"--textil-index-context --literally --stdin" \
			"--textil-index-context --no-filters plain" \
			"--textil-stdin-size=0 --path=plain --stdin" \
			"--textil-index-context --textil-stdin-size=0 --stdin" \
			"--textil-index-context --textil-stdin-size=0 --path=plain plain" \
			"--textil-index-context --textil-stdin-size=0 --path=plain --stdin plain" \
			"--textil-index-context --textil-stdin-size=0 --stdin-paths"
		do
			test_expect_code 129 git hash-object $args </dev/null >actual 2>err &&
			test_must_be_empty actual || return 1
		done &&
		for size in "" -1 +1 " 1" 1x 18446744073709551616
		do
			test_expect_code 129 git hash-object --textil-index-context \
				--path=plain --stdin --textil-stdin-size="$size" \
				</dev/null >actual 2>err &&
			test_must_be_empty actual &&
			grep "textil-stdin-size" err || return 1
		done
	) &&
	nongit test_must_fail git hash-object --textil-index-context \
		--path=plain --stdin --textil-stdin-size=0 </dev/null >actual 2>err &&
	test_must_be_empty actual
'

test_expect_success EXPENSIVE,SIZE_T_IS_64BIT \
		'files over 4GB hash literally' '
	test-tool genzeros $((5*1024*1024*1024)) >big &&
	test_oid large5GB >expect &&
	git hash-object --stdin --literally <big >actual &&
	test_cmp expect actual
'

test_expect_success EXPENSIVE,SIZE_T_IS_64BIT \
		'files over 4GB hash correctly via --stdin' '
	{ test -f big || test-tool genzeros $((5*1024*1024*1024)) >big; } &&
	test_oid large5GB >expect &&
	git hash-object --stdin <big >actual &&
	test_cmp expect actual
'

test_expect_success EXPENSIVE,SIZE_T_IS_64BIT \
		'files over 4GB hash correctly' '
	{ test -f big || test-tool genzeros $((5*1024*1024*1024)) >big; } &&
	test_oid large5GB >expect &&
	git hash-object -- big >actual &&
	test_cmp expect actual
'

# This clean filter does nothing, other than excercising the interface.
# We ensure that cleaning doesn't mangle large files on 64-bit Windows.
test_expect_success EXPENSIVE,SIZE_T_IS_64BIT \
		'hash filtered files over 4GB correctly' '
	{ test -f big || test-tool genzeros $((5*1024*1024*1024)) >big; } &&
	test_oid large5GB >expect &&
	test_config filter.null-filter.clean "cat" &&
	echo "big filter=null-filter" >.gitattributes &&
	git hash-object -- big >actual &&
	test_cmp expect actual
'

test_done
