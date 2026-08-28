#!/bin/bash

# Description: 记录用户实际使用过的软件
# Author: Shadowemperor
# Date: 2026-08-21

INTERVAL=10

DATA_DIR="$HOME/.local/share/unused-software"

USAGE_LOG="$DATA_DIR/usage.log"
HISTORY_SIZE_FILE="$DATA_DIR/history.size"
APP_PID_FILE="$DATA_DIR/app_pids.log"

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

    PACKAGE=$(dpkg -S "$PATHNAME" 2>/dev/null |
        head -n 1 |
        cut -d ':' -f 1)

    echo "$PACKAGE"

}


# ========================================
# 获取当前用户的桌面应用
# ========================================

get_desktop_apps() {

    local DESKTOP_FILE
    local APP_NAME
    local EXEC_LINE
    local EXEC_NAME

    for DESKTOP_FILE in \
        "$HOME/.local/share/applications/"*.desktop \
        "/usr/share/applications/"*.desktop
    do

        [ -f "$DESKTOP_FILE" ] || continue

        grep -q "^NoDisplay=true" "$DESKTOP_FILE" && continue
        grep -q "^Hidden=true" "$DESKTOP_FILE" && continue

        APP_NAME=$(grep "^Name=" "$DESKTOP_FILE" |
            head -n 1 |
            cut -d '=' -f 2-)

        EXEC_LINE=$(grep "^Exec=" "$DESKTOP_FILE" |
            head -n 1 |
            cut -d '=' -f 2-)

        [ -z "$APP_NAME" ] && continue
        [ -z "$EXEC_LINE" ] && continue

        EXEC_NAME=$(echo "$EXEC_LINE" |
            awk '{print $1}')

        EXEC_NAME=$(basename "$EXEC_NAME")

        echo "$APP_NAME|$EXEC_NAME|$DESKTOP_FILE"

    done |
    sort -u

}


# ========================================
# 检测 GUI 应用
#
# 通过 .desktop 文件匹配真正的应用。
# 不记录应用产生的子进程。
# ========================================

check_gui_apps() {

    local PID
    local COMMAND
    local APP_NAME
    local EXEC_NAME
    local DESKTOP_FILE

    ps -u "$USER" -o pid=,comm= 2>/dev/null |
    while read -r PID COMMAND; do

        [ -z "$PID" ] && continue
        [ -z "$COMMAND" ] && continue

        # 这个 PID 已经处理过
        if grep -q "^${PID}|" "$APP_PID_FILE" 2>/dev/null; then
            continue
        fi

        APP_NAME=""
        EXEC_NAME=""
        DESKTOP_FILE=""

        while IFS='|' read -r NAME EXEC FILE; do

            if [ "$COMMAND" = "$EXEC" ]; then

                APP_NAME="$NAME"
                EXEC_NAME="$EXEC"
                DESKTOP_FILE="$FILE"

                break

            fi

        done < <(get_desktop_apps)

        # 没有对应 .desktop
        [ -z "$APP_NAME" ] && continue

        echo "$PID|$APP_NAME" >> "$APP_PID_FILE"

        record_usage \
            "$APP_NAME" \
            "$(current_time)" \
            "gui" \
            "$EXEC_NAME"

    done

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

            COMMAND=$(basename "$COMMAND")

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

    record_usage \
        "fcitx5" \
        "$(current_time)" \
        "input-method" \
        "$CURRENT_INPUT_METHOD"

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
        "$CURRENT_INPUT_METHOD"

}


# ========================================
# 清理已经结束的 GUI PID
# ========================================

cleanup_app_pids() {

    local PID
    local APP

    [ -f "$APP_PID_FILE" ] || return

    while IFS='|' read -r PID APP; do

        [ -z "$PID" ] && continue

        if ! kill -0 "$PID" 2>/dev/null; then

            sed -i "\|^${PID}|d" "$APP_PID_FILE"

        fi

    done < "$APP_PID_FILE"

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
echo "  - GUI 应用"
echo "  - CLI 软件"
echo "  - Fcitx / IBus"
echo
echo "不会记录系统后台进程"
echo "不会执行任何卸载操作"
echo
echo "正在运行..."
echo "按 Ctrl+C 停止"
echo


# ========================================
# 初始化 Shell History
#
# 不把旧历史算成现在使用。
# ========================================

for HISTORY_FILE in \
    "$HOME/.zsh_history" \
    "$HOME/.bash_history"
do

    if [ -f "$HISTORY_FILE" ]; then

        SIZE=$(stat -c %s "$HISTORY_FILE" 2>/dev/null)

        echo "$SIZE" \
            > "$HISTORY_SIZE_FILE.$(basename "$HISTORY_FILE")"

    fi

done


# ========================================
# 主循环
# ========================================

while true; do

    check_gui_apps

    check_shell_history

    check_fcitx

    check_ibus

    cleanup_app_pids

    sleep "$INTERVAL"

done
