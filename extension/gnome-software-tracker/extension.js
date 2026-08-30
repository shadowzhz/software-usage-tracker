import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// notify::focus-window 在关窗/最小化/切换动画的首帧触发，任何同步磁盘 I/O
// 都会挤占那一天的帧预算。因此事件只写入内存缓冲，由 GLib 空闲回调一次性
// 落盘（打开→写→关闭各一次，目录仅在 enable 时创建）。
// 调试日志默认关闭，设环境变量 GNOME_SOFTWARE_TRACKER_DEBUG=1 开启，
// 开启后也走同一缓冲，不会产生逐行写盘。
export default class SoftwareUsageTracker extends Extension {

    enable() {

        this._lastFocusedPid = null;
        this._usageBuffer = [];
        this._debugBuffer = [];
        this._flushSource = 0;

        this._dataDir = Gio.File.new_for_path(GLib.build_filenamev([
            GLib.get_home_dir(),
            '.local',
            'share',
            'unused-software',
        ]));
        this._usageFile = this._dataDir.get_child('gui-events.log');
        this._debugFile = this._dataDir.get_child('tracker-debug.log');
        this._debugEnabled = GLib.getenv('GNOME_SOFTWARE_TRACKER_DEBUG') === '1';

        try {

            this._dataDir.make_directory_with_parents(null);

        } catch {

            // 目录已存在。

        }

        this._focusSignal = global.display.connect(
            'notify::focus-window',
            () => this._recordFocusWindow()
        );

        this._recordFocusWindow();

    }


    disable() {

        if (this._focusSignal) {

            global.display.disconnect(this._focusSignal);
            this._focusSignal = 0;

        }

        if (this._flushSource) {

            GLib.source_remove(this._flushSource);
            this._flushSource = 0;

        }

        this._flush();

    }


    _recordFocusWindow() {

        const window = global.display.focus_window;

        if (!window) {

            this._lastFocusedPid = null;
            return;

        }

        if (window.window_type !== Meta.WindowType.NORMAL) {

            this._lastFocusedPid = null;
            this._debug(`skip window_type=${window.window_type}`);
            return;

        }

        let pid = 0;

        try {

            pid = window.get_pid();

        } catch {

            return;

        }

        this._debug(`focus_window pid=${pid}`);

        if (!pid || pid <= 0) {

            this._lastFocusedPid = null;
            return;

        }

        if (pid === this._lastFocusedPid) {

            return;

        }

        this._lastFocusedPid = pid;

        const app = this._findAppByPid(pid);

        if (!app) {

            this._debug(`app_not_found pid=${pid}`);
            return;

        }

        const info = app.get_app_info();

        if (!info) {

            this._debug(`app_info_missing id=${app.get_id()}`);
            return;

        }

        const name = this._cleanField(info.get_display_name());
        const command = this._cleanField(info.get_executable());

        if (!name) {

            return;

        }

        this._debug(`app id=${app.get_id()} name=${name} command=${command}`);

        this._queue(
            `${name}|${GLib.DateTime.new_now_local()
                .format('%Y-%m-%d %H:%M:%S')}|gui|${command}\n`,
            false
        );

    }


    _findAppByPid(pid) {

        const appSystem = Shell.AppSystem.get_default();

        for (const app of appSystem.get_running()) {

            try {

                if (app.get_pids().includes(pid)) {
                    return app;
                }

            } catch {

                // pid 列表读取失败，跳过该应用。

            }

        }

        return null;

    }


    _cleanField(value) {

        return String(value || '')
            .replaceAll('|', '/')
            .replace(/[\r\n]+/g, ' ')
            .trim();

    }


    _queue(line, isDebug) {

        (isDebug ? this._debugBuffer : this._usageBuffer).push(line);

        if (!this._flushSource) {

            this._flushSource = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {

                this._flushSource = 0;
                this._flush();
                return GLib.SOURCE_REMOVE;

            });

        }

    }


    _debug(text) {

        if (!this._debugEnabled) {
            return;
        }

        this._queue(
            `${GLib.DateTime.new_now_local().format('%Y-%m-%d %H:%M:%S')}|${text}\n`,
            true
        );

    }


    _flush() {

        this._flushBuffer(this._usageBuffer, this._usageFile);
        this._flushBuffer(this._debugBuffer, this._debugFile);

    }


    _flushBuffer(buffer, file) {

        if (!buffer.length) {
            return;
        }

        const blob = buffer.join('');
        buffer.length = 0;

        try {

            const stream = file.append_to(Gio.FileCreateFlags.NONE, null);

            stream.write_all(
                new TextEncoder().encode(blob),
                null
            );

            stream.close(null);

        } catch {

            // 落盘失败时丢弃本批日志，主循环不值得为日志重试。

        }

    }

}
