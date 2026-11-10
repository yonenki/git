#!/bin/sh

test_description='Textil add --textil-pack-objects writes blobs and trees into one pack'

. ./test-lib.sh

loose_types () {
	find .git/objects -type f -path "*/objects/??/*" |
	sed -e "s|.*/objects/\(..\)/|\1|" |
	git cat-file --batch-check="%(objecttype)" |
	sort
}

pack_oids () {
	for idx in .git/objects/pack/*.idx
	do
		git show-index <"$idx" | cut -d" " -f2 || return 1
	done | sort
}

populate () {
	mkdir -p Content/Maps/Level/A Content/Maps/Level/B Source/Game &&
	printf "same\n" >Content/Maps/Level/A/one.txt &&
	printf "same\n" >Content/Maps/Level/B/two.txt &&
	printf "map\n" >Content/Maps/Level/A/map.r &&
	printf "source\n" >Source/Game/Game.cpp &&
	>Source/Game/empty &&
	echo "*.r filter=rot13" >.gitattributes
}

configure_filter () {
	git config filter.rot13.process "test-tool rot13-filter --log=../rot13.log clean smudge" &&
	git config filter.rot13.required true &&
	git config maintenance.auto false
}

test_expect_success 'setup reference tree with plain add' '
	git init reference &&
	(
		cd reference &&
		configure_filter &&
		populate &&
		git add . &&
		git write-tree >../expect-tree
	)
'

test_expect_success 'pack-objects add writes the same objects into one pack' '
	git init packed &&
	(
		cd packed &&
		configure_filter &&
		populate &&
		rm -f ../rot13.log &&
		git add --textil-pack-objects . &&
		grep "IN: clean Content/Maps/Level/A/map.r" ../rot13.log &&

		# Nested directories, the filter process and a repeated blob
		# leave no loose blob or tree behind.
		loose_types >actual-loose &&
		test_must_be_empty actual-loose &&
		ls .git/objects/pack/*.pack >packs &&
		test_line_count = 1 packs &&

		# The index already carries the trees, and they are the same as
		# those of a plain add.
		git write-tree >../actual-tree &&
		test_cmp ../expect-tree ../actual-tree &&
		loose_types >actual-loose &&
		test_must_be_empty actual-loose &&

		# The pack holds every blob and tree of the result exactly once.
		{
			cat ../actual-tree &&
			git ls-tree -r -t --format="%(objectname)" $(cat ../actual-tree)
		} | sort -u >expect-oids &&
		pack_oids >actual-oids &&
		test_cmp expect-oids actual-oids &&
		git fsck --strict
	)
'

test_expect_success 'the following commit writes only its commit object' '
	(
		cd packed &&
		git commit -m initial &&
		echo commit >expect-loose &&
		loose_types >actual-loose &&
		test_cmp expect-loose actual-loose &&
		git rev-parse HEAD^{tree} >actual-head-tree &&
		test_cmp ../expect-tree actual-head-tree
	)
'

test_expect_success 'objects already in the repository are not written again' '
	(
		cd packed &&
		ls .git/objects/pack/*.idx >idx-before &&
		printf "new\n" >Source/Game/new.txt &&
		# A new path whose content is an object already in the repository.
		cp Source/Game/Game.cpp Source/Game/copy.cpp &&
		git add --textil-pack-objects . &&
		ls .git/objects/pack/*.idx >idx-after &&
		comm -13 idx-before idx-after >new-idx &&
		test_line_count = 1 new-idx &&
		git show-index <"$(cat new-idx)" | cut -d" " -f2 >new-pack-oids &&
		grep "$(git rev-parse :Source/Game/new.txt)" new-pack-oids &&
		! grep "$(git rev-parse :Source/Game/copy.cpp)" new-pack-oids
	)
'

test_expect_success 'dry run writes nothing' '
	git init dry &&
	(
		cd dry &&
		populate &&
		git add --textil-pack-objects --dry-run . &&
		loose_types >actual-loose &&
		test_must_be_empty actual-loose &&
		test_path_is_missing .git/index &&
		ls .git/objects/pack >packs &&
		test_must_be_empty packs
	)
'

test_done
