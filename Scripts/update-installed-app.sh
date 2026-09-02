#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
build_script="$project_root/Scripts/build-app.sh"
built_app="$project_root/.build/app/Token Usage.app"
installed_app="/Applications/Token Usage.app"
expected_bundle_id="local.mars.TokenUsage"
executable_name="TokenUsage"
staging_root=""
preserve_staging=0

cleanup() {
    if [[ -n "$staging_root" && -d "$staging_root" && $preserve_staging -eq 0 ]]; then
        /bin/rm -rf "$staging_root"
    elif [[ -n "$staging_root" && -d "$staging_root" ]]; then
        print -u2 "为避免丢失旧应用，暂存目录已保留：$staging_root"
    fi
}
trap cleanup EXIT

bundle_id_for() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist"
}

validate_identity() {
    local candidate=$1
    [[ -d "$candidate" && ! -L "$candidate" ]] || return 1
    local candidate_bundle_id
    candidate_bundle_id=$(bundle_id_for "$candidate") || return 1
    [[ "$candidate_bundle_id" == "$expected_bundle_id" ]]
}

verify_install_candidate() {
    local candidate=$1
    validate_identity "$candidate" || return 1
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$candidate" || return 1
    /usr/bin/cmp -s \
        "$built_app/Contents/MacOS/$executable_name" \
        "$candidate/Contents/MacOS/$executable_name"
}

process_state() {
    if /usr/bin/pgrep -x "$executable_name" >/dev/null 2>&1; then
        print "running"
        return 0
    else
        local pgrep_exit_code=$?
        if [[ $pgrep_exit_code -eq 1 ]]; then
            print "stopped"
            return 0
        fi
        print -u2 "无法检查 Token Usage 进程状态（pgrep 退出码 $pgrep_exit_code）。"
        return "$pgrep_exit_code"
    fi
}

"$build_script"

if ! validate_identity "$built_app"; then
    print -u2 "找不到构建产物：$built_app"
    exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$built_app"

if [[ -L "$installed_app" ]]; then
    print -u2 "拒绝覆盖符号链接：$installed_app"
    exit 1
fi
if [[ -e "$installed_app" ]] && ! validate_identity "$installed_app"; then
    print -u2 "拒绝覆盖 Bundle ID 不匹配的应用：$installed_app"
    exit 1
fi

staging_root=$(/usr/bin/mktemp -d "/Applications/.token-usage-update.XXXXXX")
staged_app="$staging_root/Token Usage.app"
backup_app="$staging_root/Previous Token Usage.app"
/usr/bin/ditto "$built_app" "$staged_app"
if ! verify_install_candidate "$staged_app"; then
    print -u2 "暂存的应用未通过身份、签名或二进制校验。"
    exit 1
fi

current_process_state=$(process_state)
if [[ "$current_process_state" == "running" ]]; then
    /usr/bin/osascript -e "tell application id \"$expected_bundle_id\" to quit"
    for attempt in {1..50}; do
        current_process_state=$(process_state)
        if [[ "$current_process_state" == "stopped" ]]; then
            break
        fi
        /bin/sleep 0.1
    done
    if [[ "$current_process_state" != "stopped" ]]; then
        print -u2 "Token Usage 未能正常退出，已取消安装。"
        exit 1
    fi
fi

had_previous=0
if [[ -e "$installed_app" ]]; then
    preserve_staging=1
    if ! /bin/mv "$installed_app" "$backup_app"; then
        preserve_staging=0
        print -u2 "无法暂存当前安装的应用：$installed_app"
        exit 1
    fi
    had_previous=1
fi

if ! /bin/mv "$staged_app" "$installed_app"; then
    if [[ $had_previous -eq 1 ]]; then
        if /bin/mv "$backup_app" "$installed_app"; then
            preserve_staging=0
        else
            print -u2 "安装失败且旧应用未能恢复；备份保留在：$backup_app"
        fi
    fi
    print -u2 "无法把暂存应用安装到：$installed_app"
    exit 1
fi

if ! verify_install_candidate "$installed_app"; then
    failed_app="$staging_root/Failed Token Usage.app"
    if ! /bin/mv "$installed_app" "$failed_app"; then
        preserve_staging=1
        print -u2 "安装后校验失败，且无法移走失败副本：$installed_app"
        exit 1
    fi
    if [[ $had_previous -eq 1 ]] && ! /bin/mv "$backup_app" "$installed_app"; then
        preserve_staging=1
        print -u2 "安装后校验失败且旧应用未能恢复；备份保留在：$backup_app"
        exit 1
    fi
    preserve_staging=0
    if [[ $had_previous -eq 1 ]]; then
        print -u2 "安装后校验失败，已恢复先前版本。"
    else
        print -u2 "安装后校验失败，已移除失败副本。"
    fi
    exit 1
fi

preserve_staging=0
/usr/bin/open "$installed_app"

for attempt in {1..50}; do
    current_process_state=$(process_state)
    if [[ "$current_process_state" == "running" ]]; then
        break
    fi
    /bin/sleep 0.1
done
if [[ "$current_process_state" != "running" ]]; then
    print -u2 "应用已安装，但未能确认 Token Usage 成功启动。"
    exit 1
fi

print "已更新并重新打开：$installed_app"
