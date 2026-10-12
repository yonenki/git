#!/bin/sh

test_description='Textil default CA is the lowest-priority HTTPS CA source

TEXTIL_GIT_DEFAULT_SSL_CAINFO and TEXTIL_GIT_DEFAULT_SSL_CAPATH apply only
when neither a CA file nor a CA directory was determined from the config or
the GIT_SSL_* environment. Every value that is set is used.'

. ./test-lib.sh

LIB_HTTPD_SSL=1
. "$TEST_DIRECTORY"/lib-httpd.sh
start_httpd

# lib-httpd disables verification for its other users; verify here.
sane_unset GIT_SSL_NO_VERIFY
sane_unset TEXTIL_GIT_DEFAULT_SSL_CAINFO TEXTIL_GIT_DEFAULT_SSL_CAPATH

URL="$HTTPD_URL/smart/repo.git"

test_expect_success 'setup repository and CA material' '
	test_commit foo &&
	git init --bare "$HTTPD_DOCUMENT_ROOT_PATH/repo.git" &&
	git push --mirror "$HTTPD_DOCUMENT_ROOT_PATH/repo.git" &&
	sed -n "/BEGIN CERTIFICATE/,/END CERTIFICATE/p" \
		"$HTTPD_ROOT_PATH/httpd.pem" >server-ca.pem &&
	test -s server-ca.pem &&
	RANDFILE_PATH="$PWD/.rnd" openssl req -config "$TEST_PATH/ssl.cnf" \
		-new -x509 -nodes -out other-ca.pem -keyout other-key.pem &&
	mkdir server-ca-dir empty-ca-dir &&
	cp server-ca.pem "server-ca-dir/$(openssl x509 -hash -noout -in server-ca.pem).0"
'

test_expect_success 'HTTPS fails without any CA source' '
	test_must_fail git ls-remote "$URL"
'

test_expect_success 'default CAINFO is used' '
	TEXTIL_GIT_DEFAULT_SSL_CAINFO="$PWD/server-ca.pem" git ls-remote "$URL"
'

test_expect_success 'default CAPATH is used' '
	TEXTIL_GIT_DEFAULT_SSL_CAPATH="$PWD/server-ca-dir" git ls-remote "$URL"
'

test_expect_success 'default CAINFO and CAPATH are both used' '
	TEXTIL_GIT_DEFAULT_SSL_CAINFO="$PWD/other-ca.pem" \
	TEXTIL_GIT_DEFAULT_SSL_CAPATH="$PWD/server-ca-dir" \
		git ls-remote "$URL"
'

test_expect_success 'GIT_SSL_CAINFO takes precedence over the default' '
	test_must_fail env GIT_SSL_CAINFO="$PWD/other-ca.pem" \
		TEXTIL_GIT_DEFAULT_SSL_CAINFO="$PWD/server-ca.pem" \
		git ls-remote "$URL"
'

test_expect_success 'GIT_SSL_CAPATH alone suppresses the default CAINFO' '
	test_must_fail env GIT_SSL_CAPATH="$PWD/empty-ca-dir" \
		TEXTIL_GIT_DEFAULT_SSL_CAINFO="$PWD/server-ca.pem" \
		git ls-remote "$URL"
'

test_expect_success 'http.sslCAInfo takes precedence over the default' '
	test_must_fail env TEXTIL_GIT_DEFAULT_SSL_CAINFO="$PWD/server-ca.pem" \
		git -c http.sslCAInfo="$PWD/other-ca.pem" ls-remote "$URL" &&
	TEXTIL_GIT_DEFAULT_SSL_CAINFO="$PWD/other-ca.pem" \
		git -c http.sslCAInfo="$PWD/server-ca.pem" ls-remote "$URL"
'

test_expect_success 'URL-specific http.<url>.sslCAInfo takes precedence over the default' '
	test_must_fail env TEXTIL_GIT_DEFAULT_SSL_CAINFO="$PWD/server-ca.pem" \
		git -c "http.$HTTPD_URL/.sslCAInfo=$PWD/other-ca.pem" ls-remote "$URL"
'

test_expect_success 'http.sslCAPath alone suppresses the default CAINFO' '
	test_must_fail env TEXTIL_GIT_DEFAULT_SSL_CAINFO="$PWD/server-ca.pem" \
		git -c http.sslCAPath="$PWD/empty-ca-dir" ls-remote "$URL"
'

test_expect_success 'empty default values are ignored' '
	test_must_fail env TEXTIL_GIT_DEFAULT_SSL_CAINFO= \
		TEXTIL_GIT_DEFAULT_SSL_CAPATH= git ls-remote "$URL"
'

test_done
