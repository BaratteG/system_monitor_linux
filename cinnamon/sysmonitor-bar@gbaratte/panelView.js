// Compact view shown in the panel: CPU, RAM | GPU, VRAM | NET | storage.
const { Clutter, St } = imports.gi;

const Stats = require('./stats.js');
const { FixedLabel, UsageBar, label } = require('./widgets.js');

const CELL_SPACING = 4;

// on a vertical panel the disk names must fit the panel width
const NARROW_NAME_LENGTH = 6;

// label on the left of the values, stacked above them on thick panels (layout.tall);
// on vertical panels (layout.narrow) everything goes in one column
class GridCell {
    constructor(name, layout, nameSpan) {
        this._grid = new Clutter.GridLayout();
        this._grid.set_column_spacing(CELL_SPACING * global.ui_scale);
        this.actor = new St.Widget({ layout_manager: this._grid });
        this._narrow = layout.narrow;
        this._nextRow = 1;
        this._row = layout.tall ? 1 : 0;
        this._col = layout.tall ? 0 : 1;
        this._name = label(name, 'sysmon-name', 0.6);
        this._name.y_align = Clutter.ActorAlign.CENTER;
        this._name.x_align = Clutter.ActorAlign.START;
        this._grid.attach(this._name, 0, 0, layout.tall ? nameSpan : 1, 1);
    }

    _attach(actor, column, row) {
        actor.y_align = Clutter.ActorAlign.CENTER;
        if (this._narrow) this._grid.attach(actor, 0, this._nextRow++, 1, 1);
        else this._grid.attach(actor, this._col + column, this._row + row, 1, 1);
    }
}

function valueBox(number, unit) {
    const box = new St.BoxLayout();
    box.add(number.actor);
    box.add(unit, { y_fill: false, y_align: St.Align.MIDDLE });
    return box;
}

// usage percent with a thin bar, optional temperature and used/total amount
class UsageCell extends GridCell {
    constructor(name, layout) {
        super(name, layout, 3);
        this._number = new FixedLabel('sysmon-percent');
        this._attach(valueBox(this._number, label('%', 'sysmon-unit sysmon-percent-unit', 0.6)), 0, 0);
        this._bar = new UsageBar('sysmon-bar');
        this._attach(this._bar.actor, 0, 1);

        this._temp = new FixedLabel('sysmon-temp');
        this._attach(this._temp.actor, 1, 0);

        this._amountBox = new St.BoxLayout();
        this._amount = new FixedLabel('sysmon-amount', 0.75);
        this._total = label('', null, 0.5);
        this._total.visible = !layout.narrow;
        this._amountBox.add(this._amount.actor);
        this._amountBox.add(this._total);
        this._amountBox.add(label('G', 'sysmon-unit', 0.6), { y_fill: false, y_align: St.Align.MIDDLE });
        this._attach(this._amountBox, 2, 0);
    }

    update({ value, temp = -1, showTemp = false, amount = '', total = '' }, cfg) {
        this._number.text = Stats.num(value);
        this._bar.set(value, Stats.usageColor(value));

        this._temp.actor.visible = showTemp;
        this._temp.text = Stats.valid(temp) ? Math.round(temp) + '°' : '--°';
        const color = Stats.tempColor(temp, cfg);
        this._temp.label.style = color ? `color: ${color};` : '';
        this._temp.label.opacity = temp >= cfg.warningTemp ? 255 : 191;

        this._amountBox.visible = amount !== '';
        this._amount.text = amount;
        this._total.text = '/' + total;
    }
}

// one direction of network traffic: colored arrow, value, unit
class Rate {
    constructor(arrow, color) {
        this.actor = new St.BoxLayout();
        const mark = label(arrow, 'sysmon-unit');
        mark.style = `color: ${color};`;
        this._number = new FixedLabel('sysmon-rate');
        this._unit = new FixedLabel('sysmon-rate-unit', 0.6);
        this.actor.add(mark, { y_fill: false, y_align: St.Align.MIDDLE });
        this.actor.add(this._number.actor);
        this.actor.add(this._unit.actor, { y_fill: false, y_align: St.Align.MIDDLE });
    }

    update(value) {
        this._number.text = Stats.rateNum(value);
        this._unit.text = Stats.rateUnitShort(value);
    }
}

class NetCell extends GridCell {
    constructor(layout) {
        super('NET', layout, 1);
        this._down = new Rate('↓', Stats.COLORS.highlight);
        this._up = new Rate('↑', Stats.COLORS.up);
        const rates = new St.BoxLayout({ style_class: 'sysmon-rates', vertical: layout.narrow });
        rates.add(this._down.actor);
        rates.add(this._up.actor);
        this._attach(rates, 0, 0);
        // same height as the cells with a usage bar, so the text stays aligned
        this._attach(new St.Widget({ style_class: 'sysmon-bar' }), 0, 1);
    }

    update(stats) {
        this._down.update(stats.netDown);
        this._up.update(stats.netUp);
    }
}

// one disk / folder: percent with bar, or size while a folder has no capacity yet
class DiskCell extends GridCell {
    constructor(layout) {
        super('', layout, 1);
        this._number = new FixedLabel('sysmon-percent');
        this._unit = label('%', 'sysmon-unit', 0.6);
        this._attach(valueBox(this._number, this._unit), 0, 0);
        this._bar = new UsageBar('sysmon-bar');
        this._attach(this._bar.actor, 0, 1);
    }

    update(item) {
        const hasPct = item.pct >= 0;
        this._name.text = this._narrow ? item.short.slice(0, NARROW_NAME_LENGTH) : item.short;
        this._number.text = hasPct ? Stats.num(item.pct)
            : (item.size >= 0 ? Stats.sizeShortNum(item.size) : '--');
        this._unit.text = hasPct || item.size < 0 ? '%' : Stats.sizeShortUnit(item.size);
        this._bar.set(item.pct, Stats.usageColor(item.pct));
    }
}

class PanelView {
    constructor() {
        this.actor = new St.Bin();
    }

    // rebuilt only when the panel changes side or size; the new cells enter the
    // stage at the next update(), once they have their text
    setLayout(vertical, tall) {
        const layout = { tall, narrow: vertical };
        this._layout = layout;
        this._box = new St.BoxLayout({ style_class: 'sysmon-panel', vertical });
        this._separatorClass = vertical ? 'sysmon-separator-vertical' : 'sysmon-separator';

        this._cpu = new UsageCell('CPU', layout);
        this._ram = new UsageCell('RAM', layout);
        this._gpu = new UsageCell('GPU', layout);
        this._vram = new UsageCell('VRAM', layout);
        this._net = new NetCell(layout);
        this._disks = [];

        this._add(this._cpu.actor);
        this._add(this._ram.actor);
        this._gpuSeparator = this._addSeparator();
        this._add(this._gpu.actor);
        this._add(this._vram.actor);
        this._netSeparator = this._addSeparator();
        this._add(this._net.actor);
        this._diskSeparator = this._addSeparator();
    }

    _add(actor) {
        this._box.add(actor, { x_fill: false, y_fill: false, x_align: St.Align.MIDDLE, y_align: St.Align.MIDDLE });
    }

    _addSeparator() {
        const separator = new St.Widget({ style_class: this._separatorClass });
        this._add(separator);
        return separator;
    }

    update(stats, show, cfg) {
        const systemGroup = show.panelCpu || show.panelRam;
        const gpuGroup = show.panelGpu || show.panelVram;

        this._cpu.actor.visible = show.panelCpu;
        this._cpu.update({ value: stats.cpuPct, temp: stats.cpuTemp, showTemp: show.panelCpuTemp }, cfg);
        this._ram.actor.visible = show.panelRam;
        this._ram.update({
            value: stats.ramPct,
            amount: show.panelAmounts ? Stats.gioShort(stats.memTotal > 0 ? stats.memUsed : -1) : '',
            total: Stats.gioTotal(stats.memTotal),
        }, cfg);

        this._gpuSeparator.visible = gpuGroup && systemGroup;
        this._gpu.actor.visible = show.panelGpu;
        this._gpu.update({ value: stats.gpuPct, temp: stats.gpuTemp, showTemp: show.panelGpuTemp }, cfg);
        this._vram.actor.visible = show.panelVram;
        this._vram.update({
            value: stats.vramPct,
            amount: show.panelAmounts ? Stats.gioShort(Stats.valid(stats.vramPct) ? stats.vramUsed : -1) : '',
            total: Stats.gioTotal(stats.vramTotal),
        }, cfg);

        this._netSeparator.visible = show.panelNet && (systemGroup || gpuGroup);
        this._net.actor.visible = show.panelNet;
        this._net.update(stats);

        this._diskSeparator.visible = show.panelDisk && (systemGroup || gpuGroup || show.panelNet);
        this._updateDisks(show.panelDisk ? show.panelDisks : []);

        if (this.actor.get_child() !== this._box) {
            const previous = this.actor.get_child();
            if (previous) previous.destroy();
            this.actor.set_child(this._box);
        }
    }

    _updateDisks(items) {
        while (this._disks.length > items.length) this._disks.pop().actor.destroy();
        items.forEach((item, i) => {
            if (!this._disks[i]) {
                // text set before adding: a label that was never allocated doesn't
                // queue a relayout when its text changes (same for setLayout)
                this._disks[i] = new DiskCell(this._layout);
                this._disks[i].update(item);
                this._add(this._disks[i].actor);
            } else {
                this._disks[i].update(item);
            }
        });
    }
}

module.exports = { PanelView };
