# GNOME Software Usage Tracker 交接文档

更新时间：2026-08-28

项目已纳入本地 git 仓库（分支 `main`），路径：

```text
/home/<user>/Desktop/Project/Linux/Clearing/   （符号链接，实际位于挂载盘 <挂载盘>/Project/Linux/Clearing/）
```

## 项目目标

记录当前用户实际使用过的 GUI 和命令行软件，并将使用证据与系统已安装软件清单汇总，最终回答：

- 哪些已安装软件真正被使用过；
- 哪些软件在指定时间范围内没有使用证据；
- 哪些 GUI 使用记录暂时无法映射到 APT、Snap 或 Flatpak 软件包。

本项目只生成报告，不执行卸载。

## 目录结构

项目文件统一位于：

```text
/home/<user>/Desktop/Project/Linux/Clearing/
```

主要文件：

```text
Clearing/
├── HANDOFF.md
├── software_tracker.sh
├── software_usage_report.sh
└── gnome-software-tracker@shadowemperor/
    ├── extension.js
    └── metadata.json
```

文件职责：

| 文件 | 职责 |
|---|---|
| `gnome-software-tracker@shadowemperor/extension.js` | 监听 GNOME 当前焦点窗口，记录 GUI 使用事件 |
| `software_tracker.sh` | 采集 CLI、Shell history、Fcitx/IBus 等使用证据；由 systemd user 服务常驻运行 |
| `software_usage_report.sh` | 汇总已安装软件和使用证据，输出报告 |
| `HANDOFF.md` | 项目交接说明 |

注：旧版基于文件 atime 的 `unused_software.sh` 已删除；GUI 记录完全由 GNOME 扩展负责，`software_tracker.sh` 不再扫描 GUI 进程。

## 系统环境

已验证环境：

```text
Ubuntu
GNOME Shell 50.1
/usr/bin/gnome-shell --mode=ubuntu
扩展 UUID: gnome-software-tracker@shadowemperor
```

扩展安装目录：

```text
~/.local/share/gnome-shell/extensions/gnome-software-tracker@shadowemperor/
```

扩展状态检查：

```bash
gnome-extensions info gnome-software-tracker@shadowemperor
```

当前已确认：扩展可以加载，状态为 `ACTIVE`，焦点信号能够触发。

磁盘上的 `metadata.json` 与运行中的 Shell 均为版本 `3`，项目目录中的副本与已安装版本一致（由安装目录同步而来）。早期观察到的“磁盘版本 1 / 运行版本 3”缓存不一致问题已随版本同步消失。

## GUI 扩展实现

处理链路：

```text
global.display
    ↓ notify::focus-window
global.display.focus_window
    ↓
Meta.WindowType.NORMAL
    ↓
window.get_pid()
    ↓
Shell.AppSystem.get_default().get_running()
    ↓ app.get_pids().includes(pid)
GNOME App
    ↓ app.get_app_info()
display name + executable
    ↓
gui-events.log
```

日志格式：

```text
应用名称|YYYY-MM-DD HH:MM:SS|gui|可执行文件
```

示例：

```text
Firefox|2026-08-22 00:38:52|gui|/snap/bin/firefox
终端|2026-08-22 00:38:53|gui|ptyxis
钉钉|2026-08-22 00:39:24|gui|/home/<user>/.local/bin/dingtalk.sh
```

扩展已经实现连续相同 PID 去重：GNOME 对同一窗口重复发出焦点通知时不会重复记录；切换到其他 PID 后再切回原 PID，会重新记录。

## 数据文件

数据目录：

```text
~/.local/share/unused-software/
```

主要数据文件：

| 文件 | 内容 | 可信度/用途 |
|---|---|---|
| `gui-events.log` | GNOME 焦点窗口产生的 GUI 使用事件 | GUI 使用的主要来源 |
| `usage.log` | 采集脚本汇总的 CLI 命令、Fcitx/IBus 记录（每种软件只保留一行，按名字更新最后使用时间） | CLI 和输入法使用证据 |
| `pids.log` | 旧版进程快照（遗留） | 不再更新；只能说明采集时运行过，不能证明长期使用 |
| `app_pids.log` | 旧版脚本识别到的 GUI PID（遗留） | 不再更新；报告已不读取 |
| `tracker-debug.log` | 扩展调试信息 | 排查焦点、PID、App 映射问题；持续增长，无轮转 |
| `tracker-test.log` | 早期测试文件 | 当前主流程不使用 |
| `history.size.*` | Shell history 增量读取位置 | 供 `software_tracker.sh` 使用；服务重启时从断点续读，停机期间的命令仍会被补采 |

`usage.log` 的旧格式为：

```text
软件名称|时间|类型|来源
```

## 使用方式

### 1. GUI 扩展

扩展通常由 GNOME Shell 自动运行。查看状态：

```bash
gnome-extensions info gnome-software-tracker@shadowemperor
```

禁用和启用：

```bash
gnome-extensions disable gnome-software-tracker@shadowemperor
gnome-extensions enable gnome-software-tracker@shadowemperor
```

如果磁盘上的代码和运行中的版本不一致，需要重新启动 GNOME Shell 或重新登录。当前已观察到：磁盘 `metadata.json` 是版本 `1`，但运行中的 Shell 曾报告版本 `3`，说明扩展模块仍被缓存。

查看 GUI 记录：

```bash
tail -n 50 ~/.local/share/unused-software/gui-events.log
```

查看调试记录：

```bash
tail -n 50 ~/.local/share/unused-software/tracker-debug.log
```

### 2. CLI/history 采集

由 systemd user 服务 `software-tracker.service` 常驻运行，登录后自启，崩溃自动重启：

```bash
systemctl --user status  software-tracker.service
systemctl --user restart software-tracker.service
systemctl --user stop    software-tracker.service
```

服务单元位于 `~/.config/systemd/user/software-tracker.service`，指向项目目录中的 `software_tracker.sh`（磁盘未挂载时会自动重试直到就绪）。

脚本每 10 秒检查一次，只处理：

- Shell history 新增命令（增量读取，重启续读）；
- 命令对应的 APT 软件包（内建命令/别名不映射）；
- Fcitx 5 或 IBus 是否在用（证据来源记为二进制名，便于映射到包）。

GUI 使用证据完全由 GNOME 扩展负责，脚本不再扫描 GUI 进程。

### 3. 生成汇总报告

默认按最近 180 天判断：

```bash
~/Desktop/Project/Linux/Clearing/software_usage_report.sh
```

指定天数，例如最近 30 天：

```bash
~/Desktop/Project/Linux/Clearing/software_usage_report.sh 30
```

报告包含：

- APT 已使用软件；
- APT 长期未发现使用证据的软件候选；
- Snap 使用情况；
- Flatpak 使用情况；
- 未映射的 GUI 使用证据。

对 executable 先去重再查包、时间按字符串比较、desktop 文件一次性批量查询后，全量报告约 5 秒完成（旧版逐行 fork `dpkg-query` 需数分钟）。

报告是只读的，不会修改安装状态，也不会卸载软件。

## 当前已知限制

### 1. GUI executable 不一定能直接映射到软件包

例如桌面文件可能使用：

```text
Exec=env ... /usr/bin/wechat
```

GNOME AppInfo 返回的 executable 可能是 `env`，因此报告会将它列为“未映射的 GUI 使用证据”，而不是错误地归入 `coreutils`。

钉钉使用用户脚本启动：

```text
/home/<user>/.local/bin/dingtalk.sh
```

这类应用需要根据 `.desktop` 文件或启动脚本增加显式映射规则。

### 2. `pids.log`/`app_pids.log` 是遗留数据

这两个文件是旧版 GUI 扫描的产物，已停止更新，报告也不再读取。没有可靠的事件时间线，不能因为某个进程出现在其中，就判定软件被长期使用。确认无用后可以删除。

### 3. “未使用”是“未发现证据”

报告中的候选软件不是绝对未使用，而是：

```text
在指定时间范围内，没有在已采集数据中发现使用证据
```

报告不能证明用户从未使用过软件，尤其是：

- 没有 GUI desktop 映射的应用；
- 通过脚本、容器或自定义启动器启动的应用；
- 只被系统服务间接调用的组件；
- 日志采集器尚未运行期间发生的使用行为。

### 4. APT 映射仍是包级别近似

通过命令路径映射到 APT 包时，一个包可能包含多个命令；GUI 通过 executable 映射时也可能对应元包、包装脚本或实际应用包。报告结果需要人工确认后才能用于卸载决策。

## 推荐后续工作

按优先级建议：

1. 为 `software_usage_report.sh` 增加 `.desktop` 的 `Name`/`Exec` 到包名的映射，解决微信、钉钉等启动器问题（目前只把含 desktop 文件的包纳入候选筛选，未做 Exec 映射）。
2. ~~从 `software_tracker.sh` 移除重复的 `check_gui_apps()`~~ 已完成：GUI 记录完全由 GNOME 扩展负责，采集脚本改为 systemd user 服务常驻。
3. 让 `usage.log` 和 `gui-events.log` 使用统一的 source/id 字段，减少名称匹配和包装脚本带来的歧义。
4. 报告已输出最近使用时间、证据类型、来源；如需更强决策依据，可再增加置信度字段。
5. 连续运行一段时间后再使用 30、90、180 天阈值比较结果，不要基于刚开始采集的短期数据卸载软件。
6. 报告已不读取 `pids.log`、`app_pids.log`、`tracker-test.log` 等遗留文件；确认无用后可从数据目录删除。`tracker-debug.log` 持续增长且无轮转，可考虑在扩展中降低调试输出。

## 安全原则

当前所有脚本都只做采集和报告：

- 不执行 `apt remove`；
- 不执行 `snap remove`；
- 不执行 `flatpak uninstall`；
- 不删除用户数据；
- 报告中的“候选”必须人工确认后才能进行卸载。

