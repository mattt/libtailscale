#!/bin/bash
# Copyright (c) Tailscale Inc & AUTHORS
# SPDX-License-Identifier: BSD-3-Clause

# Builds TailscaleKit.xcframework for iMCP: a universal (arm64 and x86_64)
# macOS framework, Release, with the feature tags in
# swift/imcp-feature-tags.txt. Writes the xcframework and
# its zip to swift/build/imcp and prints the zip's SwiftPM checksum.
# See swift/IMCP.md.
#
# Set FEATURE_TAGS_FILE to use a different tag list, or /dev/null for none.

set -euo pipefail

if [ "$(uname -m)" != "arm64" ]; then
	echo "build-imcp.sh: requires an arm64 Mac" >&2
	exit 1
fi

swift_dir=$(cd "$(dirname "$0")/.." && pwd)
root_dir=$(dirname "$swift_dir")
out_dir="$swift_dir/build/imcp"
macos_target=15.1
tags_file=${FEATURE_TAGS_FILE:-$swift_dir/imcp-feature-tags.txt}

# One tag per line; lines starting with # are comments.
tags=$(grep -v -e '^#' -e '^[[:space:]]*$' "$tags_file" | paste -s -d , - || true)

rm -rf "$out_dir"
mkdir -p "$out_dir"

# Remove the archive before and after the build, so that a tagged archive is
# not reused by, and does not linger for, other targets.
rm -f "$root_dir/libtailscale.a" "$root_dir/libtailscale.h"
trap 'rm -f "$root_dir/libtailscale.a" "$root_dir/libtailscale.h"' EXIT

# Build one archive for each architecture, then combine them with lipo.
# For darwin, cmd/go passes -arch to clang, so cgo cross-compiles the
# amd64 archive on an arm64 Mac with the system clang.
mkdir -p "$out_dir/go"
for goarch in arm64 amd64; do
	echo "::: Building libtailscale.a (macOS $macos_target, $goarch) :::"
	GOFLAGS="-trimpath -tags=$tags '-ldflags=-s -w'" \
		GOOS=darwin GOARCH="$goarch" MACOS_TARGET="$macos_target" \
		make -C "$root_dir" c-archive
	mv "$root_dir/libtailscale.a" "$out_dir/go/libtailscale-$goarch.a"
	rm -f "$root_dir/libtailscale.h"
done
lipo -create -output "$root_dir/libtailscale.a" \
	"$out_dir/go/libtailscale-arm64.a" "$out_dir/go/libtailscale-amd64.a"
lipo -info "$root_dir/libtailscale.a"

echo "::: Building TailscaleKit.framework :::"
xcodebuild build -project "$swift_dir/TailscaleKit.xcodeproj" \
	-scheme "TailscaleKit (macOS)" \
	-derivedDataPath "$out_dir/DerivedData" \
	-configuration Release \
	-destination 'generic/platform=macOS' \
	-quiet \
	ARCHS="arm64 x86_64" \
	ONLY_ACTIVE_ARCH=NO \
	MACOSX_DEPLOYMENT_TARGET="$macos_target" \
	CODE_SIGNING_ALLOWED=NO

echo "::: Creating TailscaleKit.xcframework :::"
xcodebuild -create-xcframework \
	-framework "$out_dir/DerivedData/Build/Products/Release/TailscaleKit.framework" \
	-output "$out_dir/TailscaleKit.xcframework"

framework="$out_dir/TailscaleKit.xcframework/macos-arm64_x86_64/TailscaleKit.framework"

# Remove debug and local symbols from the binary. Remove the module's Project
# directory and ABI descriptor, which record local source paths; the
# .swiftinterface files are all that a client needs.
module="$framework/Versions/A/Modules/TailscaleKit.swiftmodule"
strip -S -x "$framework/Versions/A/TailscaleKit"
rm -rf "$module/Project"
rm -f "$module"/*.abi.json

# Sign after -create-xcframework, which removes the binary .swiftmodule from
# its copy, and after strip; either would break an earlier signature.
codesign --force --sign - --timestamp=none "$framework"
codesign --verify --strict "$framework"

(cd "$out_dir" && ditto -c -k --norsrc --noextattr --noqtn --keepParent \
	TailscaleKit.xcframework TailscaleKit.xcframework.zip)

zip="$out_dir/TailscaleKit.xcframework.zip"
echo
echo "zip:      $zip"
echo "bytes:    $(stat -f %z "$zip")"
echo "archs:    $(lipo -archs "$framework/Versions/A/TailscaleKit")"
echo "checksum: $(swift package compute-checksum "$zip")"
