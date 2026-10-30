// Popup content detached from its menu: a chrome actor that stays on screen, closes
// only with its button and moves with its title bar.
const { Clutter, St } = imports.gi;
const Main = imports.ui.main;
const { PanelLoc } = imports.ui.panel;

const { label } = require('./widgets.js');

// a box of size (w, h) kept inside an area; if it doesn't fit, its top left corner wins
function clampTo(area, x, y, w, h) {
    return [
        Math.round(Math.max(area.x, Math.min(x, area.x + area.width - w))),
        Math.round(Math.max(area.y, Math.min(y, area.y + area.height - h))),
    ];
}

function distanceTo(area, cx, cy) {
    const dx = Math.max(area.x - cx, 0, cx - (area.x + area.width));
    const dy = Math.max(area.y - cy, 0, cy - (area.y + area.height));
    return Math.hypot(dx, dy);
}

// the gaps between monitors of different sizes must not stop a drag
function nearestArea(areas, px, py) {
    return areas.reduce((best, area) => {
        return distanceTo(area, px, py) < distanceTo(best, px, py) ? area : best;
    });
}

// while dragging, the monitor under the center of the box
function clampDragged(areas, x, y, w, h) {
    return clampTo(nearestArea(areas, x + w / 2, y + h / 2), x, y, w, h);
}

// when the size changes, the monitor of the top left corner, which doesn't move:
// the center could cross over to the next monitor
function clampResized(areas, x, y, w, h) {
    return clampTo(nearestArea(areas, x + 1, y + 1), x, y, w, h);
}

// a position read back from the settings: its monitor may be gone
function safePosition(areas, primary, x, y, w, h) {
    const cx = x + w / 2, cy = y + h / 2;
    if (areas.some(area => distanceTo(area, cx, cy) === 0)) return clampDragged(areas, x, y, w, h);
    return clampTo(primary, primary.x + (primary.width - w) / 2, primary.y + (primary.height - h) / 2, w, h);
}

// the monitor without its visible panels, which are stacked above this window
function workArea(monitor) {
    const area = { x: monitor.x, y: monitor.y, width: monitor.width, height: monitor.height };
    for (const panel of Main.panelManager.getPanelsInMonitor(monitor.index)) {
        if (!panel.getIsVisible()) continue;
        switch (panel.panelPosition) {
        case PanelLoc.top:
            area.y += panel.actor.height;
            area.height -= panel.actor.height;
            break;
        case PanelLoc.bottom:
            area.height -= panel.actor.height;
            break;
        case PanelLoc.left:
            area.x += panel.actor.width;
            area.width -= panel.actor.width;
            break;
        case PanelLoc.right:
            area.width -= panel.actor.width;
            break;
        }
    }
    return area;
}

class FloatWindow {
    // onClose(): the close button was clicked; onMoved(x, y): end of a drag
    constructor({ onClose, onMoved }) {
        this._onMoved = onMoved;
        this._drag = null;

        // the look of a menu, and the theme text color it brings
        this.actor = new St.BoxLayout({
            vertical: true, reactive: true, style_class: 'menu', important: true,
        });

        this._title = new St.BoxLayout({ style_class: 'sysmon-float-title', reactive: true });
        this._title.add(label('System Monitor', 'sysmon-title'), {
            expand: true, x_fill: true, y_fill: false, y_align: St.Align.MIDDLE,
        });
        const close = new St.Button({ style_class: 'sysmon-icon-button', label: '×' });
        close.connect('clicked', () => onClose());
        this._title.add(close, { y_fill: false, y_align: St.Align.MIDDLE });
        this.actor.add(this._title, { x_fill: true });

        this._body = new St.BoxLayout({ vertical: true, style_class: 'popup-menu-content' });
        this.actor.add(this._body, { x_fill: true });

        this._title.connect('button-press-event', (actor, event) => this._onPress(event));
        this._title.connect('motion-event', (actor, event) => this._onMotion(event));
        this._title.connect('button-release-event', () => this._onRelease());

        Main.layoutManager.addChrome(this.actor, { visibleInFullscreen: false });
        this._lower();

        this.actor.connect('notify::allocation', () => this._keepInside());
        this._monitorsId = Main.layoutManager.connect('monitors-changed', () => this.placeAt(this.actor.x, this.actor.y));
    }

    get visible() { return this.actor.visible; }

    setContent(actor) {
        this._body.add(actor, { x_fill: true });
    }

    // the content must have been taken out first if it has to survive
    destroy() {
        this._stopDrag();
        Main.layoutManager.disconnect(this._monitorsId);
        Main.layoutManager.removeChrome(this.actor);
        this.actor.destroy();
    }

    toggle() {
        this.actor.visible = !this.actor.visible;
        if (this.actor.visible) {
            this._lower();
            this.placeAt(this.actor.x, this.actor.y);
        }
    }

    // to be called once the content is in: the size of the window depends on it
    placeAt(x, y) {
        const primary = workArea(Main.layoutManager.primaryMonitor);
        this.actor.set_position(...safePosition(this._areas(), primary, x, y, ...this._size()));
    }

    _size() {
        const [, , w, h] = this.actor.get_preferred_size();
        return [w, h];
    }

    _areas() {
        return Main.layoutManager.monitors.map(workArea);
    }

    // above the windows but under the panels: PopupMenu.open() puts every menu just
    // under the lowest panel, and they must not open behind this window
    _lower() {
        const children = Main.uiGroup.get_children();
        const panels = Main.panelManager.getPanels().filter(panel => panel)
            .map(panel => children.indexOf(panel.actor)).filter(i => i >= 0);
        if (panels.length > 0) Main.uiGroup.set_child_below_sibling(this.actor, children[Math.min(...panels)]);
    }

    // the window grows when the process panel opens
    _keepInside() {
        if (this._drag) return;
        const [x, y] = clampResized(this._areas(), this.actor.x, this.actor.y, ...this._size());
        if (x !== this.actor.x || y !== this.actor.y) this.actor.set_position(x, y);
    }

    // Same grabs as dnd.js: a fast pointer gets ahead of the window and out of the input
    // region of the chrome, and only a modal grab keeps its events coming. Clicks on the
    // close button never get here: St.Button stops them.
    _onPress(event) {
        if (event.get_button() !== Clutter.BUTTON_PRIMARY) return Clutter.EVENT_PROPAGATE;
        if (!Main.pushModal(this._title)) return Clutter.EVENT_PROPAGATE;
        const [px, py] = event.get_coords();
        this._drag = { device: event.get_device(), dx: px - this.actor.x, dy: py - this.actor.y };
        this._drag.device.grab(this._title);
        return Clutter.EVENT_STOP;
    }

    _onMotion(event) {
        if (!this._drag) return Clutter.EVENT_PROPAGATE;
        const [px, py] = event.get_coords();
        const position = clampDragged(this._areas(), px - this._drag.dx, py - this._drag.dy, ...this._size());
        this.actor.set_position(...position);
        return Clutter.EVENT_STOP;
    }

    _onRelease() {
        if (!this._drag) return Clutter.EVENT_PROPAGATE;
        this._stopDrag();
        this._onMoved(this.actor.x, this.actor.y);
        return Clutter.EVENT_STOP;
    }

    _stopDrag() {
        if (!this._drag) return;
        this._drag.device.ungrab();
        Main.popModal(this._title);
        this._drag = null;
    }
}

module.exports = { FloatWindow, clampDragged, clampResized, clampTo, safePosition };
