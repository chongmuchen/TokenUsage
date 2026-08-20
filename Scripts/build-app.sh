#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
developer_dir=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
swift_bin="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"

if [[ ! -x "$swift_bin" ]]; then
    print -u2 "找不到 Xcode Swift 工具链：$swift_bin"
    exit 1
fi

export DEVELOPER_DIR="$developer_dir"
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/token-usage-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

cd "$project_root"
"$swift_bin" build --disable-sandbox -c release
bin_dir=$("$swift_bin" build --disable-sandbox -c release --show-bin-path)

product_dir="$project_root/.build/app"
app="$product_dir/Token Usage.app"
contents="$app/Contents"

rm -rf "$app"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_dir/TokenUsage" "$contents/MacOS/TokenUsage"
cp "$project_root/Support/Info.plist" "$contents/Info.plist"
cp "$project_root/Support/AppIcon.icns" "$contents/Resources/AppIcon.icns"

resource_bundle="$bin_dir/TokenUsage_TokenUsageCore.bundle"
if [[ ! -d "$resource_bundle" ]]; then
    print -u2 "找不到 SwiftPM 资源包：$resource_bundle"
    exit 1
fi

# macOS 代码签名要求资源位于 Contents/Resources；Core 的资源定位器
# 同时兼容这里的标准 App 布局与 SwiftPM 命令行布局。
ditto "$resource_bundle" "$contents/Resources/TokenUsage_TokenUsageCore.bundle"

/usr/bin/codesign --force --deep --sign - "$app"
print "$app"
