#!/bin/sh
set -eu

mode=${1:-build}
case "$mode" in build|run|install) ;; *) echo "usage: $0 {build|run|install}" >&2; exit 2 ;; esac

cd "$(dirname "$0")/.."
app="$PWD/build/clt/Codenotch.app"
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
if [ -n "${SDKROOT:-}" ]; then
    sdk=$SDKROOT
elif [ -d "$developer_dir/SDKs/MacOSX26.sdk" ]; then
    sdk="$developer_dir/SDKs/MacOSX26.sdk"
else
    sdk=$(xcrun --sdk macosx --show-sdk-path)
fi

# Some newer CLT SDKs declare SwiftUI state through a compiler macro whose
# implementation ships with Xcode only. Prefer the included 26.x SDK above,
# and fail before a long build if the selected CLT cannot compile SwiftUI.
if ! printf 'import SwiftUI\nstruct Probe: View { @State var n = 0; var body: some View { Text("\\(n)") } }\n' \
    | xcrun swiftc -swift-version 5 -sdk "$sdk" -typecheck - >/dev/null 2>&1; then
    echo "The selected Command Line Tools SDK cannot compile SwiftUI; install CLT with a compatible macOS SDK." >&2
    exit 1
fi

# SwiftPM works with Command Line Tools and resolves the pinned NIO packages.
swift build -c release --product Codenotch --sdk "$sdk"
bin_dir=$(swift build -c release --show-bin-path --sdk "$sdk")
python3 Scripts/package-clt.py "$bin_dir/Codenotch" "$app"

# The compiler may need compatibility libraries on older supported macOS releases.
mkdir -p "$app/Contents/Frameworks"
xcrun swift-stdlib-tool --copy --platform macosx \
    --scan-executable "$app/Contents/MacOS/Codenotch" \
    --destination "$app/Contents/Frameworks" --sign -
codesign --force --options runtime --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"

if [ "$mode" = run ]; then
    open "$app"
elif [ "$mode" = install ]; then
    applications_dir=${CODENOTCH_APPLICATIONS_DIR:-/Applications}
    destination="$applications_dir/Codenotch.app"
    mkdir -p "$applications_dir"
    if [ "${CODENOTCH_SKIP_LAUNCH:-0}" != 1 ]; then
        pkill -x Codenotch 2>/dev/null || true
    fi
    ditto "$app" "$destination"
    codesign --verify --deep --strict "$destination"
    echo "Installed $destination"
    if [ "${CODENOTCH_SKIP_LAUNCH:-0}" != 1 ]; then
        open "$destination"
    fi
fi
