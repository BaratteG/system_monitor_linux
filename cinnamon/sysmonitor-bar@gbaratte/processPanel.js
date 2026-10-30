// Side panel of the popup: busiest processes, with "Fin de tâche" under the CPU list.
const { Clutter, Pango, St } = imports.gi;
const Tooltips = imports.ui.tooltips;

const Stats = require('./stats.js');
const { FixedLabel, label } = require('./widgets.js');

const TITLES = { cpu: 'Processus CPU', gpu: 'Processus GPU' };
const COLUMNS = { cpu: ['CPU %', 'Mémoire'], gpu: ['GPU %', 'VRAM'] };

const DIMMED_OPACITY = 140;
const DISABLED_OPACITY = 110;

// name, then right-aligned numbers: the same widths for the header and the rows
class ProcessColumns {
    constructor(styleClass, reactive) {
        this.actor = new St.BoxLayout({ style_class: styleClass, reactive, track_hover: reactive });
        this.name = label('', null);
        this.name.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        this.pid = new FixedLabel('sysmon-proc-pid');
        this.use = new FixedLabel('sysmon-proc-use');
        this.mem = new FixedLabel('sysmon-proc-mem');

        this.actor.add(this.name, { expand: true, x_fill: true, y_fill: false, y_align: St.Align.MIDDLE });
        for (const cell of [this.pid, this.use, this.mem]) {
            this.actor.add(cell.actor, { y_fill: false, y_align: St.Align.MIDDLE });
        }
    }
}

class ProcessRow extends ProcessColumns {
    constructor(onSelect) {
        super('sysmon-proc-row', true);
        this.processId = 0;
        this._tooltipText = '';
        // before our handler: it stops the event, the tooltip must still see it
        this._tooltip = new Tooltips.Tooltip(this.actor, '');
        this.actor.connect('button-press-event', (actor, event) => {
            if (event.get_button() !== Clutter.BUTTON_PRIMARY) return Clutter.EVENT_PROPAGATE;
            onSelect(this.processId);
            return Clutter.EVENT_STOP;
        });
    }

    update(row, kind) {
        this.processId = row.pid;
        this.name.text = row.name;
        this.pid.text = String(row.pid);
        this.use.text = Stats.processUseText(kind, row.use);
        this.mem.text = Stats.processMemText(row.mem);
        this.actor.opacity = row.killable ? 255 : DIMMED_OPACITY;

        const tooltip = Stats.processTooltip(row);
        if (tooltip !== this._tooltipText) {
            this._tooltipText = tooltip;
            this._tooltip.set_text(tooltip);
        }
    }

    set selected(selected) {
        this.actor.change_style_pseudo_class('checked', selected);
    }
}

class ProcessPanel {
    // tasks: Stats.EndTask; onScrollbarDrag(active): see the 'scroll-start' handler
    constructor(tasks, { onEndTask, onScrollbarDrag }) {
        this._tasks = tasks;
        this._kind = null;
        this._rows = [];

        this.actor = new St.BoxLayout({ vertical: true, style_class: 'sysmon-proc-panel' });
        this._title = label('', 'sysmon-title');
        this.actor.add(this._title);

        this._head = new ProcessColumns('sysmon-proc-head', false);
        this._head.name.text = 'Nom';
        this._head.pid.text = 'PID';
        this._head.actor.opacity = 153;
        this.actor.add(this._head.actor, { x_fill: true });

        // overlay: a scrollbar that takes space would shift the rows from the header
        this._scroll = new St.ScrollView({
            hscrollbar_policy: St.PolicyType.NEVER,
            vscrollbar_policy: St.PolicyType.AUTOMATIC,
            overlay_scrollbars: true,
        });
        this._list = new St.BoxLayout({ vertical: true });
        this._scroll.add_actor(this._list);
        this.actor.add(this._scroll, { expand: true, x_fill: true, y_fill: true });

        // the scrollbar grabs the pointer: the menu must not take the release for an
        // outside click (same as PopupMenu.PopupSubMenu)
        const vscroll = this._scroll.get_vscroll_bar();
        vscroll.connect('scroll-start', () => onScrollbarDrag(true));
        vscroll.connect('scroll-stop', () => onScrollbarDrag(false));

        this._message = label('', 'sysmon-unit', 0.6);
        this.actor.add(this._message, {
            expand: true, x_fill: false, y_fill: false, x_align: St.Align.MIDDLE, y_align: St.Align.MIDDLE,
        });

        this._footer = new St.BoxLayout({ vertical: true, style_class: 'sysmon-proc-footer' });
        const actions = new St.BoxLayout({ style_class: 'sysmon-proc-actions' });
        this._selection = label('', null);
        this._selection.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        this._endButton = new St.Button({ style_class: 'sysmon-button', label: 'Fin de tâche' });
        this._endButton.connect('clicked', () => onEndTask());
        actions.add(this._selection, { expand: true, x_fill: true, y_fill: false, y_align: St.Align.MIDDLE });
        actions.add(this._endButton, { y_fill: false, y_align: St.Align.MIDDLE });
        this._footer.add(actions, { x_fill: true });
        this._status = label('', 'sysmon-unit');
        this._status.clutter_text.ellipsize = Pango.EllipsizeMode.END;
        this._footer.add(this._status, { x_fill: true });
        this.actor.add(this._footer, { x_fill: true });
    }

    // new list: nothing to show until its first result
    setKind(kind) {
        this._kind = kind;
        this._title.text = TITLES[kind];
        [this._head.use.text, this._head.mem.text] = COLUMNS[kind];
        this._footer.visible = kind === 'cpu';
        this._scroll.get_vscroll_bar().get_adjustment().set_value(0);
        this._showMessage('Chargement…');
        this.updateTasks();
    }

    // list: result of Stats.parseProcesses(); the rows are reused so that the scroll
    // position survives a refresh
    update(list) {
        const rows = list.kind === 'none' ? [] : list.rows;
        while (this._rows.length > rows.length) this._rows.pop().actor.destroy();
        rows.forEach((row, i) => {
            if (!this._rows[i]) {
                this._rows[i] = new ProcessRow(pid => this._select(pid));
                this._rows[i].update(row, this._kind);
                this._list.add(this._rows[i].actor, { x_fill: true });
            } else {
                this._rows[i].update(row, this._kind);
            }
        });

        if (list.kind === 'none') this._showMessage('Aucune donnée par processus pour ce GPU');
        else if (rows.length === 0) this._showMessage('Aucun processus');
        else this._showMessage('');
        this.updateTasks();
    }

    updateTasks() {
        const tasks = this._tasks;
        for (const row of this._rows) {
            row.selected = this._kind === 'cpu' && row.processId === tasks.selectedPid;
        }

        const selected = tasks.selected;
        this._selection.text = selected ? selected.name + ' · PID ' + selected.pid : 'Aucun processus sélectionné';
        this._selection.opacity = selected ? 255 : 153;

        const { text, enabled } = tasks.button;
        this._endButton.label = text;
        this._endButton.reactive = enabled;
        this._endButton.opacity = enabled ? 255 : DISABLED_OPACITY;
        // a button that stops being reactive never gets its leave event
        if (!enabled) this._endButton.hover = false;

        const status = tasks.status;
        this._status.text = status ? status.text : '';
        if (!status || status.ok === null) this._status.style = '';
        else this._status.style = `color: ${status.ok ? Stats.COLORS.positive : Stats.COLORS.negative};`;
    }

    _select(pid) {
        if (this._kind !== 'cpu') return;
        this._tasks.select(pid);
        this.updateTasks();
    }

    _showMessage(text) {
        this._message.text = text;
        this._message.visible = text !== '';
        this._scroll.visible = text === '';
    }
}

module.exports = { ProcessPanel };
