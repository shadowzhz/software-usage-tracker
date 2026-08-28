# Software Usage Tracker (Clearing)

**用真实使用证据回答三个问题：哪些已安装软件真的用过？哪些长期没有使用痕迹？哪些使用证据映射不到软件包？只生成报告，绝不卸载任何东西。**

Answer, with actual usage evidence: which installed software did you really use, which has had no trace of use for a long time, and which evidence can't be mapped to a package. **Read-only reporting — nothing is ever uninstalled by this tool.**

> 在 Ubuntu 26.04 / GNOME Shell 50（Wayland）上开发和测试。测试环境用 uutils coreutils（Rust 版 basename 等），对 GNU 环境同样兼容。

## 为什么需要它

Linux 桌面用户装软件容易、清理难：装的时候是明确的，忘的时候是无声的。`apt autoremove` 只能看到依赖图意义上的孤儿；一个你三年没打开过的应用、一个从未被宿主加载过的解码器插件、一个装了但从来没切换到过的输入法引擎，在系统里没有任何现成的"没用过"标记。

本项目用四层互补的证据把它们找出来：

| 层 | 机制 | 回答的问题 | 性质 |
|---|---|---|---|
| 依赖图 | `apt autoremove` 模拟、Snap 旧版本、Flatpak 未使用运行时 | 系统还需要它吗 | 确定性 |
| 应用级 | GNOME 焦点窗口记录 + Shell history + `.desktop` 名称/可执行文件映射 | 独立应用用过吗 | 使用证据 |
| 组件级 | 文件 atime（包内所有文件在窗口期内从未被读取） | 组件被宿主加载过吗 | 间接证据 |
| 输入法 | fcitx5 引擎切换事件 → addon → 包（包级聚合） | 引擎插件被切换到过吗 | 使用证据 |

组件级检测是通用的：库、gstreamer 解码器、拼写词典、字体、主题、Shell 扩展、没有桌面入口的 CLI 工具——任何"无独立入口、靠宿主加载"的东西都在覆盖范围内，不需要为每个应用写适配。

## 组成

```text
gnome-software-tracker@shadowemperor/   GNOME Shell 扩展：记录焦点窗口的 GUI 使用事件
software_tracker.sh                     采集器（systemd user 服务常驻）：Shell history 增量、
                                        CLI→APT 包映射、fcitx5 框架与引擎切换证据
software_usage_report.sh                报告生成器（只读，约 10 秒出全量报告）
software-tracker.service                systemd user 服务单元
HANDOFF.md                              设计细节与已知限制（中文）
```

数据目录：`~/.local/share/unused-software/`。所有数据只留在本机，不上传任何内容。

## 安装

```bash
# 1. GNOME 扩展（GUI 使用证据）
mkdir -p ~/.local/share/gnome-shell/extensions
cp -r gnome-software-tracker@shadowemperor ~/.local/share/gnome-shell/extensions/
gnome-extensions enable gnome-software-tracker@shadowemperor
# X11 会话可用 Alt+F2 输入 'r' 重启 Shell；Wayland 需注销重登

# 2. 采集服务（CLI / 输入法证据）
mkdir -p ~/.config/systemd/user
cp software-tracker.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now software-tracker.service

# 3. 报告（默认按最近 180 天判定）
./software_usage_report.sh          # 全量报告
./software_usage_report.sh 30       # 指定天数窗口
```

扩展要求 GNOME Shell 50（`metadata.json` 中的 `shell-version`，可按需放宽）；采集服务只依赖 bash、coreutils、dpkg，可选 fcitx5 / snap / flatpak。

## 报告示例

```text
[清理候选（依赖图判定，确定性）]
APT 孤儿依赖: 无
Snap 旧版本残留: 无

[APT 长期未发现使用证据: 180 天]
候选	com.alibabainc.dingtalk	8.1.0.6021101
候选	wechat	4.1.1.8
...

[输入法引擎使用情况]
已用引擎	pinyin（fcitx5-pinyin）
待判定	fcitx5-table	引擎证据积累不足 7 天

[组件/插件包访问证据（atime，窗口 180 天）]
组件包统计: 有访问证据 2046，未发现访问证据 4
候选	g++	4:15.2.0-5ubuntu1
候选	gcc-x86-64-linux-gnu	4:15.2.0-5ubuntu1
```

## 设计要点

- **只报告，不卸载**：所有"候选"都需要人工确认后手动执行删除命令。报告脚本没有任何卸载路径。
- **诚实的不确定性**：报告中的"未使用"是"在窗口期内未发现使用证据"，不是"从未用过"。启动器包装（`Exec=env ...`）、用户脚本启动的应用会先尝试 `.desktop` 名称/可执行文件映射，映射不了就原样列在"未映射的 GUI 使用证据"里，而不是猜一个包。
- **歧义保护**：一个名字对应多个包时不做映射；歧义的输入法插件不参与判定；根分区以 `noatime` 挂载时 atime 证据自动停用。
- **冷启动保护**：输入法引擎证据积累不足 7 天时候选只显示"待判定"，避免刚部署就误报。
- **性能**：报告对全部日志做单遍聚合，包归属查询先去重再批量执行，全量报告约 10 秒（2000+ 已安装包、4000+ 使用事件）。

## 已知限制

- GNOME 扩展依赖 `Shell.AppSystem` 映射，极少数应用的可执行名与桌面文件不一致时落在"未映射"节；
- atime 在 `relatime` 下每天最多更新一次，足以区分"窗口内有无痕迹"，但不能给出精确的使用次数；
- 应用内插件（VS Code 扩展、浏览器扩展）不在系统包体系内，暂不覆盖；
- Debian/Ubuntu 系专用（dpkg），Snap/Flatpak 部分是可选增强。

## 同类工具与差异

依赖图方向：`apt autoremove`、`deborphan`、Fedora `dnf package-cleanup --leaves`、Synaptic 的"auto removable"标记——都只看依赖关系，没有使用证据。使用统计方向：Debian `popularity-contest`（atime 采样，为发行版聚合统计设计）、GitHub 上的 GNOME 应用使用时长追踪扩展（面向 screen time，不做包映射）——都没有落到"哪些包可以清理"的决策上。将使用证据、依赖图、启动器映射、多包格式（deb/snap/flatpak）整合成一份只读清理建议报告，是本项目的不同之处。

## License

MIT，见 [LICENSE](LICENSE)。
