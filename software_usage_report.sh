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
PID_LOG="$DATA_DIR/pids.log"
APP_PID_LOG="$DATA_DIR/app_pids.log"
CUTOFF=$(( $(date +%s) - DAYS * 86400 ))

declare -A INSTALLED_APT=()
declare -A INSTALLED_SNAP=()
declare -A INSTALLED_FLATPAK=()
declare -A USED_LAST=()
declare -A USED_TYPES=()
declare -A USED_SOURCES=()
declare -A OBSERVED_GUI=()
declare -A DESKTOP_APT=()

mark_used() {
    local KEY="$1"
    local TIME="$2"
    local TYPE="$3"
    local SOURCE="$4"

    [ -z "$KEY" ] && return

    if [ -z "${USED_LAST[$KEY]+x}" ] || [ "$TIME" -gt "${USED_LAST[$KEY]}" ]; then
        USED_LAST["$KEY"]="$TIME"
    fi

    case ",${USED_TYPES[$KEY]-}," in
        *",$TYPE,"*) ;;
        *) USED_TYPES["$KEY"]="${USED_TYPES[$KEY]-}${USED_TYPES[$KEY]:+,}$TYPE" ;;
    esac

    case ",${USED_SOURCES[$KEY]-}," in
        *",$SOURCE,"*) ;;
        *) USED_SOURCES["$KEY"]="${USED_SOURCES[$KEY]-}${USED_SOURCES[$KEY]:+,}$SOURCE" ;;
    esac
}

resolve_source() {
    local NAME="$1"
    local SOURCE="$2"
    local PATHNAME=""
    local PACKAGE=""

    case "$SOURCE" in
        env|bash|sh|zsh|fish|python|python3|java|electron)
            printf 'observed:%s\n' "$NAME"
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

    if [ -n "$PATHNAME" ]; then
        case "$PATHNAME" in
            /snap/bin/*)
                printf 'snap:%s\n' "$(basename "$PATHNAME")"
                return
                ;;
        esac

        PACKAGE=$(dpkg-query -S "$PATHNAME" 2>/dev/null |
            head -n 1 | cut -d: -f1)

        if [ -n "$PACKAGE" ]; then
            printf 'apt:%s\n' "$PACKAGE"
            return
        fi
    fi

    # 保留无法映射到包的 GUI 证据，供人工确认。
    printf 'observed:%s\n' "$NAME"
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
    local DESKTOP PACKAGE

    while IFS= read -r DESKTOP; do
        [ -f "$DESKTOP" ] || continue
        PACKAGE=$(dpkg-query -S "$DESKTOP" 2>/dev/null |
            head -n 1 | cut -d: -f1)
        [ -n "$PACKAGE" ] && DESKTOP_APT["apt:$PACKAGE"]=1
    done < <(
        find "$HOME/.local/share/applications" /usr/share/applications \
            -maxdepth 1 -type f -name '*.desktop' 2>/dev/null
    )
}

load_usage_log() {
    local NAME TIME_TEXT TYPE SOURCE TIME KEY

    [ -f "$USAGE_LOG" ] || return

    while IFS='|' read -r NAME TIME_TEXT TYPE SOURCE; do
        TIME=$(date -d "$TIME_TEXT" +%s 2>/dev/null || true)
        [[ "$TIME" =~ ^[0-9]+$ ]] || continue
        [ "$TIME" -ge "$CUTOFF" ] || continue
        KEY=$(resolve_source "$NAME" "$SOURCE")
        mark_used "$KEY" "$TIME" "$TYPE" "$SOURCE"
    done < "$USAGE_LOG"
}

load_gui_log() {
    local NAME TIME_TEXT TYPE SOURCE TIME KEY

    [ -f "$GUI_LOG" ] || return

    while IFS='|' read -r NAME TIME_TEXT TYPE SOURCE; do
        TIME=$(date -d "$TIME_TEXT" +%s 2>/dev/null || true)
        [[ "$TIME" =~ ^[0-9]+$ ]] || continue
        [ "$TIME" -ge "$CUTOFF" ] || continue
        KEY=$(resolve_source "$NAME" "$SOURCE")
        mark_used "$KEY" "$TIME" "$TYPE" "$SOURCE"

        if [[ "$KEY" == observed:* ]]; then
            OBSERVED_GUI["$NAME"]="$TIME_TEXT|$SOURCE"
        fi
    done < "$GUI_LOG"
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
                "$(date -d "@$TIME" '+%Y-%m-%d %H:%M:%S')" \
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
                "$(date -d "@$TIME" '+%Y-%m-%d %H:%M:%S')" "${USED_TYPES[$KEY]}"
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

print_runtime_evidence() {
    printf '\n[运行时快照: 仅表示采集时正在运行，不等同于长期使用证据]\n'
    if [ -f "$APP_PID_LOG" ]; then
        awk -F'|' 'NF >= 2 {print "GUI运行中\t" $2 "\tPID " $1}' "$APP_PID_LOG" | sort -u
    fi
    if [ -f "$PID_LOG" ]; then
        printf 'pids.log 记录的是进程快照，未用于判定长期使用。\n'
    fi
}

printf '软件使用汇总\n'
printf '生成时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '长期未发现使用证据阈值: %s 天\n' "$DAYS"
printf '数据目录: %s\n' "$DATA_DIR"

load_installed
load_desktop_packages
load_usage_log
load_gui_log
print_apt_report
print_other_report
print_unresolved
print_runtime_evidence
