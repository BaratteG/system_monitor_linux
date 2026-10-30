const Applet = imports.ui.applet;
const PopupMenu = imports.ui.popupMenu;
const Settings = imports.ui.settings;
const Util = imports.misc.util;
const { GLib, St } = imports.gi;

const Stats = require('./stats.js');
const { FloatWindow } = require('./floatWindow.js');
const { PanelView } = require('./panelView.js');
const { PopupView } = require('./popupView.js');

// thick panels get the label stacked above the value
const TALL_PANEL_HEIGHT = 42;

// period of the checks while a process is being stopped
const TASK_CHECK_INTERVAL = 500;

const REFRESH_KEYS = ['gpuSource', 'netInterface', 'customPaths', 'folderRefresh'];
const DISPLAY_KEYS = [
    'warningTemp', 'criticalTemp', 'autoHide', 'diskPrefs',
    'cpuPanel', 'cpuPopup', 'tempPanel', 'tempPopup', 'freqPopup', 'threadsPopup',
    'ramPanel', 'ramPopup', 'amountsPanel', 'gpuPanel', 'gpuPopup', 'vramPanel', 'vramPopup',
    'diskPanel', 'diskPopup', 'netPanel', 'netPopup',
];
// floating window state, not shown in the settings dialog
const FLOAT_KEYS = ['floating', 'floatX', 'floatY'];
// CPU graph of the popup: total curve or one mini graph per thread, not shown in the settings dialog
const THREAD_GRAPH_KEY = 'threadGraph';

class SysMonitorApplet extends Applet.Applet {
    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);
        this.setAllowedLayout(Applet.AllowedLayout.BOTH);

        this._script = metadata.path + '/sysstats.sh';
        this._processScript = metadata.path + '/procstats.sh';
        this._stats = new Stats.SysStats();
        this._tasks = new Stats.EndTask();
        this._running = false;
        this._processRunning = false;
        this._removed = false;
        this._timer = 0;
        this._processTimer = 0;
        this._taskTimer = 0;
        this._float = null;

        this._cfg = {};
        this._settings = new Settings.AppletSettings(this, metadata.uuid, instanceId);
        this._settings.bindWithObject(this._cfg, 'updateInterval', 'updateInterval', () => this._startTimer());
        for (const key of REFRESH_KEYS) {
            this._settings.bindWithObject(this._cfg, key, key, () => this._refresh());
        }
        for (const key of DISPLAY_KEYS) {
            this._settings.bindWithObject(this._cfg, key, key, () => this._updateViews());
        }
        for (const key of FLOAT_KEYS) this._settings.bindWithObject(this._cfg, key, key);
        this._settings.bindWithObject(this._cfg, THREAD_GRAPH_KEY, THREAD_GRAPH_KEY);

        this._panelView = new PanelView();
        this.actor.add(this._panelView.actor);

        this._popupView = new PopupView(this._tasks, {
            onDetach: () => this._detach(),
            onProcessKind: () => this._onProcessKind(),
            onEndTask: () => this._endTask(),
            onScrollbarDrag: active => { this.menu.passEvents = active; },
            onThreadGraph: () => this._toggleThreadGraph(),
        });
        this.menuManager = new PopupMenu.PopupMenuManager(this);
        this.menu = new Applet.AppletPopupMenu(this, orientation);
        this.menuManager.addMenu(this.menu);
        this.menu.addActor(this._popupView.actor);
        this.menu.connect('open-state-changed', (menu, isOpen) => {
            if (isOpen) this._updateViews();
            this._syncProcesses();
        });

        this._startTimer();
    }

    // also called when the panel of the applet changes
    on_applet_added_to_panel() {
        this._updateLayout();
        if (this._cfg.floating && !this._float) this._openFloat(this._cfg.floatX, this._cfg.floatY);
    }

    on_orientation_changed() {
        this._updateLayout();
    }

    on_panel_height_changed() {
        this._updateLayout();
    }

    on_applet_clicked() {
        if (this._float) {
            this._float.toggle();
            this._updateViews();
            this._syncProcesses();
        } else {
            this.menu.toggle();
        }
    }

    on_applet_removed_from_panel() {
        this._removed = true;
        // first: a chrome actor left behind would stay on screen until a restart
        if (this._float) this._float.destroy();
        this._float = null;
        GLib.source_remove(this._timer);
        if (this._processTimer) GLib.source_remove(this._processTimer);
        if (this._taskTimer) GLib.source_remove(this._taskTimer);
        this._settings.finalize();
        this.menu.destroy();
    }

    _updateLayout() {
        const vertical = this._orientation === St.Side.LEFT || this._orientation === St.Side.RIGHT;
        // this.panel is unset while a panel moves to another side
        const height = this.panel ? this._panelHeight : 0;
        const tall = vertical || height >= TALL_PANEL_HEIGHT * global.ui_scale;
        this._panelView.setLayout(vertical, tall);
        this._updateViews();
    }

    _startTimer() {
        if (this._timer) GLib.source_remove(this._timer);
        this._timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, this._cfg.updateInterval, () => {
            this._refresh();
            return GLib.SOURCE_CONTINUE;
        });
        this._refresh();
        if (this._processTimer) {
            this._stopProcessTimer();
            this._syncProcesses();
        }
    }

    // the script runs outside the Cinnamon process: a slow nvidia-smi only delays
    // the next sample, it never blocks the desktop
    _refresh() {
        if (this._running) return;
        this._running = true;
        const argv = ['bash', this._script, ...Stats.scriptArgs(this._cfg)];
        Util.spawnCommandLineAsyncIO('', stdout => {
            this._running = false;
            if (this._removed || !stdout) return;
            this._stats.update(stdout);
            this._addNewDisks();
            this._updateViews();
        }, { argv });
    }

    // detected partitions are listed in the settings so they can be toggled there
    _addNewDisks() {
        const known = new Set(this._cfg.diskPrefs.map(p => p.mount));
        const added = this._stats.disks.filter(d => !known.has(d.mount))
            .map(d => ({ mount: d.mount, panel: d.mount === '/', popup: true }));
        if (added.length > 0) this._settings.setValue('diskPrefs', this._cfg.diskPrefs.concat(added));
    }

    get _contentVisible() {
        return this._float ? this._float.visible : this.menu.isOpen;
    }

    _updateViews() {
        const storage = Stats.storageItems(this._stats, this._cfg);
        const show = Stats.displayed(this._stats, this._cfg, storage);
        this._panelView.update(this._stats, show, this._cfg);
        // the popup is only redrawn while it is visible
        if (this._contentVisible) this._popupView.update(this._stats, show, this._cfg);
        this.set_applet_tooltip(Stats.tooltipText(this._stats, show, this._cfg));
    }

    _toggleThreadGraph() {
        this._settings.setValue(THREAD_GRAPH_KEY, !this._cfg.threadGraph);
        this._updateViews();
    }

    // the same actor goes from the menu to the floating window and back
    _detach() {
        const [x, y] = this.menu.actor.get_transformed_position();
        const saved = this._cfg.floatX >= 0 && this._cfg.floatY >= 0;
        this.menu.close(false);
        this._openFloat(saved ? this._cfg.floatX : x, saved ? this._cfg.floatY : y);
        this._saveFloatPosition(this._float.actor.x, this._float.actor.y);
        this._settings.setValue('floating', true);
    }

    _saveFloatPosition(x, y) {
        this._settings.setValue('floatX', x);
        this._settings.setValue('floatY', y);
    }

    _openFloat(x, y) {
        const content = this._popupView.actor;
        content.get_parent().remove_child(content);
        this._float = new FloatWindow({
            onClose: () => this._closeFloat(),
            onMoved: (newX, newY) => this._saveFloatPosition(newX, newY),
        });
        this._float.setContent(content);
        this._popupView.floating = true;
        this._float.placeAt(x, y);
        this._updateViews();
        this._syncProcesses();
    }

    _closeFloat() {
        const content = this._popupView.actor;
        content.get_parent().remove_child(content);
        this._float.destroy();
        this._float = null;
        this.menu.addActor(content);
        this._popupView.floating = false;
        this._settings.setValue('floating', false);
        this._syncProcesses();
    }

    // the process list only runs while it can be seen
    _syncProcesses() {
        if (!this._contentVisible || !this._popupView.processKind) {
            this._stopProcessTimer();
        } else if (!this._processTimer) {
            this._processTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, Stats.processInterval(this._cfg), () => {
                this._refreshProcesses();
                return GLib.SOURCE_CONTINUE;
            });
            this._refreshProcesses();
        }
    }

    _stopProcessTimer() {
        if (this._processTimer) GLib.source_remove(this._processTimer);
        this._processTimer = 0;
    }

    _onProcessKind() {
        this._syncProcesses();
        this._refreshProcesses();
        this._watchTasks();
    }

    _refreshProcesses() {
        const kind = this._popupView.processKind;
        if (this._processRunning || !this._processTimer || !kind) return;
        this._processRunning = true;
        const argv = ['bash', this._processScript, ...Stats.processArgs(kind, this._cfg)];
        Util.spawnCommandLineAsyncIO('', stdout => {
            this._processRunning = false;
            if (this._removed || !this._processTimer) return;
            // the other list was asked for in the meantime
            if (kind !== this._popupView.processKind) {
                this._refreshProcesses();
                return;
            }
            const list = Stats.parseProcesses(stdout);
            if (!list) return;
            if (kind === 'cpu') this._tasks.setList(list.rows);
            this._popupView.setProcesses(list);
            this._watchTasks();
        }, { argv });
    }

    // from here on the pid has been validated by EndTask.request(): it comes from the
    // list on screen, and the argv never goes through a shell
    _endTask() {
        const request = this._tasks.request();
        if (!request) return;
        const { pid, signal } = request;
        this._popupView.updateTasks();
        this._spawn(Stats.killArgs(pid, signal), (stdout, stderr, exitCode) => {
            this._tasks.sent(pid, exitCode);
            this._popupView.updateTasks();
            this._watchTasks();
        });
    }

    _watchTasks() {
        if (this._taskTimer || !this._tasks.watching) return;
        this._taskTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, TASK_CHECK_INTERVAL, () => {
            for (const pid of this._tasks.checksDue()) this._checkTask(pid);
            if (this._tasks.watching) return GLib.SOURCE_CONTINUE;
            this._taskTimer = 0;
            return GLib.SOURCE_REMOVE;
        });
    }

    _checkTask(pid) {
        this._spawn(Stats.processCheckArgs(pid), (stdout, stderr, exitCode) => {
            // -1: ps did not run, which says nothing about the process
            this._tasks.checked(pid, exitCode === -1 || Stats.processAlive(stdout));
            this._popupView.updateTasks();
            this._watchTasks();
        });
    }

    // a command missing from the system throws here: it counts as a failed one
    _spawn(argv, callback) {
        try {
            Util.spawnCommandLineAsyncIO('', (stdout, stderr, exitCode) => {
                if (!this._removed) callback(stdout, stderr, exitCode);
            }, { argv });
        } catch (e) {
            global.logError(e);
            callback('', '', -1);
        }
    }
}

function main(metadata, orientation, panelHeight, instanceId) {
    return new SysMonitorApplet(metadata, orientation, panelHeight, instanceId);
}
