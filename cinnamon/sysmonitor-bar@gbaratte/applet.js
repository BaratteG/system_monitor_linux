const Applet = imports.ui.applet;
const PopupMenu = imports.ui.popupMenu;
const Settings = imports.ui.settings;
const Util = imports.misc.util;
const { GLib, St } = imports.gi;

const Stats = require('./stats.js');
const { PanelView } = require('./panelView.js');
const { PopupView } = require('./popupView.js');

// thick panels get the label stacked above the value
const TALL_PANEL_HEIGHT = 42;

const REFRESH_KEYS = ['gpuSource', 'netInterface', 'customPaths', 'folderRefresh'];
const DISPLAY_KEYS = [
    'warningTemp', 'criticalTemp', 'autoHide', 'diskPrefs',
    'cpuPanel', 'cpuPopup', 'tempPanel', 'tempPopup', 'freqPopup', 'threadsPopup',
    'ramPanel', 'ramPopup', 'amountsPanel', 'gpuPanel', 'gpuPopup', 'vramPanel', 'vramPopup',
    'diskPanel', 'diskPopup', 'netPanel', 'netPopup',
];

class SysMonitorApplet extends Applet.Applet {
    constructor(metadata, orientation, panelHeight, instanceId) {
        super(orientation, panelHeight, instanceId);
        this.setAllowedLayout(Applet.AllowedLayout.BOTH);

        this._script = metadata.path + '/sysstats.sh';
        this._stats = new Stats.SysStats();
        this._running = false;
        this._removed = false;
        this._timer = 0;

        this._cfg = {};
        this._settings = new Settings.AppletSettings(this, metadata.uuid, instanceId);
        this._settings.bindWithObject(this._cfg, 'updateInterval', 'updateInterval', () => this._startTimer());
        for (const key of REFRESH_KEYS) {
            this._settings.bindWithObject(this._cfg, key, key, () => this._refresh());
        }
        for (const key of DISPLAY_KEYS) {
            this._settings.bindWithObject(this._cfg, key, key, () => this._updateViews());
        }

        this._panelView = new PanelView();
        this.actor.add(this._panelView.actor);

        this._popupView = new PopupView();
        this.menuManager = new PopupMenu.PopupMenuManager(this);
        this.menu = new Applet.AppletPopupMenu(this, orientation);
        this.menuManager.addMenu(this.menu);
        this.menu.addActor(this._popupView.actor);
        this.menu.connect('open-state-changed', (menu, isOpen) => {
            if (isOpen) this._updateViews();
        });

        this._startTimer();
    }

    on_applet_added_to_panel() {
        this._updateLayout();
    }

    on_orientation_changed() {
        this._updateLayout();
    }

    on_panel_height_changed() {
        this._updateLayout();
    }

    on_applet_clicked() {
        this.menu.toggle();
    }

    on_applet_removed_from_panel() {
        this._removed = true;
        GLib.source_remove(this._timer);
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

    _updateViews() {
        const storage = Stats.storageItems(this._stats, this._cfg);
        const show = Stats.displayed(this._stats, this._cfg, storage);
        this._panelView.update(this._stats, show, this._cfg);
        // the popup is only redrawn while it is visible
        if (this.menu.isOpen) this._popupView.update(this._stats, show, this._cfg);
        this.set_applet_tooltip(Stats.tooltipText(this._stats, show, this._cfg));
    }
}

function main(metadata, orientation, panelHeight, instanceId) {
    return new SysMonitorApplet(metadata, orientation, panelHeight, instanceId);
}
