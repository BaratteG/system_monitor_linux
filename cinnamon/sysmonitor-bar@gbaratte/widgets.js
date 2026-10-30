// Small building blocks shared by the panel and the popup.
const Cairo = imports.cairo;
const { Clutter, Pango, St } = imports.gi;

const { COLORS, HISTORY_LENGTH, num } = require('./stats.js');

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
        this._detail2 = label('', 'sysmon-detail', 0.8);
        for (const line of [this._caption, this._detail, this._detail2]) {
            this.actor.add(line, { x_fill: false, x_align: St.Align.MIDDLE });
        }
    }

    update({ value, color, caption, detail = '', detail2 = '' }) {
        this._number.text = num(value);
        this._caption.text = caption;
        this._detail.text = detail;
        this._detail.visible = detail !== '';
        this._detail2.text = detail2;
        this._detail2.visible = detail2 !== '';
        this._value = value;
        this._color = color;
        this._ring.queue_repaint();
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

// area sparkline of a history (one or two series, single y-axis).
// maxValue > 0: fixed scale (percent); 0: auto-scale to the peak.
class Sparkline {
    constructor({ color = COLORS.highlight, color2 = COLORS.up, maxValue = 100, minScale = 1 } = {}) {
        this._series = [[], []];
        this._colors = [color, color2];
        this._maxValue = maxValue;
        this._minScale = minScale;

        this.actor = new St.BoxLayout({ vertical: true, style_class: 'sysmon-sparkline' });
        this._caption = label('', 'sysmon-caption', 0.6);
        this.actor.add(this._caption);
        this._area = new St.DrawingArea({ style_class: 'sysmon-sparkline-area' });
        this._area.connect('repaint', area => this._paint(area));
        this.actor.add(this._area, { expand: true, x_fill: true, y_fill: true });
    }

    get chartMax() {
        if (this._maxValue > 0) return this._maxValue;
        return Math.max(this._minScale, ...this._series[0], ...this._series[1]) * 1.1;
    }

    update(values, values2 = []) {
        this._series = [values, values2];
        this._area.queue_repaint();
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

    _drawSeries(cr, v, color, w, h, pad) {
        if (v.length < 2) return;
        const [r, g, b] = rgb(color);
        const step = w / (HISTORY_LENGTH - 1);
        const x0 = w - (v.length - 1) * step;
        const max = this.chartMax;
        const yOf = p => pad + (h - 2 * pad) * (1 - Math.max(0, Math.min(max, p)) / max);

        cr.moveTo(x0, h);
        v.forEach((p, i) => cr.lineTo(x0 + i * step, yOf(p)));
        cr.lineTo(w, h);
        cr.closePath();
        const gradient = new Cairo.LinearGradient(0, 0, 0, h);
        gradient.addColorStopRGBA(0, r, g, b, 0.30);
        gradient.addColorStopRGBA(1, r, g, b, 0.02);
        cr.setSource(gradient);
        cr.fill();

        v.forEach((p, i) => {
            if (i === 0) cr.moveTo(x0, yOf(p));
            else cr.lineTo(x0 + i * step, yOf(p));
        });
        cr.setLineWidth(2 * global.ui_scale);
        cr.setLineJoin(Cairo.LineJoin.ROUND);
        cr.setSourceRGB(r, g, b);
        cr.stroke();
    }
}

module.exports = { FixedLabel, Gauge, Sparkline, UsageBar, hexAlpha, label };
