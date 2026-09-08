#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
build_script="$project_root/Scripts/build-app.sh"
built_app="$project_root/.build/app/Token Usage.app"
installed_app="/Applications/Token Usage.app"
expected_bundle_id="local.mars.TokenUsage"
executable_name="TokenUsage"
resource_bundle_relative="Contents/Resources/TokenUsage_TokenUsageCore.bundle"
parser_source_relative="Sources/TokenUsageCore/Resources/token_usage.py"
catalog_source_relative="Sources/TokenUsageCore/Resources/pricing_catalog.json"
codex_data_root="${CODEX_HOME:-$HOME/.codex}"
hook_parser="$codex_data_root/hooks/token_usage.py"
hook_catalog="$codex_data_root/hooks/pricing_catalog.json"
staging_root=""
preserve_staging=0
hook_parser_staging=""
hook_parser_backup=""
hook_catalog_staging=""
hook_catalog_backup=""
hook_update_mode="absent"

cleanup() {
    if [[ -n "$hook_parser_staging" && -f "$hook_parser_staging" ]]; then
        /bin/rm -f "$hook_parser_staging"
    fi
    if [[ -n "$hook_parser_backup" && -f "$hook_parser_backup" ]]; then
        /bin/rm -f "$hook_parser_backup"
    fi
    if [[ -n "$hook_catalog_staging" && -f "$hook_catalog_staging" ]]; then
        /bin/rm -f "$hook_catalog_staging"
    fi
    if [[ -n "$hook_catalog_backup" && -f "$hook_catalog_backup" ]]; then
        /bin/rm -f "$hook_catalog_backup"
    fi
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
        "$candidate/Contents/MacOS/$executable_name" \
        && /usr/bin/cmp -s \
            "$built_app/$resource_bundle_relative/token_usage.py" \
            "$candidate/$resource_bundle_relative/token_usage.py" \
        && /usr/bin/cmp -s \
            "$built_app/$resource_bundle_relative/pricing_catalog.json" \
            "$candidate/$resource_bundle_relative/pricing_catalog.json"
}

hook_pair_matches() {
    local parser_candidate=$1
    local catalog_candidate=$2
    [[ -f "$parser_candidate" && -f "$catalog_candidate" ]] \
        && /usr/bin/cmp -s "$parser_candidate" "$hook_parser" \
        && /usr/bin/cmp -s "$catalog_candidate" "$hook_catalog"
}

hook_file_matches_git_history() {
    local source_relative=$1
    local installed_file=$2
    local revision

    while IFS= read -r revision; do
        [[ -n "$revision" ]] || continue
        if /usr/bin/git -C "$project_root" show "$revision:$source_relative" 2>/dev/null \
            | /usr/bin/cmp -s - "$installed_file"; then
            return 0
        fi
    done < <(/usr/bin/git -C "$project_root" rev-list HEAD -- "$source_relative" 2>/dev/null)
    return 1
}

hook_pair_matches_git_history() {
    hook_file_matches_git_history "$parser_source_relative" "$hook_parser" \
        && hook_file_matches_git_history "$catalog_source_relative" "$hook_catalog"
}

prepare_hook_update() {
    local built_resources="$built_app/$resource_bundle_relative"
    local installed_resources="$installed_app/$resource_bundle_relative"

    [[ -e "$hook_parser" || -e "$hook_catalog" ]] || return 0
    if [[ -L "$hook_parser" || ! -f "$hook_parser" \
        || -L "$hook_catalog" || ! -f "$hook_catalog" ]]; then
        print -u2 "Hook 解析器或价格目录不是普通文件，已整组保留不动。"
        hook_update_mode="custom"
        return 0
    fi
    if hook_pair_matches \
        "$built_resources/token_usage.py" \
        "$built_resources/pricing_catalog.json"; then
        hook_update_mode="current"
        return 0
    fi
    if hook_pair_matches \
        "$installed_resources/token_usage.py" \
        "$installed_resources/pricing_catalog.json"; then
        hook_update_mode="update"
        return 0
    fi
    if hook_pair_matches_git_history; then
        hook_update_mode="update"
        return 0
    fi

    hook_update_mode="custom"
    print -u2 "检测到自定义 Hook 解析器或价格目录，已整组保留不覆盖。"
}

sync_hook_resources() {
    [[ "$hook_update_mode" == "update" ]] || return 0
    local installed_resources="$installed_app/$resource_bundle_relative"
    local built_parser="$installed_resources/token_usage.py"
    local built_catalog="$installed_resources/pricing_catalog.json"
    local hook_directory="${hook_parser:h}"

    hook_parser_staging=$(/usr/bin/mktemp "$hook_directory/.token_usage.py.update.XXXXXX")
    hook_parser_backup=$(/usr/bin/mktemp "$hook_directory/.token_usage.py.backup.XXXXXX")
    hook_catalog_staging=$(/usr/bin/mktemp "$hook_directory/.pricing_catalog.json.update.XXXXXX")
    hook_catalog_backup=$(/usr/bin/mktemp "$hook_directory/.pricing_catalog.json.backup.XXXXXX")
    /bin/cp -p "$hook_parser" "$hook_parser_backup"
    /bin/cp -p "$hook_catalog" "$hook_catalog_backup"
    /usr/bin/install -m 700 "$built_parser" "$hook_parser_staging"
    /usr/bin/install -m 644 "$built_catalog" "$hook_catalog_staging"
    /usr/bin/python3 -c \
        'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' \
        "$hook_parser_staging"
    /usr/bin/python3 -c \
        'import json, pathlib, sys; json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' \
        "$hook_catalog_staging"

    # Publish the backwards-compatible data file first and the importing
    # Python module last, so the new parser can never observe an old catalog.
    if ! /bin/mv -f "$hook_catalog_staging" "$hook_catalog"; then
        print -u2 "无法发布新版 Hook 价格目录，原文件保持不变。"
        exit 1
    fi
    hook_catalog_staging=""
    if ! /bin/mv -f "$hook_parser_staging" "$hook_parser"; then
        /bin/mv -f "$hook_catalog_backup" "$hook_catalog"
        hook_catalog_backup=""
        print -u2 "无法发布新版 Hook 解析器，已恢复原价格目录。"
        exit 1
    fi
    hook_parser_staging=""

    if ! hook_pair_matches "$built_parser" "$built_catalog" \
        || [[ ! -x "$hook_parser" || ! -r "$hook_catalog" ]]; then
        /bin/mv -f "$hook_parser_backup" "$hook_parser"
        hook_parser_backup=""
        /bin/mv -f "$hook_catalog_backup" "$hook_catalog"
        hook_catalog_backup=""
        print -u2 "Hook 资源同步校验失败，已恢复原文件。"
        exit 1
    fi

    /bin/rm -f "$hook_parser_backup" "$hook_catalog_backup"
    hook_parser_backup=""
    hook_catalog_backup=""
    print "已同步 Stop Hook 解析器与价格目录：${hook_parser:h}"
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
prepare_hook_update

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
sync_hook_resources
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
