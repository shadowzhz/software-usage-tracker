#!/bin/bash

# Description: 记录用户实际使用过的软件
# Author: Shadowemperor
# Date: 2026-08-21

INTERVAL=10

DATA_DIR="$HOME/.local/share/unused-software"

USAGE_LOG="$DATA_DIR/usage.log"
HISTORY_SIZE_FILE="$DATA_DIR/history.size"

mkdir -p "$DATA_DIR"


# ========================================
# 当前时间
# ========================================

current_time() {

    date "+%Y-%m-%d %H:%M:%S"

}


# ========================================
# 记录软件使用
#
# 格式：
# 软件|最后使用时间|类型|来源
# ========================================

record_usage() {

    local NAME="$1"
    local TIME="$2"
    local TYPE="$3"
    local SOURCE="$4"

    [ -z "$NAME" ] && return

    if grep -q "^${NAME}|" "$USAGE_LOG" 2>/dev/null; then

        awk -F '|' \
            -v name="$NAME" \
            -v time="$TIME" \
            -v type="$TYPE" \
            -v source="$SOURCE" '

            BEGIN {
                OFS="|"
            }

            $1 == name {
                $2 = time
                $3 = type
                $4 = source
            }

            {
                print
            }

        ' "$USAGE_LOG" > "$USAGE_LOG.tmp"

        mv "$USAGE_LOG.tmp" "$USAGE_LOG"

    else

        echo "$NAME|$TIME|$TYPE|$SOURCE" >> "$USAGE_LOG"

    fi

}


# ========================================
# 判断是否为基础 Shell 命令
# ========================================

is_basic_command() {

    case "$1" in

        awk|basename|cat|cd|chmod|chown|cp|cut|date|dirname)
            return 0
            ;;

        echo|env|export|false|find|grep|head|id|kill|less|ls)
            return 0
            ;;

        mkdir|mv|printf|pwd|read|rm|sed|sleep|sort|stat|tail)
            return 0
            ;;

        test|touch|tr|true|uniq|wc|which)
            return 0
            ;;

        bash|sh|dash|zsh|fish)
            return 0
            ;;

        *)
            return 1
            ;;

    esac

}


# ========================================
# 获取命令对应的 APT 软件包
# ========================================

get_package_from_command() {

    local COMMAND="$1"
    local PATHNAME
    local PACKAGE

    PATHNAME=$(command -v "$COMMAND" 2>/dev/null)

    [ -z "$PATHNAME" ] && return

    # 内建命令/别名解析结果不含路径，交给 dpkg 会模糊误配
    case "$PATHNAME" in
        */*) ;;
        *) return ;;
    esac

    PACKAGE=$(dpkg -S "$PATHNAME" 2>/dev/null |
        head -n 1 |
        cut -d ':' -f 1)

    echo "$PACKAGE"

}


# ========================================
# Shell History
#
# 只处理脚本启动之后新增的内容。
# ========================================

check_shell_history() {

    local HISTORY_FILE
    local CURRENT_SIZE
    local OLD_SIZE
    local LINE
    local COMMAND
    local PACKAGE

    for HISTORY_FILE in \
        "$HOME/.zsh_history" \
        "$HOME/.bash_history"
    do

        [ -f "$HISTORY_FILE" ] || continue

        CURRENT_SIZE=$(stat -c %s "$HISTORY_FILE" 2>/dev/null)

        OLD_SIZE=0

        if [ -f "$HISTORY_SIZE_FILE.$(basename "$HISTORY_FILE")" ]; then

            OLD_SIZE=$(cat \
                "$HISTORY_SIZE_FILE.$(basename "$HISTORY_FILE")")

        fi

        if [ "$CURRENT_SIZE" -le "$OLD_SIZE" ]; then
            continue
        fi

        tail -c +"$((OLD_SIZE + 1))" "$HISTORY_FILE" 2>/dev/null |
        while IFS= read -r LINE; do

            [ -z "$LINE" ] && continue

            # zsh extended history
            if [[ "$HISTORY_FILE" == "$HOME/.zsh_history" ]]; then

                case "$LINE" in

                    :\ *\;*)
                        COMMAND="${LINE#*;}"
                        ;;

                    *)
                        COMMAND="$LINE"
                        ;;

                esac

            else

                COMMAND="$LINE"

            fi

            # 去掉命令前面的空格
            COMMAND="${COMMAND#"${COMMAND%%[![:space:]]*}"}"

            # 取第一个命令
            COMMAND=$(echo "$COMMAND" |
                awk '{print $1}')

            # 多行命令的续行片段（如 --dest）不是命令
            case "$COMMAND" in
                ''|-*)
                    continue
                    ;;
            esac

            COMMAND=$(basename -- "$COMMAND")

            [ -z "$COMMAND" ] && continue

            if is_basic_command "$COMMAND"; then
                continue
            fi

            PACKAGE=$(get_package_from_command "$COMMAND")

            [ -z "$PACKAGE" ] && continue

            record_usage \
                "$PACKAGE" \
                "$(current_time)" \
                "cli" \
                "$COMMAND"

        done

        echo "$CURRENT_SIZE" \
            > "$HISTORY_SIZE_FILE.$(basename "$HISTORY_FILE")"

    done

}


# ========================================
# Fcitx 5
#
# 不把 fcitx addon 当成软件使用。
# ========================================

check_fcitx() {

    local CURRENT_INPUT_METHOD

    if ! command -v fcitx5-remote >/dev/null 2>&1; then
        return
    fi

    CURRENT_INPUT_METHOD=$(
        fcitx5-remote -n 2>/dev/null
    )

    [ -z "$CURRENT_INPUT_METHOD" ] && return

    # SOURCE 记录二进制名而不是引擎名，报告才能映射到 fcitx5 包
    record_usage \
        "fcitx5" \
        "$(current_time)" \
        "input-method" \
        "fcitx5"

}


# ========================================
# IBus
# ========================================

check_ibus() {

    local CURRENT_INPUT_METHOD

    if ! command -v ibus >/dev/null 2>&1; then
        return
    fi

    CURRENT_INPUT_METHOD=$(
        ibus engine 2>/dev/null
    )

    [ -z "$CURRENT_INPUT_METHOD" ] && return

    record_usage \
        "ibus" \
        "$(current_time)" \
        "input-method" \
        "ibus"

}


# ========================================
# 初始化
# ========================================

echo "========================================"
echo "       软件使用记录器"
echo "========================================"
echo
echo "检查间隔: $INTERVAL 秒"
echo "数据目录: $DATA_DIR"
echo
echo "监控:"
echo "  - CLI 软件"
echo "  - Fcitx / IBus"
echo
echo "GUI 使用由 GNOME 扩展 gnome-software-tracker 记录"
echo "不会执行任何卸载操作"
echo
echo "正在运行..."


# ========================================
# 初始化 Shell History 断点
#
# 断点文件已存在时从上次位置继续，
# 保证服务重启期间写入的历史不丢失。
# ========================================

for HISTORY_FILE in \
    "$HOME/.zsh_history" \
    "$HOME/.bash_history"
do

    if [ -f "$HISTORY_FILE" ] && [ ! -f "$HISTORY_SIZE_FILE.$(basename "$HISTORY_FILE")" ]; then

        SIZE=$(stat -c %s "$HISTORY_FILE" 2>/dev/null)

        echo "$SIZE" \
            > "$HISTORY_SIZE_FILE.$(basename "$HISTORY_FILE")"

    fi

done


# ========================================
# 主循环
# ========================================

trap 'exit 0' TERM INT

while true; do

    check_shell_history

    check_fcitx

    check_ibus

    sleep "$INTERVAL" &

    wait $!

done
