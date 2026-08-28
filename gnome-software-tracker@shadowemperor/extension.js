import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

export default class SoftwareUsageTracker extends Extension {

    enable() {

        this._lastFocusedPid = null;
        this._writeDebug('enable entered');

        try {

            this._focusSignal = global.display.connect(
                'notify::focus-window',
                () => this._recordFocusWindow('signal')
            );

            this._writeDebug(`focus signal connected id=${this._focusSignal}`);

        } catch (error) {

            this._writeDebug(`focus signal error=${error}`);

        }

        this._recordFocusWindow('initial');


    }


    disable() {

        if (this._focusSignal) {

            global.display.disconnect(this._focusSignal);
            this._focusSignal = 0;

        }

        this._writeDebug('disable');

    }


    _recordFocusWindow(source) {

        this._writeDebug(`recordFocusWindow source=${source}`);

        const window = global.display.focus_window;

        if (!window) {

            this._lastFocusedPid = null;
            this._writeDebug('focus_window=none');
            return;

        }

        if (window.window_type !== Meta.WindowType.NORMAL) {

            this._lastFocusedPid = null;
            this._writeDebug(`skip window_type=${window.window_type}`);
            return;

        }

        let title = '';

        try {

            title = window.get_title() || '';

        } catch (error) {

            this._writeDebug(`get_title_error=${error}`);

        }

        let windowType = 'unknown';

        try {

            windowType = String(window.window_type);

        } catch (error) {

            this._writeDebug(`window_type_error=${error}`);

        }

        let pid = 0;

        try {

            pid = window.get_pid();

        } catch (error) {

            this._writeDebug(`get_pid_error=${error}`);

        }

        this._writeDebug(
            `focus_window title=${JSON.stringify(title)} window_type=${windowType} pid=${pid}`
        );

        if (!pid || pid <= 0) {

            this._lastFocusedPid = null;
            this._writeDebug('skip invalid_pid');
            return;

        }

        if (pid === this._lastFocusedPid) {

            this._writeDebug(`skip duplicate_pid=${pid}`);
            return;

        }

        this._lastFocusedPid = pid;

        const app = this._findAppByPid(pid);

        if (!app) {

            this._writeDebug(`app_not_found pid=${pid}`);
            return;

        }

        const info = app.get_app_info();

        if (!info) {

            this._writeDebug(`app_info_missing id=${app.get_id()}`);
            return;

        }

        const name = this._cleanField(info.get_display_name());
        const command = this._cleanField(info.get_executable());

        if (!name) {

            this._writeDebug(`app_name_missing id=${app.get_id()}`);
            return;

        }

        this._writeDebug(
            `app id=${app.get_id()} name=${JSON.stringify(name)} command=${JSON.stringify(command)}`
        );

        this._writeUsage(name, command);

    }


    _findAppByPid(pid) {

        const appSystem = Shell.AppSystem.get_default();

        for (const app of appSystem.get_running()) {

            try {

                if (app.get_pids().includes(pid)) {
                    return app;
                }

            } catch (error) {

                this._writeDebug(`get_pids_error=${error}`);

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


    _writeUsage(name, command) {

        const directory = Gio.File.new_for_path(
            GLib.build_filenamev([
                GLib.get_home_dir(),
                '.local',
                'share',
                'unused-software'
            ])
        );

        try {

            directory.make_directory_with_parents(null);

        } catch (error) {

            // The directory may already exist.

        }

        const file = Gio.File.new_for_path(
            GLib.build_filenamev([
                GLib.get_home_dir(),
                '.local',
                'share',
                'unused-software',
                'gui-events.log'
            ])
        );

        try {

            const stream = file.append_to(
                Gio.FileCreateFlags.NONE,
                null
            );

            const line = `${name}|${GLib.DateTime.new_now_local()
                .format('%Y-%m-%d %H:%M:%S')}|gui|${command}\n`;

            stream.write_all(
                new TextEncoder().encode(line),
                null
            );

            stream.close(null);
            this._writeDebug(`writeUsage line=${JSON.stringify(line.trim())}`);

        } catch (error) {

            this._writeDebug(`writeUsage_error=${error}`);

        }

    }


    _writeDebug(text) {

        const directory = Gio.File.new_for_path(
            GLib.build_filenamev([
                GLib.get_home_dir(),
                '.local',
                'share',
                'unused-software'
            ])
        );

        try {

            directory.make_directory_with_parents(null);

        } catch (error) {

            // The directory may already exist.

        }

        const file = Gio.File.new_for_path(
            GLib.build_filenamev([
                GLib.get_home_dir(),
                '.local',
                'share',
                'unused-software',
                'tracker-debug.log'
            ])
        );

        try {

            const stream = file.append_to(
                Gio.FileCreateFlags.NONE,
                null
            );

            const line = `${GLib.DateTime.new_now_local()
                .format('%Y-%m-%d %H:%M:%S')}|${text}\n`;

            stream.write_all(
                new TextEncoder().encode(line),
                null
            );

            stream.close(null);

        } catch (error) {

            log(`Software Usage Tracker: debug write failed: ${error}`);

        }

    }

}
