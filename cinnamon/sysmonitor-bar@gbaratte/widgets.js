// Small building blocks shared by the panel and the popup.
const Cairo = imports.cairo;
const { Clutter, Pango, St } = imports.gi;
const Tooltips = imports.ui.tooltips;

const {
    COLORS, HISTORY_LENGTH, THREAD_BLOCKS_WIDTH, num, threadBlockLayout, threadGridColumns, usageColor,
} = require('./stats.js');

function rgb(hex) {
    return [1, 3, 5].map(i => parseInt(hex.substr(i, 2), 16) / 255);
}

function hexAlpha(hex, alpha) {
    const [r, g, b] = rgb(hex).map(v => Math.round(v * 255));
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

function foreground(area) {
    const c = area.get_theme_node().get_foreground_color();
    return [c.red / 255, c.green / 255, c.blue / 255];
}

// never ellipsized by default: Clutter.GridLayout allocates the minimum width,
// which is a single character for an ellipsized St.Label
function label(text, styleClass, opacity = 1) {
    const actor = new St.Label({ text, style_class: styleClass });
    actor.clutter_text.ellipsize = Pango.EllipsizeMode.NONE;
    actor.opacity = Math.round(opacity * 255);
    return actor;
}

// right-aligned text in a minimum width (CSS), so values don't shift when they change
class FixedLabel {
    constructor(styleClass, opacity = 1) {
        this.label = label('', null, opacity);
        this.actor = new St.Bin({
            style_class: styleClass, x_align: St.Align.END, x_fill: false, child: this.label,
        });
    }

    set text(text) { this.label.text = text; }
}

// the height comes from the CSS class
class UsageBar {
    constructor(styleClass) {
        this._value = -1;
        this._color = COLORS.highlight;
        this.actor = new St.DrawingArea({ style_class: styleClass });
        this.actor.connect('repaint', area => this._paint(area));
    }

    set(value, color) {
        if (value === this._value && color === this._color) return;
        this._value = value;
        this._color = color;
        this.actor.queue_repaint();
    }

    _paint(area) {
        const cr = area.get_context();
        const [w, h] = area.get_surface_size();
        if (this._value >= 0) {
            const [r, g, b] = foreground(area);
            cr.setLineWidth(h);
            cr.setLineCap(Cairo.LineCap.ROUND);
            cr.setSourceRGBA(r, g, b, 0.15);
            cr.moveTo(h / 2, h / 2);
            cr.lineTo(w - h / 2, h / 2);
            cr.stroke();
            const f = Math.min(100, this._value) / 100;
            if (f > 0) {
                cr.setSourceRGB(...rgb(this._color));
                cr.moveTo(h / 2, h / 2);
                cr.lineTo(h / 2 + (w - h) * f, h / 2);
                cr.stroke();
            }
        }
        cr.$dispose();
    }
}

// ring gauge: 270° arc, value in the middle, caption below
class Gauge {
    constructor() {
        this._value = -1;
        this._color = COLORS.highlight;
        this.actor = new St.BoxLayout({ vertical: true, style_class: 'sysmon-gauge' });

        const dial = new St.Widget({
            style_class: 'sysmon-dial', layout_manager: new Clutter.BinLayout(),
        });
        this._ring = new St.DrawingArea({ x_expand: true, y_expand: true });
        this._ring.connect('repaint', area => this._paint(area));
        dial.add_child(this._ring);

        const center = new St.BoxLayout({
            x_align: Clutter.ActorAlign.CENTER, y_align: Clutter.ActorAlign.CENTER,
            x_expand: true, y_expand: true,
        });
        this._number = label('--', 'sysmon-big-number');
        center.add(this._number);
        center.add(label('%', 'sysmon-unit', 0.6), { y_fill: false, y_align: St.Align.END });
        dial.add_child(center);
        this.actor.add(dial, { x_fill: false, x_align: St.Align.MIDDLE });

        this._caption = label('', 'sysmon-caption', 0.6);
        this._detail = label('', 'sysmon-detail', 0.8);
        for (const line of [this._caption, this._detail]) {
            this.actor.add(line, { x_fill: false, x_align: St.Align.MIDDLE });
        }

        // one block per hardware thread, on a single surface; sized when their number changes
        this._threads = [];
        this._blocks = new St.DrawingArea();
        this._blocks.connect('repaint', area => this._paintBlocks(area));
        this._blocks.hide();
        this.actor.add(this._blocks, { x_fill: false, x_align: St.Align.MIDDLE });
    }

    // threads: % of each hardware thread, [] for none
    update({ value, color, caption, detail = '', threads = [] }) {
        this._number.text = num(value);
        this._caption.text = caption;
        this._detail.text = detail;
        this._detail.visible = detail !== '';
        this._value = value;
        this._color = color;
        this._ring.queue_repaint();
        this._updateBlocks(threads);
    }

    _updateBlocks(threads) {
        const previous = this._threads;
        this._threads = threads;
        this._blocks.visible = threads.length > 0;
        if (threads.length === 0) return;
        if (threads.length !== previous.length) {
            const { height } = threadBlockLayout(threads.length, THREAD_BLOCKS_WIDTH);
            this._blocks.style = `width: ${THREAD_BLOCKS_WIDTH}px; height: ${height}px;`;
        }
        if (threads.some((v, i) => v !== previous[i])) this._blocks.queue_repaint();
    }

    // below 1 % (or no data yet) the block is hollow: a 1 px outline of the same outer size,
    // on whole pixels so that it stays sharp
    _paintBlocks(area) {
        const cr = area.get_context();
        const [w] = area.get_surface_size();
        const scale = global.ui_scale;
        const layout = threadBlockLayout(this._threads.length, THREAD_BLOCKS_WIDTH);
        const size = Math.round(layout.size * scale), gap = Math.max(1, Math.round(layout.gap * scale));
        const step = size + gap;
        const x0 = Math.max(0, Math.round((w - (layout.cols * step - gap)) / 2));
        const [fr, fg, fb] = foreground(area);
        cr.setLineWidth(1);
        this._threads.forEach((v, i) => {
            const x = x0 + (i % layout.cols) * step, y = Math.floor(i / layout.cols) * step;
            if (v >= 1) {
                cr.setSourceRGB(...rgb(usageColor(v)));
                cr.rectangle(x, y, size, size);
                cr.fill();
            } else {
                cr.setSourceRGBA(fr, fg, fb, 0.35);
                cr.rectangle(x + 0.5, y + 0.5, size - 1, size - 1);
                cr.stroke();
            }
        });
        cr.$dispose();
    }

    _paint(area) {
        const cr = area.get_context();
        const [w, h] = area.get_surface_size();
        const lw = Math.max(4, w * 0.08);
        const radius = (Math.min(w, h) - lw) / 2;
        const start = 0.75 * Math.PI, sweep = 1.5 * Math.PI;
        const [r, g, b] = foreground(area);

        cr.setLineCap(Cairo.LineCap.ROUND);
        cr.setLineWidth(lw);
        cr.setSourceRGBA(r, g, b, 0.12);
        cr.arc(w / 2, h / 2, radius, start, start + sweep);
        cr.stroke();

        const f = Math.max(0, Math.min(100, this._value)) / 100;
        if (f > 0.005) {
            cr.setSourceRGB(...rgb(this._color));
            cr.arc(w / 2, h / 2, radius, start, start + sweep * f);
            cr.stroke();
        }
        cr.$dispose();
    }
}

// Adds the curve of a history to the path: the points are at x0 + i * step, at the height yOf(v[i]).
// Each segment is a cubic Bézier whose two control points are halfway in x, at the height of each
// end: the curve never goes beyond its neighbouring values (no dip under 0, no peak over 100 %).
// join: continue the current path instead of starting a new one. Under 2 px between two points the
// curve would bring nothing and cost thousands of segments: straight lines then.
function tracePath(cr, v, x0, step, yOf, join) {
    let px = x0, py = yOf(v[0]);
    if (join) cr.lineTo(px, py);
    else cr.moveTo(px, py);
    for (let i = 1; i < v.length; i++) {
        const x = x0 + i * step, y = yOf(v[i]);
        if (step >= 2) {
            const xm = (px + x) / 2;
            cr.curveTo(xm, py, xm, y, x, y);
        } else {
            cr.lineTo(x, y);
        }
        px = x;
        py = y;
    }
}

// area sparkline of a history (one or two series, single y-axis).
// maxValue > 0: fixed scale (percent); 0: auto-scale to the peak.
//
// onToggle(): adds a button on the legend line that swaps the curve for one mini graph per
// thread (setThreads()); both surfaces take the same room, so nothing moves.
class Sparkline {
    constructor({
        color = COLORS.highlight, color2 = COLORS.up, maxValue = 100, minScale = 1, onToggle = null,
    } = {}) {
        this._series = [[], []];
        this._colors = [color, color2];
        this._maxValue = maxValue;
        this._minScale = minScale;
        this._threads = [];
        this._threadMode = false;

        this.actor = new St.BoxLayout({ vertical: true, style_class: 'sysmon-sparkline' });
        const legend = new St.BoxLayout();
        this._caption = label('', 'sysmon-caption', 0.6);
        legend.add(this._caption, { expand: true, y_fill: false, y_align: St.Align.MIDDLE });
        if (onToggle) {
            this._toggle = new St.Button({ style_class: 'sysmon-icon-button sysmon-caption', label: '▦' });
            this._toggleTooltip = new Tooltips.Tooltip(this._toggle, '');
            this._toggle.connect('clicked', () => onToggle());
            this._toggle.hide();
            legend.add(this._toggle, { y_fill: false, y_align: St.Align.MIDDLE });
        }
        this.actor.add(legend, { x_fill: true });
        this._area = new St.DrawingArea({ style_class: 'sysmon-sparkline-area' });
        this._area.connect('repaint', area => this._paint(area));
        this.actor.add(this._area, { expand: true, x_fill: true, y_fill: true });
        this._grid = new St.DrawingArea({ style_class: 'sysmon-sparkline-area' });
        this._grid.connect('repaint', area => this._paintThreads(area));
        this._grid.hide();
        this.actor.add(this._grid, { expand: true, x_fill: true, y_fill: true });
    }

    get chartMax() {
        if (this._maxValue > 0) return this._maxValue;
        return Math.max(this._minScale, ...this._series[0], ...this._series[1]) * 1.1;
    }

    update(values, values2 = []) {
        this._series = [values, values2];
        if (!this._threadMode) this._area.queue_repaint();
    }

    // histories: one per thread (percent, oldest first); active: show them instead of the curve.
    // A hidden surface is not redrawn.
    setThreads(histories, active) {
        this._threads = histories;
        this._threadMode = active && histories.length > 0;
        this._area.visible = !this._threadMode;
        this._grid.visible = this._threadMode;
        if (this._toggle) {
            this._toggle.visible = histories.length > 0;
            this._toggle.change_style_pseudo_class('checked', this._threadMode);
            this._toggleTooltip.set_text(this._threadMode ? 'Afficher le total' : 'Afficher chaque thread');
        }
        if (this._threadMode) this._grid.queue_repaint();
        else this._area.queue_repaint();
    }

    set caption(text) { this._caption.text = text; }

    _paint(area) {
        const cr = area.get_context();
        const [w, h] = area.get_surface_size();
        const pad = 1;
        const [r, g, b] = foreground(area);

        // recessive gridlines at 0 / 50 / 100 % of the scale
        cr.setSourceRGBA(r, g, b, 0.10);
        cr.setLineWidth(1);
        for (let i = 0; i <= 2; i++) {
            const y = Math.round(pad + (h - 2 * pad) * i / 2) + 0.5;
            cr.moveTo(0, y);
            cr.lineTo(w, y);
            cr.stroke();
        }
        this._series.forEach((v, i) => this._drawSeries(cr, v, this._colors[i], w, h, pad));
        cr.$dispose();
    }

    // all the threads on one surface: fixed 0-100 % scale, the color of each curve follows the
    // last value of its thread
    _paintThreads(area) {
        const cr = area.get_context();
        const [w, h] = area.get_surface_size();
        const hs = this._threads, n = hs.length;
        if (n === 0) {
            cr.$dispose();
            return;
        }
        const gap = Math.max(1, Math.round(2 * global.ui_scale));
        const cols = threadGridColumns(n, w, h, gap);
        const rows = Math.ceil(n / cols);
        const cw = (w - (cols - 1) * gap) / cols, ch = (h - (rows - 1) * gap) / rows;
        const [fr, fg, fb] = foreground(area);
        const pad = 1;
        hs.forEach((v, i) => {
            // pixel-aligned cell
            const c = i % cols, r = Math.floor(i / cols);
            const x = Math.round(c * (cw + gap)), y = Math.round(r * (ch + gap));
            const cellW = Math.round(c * (cw + gap) + cw) - x, cellH = Math.round(r * (ch + gap) + ch) - y;
            cr.setSourceRGBA(fr, fg, fb, 0.06);
            cr.moveTo(x, y);
            cr.lineTo(x + cellW, y);
            cr.lineTo(x + cellW, y + cellH);
            cr.lineTo(x, y + cellH);
            cr.closePath();
            cr.fill();
            if (v.length < 2) return;

            const last = v[v.length - 1];
            const [r2, g2, b2] = last >= 0 ? rgb(usageColor(last)) : [fr, fg, fb];
            const step = cellW / (HISTORY_LENGTH - 1);
            const x0 = x + cellW - (v.length - 1) * step;
            const yOf = p => y + pad + (cellH - 2 * pad) * (1 - Math.max(0, Math.min(100, p)) / 100);

            cr.moveTo(x0, y + cellH);
            tracePath(cr, v, x0, step, yOf, true);
            cr.lineTo(x + cellW, y + cellH);
            cr.closePath();
            cr.setSourceRGBA(r2, g2, b2, 0.25);
            cr.fill();

            tracePath(cr, v, x0, step, yOf, false);
            cr.setLineWidth(1);
            cr.setLineJoin(Cairo.LineJoin.ROUND);
            cr.setSourceRGB(r2, g2, b2);
            cr.stroke();
        });
        cr.$dispose();
    }

    _drawSeries(cr, v, color, w, h, pad) {
        if (v.length < 2) return;
        const [r, g, b] = rgb(color);
        const step = w / (HISTORY_LENGTH - 1);
        const x0 = w - (v.length - 1) * step;
        const max = this.chartMax;
        const yOf = p => pad + (h - 2 * pad) * (1 - Math.max(0, Math.min(max, p)) / max);

        cr.moveTo(x0, h);
        tracePath(cr, v, x0, step, yOf, true);
        cr.lineTo(w, h);
        cr.closePath();
        const gradient = new Cairo.LinearGradient(0, 0, 0, h);
        gradient.addColorStopRGBA(0, r, g, b, 0.30);
        gradient.addColorStopRGBA(1, r, g, b, 0.02);
        cr.setSource(gradient);
        cr.fill();

        tracePath(cr, v, x0, step, yOf, false);
        cr.setLineWidth(2 * global.ui_scale);
        cr.setLineJoin(Cairo.LineJoin.ROUND);
        cr.setSourceRGB(r, g, b);
        cr.stroke();
    }
}

module.exports = { FixedLabel, Gauge, Sparkline, UsageBar, hexAlpha, label };
