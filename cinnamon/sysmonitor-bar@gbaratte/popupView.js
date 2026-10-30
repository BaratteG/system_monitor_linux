// Popup content: Processeur, Carte graphique, Réseau and Stockage cards.
const { Pango, St } = imports.gi;
const Tooltips = imports.ui.tooltips;

const Stats = require('./stats.js');
const { FixedLabel, Gauge, Sparkline, UsageBar, hexAlpha, label } = require('./widgets.js');

const FILL = { expand: true, x_fill: true, y_fill: true };

function header(title) {
    const box = new St.BoxLayout({ style_class: 'sysmon-card-header' });
    box.add(label(title, 'sysmon-title'), { y_fill: false, y_align: St.Align.MIDDLE });
    return box;
}

function subtitleLabel() {
    const actor = label('', 'sysmon-unit', 0.6);
    actor.clutter_text.ellipsize = Pango.EllipsizeMode.END;
    return actor;
}

// title, subtitle, temperature pill, two gauges and the usage history
class Card {
    constructor(title) {
        this.actor = new St.BoxLayout({ vertical: true, style_class: 'sysmon-card' });

        const head = header(title);
        this._subtitle = subtitleLabel();
        head.add(this._subtitle, { expand: true, x_fill: true, y_fill: false, y_align: St.Align.MIDDLE });
        this._pill = new St.BoxLayout({ style_class: 'sysmon-pill' });
        this._dot = new St.Widget({ style_class: 'sysmon-dot' });
        this._temp = label('', 'sysmon-title');
        this._pill.add(this._dot, { y_fill: false, y_align: St.Align.MIDDLE });
        this._pill.add(this._temp, { y_fill: false, y_align: St.Align.MIDDLE });
        head.add(this._pill, { y_fill: false, y_align: St.Align.MIDDLE });
        this.actor.add(head, { x_fill: true });

        const body = new St.BoxLayout({ style_class: 'sysmon-card-body' });
        this._a = new Gauge();
        this._b = new Gauge();
        this._history = new Sparkline();
        body.add(this._a.actor);
        body.add(this._b.actor);
        body.add(this._history.actor, FILL);
        this.actor.add(body, { x_fill: true });
    }

    update({ subtitle, showTemp, temp, a, b, history, caption }, cfg) {
        this._subtitle.text = subtitle;
        this._pill.visible = showTemp;
        const dot = Stats.valid(temp) ? Stats.tempDotColor(temp, cfg) : 'rgba(128, 128, 128, 0.5)';
        this._dot.style = `background-color: ${dot};`;
        this._pill.style = temp >= cfg.warningTemp ? `background-color: ${hexAlpha(dot, 0.18)};` : '';
        this._temp.text = Stats.tempText(temp);

        this._a.actor.visible = a.visible;
        this._a.update(a);
        this._b.actor.visible = b.visible;
        this._b.update(b);
        this._history.update(history);
        this._history.caption = caption;
    }
}

// network: legend + current rate for one direction
class RateStat {
    constructor(caption, color) {
        this.actor = new St.BoxLayout({ vertical: true });
        const legend = new St.BoxLayout({ style_class: 'sysmon-legend' });
        const mark = new St.Widget({ style_class: 'sysmon-mark', style: `background-color: ${color};` });
        legend.add(mark, { y_fill: false, y_align: St.Align.MIDDLE });
        legend.add(label(caption, 'sysmon-caption', 0.6));
        this.actor.add(legend);

        const value = new St.BoxLayout({ style_class: 'sysmon-legend' });
        this._number = label('--', 'sysmon-big-number');
        this._unit = label('', 'sysmon-unit', 0.6);
        value.add(this._number);
        value.add(this._unit, { y_fill: false, y_align: St.Align.END });
        this.actor.add(value);
    }

    update(bps) {
        this._number.text = Stats.rateNum(bps);
        this._unit.text = Stats.rateUnit(bps);
    }
}

class NetCard {
    constructor() {
        this.actor = new St.BoxLayout({ vertical: true, style_class: 'sysmon-card' });

        const head = header('Réseau');
        this._ifName = subtitleLabel();
        this._totals = subtitleLabel();
        head.add(this._ifName, { expand: true, x_fill: true, y_fill: false, y_align: St.Align.MIDDLE });
        head.add(this._totals, { y_fill: false, y_align: St.Align.MIDDLE });
        this.actor.add(head, { x_fill: true });

        const body = new St.BoxLayout({ style_class: 'sysmon-card-body' });
        const rates = new St.BoxLayout({ vertical: true, style_class: 'sysmon-rate-stats' });
        this._down = new RateStat('RÉCEPTION', Stats.COLORS.highlight);
        this._up = new RateStat('ENVOI', Stats.COLORS.up);
        rates.add(this._down.actor);
        rates.add(this._up.actor);
        body.add(rates);
        // 10 Ko/s minimum, so idle noise stays flat
        this._history = new Sparkline({ maxValue: 0, minScale: 10000 });
        body.add(this._history.actor, FILL);
        this.actor.add(body, { x_fill: true });
    }

    update(stats, span) {
        this._ifName.text = stats.netIf || 'aucune interface';
        this._totals.text = 'depuis le démarrage  ↓ ' + Stats.bytesText(stats.netRxTotal)
            + '  ↑ ' + Stats.bytesText(stats.netTxTotal);
        this._down.update(stats.netDown);
        this._up.update(stats.netUp);
        this._history.update(stats.downHistory, stats.upHistory);
        this._history.caption = 'Débit · ' + span + (stats.downHistory.length >= 2
            ? ' · échelle ' + Stats.rateText(this._history.chartMax) : '');
    }
}

// one row per tracked filesystem or folder
class DiskRow {
    constructor() {
        this.actor = new St.BoxLayout({ style_class: 'sysmon-disk-row', reactive: true, track_hover: true });
        this._name = label('', 'sysmon-disk-name');
        this._name.clutter_text.ellipsize = Pango.EllipsizeMode.MIDDLE;
        this._bar = new UsageBar('sysmon-bar-large');
        this._amountBox = new St.BoxLayout();
        this._used = label('', null);
        this._total = label('', 'sysmon-unit', 0.6);
        this._amountBox.add(this._used);
        this._amountBox.add(this._total, { y_fill: false, y_align: St.Align.END });
        this._amount = new St.Bin({
            style_class: 'sysmon-disk-amount', x_align: St.Align.END, x_fill: false, child: this._amountBox,
        });
        this._pct = new FixedLabel('sysmon-disk-percent');
        this._pct.label.style_class = 'sysmon-title';
        this._tooltip = new Tooltips.Tooltip(this.actor, '');

        this.actor.add(this._name, { y_fill: false, y_align: St.Align.MIDDLE });
        this.actor.add(this._bar.actor, { expand: true, x_fill: true, y_fill: false, y_align: St.Align.MIDDLE });
        this.actor.add(this._amount);
        this.actor.add(this._pct.actor);
    }

    update(item) {
        const hasPct = item.pct >= 0;
        this._name.text = item.label;
        // a folder without capacity yet (df failed): no track, just the size
        this._bar.set(hasPct ? item.pct : -1, Stats.usageColor(item.pct));

        if (item.state === 'ok') {
            this._used.text = Stats.sizeNum(item.size, item.total > 0 ? item.total : item.size);
        } else {
            this._used.text = item.state === 'pending' ? 'calcul…' : 'indisponible';
        }
        this._used.opacity = item.state === 'ok' ? 255 : 153;
        if (item.state !== 'ok') this._total.text = '';
        else if (item.total > 0) this._total.text = ' / ' + Stats.sizeText(item.total);
        else this._total.text = ' ' + (Stats.diskUnitTio(item.size) ? 'Tio' : 'Gio');

        this._pct.text = hasPct ? Math.round(item.pct) + ' %' : '';
        this._tooltip.set_text(item.label + this._basis(item));
    }

    _basis(item) {
        if (item.kind !== 'folder') return '';
        if (item.base === 'quota') return ' (taille du dossier / quota)';
        if (item.base === 'disk') return ' (taille du dossier / taille du disque)';
        return ' (taille du dossier)';
    }
}

class DiskCard {
    constructor() {
        this.actor = new St.BoxLayout({ vertical: true, style_class: 'sysmon-card' });
        const head = header('Stockage');
        this._subtitle = subtitleLabel();
        head.add(this._subtitle, { expand: true, x_fill: true, y_fill: false, y_align: St.Align.MIDDLE });
        this.actor.add(head, { x_fill: true });
        this._rows = [];
    }

    update(items) {
        const n = items.length;
        this._subtitle.text = n + (n > 1 ? ' éléments suivis' : ' élément suivi');
        while (this._rows.length > n) this._rows.pop().actor.destroy();
        items.forEach((item, i) => {
            if (!this._rows[i]) {
                this._rows[i] = new DiskRow();
                this._rows[i].update(item);
                this.actor.add(this._rows[i].actor, { x_fill: true });
            } else {
                this._rows[i].update(item);
            }
        });
    }
}

class PopupView {
    constructor() {
        this.actor = new St.BoxLayout({ vertical: true, style_class: 'sysmon-popup' });
        this._cpu = new Card('Processeur');
        this._gpu = new Card('Carte graphique');
        this._net = new NetCard();
        this._disk = new DiskCard();
        for (const card of [this._cpu, this._gpu, this._net, this._disk]) {
            this.actor.add(card.actor, { x_fill: true });
        }
    }

    update(stats, show, cfg) {
        const span = Stats.historySpan(cfg.updateInterval);
        const usage = v => Stats.usageColor(v);

        this._cpu.actor.visible = show.popupCpu || show.popupRam;
        this._cpu.update({
            subtitle: stats.cpuName,
            showTemp: show.popupCpuTemp,
            temp: stats.cpuTemp,
            a: {
                visible: show.popupCpu, caption: 'CPU', value: stats.cpuPct, color: usage(stats.cpuPct),
                detail: show.popupFreq ? Stats.freqDetail(stats.cpuFreq, cfg) : ' ',
                detail2: show.popupThreads ? stats.threadsText() : '',
            },
            b: {
                visible: show.popupRam, caption: 'RAM', value: stats.ramPct, color: usage(stats.ramPct),
                detail: stats.ramDetail(),
            },
            history: stats.cpuHistory,
            caption: 'CPU · ' + span,
        }, cfg);

        this._gpu.actor.visible = show.popupGpu || show.popupVram;
        this._gpu.update({
            subtitle: stats.gpuName,
            showTemp: show.popupGpuTemp,
            temp: stats.gpuTemp,
            a: {
                visible: show.popupGpu, caption: 'GPU', value: stats.gpuPct, color: usage(stats.gpuPct),
                detail: show.popupFreq ? Stats.freqDetail(stats.gpuFreq, cfg) : ' ',
            },
            b: {
                visible: show.popupVram, caption: 'VRAM', value: stats.vramPct, color: usage(stats.vramPct),
                detail: stats.vramDetail(),
            },
            history: stats.gpuHistory,
            caption: 'GPU · ' + span,
        }, cfg);

        this._net.actor.visible = show.popupNet;
        this._net.update(stats, span);

        this._disk.actor.visible = show.popupDisk;
        this._disk.update(show.popupDisks);
    }
}

module.exports = { PopupView };
