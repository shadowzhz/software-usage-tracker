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

# 扫描 .desktop 文件，建立 GUI 证据的兜底映射表：
#   N 行: 应用显示名 -> 包       （解决微信、钉钉等 wrapper/脚本启动器）
#   X 行: 可执行文件名 -> 包     （解决启动脚本路径与包内路径不一致）
# 歧义名字（同名对应多个包）不映射，宁缺毋滥。无法归属包的 desktop 文件跳过。
load_desktop_map() {
    local DIR FILE BASE
    local FILES_KEY="$TMP_DIR/desktop_files"

    : > "$FILES_KEY"

    for DIR in /usr/share/applications /usr/local/share/applications \
        "$HOME/.local/share/applications"
    do
        while IFS= read -r -d '' FILE; do
            printf '%s\t\n' "$FILE" >> "$FILES_KEY"
        done < <(find "$DIR" -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null)
    done

    while IFS= read -r -d '' FILE; do
        BASE=$(basename "$FILE" .desktop)
        printf '%s\tsnap:%s\n' "$FILE" "${BASE%%_*}" >> "$FILES_KEY"
    done < <(find /var/lib/snapd/desktop/applications -maxdepth 1 -type f \
        -name '*.desktop' -print0 2>/dev/null)

    for DIR in /var/lib/flatpak/exports/share/applications \
        "$HOME/.local/share/flatpak/exports/share/applications"
    do
        while IFS= read -r -d '' FILE; do
            printf '%s\tflatpak:%s\n' "$FILE" \
                "$(basename "$FILE" .desktop)" >> "$FILES_KEY"
        done < <(find "$DIR" -maxdepth 1 -type f -name '*.desktop' -print0 2>/dev/null)
    done

    # 待定文件：用一次 dpkg-query 批量找归属包
    awk -F'\t' '$2 == "" { print $1 }' "$FILES_KEY" > "$TMP_DIR/pending_desktops"

    if [ -s "$TMP_DIR/pending_desktops" ]; then
        local PENDING=() LINE PKG PATH_TEXT
        mapfile -t PENDING < "$TMP_DIR/pending_desktops"

        while IFS= read -r LINE; do
            PKG="${LINE%%:*}"
            case "$PKG" in
                *' '*) continue ;;          # diversion 等非包行
            esac
            [ -z "$PKG" ] && continue
            PATH_TEXT="${LINE#*: }"
            [ -n "$PATH_TEXT" ] || continue
            printf '%s\tapt:%s\n' "$PATH_TEXT" "$PKG" >> "$FILES_KEY"
            DESKTOP_APT["apt:$PKG"]=1
        done < <(dpkg-query -S "${PENDING[@]}" 2>/dev/null |
            awk '!seen[$0]++')
    fi

    # 一次 grep 提取所有 desktop 的 Name*/Exec 行
    local DESKTOPS=()
    mapfile -t DESKTOPS < <(awk -F'\t' '$2 != "" { print $1 }' "$FILES_KEY")
    [ "${#DESKTOPS[@]}" -eq 0 ] && return

    grep -H -E '^(Name[^=]*|Exec)=' "${DESKTOPS[@]}" 2>/dev/null |
    awk -F'\t' '
        function basename_of(p) { sub(/.*\//, "", p); return p }

        # 取 Exec 里真正的可执行文件：跳过 env 与变量赋值，处理引号
        function exec_base(e,   n, tok, i, t) {
            sub(/^[ \t]+/, "", e)
            if (substr(e, 1, 1) == "\"") {
                i = index(substr(e, 2), "\"")
                t = (i > 0) ? substr(e, 2, i - 1) : e
            } else {
                n = split(e, tok, "[ \t]")
                t = ""
                for (i = 1; i <= n; i++) {
                    if (tok[i] == "" || tok[i] == "env") continue
                    if (tok[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
                    t = tok[i]
                    break
                }
            }
            if (t == "") return ""
            return basename_of(t)
        }

        # FILES_KEY: FILE \t KEY
        NR == FNR {
            fkey[$1] = $2
            order[++count] = $1
            next
        }

        # grep 输出: FILE:KEY=VALUE
        index($0, ":") > 0 {
            file = substr($0, 1, index($0, ":") - 1)
            rest = substr($0, index($0, ":") + 1)
            dkey = substr(rest, 1, index(rest, "=") - 1)
            dval = substr(rest, index(rest, "=") + 1)

            if (file != cur) {
                flush(cur)
                cur = file
                delete names
                nexec = ""
            }

            if (dkey == "Exec") {
                nexec = exec_base(dval)
            } else if (dkey ~ /^Name/) {
                if (dval != "") names[dval] = 1
            }
        }

        function flush(f,   k, name) {
            if (!(f in fkey) || fkey[f] == "") return
            k = fkey[f]
            for (name in names) {
                printf "N\t%s\t%s\n", name, k
            }
            if (nexec != "") {
                printf "X\t%s\t%s\n", nexec, k
            }
        }

        END {
            flush(cur)
        }
    ' "$FILES_KEY" - |
    sort -u |
    # 同名对应多个包的视为歧义，丢弃
    awk -F'\t' '
        {
            id = $1 SUBSEP $2
            if (id in amb) {
                next
            }
            if (id in first && first[id] != $3) {
                amb[id] = 1
                next
            }
            first[id] = $3
        }
        END {
            for (id in first) {
                if (id in amb) continue
                split(id, a, SUBSEP)
                print a[1] "\t" a[2] "\t" first[id]
            }
        }
    ' > "$TMP_DIR/desktop_map"
}

# 汇总两份日志的使用证据。
# 先对 SOURCE 去重并逐个解析成包，加上 .desktop 映射表，再用一次 awk
# 遍历完成时间过滤、按 KEY 聚合最近使用时间和证据类型，避免逐行 fork 子进程。
# 解析顺序：SOURCE 直查包 -> desktop 可执行名 -> desktop 应用名 -> observed:应用名。
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
        printf 'S\t%s\t%s\n' "$SOURCE" "$KEY" >> "$TMP_DIR/source_map"
    done < "$TMP_DIR/sources"

    # 前置映射统一为: TYPE \t VALUE \t KEY
    cat "$TMP_DIR/source_map" "$TMP_DIR/desktop_map" > "$TMP_DIR/premap"

    awk -F'|' -v cutoff="$CUTOFF_TEXT" '

        # premap: S=SOURCE直查, N=desktop应用名, X=desktop可执行名
        NR == FNR {
            split($0, m, "\t")
            if (m[1] == "S") {
                smap[m[2]] = m[3]
            } else if (m[1] == "N") {
                nmap[m[2]] = m[3]
            } else if (m[1] == "X") {
                xmap[m[2]] = m[3]
            }
            next
        }

        # 数据行: NAME|TIME|TYPE|SOURCE
        NF < 4 { next }
        $2 !~ /^[0-9][0-9][0-9][0-9]-/ { next }
        $2 < cutoff { next }

        {
            key = ($4 in smap) ? smap[$4] : ""

            if (key == "" && $3 == "gui") {
                n = split($4, seg, "/")
                base = seg[n]
                key = (base in xmap) ? xmap[base] : ""
                if (key == "" && ($1 in nmap)) {
                    key = nmap[$1]
                }
            }

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
    ' "$TMP_DIR/premap" "$USAGE_LOG" "$GUI_LOG" > "$TMP_DIR/used"

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
load_desktop_map
accumulate_usage
print_apt_report
print_other_report
print_unresolved
