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
IME_LOG="$DATA_DIR/ime-engines.log"
FCITX_ADDON_DIR="/usr/share/fcitx5/addon"
FCITX_IM_DIR="/usr/share/fcitx5/inputmethod"
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

# 输入法引擎证据（由 load_ime_evidence 填充）
declare -A IME_USED_ENGINES=()      # 引擎id -> 1
declare -A IME_ENGINE_PKG=()        # 引擎id -> 归属包名（映射不到为空）
declare -A IME_PKG_LAST=()          # apt:包名 -> 最近一次引擎使用时间
declare -A IME_INSTALLED_PKGS=()    # apt:包名 -> 1（安装了引擎类插件的包）
IME_MATURE=0                        # 引擎证据是否已积累满 7 天

# 组件/插件包 atime 证据（由 load_component_evidence 填充）
declare -A COMP_UNUSED=()           # 包名 -> 版本（窗口内未发现访问证据）
COMP_USED_COUNT=0
COMPONENT_ATIME_OK=1                # 挂载为 noatime 时证据不可用，置 0

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

# 引擎 id -> fcitx5 addon id
# 链路：inputmethod/<引擎>.conf 的 Addon= 字段（pinyin/shuangpin/wbx 等都走这里）
#       keyboard-* 前缀按 fcitx5 约定归 keyboard 插件
#       兜底：引擎 id 本身就是 addon id
resolve_ime_addon() {
    local ENGINE="$1"
    local CONF ADDON=""

    CONF="$FCITX_IM_DIR/$ENGINE.conf"
    if [ -f "$CONF" ]; then
        ADDON=$(grep -m1 '^Addon=' "$CONF" 2>/dev/null | cut -d= -f2)
        [ -n "$ADDON" ] && printf '%s' "$ADDON" && return
    fi

    case "$ENGINE" in
        keyboard-*)
            printf 'keyboard'
            return
            ;;
        table:*)
            CONF="$FCITX_IM_DIR/${ENGINE#table:}.conf"
            if [ -f "$CONF" ]; then
                ADDON=$(grep -m1 '^Addon=' "$CONF" 2>/dev/null | cut -d= -f2)
                [ -n "$ADDON" ] && printf '%s' "$ADDON" && return
            fi
            printf 'table'
            return
            ;;
    esac

    [ -f "$FCITX_ADDON_DIR/$ENGINE.conf" ] && printf '%s' "$ENGINE"
}

# 装载输入法引擎证据：
#   引擎 -> addon -> 包，判定粒度是包（能卸载的单位）：
#   包内任一引擎被切换使用过，整包算已使用；其余引擎包是清理候选。
#   只统计 Category=InputMethod 的插件，工具类插件（剪贴板等）不参与。
#   证据不足 7 天时只展示不判定，防止冷启动期误报。
load_ime_evidence() {
    local LINE E T ADDON PKG CONF
    local FIRST_TIME=""

    [ -d "$FCITX_ADDON_DIR" ] || return
    [ -f "$IME_LOG" ] || return

    while IFS='|' read -r E T; do
        [ -z "$E" ] || [ -z "$T" ] && continue
        IME_USED_ENGINES["$E"]=1
        [ -z "$FIRST_TIME" ] && FIRST_TIME="$T"
    done < "$IME_LOG"

    [ "${#IME_USED_ENGINES[@]}" -gt 0 ] || return

    local SEVEN_DAYS_AGO
    SEVEN_DAYS_AGO=$(date -d '7 days ago' '+%Y-%m-%d %H:%M:%S')
    if [ -n "$FIRST_TIME" ] && [[ "$FIRST_TIME" < "$SEVEN_DAYS_AGO" ]]; then
        IME_MATURE=1
    fi

    # 引擎归属包 + 包级最近使用时间
    for E in "${!IME_USED_ENGINES[@]}"; do
        ADDON=$(resolve_ime_addon "$E")
        [ -z "$ADDON" ] && continue

        CONF="$FCITX_ADDON_DIR/$ADDON.conf"
        PKG=$(dpkg-query -S "$CONF" 2>/dev/null | head -n 1 | cut -d: -f1)
        [ -z "$PKG" ] && continue

        IME_ENGINE_PKG["$E"]="$PKG"
        IME_INSTALLED_PKGS["apt:$PKG"]=1
    done

    # 重算每个包的最近使用时间：逐引擎比对时间取最大
    for E in "${!IME_ENGINE_PKG[@]}"; do
        ADDON=$(resolve_ime_addon "$E")
        PKG="${IME_ENGINE_PKG[$E]}"
        [ -z "$PKG" ] && continue
        while IFS='|' read -r E2 T2; do
            [ "$E2" = "$E" ] || continue
            if [ -z "${IME_PKG_LAST[apt:$PKG]+x}" ] || [[ "$T2" > "${IME_PKG_LAST[apt:$PKG]}" ]]; then
                IME_PKG_LAST["apt:$PKG"]="$T2"
            fi
        done < "$IME_LOG"
    done

    # 把引擎包的使用证据并入主证据集，让 APT 汇总保持一致
    local KEY
    for KEY in "${!IME_PKG_LAST[@]}"; do
        T="${IME_PKG_LAST[$KEY]}"
        if [ -z "${USED_LAST[$KEY]+x}" ] || [[ "$T" > "${USED_LAST[$KEY]}" ]]; then
            USED_LAST["$KEY"]="$T"
        fi
        case ",${USED_TYPES[$KEY]-}," in
            *,input-method,*) ;;
            *) USED_TYPES["$KEY"]="${USED_TYPES[$KEY]-}${USED_TYPES[$KEY]:+,}input-method" ;;
        esac
        case ",${USED_SOURCES[$KEY]-}," in
            *,fcitx5-engine,*) ;;
            *) USED_SOURCES["$KEY"]="${USED_SOURCES[$KEY]-}${USED_SOURCES[$KEY]:+,}fcitx5-engine" ;;
        esac
    done

    # 已安装的引擎类插件包（一次批量查归属）
    local ENGINE_CONFS=()
    mapfile -t ENGINE_CONFS < <(grep -l '^Category=InputMethod' \
        "$FCITX_ADDON_DIR"/*.conf 2>/dev/null)

    if [ "${#ENGINE_CONFS[@]}" -gt 0 ]; then
        while IFS= read -r LINE; do
            PKG="${LINE%%:*}"
            case "$PKG" in
                *' '*) continue ;;
            esac
            [ -n "$PKG" ] && IME_INSTALLED_PKGS["apt:$PKG"]=1
        done < <(dpkg-query -S "${ENGINE_CONFS[@]}" 2>/dev/null |
            awk '!seen[$0]++')
    fi
}

# 依赖图清理候选：autoremove 模拟 + Snap 旧版本 + Flatpak 未使用运行时。
# 与使用证据无关，是确定性结论；全部只读，删除命令需人工执行。
print_cleanup_report() {
    local COUNT=0

    printf '\n[清理候选（依赖图判定，确定性）]\n'

    if command -v apt-get >/dev/null 2>&1; then
        COUNT=$(apt-get -s autoremove 2>/dev/null | grep -c '^Remv ' || true)
        if [ "$COUNT" -gt 0 ]; then
            printf 'APT 孤儿依赖（autoremove 会移除，共 %s 个）:\n' "$COUNT"
            apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print "可移除\t" $2}' | head -60
            [ "$COUNT" -gt 60 ] && printf '……其余 %s 个略\n' "$((COUNT - 60))"
            printf '执行需人工确认: apt autoremove\n'
        else
            printf 'APT 孤儿依赖: 无\n'
        fi
    fi

    if command -v snap >/dev/null 2>&1; then
        COUNT=$(snap list --all 2>/dev/null | grep -c 'disabled' || true)
        if [ "$COUNT" -gt 0 ]; then
            printf 'Snap 旧版本残留（disabled，共 %s 个）:\n' "$COUNT"
            snap list --all 2>/dev/null | grep 'disabled' | awk '{print "可移除\t" $1 "\t" $2 "\trev" $3}'
            printf '执行需人工确认: snap remove <名称> --revision=<修订号>\n'
        else
            printf 'Snap 旧版本残留: 无\n'
        fi
    fi

    if command -v flatpak >/dev/null 2>&1; then
        COUNT=$(flatpak list --unused 2>/dev/null | wc -l)
        if [ "$COUNT" -gt 0 ]; then
            printf 'Flatpak 未使用运行时（共 %s 个）:\n' "$COUNT"
            flatpak list --unused 2>/dev/null | awk '{print "可移除\t" $1}'
            printf '执行需人工确认: flatpak uninstall --unused\n'
        else
            printf 'Flatpak 未使用运行时: 无\n'
        fi
    fi
}

# 组件/插件包通用检测：不针对特定应用，靠文件 atime。
# 组件被宿主加载/读取时其文件 atime 会更新（relatime 下每天至少一次）；
# 包内所有文件自窗口起点起都未被读过的包，即"未发现使用证据"。
# 覆盖库、解码器插件、词典、字体、主题、无桌面入口的 CLI 工具等所有形态。
load_component_evidence() {
    local OPTS STATUS_FILE ACC PRE

    OPTS=$(findmnt -no OPTIONS / 2>/dev/null)
    case ",$OPTS," in
        *,noatime,*)
            COMPONENT_ATIME_OK=0
            return
            ;;
    esac

    STATUS_FILE="/var/lib/dpkg/status"
    ACC="$TMP_DIR/accessed"
    PRE="$TMP_DIR/compmeta"

    find /usr /lib /lib64 /opt /etc /var/lib -xdev -type f \
        -newerat "$CUTOFF_TEXT" -print 2>/dev/null > "$ACC"

    # 前置映射: A=窗口内被访问过的文件, D=拥有桌面入口的包
    {
        sed 's|^|A\t|' "$ACC"
        if [ "${#DESKTOP_APT[@]}" -gt 0 ]; then
            printf '%s\n' "${!DESKTOP_APT[@]}" | sed 's|^|D\t|'
        fi
    } > "$PRE"

    awk -F'\t' -v pre="$PRE" -v st="$STATUS_FILE" '
        function flushpkg(   m, prio, ess, prot, ver) {
            if (curpkg == "" || ! (curpkg in meta)) return
            split(meta[curpkg], m, "\t")
            prio = m[1]; ess = m[2]; prot = m[3]; ver = m[4]

            if (prio == "required" || ess == "yes" || prot == "yes") return
            if (curpkg in desk) return
            if (curpkg ~ /^(linux-(image|headers|modules|firmware|tools|source)|linux-base|firmware-|nvidia-dkms|initramfs-tools|shim|secureboot|mokutil)|-dkms$/) return
            if (nscan == 0) return        # 文件都在扫描目录之外，证据不可判

            if (used) {
                usedcnt++
            } else {
                printf "N\t%s\t%s\n", curpkg, ver
            }
        }

        FILENAME == pre {
            if ($1 == "A") acc[$2] = 1
            else if ($1 == "D") desk[$2] = 1
            next
        }

        FILENAME == st {
            if ($0 ~ /^Package: /)       pkg = substr($0, 10)
            else if ($0 ~ /^Status: /)   stat = substr($0, 9)
            else if ($0 ~ /^Version: /)  ver = substr($0, 10)
            else if ($0 ~ /^Priority: /) prio = substr($0, 11)
            else if ($0 ~ /^Essential: /) ess = substr($0, 12)
            else if ($0 ~ /^Protected: /) prot = substr($0, 12)
            else if ($0 == "") {
                if (pkg != "" && stat ~ /installed$/) {
                    meta[pkg] = prio "\t" ess "\t" prot "\t" ver
                }
                pkg = ""; stat = ""; ver = ""; prio = ""; ess = ""; prot = ""
            }
            next
        }

        # /var/lib/dpkg/info/<包>[.<架构>].list
        FILENAME != curfile {
            flushpkg()
            curfile = FILENAME
            curpkg = curfile
            sub(/.*\//, "", curpkg)
            sub(/\.list$/, "", curpkg)
            sub(/:(amd64|i386|arm64|armhf|armel|riscv64|ppc64el|s390x|all)$/, "", curpkg)
            used = 0
            nscan = 0
        }

        {
            if (!used && ($0 in acc)) used = 1
            if ($0 ~ /^\/(usr|lib|lib64|opt|etc|var\/lib)\//) nscan = 1
        }

        END {
            flushpkg()
            printf "U\t%s\n", usedcnt
        }
    ' "$PRE" "$STATUS_FILE" /var/lib/dpkg/info/*.list > "$TMP_DIR/compout"

    local LINE KIND PKG VER
    while IFS=$'\t' read -r KIND PKG VER; do
        if [ "$KIND" = "U" ]; then
            COMP_USED_COUNT="$PKG"
        elif [ "$KIND" = "N" ] && [ -n "$PKG" ]; then
            COMP_UNUSED["$PKG"]="$VER"
        fi
    done < "$TMP_DIR/compout"
}

print_component_report() {
    local PKG VER N=0

    printf '\n[组件/插件包访问证据（atime，窗口 %s 天）]\n' "$DAYS"

    if [ "$COMPONENT_ATIME_OK" -eq 0 ]; then
        printf '（根分区以 noatime 挂载，atime 不更新，本节不可判定）\n'
        return
    fi

    if [ "${#COMP_UNUSED[@]}" -eq 0 ]; then
        printf '所有组件包在窗口内均有访问痕迹，未发现候选。\n'
        return
    fi

    printf '机制: 包内所有文件自窗口起点均未被任何程序读取，即未发现使用证据。\n'
    printf '已排除: 必需/受保护/内核固件类包、有桌面入口的应用（见 APT 候选节）。\n'
    printf '组件包统计: 有访问证据 %s，未发现访问证据 %s\n' \
        "$COMP_USED_COUNT" "${#COMP_UNUSED[@]}"

    for PKG in "${!COMP_UNUSED[@]}"; do
        N=$((N + 1))
        [ "$N" -gt 60 ] && continue
        VER="${COMP_UNUSED[$PKG]}"
        printf '候选\t%s\t%s\n' "$PKG" "$VER"
    done | sort -k2,2

    [ "$N" -gt 60 ] && printf '……其余 %s 个略\n' "$((N - 60))"
    printf 'atime 是间接证据（且不代表从未用过，仅窗口内无痕迹），删除前请人工确认。\n'
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

print_ime_report() {
    local E KEY PKG

    [ -d "$FCITX_ADDON_DIR" ] || return

    printf '\n[输入法引擎使用情况]\n'

    if [ "${#IME_USED_ENGINES[@]}" -eq 0 ]; then
        printf '（暂无引擎使用记录）\n'
        return
    fi

    for E in "${!IME_USED_ENGINES[@]}"; do
        PKG="${IME_ENGINE_PKG[$E]-}"
        if [ -n "$PKG" ]; then
            printf '已用引擎\t%s（%s）\n' "$E" "$PKG"
        else
            printf '已用引擎\t%s（归属包未知）\n' "$E"
        fi
    done | sort -k2,2

    if [ "${#IME_INSTALLED_PKGS[@]}" -eq 0 ]; then
        return
    fi

    for KEY in "${!IME_INSTALLED_PKGS[@]}"; do
        PKG="${KEY#apt:}"
        if [ -n "${IME_PKG_LAST[$KEY]+x}" ]; then
            printf '已使用\t%s\t最后切换 %s\n' "$PKG" "${IME_PKG_LAST[$KEY]}"
        elif [ "$IME_MATURE" -eq 1 ]; then
            printf '候选\t%s\t提供的引擎从未被切换使用\n' "$PKG"
        else
            printf '待判定\t%s\t引擎证据积累不足 7 天\n' "$PKG"
        fi
    done | sort -k2,2

    printf '判定粒度是包：包内任一引擎被使用过即整包视为已使用。\n'
}

printf '软件使用汇总\n'
printf '生成时间: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '长期未发现使用证据阈值: %s 天\n' "$DAYS"
printf '数据目录: %s\n' "$DATA_DIR"

load_installed
load_desktop_map
accumulate_usage
load_ime_evidence
load_component_evidence
print_cleanup_report
print_apt_report
print_other_report
print_ime_report
print_component_report
print_unresolved
