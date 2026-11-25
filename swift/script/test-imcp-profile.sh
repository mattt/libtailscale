#!/bin/bash
# Copyright (c) Tailscale Inc & AUTHORS
# SPDX-License-Identifier: BSD-3-Clause

set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/swift/script" "$work/swift/build/imcp"
cp "$script_dir/build-imcp.sh" "$work/swift/script/"
cd "$work"
export PATH="$work/bin:$PATH"
unset FEATURE_TAGS_FILE

# Record the options at the first build step, then stop.
printf '#!/bin/sh\necho arm64\n' > bin/uname
cat > bin/make <<'EOF'
#!/bin/sh
printf '%s\n' "$GOFLAGS" > make-flags
exit 77
EOF
chmod +x bin/uname bin/make

check_rejected() {
	touch swift/build/imcp/previous-build
	if FEATURE_TAGS_FILE="$1" swift/script/build-imcp.sh > build.log 2>&1; then
		echo "unexpected success for $1" >&2
		exit 1
	fi
	grep -Fq -- "$1" build.log
	test ! -e make-flags
	test -f swift/build/imcp/previous-build
}

check_tags() {
	local status=0
	swift/script/build-imcp.sh > build.log 2>&1 || status=$?
	test "$status" -eq 77
	test "$(cat make-flags)" = "-trimpath -tags=$1 '-ldflags=-s -w'"
}

check_rejected missing-profile
check_rejected swift/script
touch unreadable-profile
chmod 000 unreadable-profile
# A privileged test process can still read mode-000 files.
if [[ ! -r unreadable-profile ]]; then
	check_rejected unreadable-profile
fi

printf 'first\n# comment\n \t\nsecond' > swift/imcp-feature-tags.txt
check_tags first,second
printf 'custom\n' > "custom profile"
FEATURE_TAGS_FILE="custom profile" check_tags custom
: > empty-profile
FEATURE_TAGS_FILE=empty-profile check_tags ""
printf '# comment\n\t\n' > comments-profile
FEATURE_TAGS_FILE=comments-profile check_tags ""
FEATURE_TAGS_FILE=/dev/null check_tags ""
