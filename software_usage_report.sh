#!/usr/bin/env bash

# 汇总 GUI、CLI、历史和已安装软件清单，生成只读使用报告。

set -u

DAYS="${1:-180}"

if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
    printf '用法: %s [天数]\n' "$0" >&2
    exit 1
fi

DATA_DIR="$HOME/.local/share/unused-software"
GUI_LOG="$DATA_DIR/gui-events.log"
USAGE_LOG="$DATA_DIR/usage.log"
CUTOFF=$(( $(date +%s) - DAYS * 86400 ))
# 日志时间固定为 YYYY-MM-DD HH:MM:SS，补零后可直接按字符串比较
CUTOFF_TEXT=$(date -d "@$CUTOFF" '+%Y-%m-%d %H:%M:%S')

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

declare -A INSTALLED_APT=()
declare -A INSTALLED_SNAP=()
declare -A INSTALLED_FLATPAK=()
declare -A USED_LAST=()
declare -A USED_TYPES=()
declare -A USED_SOURCES=()
declare -A OBSERVED_GUI=()
declare -A DESKTOP_APT=()

# 把 executable 解析成 snap/apt 包，输出为空表示无法可靠映射。
# env/bash 等包装器不解析，避免把应用算进 coreutils 之类的包。
resolve_source() {
    local SOURCE="$1"
    local PATHNAME=""
    local PACKAGE=""

    case "$SOURCE" in
        env|bash|sh|zsh|fish|python|python3|java|electron)
            return
            ;;
        /snap/bin/*)
            printf 'snap:%s\n' "$(basename "$SOURCE")"
            return
            ;;
    esac

    if [[ "$SOURCE" == /* ]]; then
        PATHNAME="$SOURCE"
    else
        PATHNAME=$(command -v "$SOURCE" 2>/dev/null || true)
    fi

    case "$PATHNAME" in
        /snap/bin/*)
            printf 'snap:%s\n' "$(basename "$PATHNAME")"
            return
            ;;
    esac

    if [ -n "$PATHNAME" ]; then
        PACKAGE=$(dpkg-query -S "$PATHNAME" 2>/dev/null |
            head -n 1 | cut -d: -f1)
        [ -n "$PACKAGE" ] && printf 'apt:%s\n' "$PACKAGE"
    fi
}

load_installed() {
    local PACKAGE VERSION STATUS

    while IFS=$'\t' read -r PACKAGE VERSION STATUS; do
        [ "$STATUS" = installed ] || continue
        INSTALLED_APT["apt:$PACKAGE"]="$PACKAGE|$VERSION"
    done < <(dpkg-query -W -f='${binary:Package}\t${Version}\t${db:Status-Status}\n' 2>/dev/null)

    if command -v snap >/dev/null 2>&1; then
        while read -r PACKAGE VERSION REV TRACK PUBLISHER NOTES; do
            [ "$PACKAGE" = Name ] || [ "$PACKAGE" = 名称 ] && continue
            [ -z "$PACKAGE" ] && continue
            INSTALLED_SNAP["snap:$PACKAGE"]="$PACKAGE|$VERSION"
        done < <(snap list 2>/dev/null)
    fi

    if command -v flatpak >/dev/null 2>&1; then
        while IFS=$'\t' read -r APP VERSION BRANCH ORIGIN; do
            [ -z "$APP" ] && continue
            INSTALLED_FLATPAK["flatpak:$APP"]="$APP|$VERSION"
        done < <(flatpak list --app --columns=application,version,branch,origin 2>/dev/null)
    fi
}

load_desktop_packages() {
    local DESKTOPS=()
    local LINE PKG

    while IFS= read -r -d '' DESKTOP; do
        DESKTOPS+=("$DESKTOP")
    done < <(
        find "$HOME/.local/share/applications" /usr/share/applications \
            -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null
    )

    [ "${#DESKTOPS[@]}" -eq 0 ] && return

    # 一次查询所有 desktop 文件，输出形如 "libc6:amd64: /path/x.desktop"
    while IFS= read -r LINE; do
        PKG="${LINE%%:*}"
        [ -n "$PKG" ] && DESKTOP_APT["apt:$PKG"]=1
    done < <(dpkg-query -S "${DESKTOPS[@]}" 2>/dev/null || true)
}

# 汇总两份日志的使用证据。
# 先对 SOURCE 去重并逐个解析成包（source_map），再用一次 awk 遍历完成
# 时间过滤、按 KEY 聚合最近使用时间和证据类型，避免每行 fork 子进程。
accumulate_usage() {
    local SOURCE KEY

    {
        [ -f "$USAGE_LOG" ] || [ -f "$GUI_LOG" ] || return
    }

    awk -F'|' 'NF >= 4 && $4 != "" { print $4 }' \
        "$USAGE_LOG" "$GUI_LOG" 2>/dev/null | sort -u > "$TMP_DIR/sources"

    : > "$TMP_DIR/source_map"
    while IFS= read -r SOURCE; do
        KEY=$(resolve_source "$SOURCE")
        printf '%s\t%s\n' "$SOURCE" "$KEY" >> "$TMP_DIR/source_map"
    done < "$TMP_DIR/sources"

    awk -F'|' -v cutoff="$CUTOFF_TEXT" '

        # source_map: SOURCE \t KEY，KEY 为空表示不可映射
        NR == FNR {
            i = index($0, "\t")
            if (i > 0) {
                map[substr($0, 1, i - 1)] = substr($0, i + 1)
            }
            next
        }

        # 数据行: NAME|TIME|TYPE|SOURCE
        NF < 4 { next }
        $2 !~ /^[0-9][0-9][0-9][0-9]-/ { next }
        $2 < cutoff { next }

        {
            key = ($4 in map) ? map[$4] : ""
            if (key == "") {
                key = "observed:" $1
            }

            if (!(key in last) || $2 > last[key]) {
                last[key] = $2
            }

            if (index(types[key], "|" $3 "|") == 0) {
                types[key] = types[key] "|" $3 "|"
            }

            if (index(sources[key], "|" $4 "|") == 0) {
                sources[key] = sources[key] "|" $4 "|"
            }

            # 输入法状态不算未映射的 GUI 证据
            if (key ~ /^observed:/ && $3 != "input-method") {
                if (!($1 in obs_last) || $2 > obs_last[$1]) {
                    obs_last[$1] = $2
                    obs_src[$1] = $4
                }
            }
        }

        END {
            for (key in last) {
                t = types[key]
                gsub(/^\|/, "", t)
                gsub(/\|$/, "", t)
                gsub(/\|\|/, ",", t)
                s = sources[key]
                gsub(/^\|/, "", s)
                gsub(/\|$/, "", s)
                gsub(/\|\|/, ",", s)
                if (t == "") t = "-"
                printf "%s\t%s\t%s\t%s\n", key, last[key], t, s
            }
            for (name in obs_last) {
                printf "observed:%s\t%s\t%s\t%s\n", name, obs_last[name], "-", obs_src[name]
            }
        }
    ' "$TMP_DIR/source_map" "$USAGE_LOG" "$GUI_LOG" > "$TMP_DIR/used"

    local KEY LAST TYPES SOURCES NAME
    while IFS=$'\t' read -r KEY LAST TYPES SOURCES; do
        [ -n "$KEY" ] || continue
        case "$KEY" in
            observed:*)
                NAME="${KEY#observed:}"
                OBSERVED_GUI["$NAME"]="$LAST|$SOURCES"
                ;;
            *)
                USED_LAST["$KEY"]="$LAST"
                USED_TYPES["$KEY"]="$TYPES"
                USED_SOURCES["$KEY"]="$SOURCES"
                ;;
        esac
    done < "$TMP_DIR/used"
}

print_apt_report() {
    local KEY VALUE PACKAGE VERSION TIME TYPES SOURCES
    local USED_COUNT=0 UNUSED_COUNT=0

    for KEY in "${!INSTALLED_APT[@]}"; do
        [ -n "${USED_LAST[$KEY]+x}" ] && USED_COUNT=$((USED_COUNT + 1))
        if [ -n "${DESKTOP_APT[$KEY]+x}" ] && [ -z "${USED_LAST[$KEY]+x}" ]; then
            UNUSED_COUNT=$((UNUSED_COUNT + 1))
        fi
    done

    printf '\n[APT 应用/有使用证据的软件]\n'
    for KEY in "${!INSTALLED_APT[@]}"; do
        if [ -n "${USED_LAST[$KEY]+x}" ]; then
            VALUE="${INSTALLED_APT[$KEY]}"
            PACKAGE="${VALUE%%|*}"
            VERSION="${VALUE#*|}"
            TIME="${USED_LAST[$KEY]}"
            TYPES="${USED_TYPES[$KEY]}"
            SOURCES="${USED_SOURCES[$KEY]}"
            printf '已使用\t%s\t%s\t%s\t%s\t%s\n' \
                "$PACKAGE" "$VERSION" \
                "$TIME" \
                "$TYPES" "$SOURCES"
        fi
    done | sort -k3,3r

    printf '\n[APT 长期未发现使用证据: %s 天]\n' "$DAYS"
    for KEY in "${!INSTALLED_APT[@]}"; do
        [ -n "${DESKTOP_APT[$KEY]+x}" ] || continue
        [ -n "${USED_LAST[$KEY]+x}" ] && continue
        VALUE="${INSTALLED_APT[$KEY]}"
        PACKAGE="${VALUE%%|*}"
        VERSION="${VALUE#*|}"
        printf '候选\t%s\t%s\n' "$PACKAGE" "$VERSION"
    done | sort -k2,2

    printf '\nAPT 汇总: 已使用 %s，长期未发现证据 %s\n' "$USED_COUNT" "$UNUSED_COUNT"
}

print_other_report() {
    local KEY VALUE PACKAGE VERSION TIME

    printf '\n[Snap 使用情况]\n'
    for KEY in "${!INSTALLED_SNAP[@]}"; do
        VALUE="${INSTALLED_SNAP[$KEY]}"
        PACKAGE="${VALUE%%|*}"
        VERSION="${VALUE#*|}"
        if [ -n "${USED_LAST[$KEY]+x}" ]; then
            TIME="${USED_LAST[$KEY]}"
            printf '已使用\t%s\t%s\t%s\t%s\n' "$PACKAGE" "$VERSION" \
                "$TIME" "${USED_TYPES[$KEY]}"
        else
            printf '候选\t%s\t%s\n' "$PACKAGE" "$VERSION"
        fi
    done | sort -k2,2

    printf '\n[Flatpak 使用情况]\n'
    for KEY in "${!INSTALLED_FLATPAK[@]}"; do
        VALUE="${INSTALLED_FLATPAK[$KEY]}"
        PACKAGE="${VALUE%%|*}"
        VERSION="${VALUE#*|}"
        if [ -n "${USED_LAST[$KEY]+x}" ]; then
            TIME="${USED_LAST[$KEY]}"
            printf '已使用\t%s\t%s\t%s\t%s\n' "$PACKAGE" "$VERSION" \
                "$(date -d "@$TIME" '+%Y-%m-%d %H:%M:%S')" "${USED_TYPES[$KEY]}"
        else
            printf '候选\t%s\t%s\n' "$PACKAGE" "$VERSION"
        fi
    done | sort -k2,2
}

print_unresolved() {
    local NAME VALUE

    printf '\n[未映射的 GUI 使用证据]\n'
    for NAME in "${!OBSERVED_GUI[@]}"; do
        VALUE="${OBSERVED_GUI[$NAME]}"
        printf '需确认\t%s\t最后记录 %s\t来源 %s\n' \
            "$NAME" "${VALUE%%|*}" "${VALUE#*|}"
    done | sort -k2,2
}

printf '软件使用汇总\n'
printf '生成时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '长期未发现使用证据阈值: %s 天\n' "$DAYS"
printf '数据目录: %s\n' "$DATA_DIR"

load_installed
load_desktop_packages
accumulate_usage
print_apt_report
print_other_report
print_unresolved
