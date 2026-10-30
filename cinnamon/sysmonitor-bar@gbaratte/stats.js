// Parsing of the sysstats.sh output and value formatting. No St or Clutter here:
// the views only read this state. Same logic as the data section of the KDE
// widget (package/contents/ui/main.qml).

const HISTORY_LENGTH = 60;

// consecutive samples without data; a source is declared missing after a few
// misses so that one slow nvidia-smi call doesn't make a group blink
const MISS_LIMIT = 3;

// Breeze palette, so the colors don't depend on the Cinnamon theme
const COLORS = {
    negative: '#da4453',
    neutral: '#f67400',
    positive: '#27ae60',
    highlight: '#3daee9',
    up: '#d2608c',
};

function valid(v) { return v >= 0 && !isNaN(v); }
function num(v) { return valid(v) ? Math.round(v).toString() : '--'; }

// compact form: one decimal below 100 Gio, integer above (fixed width)
function gioShort(mib) {
    if (!valid(mib)) return '--';
    const v = mib / 1024;
    return v < 99.95 ? v.toFixed(1) : Math.round(v).toString();
}

// capacity: integer from 10 Gio (60, 32), one decimal below (2.0)
function gioTotal(mib) {
    if (!(mib > 0)) return '--';
    const v = mib / 1024;
    return v >= 10 ? Math.round(v).toString() : v.toFixed(1);
}

function gio(mib) { return (mib / 1024).toFixed(1); }

// "AMD Ryzen 9 9950X3D 16-Core Processor" -> "AMD Ryzen 9 9950X3D"
// "Intel(R) Core(TM) i7-9700K CPU @ 3.60GHz" -> "Intel Core i7-9700K"
function cleanCpuName(name) {
    return name.replace(/\((R|TM)\)/gi, '')
        .replace(/\s+@\s+.*$/, '')
        .replace(/\s+w\/\s.*$/i, '')
        .replace(/\s+\d+-Cores?( Processor)?$/i, '')
        .replace(/\s+(CPU|Processor)$/i, '')
        .replace(/\s+/g, ' ').trim();
}

// disk sizes: used and total share the unit of the total, so the two numbers
// compare at a glance (Gio below 1024 Gio, Tio from there)
function diskUnitTio(totalMib) { return totalMib >= 1024 * 1024; }

function sizeNum(mib, totalMib) {
    const g = mib / 1024;
    // two decimals below 10 Tio, so "0.35 / 1.30" keeps Gio-level detail
    if (diskUnitTio(totalMib)) return (g / 1024).toFixed(totalMib < 10 * 1024 * 1024 ? 2 : 1);
    return g < 99.95 ? g.toFixed(1) : Math.round(g).toString();
}

function sizeText(mib) { return sizeNum(mib, mib) + (diskUnitTio(mib) ? ' Tio' : ' Gio'); }

// panel size: "42.0G" below 1024 Gio, "1.3T" from there
function sizeShortNum(mib) {
    const g = mib / 1024;
    if (diskUnitTio(mib)) return (g / 1024).toFixed(1);
    return g < 99.95 ? g.toFixed(1) : Math.round(g).toString();
}

function sizeShortUnit(mib) { return diskUnitTio(mib) ? 'T' : 'G'; }
function sizeShort(mib) { return sizeShortNum(mib) + sizeShortUnit(mib); }

// network rates: decimal units, Ko/s minimum, 3 significant chars
function rateParts(bps) {
    const units = ['Ko/s', 'Mo/s', 'Go/s', 'To/s'];
    if (!valid(bps)) return ['--', units[0]];
    let v = bps / 1000, i = 0;
    while (v >= 999.5 && i < 3) { v /= 1000; i++; }
    return [v < 9.95 ? v.toFixed(1) : Math.round(v).toString(), units[i]];
}

function rateNum(bps) { return rateParts(bps)[0]; }
function rateUnit(bps) { return rateParts(bps)[1]; }
// panel form: the arrows already say "per second"
function rateUnitShort(bps) { return rateUnit(bps).charAt(0); }
function rateText(bps) { return rateNum(bps) + ' ' + rateUnit(bps); }

function bytesText(b) {
    if (!valid(b)) return '--';
    const units = ['o', 'Ko', 'Mo', 'Go', 'To'];
    let i = 0;
    while (b >= 1000 && i < 4) { b /= 1000; i++; }
    return (b < 9.95 ? b.toFixed(1) : Math.round(b)) + ' ' + units[i];
}

function ghz(mhz) { return valid(mhz) ? (mhz / 1000).toFixed(2) + ' GHz' : '-- GHz'; }
function tempText(v) { return valid(v) ? Math.round(v) + ' °C' : '-- °C'; }

// temperatures are states -> status colors; null keeps the theme text color
function tempColor(v, cfg) {
    if (v >= cfg.criticalTemp) return COLORS.negative;
    if (v >= cfg.warningTemp) return COLORS.neutral;
    return null;
}

function tempDotColor(v, cfg) {
    return tempColor(v, cfg) || COLORS.positive;
}

// usage bars and gauges: blue < 25 %, green < 50 %, orange < 80 %, red from 80 %
function usageColor(v) {
    if (v >= 80) return COLORS.negative;
    if (v >= 50) return COLORS.neutral;
    if (v >= 25) return COLORS.positive;
    return COLORS.highlight;
}

function historySpan(updateInterval) {
    const s = Math.round(HISTORY_LENGTH * updateInterval / 1000);
    return s >= 60 ? Math.round(s / 60) + ' min' : s + ' s';
}

function pushHistory(list, v) {
    const a = list.slice(Math.max(0, list.length - HISTORY_LENGTH + 1));
    a.push(v);
    return a;
}

function shortName(path) {
    if (path === '/') return '/';
    const p = path.replace(/\/+$/, '');
    return p.substring(p.lastIndexOf('/') + 1) || p;
}

// the file chooser of the settings dialog stores a file:// URI
function localPath(path) {
    return path.startsWith('file://') ? decodeURIComponent(path.slice(7)) : path;
}

class SysStats {
    constructor() {
        this.cpuPct = -1;
        this.cpuTemp = -1;
        this.cpuFreq = -1;      // MHz, average over all threads
        this.gpuFreq = -1;      // MHz, graphics clock
        this.gpuPct = -1;
        this.gpuTemp = -1;
        this.memTotal = 0;      // MiB
        this.memUsed = 0;       // MiB
        this.vramTotal = -1;    // MiB
        this.vramUsed = -1;     // MiB
        this.gpuName = '';
        this.cpuName = '';
        this.threadsBusy = -1;  // busy hardware threads, -1 until two samples
        this.threadsTotal = 0;
        this.disks = [];        // [{ mount, used, total, pct }], sizes in MiB
        this.trackedData = [];  // per tracked entry: { a, b, age } from the script (KiB)
        this.home = '';
        this.netDown = -1;      // bytes/s
        this.netUp = -1;        // bytes/s
        this.netRxTotal = -1;   // bytes since boot
        this.netTxTotal = -1;
        this.netIf = '';

        this.gpuMisses = 0;
        this.vramMisses = 0;
        this.netMisses = 0;
        this.cpuTempMisses = 0;
        this.gpuTempMisses = 0;

        // usage history for the popup sparklines (oldest first)
        this.cpuHistory = [];
        this.gpuHistory = [];
        this.downHistory = [];
        this.upHistory = [];

        this._prevTotal = -1;
        this._prevIdle = -1;
        this._prevThreads = [];
        this._prevRx = -1;
        this._prevTx = -1;
        this._prevNetTime = 0;
    }

    get ramPct() { return this.memTotal > 0 ? 100 * this.memUsed / this.memTotal : -1; }

    get vramPct() {
        return this.vramTotal > 0 && this.vramUsed >= 0 ? 100 * this.vramUsed / this.vramTotal : -1;
    }

    ramDetail() {
        return this.memTotal > 0 ? gio(this.memUsed) + ' / ' + gio(this.memTotal) + ' Gio' : '--';
    }

    vramDetail() {
        return valid(this.vramPct) ? gio(this.vramUsed) + ' / ' + gio(this.vramTotal) + ' Gio' : '--';
    }

    threadsText() {
        return (this.threadsBusy >= 0 ? this.threadsBusy : '--') + '/' + this.threadsTotal + ' threads';
    }

    // out: the key=value;key=value line printed by sysstats.sh
    update(out, now = Date.now()) {
        const d = {};
        for (const part of out.trim().split(';')) {
            const k = part.indexOf('=');
            if (k > 0) d[part.substring(0, k)] = part.substring(k + 1);
        }
        if (d.cpuTotal === undefined) return;

        this._updateCpu(d);
        this.memTotal = parseFloat(d.memTotal);
        this.memUsed = this.memTotal - parseFloat(d.memAvail);
        this.gpuPct = parseFloat(d.gpuUse);
        this.gpuTemp = parseFloat(d.gpuTemp);
        this.gpuFreq = d.gpuFreq !== undefined ? parseFloat(d.gpuFreq) : -1;
        this.vramUsed = parseFloat(d.vramUsed);
        this.vramTotal = parseFloat(d.vramTotal);
        this.gpuName = d.gpuName || '';
        this._updateStorage(d);
        this.home = d.home || '';

        this.gpuMisses = d.gpuKind ? 0 : this.gpuMisses + 1;
        this.vramMisses = this.vramTotal > 0 ? 0 : this.vramMisses + 1;
        this.cpuTempMisses = valid(this.cpuTemp) ? 0 : this.cpuTempMisses + 1;
        this.gpuTempMisses = valid(this.gpuTemp) ? 0 : this.gpuTempMisses + 1;
        if (this.cpuPct >= 0) this.cpuHistory = pushHistory(this.cpuHistory, this.cpuPct);
        if (this.gpuPct >= 0) this.gpuHistory = pushHistory(this.gpuHistory, this.gpuPct);

        this._updateNetwork(d, now);
    }

    _updateCpu(d) {
        const tot = parseFloat(d.cpuTotal), idl = parseFloat(d.cpuIdle);
        if (this._prevTotal >= 0 && tot > this._prevTotal) {
            const busy = 1 - (idl - this._prevIdle) / (tot - this._prevTotal);
            this.cpuPct = Math.max(0, Math.min(100, 100 * busy));
        }
        this._prevTotal = tot;
        this._prevIdle = idl;

        // hardware threads above 50 % over the last interval
        const cur = [];
        let busyThreads = 0;
        for (const thread of (d.cpuThreads || '').split('|')) {
            const [tt, ti] = thread.split(',').map(parseFloat);
            if (isNaN(tt) || isNaN(ti)) continue;
            cur.push([tt, ti]);
            const pv = this._prevThreads[cur.length - 1];
            if (pv && tt > pv[0] && 1 - (ti - pv[1]) / (tt - pv[0]) > 0.5) busyThreads++;
        }
        this.threadsBusy = this._prevThreads.length === cur.length ? busyThreads : -1;
        this.threadsTotal = cur.length;
        this._prevThreads = cur;

        this.cpuTemp = parseFloat(d.cpuTemp);
        this.cpuFreq = d.cpuFreq !== undefined ? parseFloat(d.cpuFreq) : -1;
        this.cpuName = cleanCpuName(d.cpuName || '');
    }

    _updateStorage(d) {
        const disks = [];
        for (const entry of (d.disks || '').split('|')) {
            const f = entry.split(':');
            if (f.length < 3) continue;
            const used = parseFloat(f[1]) / 1024, total = used + parseFloat(f[2]) / 1024;
            if (total > 0) disks.push({ mount: f[0], used, total, pct: 100 * used / total });
        }
        this.disks = disks;

        const tracked = [];
        for (const row of (d.custom || '').split('|')) {
            const g = row.split(':');
            if (g.length >= 4) {
                tracked[parseInt(g[0])] = { a: parseFloat(g[1]), b: parseFloat(g[2]), age: parseFloat(g[3]) };
            }
        }
        this.trackedData = tracked;
    }

    _updateNetwork(d, now) {
        this.netIf = d.netIf || '';
        const up = this.netIf !== '';
        const rx = parseFloat(d.netRx), tx = parseFloat(d.netTx);
        if (!up) {
            this.netDown = this.netUp = -1;
        } else if (this._prevRx >= 0 && rx >= this._prevRx && tx >= this._prevTx && now > this._prevNetTime) {
            const dt = (now - this._prevNetTime) / 1000;
            this.netDown = (rx - this._prevRx) / dt;
            this.netUp = (tx - this._prevTx) / dt;
            this.downHistory = pushHistory(this.downHistory, this.netDown);
            this.upHistory = pushHistory(this.upHistory, this.netUp);
        }
        this.netMisses = up ? 0 : this.netMisses + 1;
        this.netRxTotal = up ? rx : -1;
        this.netTxTotal = up ? tx : -1;
        this._prevRx = up ? rx : -1;
        this._prevTx = tx;
        this._prevNetTime = now;
    }
}

function trackedEntries(cfg) {
    return cfg.customPaths.filter(e => e && e.path)
        .map(e => Object.assign({}, e, { path: localPath(e.path) }));
}

// argv of the data script; an array, so paths never go through a shell
function scriptArgs(cfg) {
    const spec = trackedEntries(cfg).map(t => {
        return (t.kind === 'mount' ? 'm|' : 'f|') + t.path.replace(/[\r\n]/g, '');
    }).join('\n');
    return [cfg.gpuSource, cfg.netInterface, spec, String(Math.max(60, cfg.folderRefresh * 60))];
}

// one list for both views: { label, short, kind, used, total, size, pct, state, panel, popup }
// sizes in MiB; pct -1 when there is no capacity (folder not measured yet);
// base (folders): "quota" or "disk", what total and pct refer to;
// state: "ok", "pending" (first measure running) or "error"
function storageItems(stats, cfg) {
    const prefs = {};
    for (const p of cfg.diskPrefs) prefs[p.mount] = p;

    const items = stats.disks.map(dk => {
        const pref = prefs[dk.mount];
        return {
            label: dk.mount, short: shortName(dk.mount), kind: 'mount', state: 'ok',
            used: dk.used, total: dk.total, size: dk.used, pct: dk.pct,
            panel: pref ? !!pref.panel : dk.mount === '/',
            popup: pref ? pref.popup !== false : true,
        };
    });

    trackedEntries(cfg).forEach((t, i) => {
        const r = stats.trackedData[i] || { a: -1, b: -1 };
        const home = stats.home;
        const it = {
            label: home && t.path.indexOf(home) === 0 ? '~' + t.path.substring(home.length) : t.path,
            short: shortName(t.path), kind: t.kind === 'mount' ? 'mount' : 'folder',
            state: r.a === -1 ? 'pending' : (r.a < 0 ? 'error' : 'ok'),
            used: -1, total: -1, size: -1, pct: -1, base: '',
            panel: !!t.panel, popup: t.popup !== false,
        };
        if (it.state === 'ok' && it.kind === 'mount') {
            it.used = r.a / 1024;
            it.total = (r.a + r.b) / 1024;
            it.size = it.used;
            it.pct = it.total > 0 ? 100 * it.used / it.total : -1;
        } else if (it.state === 'ok') {
            it.size = r.a / 1024;
            // share of the quota if set, else of the disk that holds the folder
            if (t.quota > 0) {
                it.total = t.quota * 1024;
                it.base = 'quota';
            } else if (r.b > 0) {
                it.total = r.b / 1024;
                it.base = 'disk';
            }
            if (it.total > 0) it.pct = 100 * it.size / it.total;
        }
        items.push(it);
    });
    return items;
}

// what is actually displayed: choice of the settings AND data available
function displayed(stats, cfg, storage) {
    const avail = misses => !cfg.autoHide || misses < MISS_LIMIT;
    const gpu = avail(stats.gpuMisses);
    const vram = gpu && avail(stats.vramMisses);
    const net = avail(stats.netMisses);
    const cpuTemp = avail(stats.cpuTempMisses);
    const gpuTemp = avail(stats.gpuTempMisses);
    const panelDisks = storage.filter(d => d.panel);
    const popupDisks = storage.filter(d => d.popup);
    return {
        panelDisks,
        popupDisks,
        panelCpu: cfg.cpuPanel,
        panelRam: cfg.ramPanel,
        panelGpu: cfg.gpuPanel && gpu,
        panelVram: cfg.vramPanel && vram,
        panelCpuTemp: cfg.tempPanel && cpuTemp,
        panelGpuTemp: cfg.tempPanel && gpuTemp,
        panelAmounts: cfg.amountsPanel,
        panelDisk: cfg.diskPanel && panelDisks.length > 0,
        panelNet: cfg.netPanel && net,
        popupCpu: cfg.cpuPopup,
        popupRam: cfg.ramPopup,
        popupGpu: cfg.gpuPopup && gpu,
        popupVram: cfg.vramPopup && vram,
        popupCpuTemp: cfg.tempPopup && cpuTemp,
        popupGpuTemp: cfg.tempPopup && gpuTemp,
        popupFreq: cfg.freqPopup,
        popupThreads: cfg.threadsPopup && stats.threadsTotal > 0,
        popupDisk: cfg.diskPopup && popupDisks.length > 0,
        popupNet: cfg.netPopup && net,
    };
}

function freqDetail(mhz, cfg) { return valid(mhz) || !cfg.autoHide ? ghz(mhz) : ' '; }

function tooltipText(stats, show, cfg) {
    const temp = (on, v) => (on ? ' · ' + tempText(v) : '');
    const freq = v => (show.popupFreq && (valid(v) || !cfg.autoHide) ? ' · ' + ghz(v) : '');
    const lines = [];
    if (show.popupCpu) {
        lines.push('CPU  ' + num(stats.cpuPct) + ' %' + temp(show.popupCpuTemp, stats.cpuTemp)
            + freq(stats.cpuFreq) + (show.popupThreads ? ' · ' + stats.threadsText() : ''));
    }
    if (show.popupRam) lines.push('RAM  ' + num(stats.ramPct) + ' % · ' + stats.ramDetail());
    if (show.popupGpu) {
        lines.push('GPU  ' + num(stats.gpuPct) + ' %' + temp(show.popupGpuTemp, stats.gpuTemp)
            + freq(stats.gpuFreq));
    }
    if (show.popupVram) lines.push('VRAM  ' + num(stats.vramPct) + ' % · ' + stats.vramDetail());
    if (show.popupNet) lines.push('Réseau  ↓ ' + rateText(stats.netDown) + ' · ↑ ' + rateText(stats.netUp));
    if (show.popupDisk) {
        lines.push('Stockage  ' + show.popupDisks.map(d => {
            return d.short + ' ' + (d.pct >= 0 ? Math.round(d.pct) + ' %' : (d.size >= 0 ? sizeShort(d.size) : '--'));
        }).join(' · '));
    }
    return lines.join('\n');
}

module.exports = {
    COLORS,
    HISTORY_LENGTH,
    SysStats,
    bytesText,
    diskUnitTio,
    displayed,
    freqDetail,
    gioShort,
    gioTotal,
    historySpan,
    num,
    rateNum,
    rateText,
    rateUnit,
    rateUnitShort,
    scriptArgs,
    sizeNum,
    sizeShortNum,
    sizeShortUnit,
    sizeText,
    storageItems,
    tempColor,
    tempDotColor,
    tempText,
    tooltipText,
    usageColor,
    valid,
};
