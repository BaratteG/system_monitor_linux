import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 3.0 as PlasmaComponents3

Item {
    id: root

    Plasmoid.preferredRepresentation: Plasmoid.compactRepresentation

    // ---- configuration ----
    readonly property int updateInterval: plasmoid.configuration.updateInterval
    readonly property string gpuSource: plasmoid.configuration.gpuSource
    // interface name is passed to the shell: keep only safe characters
    readonly property string netInterface: (plasmoid.configuration.netInterface || "").replace(/[^A-Za-z0-9_.:@-]/g, "")
    readonly property bool autoHide: plasmoid.configuration.autoHide
    readonly property int warnTemp: plasmoid.configuration.warningTemp
    readonly property int critTemp: plasmoid.configuration.criticalTemp

    // ---- data ----
    property real cpuPct: -1
    property real cpuTemp: -1
    property real cpuFreq: -1     // MHz, average over all threads
    property real gpuFreq: -1     // MHz, graphics clock
    property real cpuPower: -1    // W, whole CPU package (RAPL, needs enable-cpu-power.sh)
    property real gpuPower: -1    // W
    property real prevEnergy: -1  // µJ, RAPL counter of the previous sample
    property real prevEnergyMs: 0 // script timestamp of that sample
    property real gpuPct: -1
    property real gpuTemp: -1
    property real memTotal: 0     // MiB
    property real memUsed: 0      // MiB
    property real vramTotal: -1   // MiB
    property real vramUsed: -1    // MiB
    property string gpuName: ""
    property string cpuName: ""
    property int threadsBusy: -1      // busy hardware threads, -1 until two samples
    property int threadsTotal: 0
    property var prevThreads: []
    property var threadPct: []        // current % of each hardware thread, -1 until two samples
    property var threadHistory: []    // per thread, same length as cpuHistory (oldest first)
    property var disks: []        // [{ mount, used, total, pct }], sizes in MiB
    property real prevTotal: -1
    property real prevIdle: -1
    property real netDown: -1     // bytes/s
    property real netUp: -1       // bytes/s
    property real netRxTotal: -1  // bytes since boot
    property real netTxTotal: -1
    property string netIf: ""
    property real prevRx: -1
    property real prevTx: -1
    property real prevNetTime: 0

    // consecutive samples without data; a source is declared missing after a
    // few misses so that one slow nvidia-smi call doesn't make a group blink
    readonly property int missLimit: 3
    property int gpuMisses: 0
    property int vramMisses: 0
    property int netMisses: 0
    property int diskMisses: 0
    property int cpuTempMisses: 0
    property int gpuTempMisses: 0
    property int cpuPowerMisses: 0
    property int gpuPowerMisses: 0
    function avail(misses) { return !autoHide || misses < missLimit }

    // data available on this machine (auto-hide)
    readonly property bool gpuAvail: avail(gpuMisses)
    readonly property bool vramAvail: avail(gpuMisses) && avail(vramMisses)
    readonly property bool netAvail: avail(netMisses)
    readonly property bool cpuTempAvail: avail(cpuTempMisses)
    readonly property bool gpuTempAvail: avail(gpuTempMisses)

    // what is actually displayed: choice of the Display tab AND data available
    readonly property var cfg: plasmoid.configuration
    readonly property bool panelCpu: cfg.cpuPanel
    readonly property bool panelRam: cfg.ramPanel
    readonly property bool panelGpu: cfg.gpuPanel && gpuAvail
    readonly property bool panelVram: cfg.vramPanel && vramAvail
    readonly property bool panelCpuTemp: cfg.tempPanel && cpuTempAvail
    readonly property bool panelGpuTemp: cfg.tempPanel && gpuTempAvail
    readonly property bool panelAmounts: cfg.amountsPanel
    readonly property bool panelDisk: cfg.diskPanel && panelDisks.length > 0
    readonly property bool panelNet: cfg.netPanel && netAvail
    readonly property bool popupCpu: cfg.cpuPopup
    readonly property bool popupRam: cfg.ramPopup
    readonly property bool popupGpu: cfg.gpuPopup && gpuAvail
    readonly property bool popupVram: cfg.vramPopup && vramAvail
    readonly property bool popupCpuTemp: cfg.tempPopup && cpuTempAvail
    readonly property bool popupGpuTemp: cfg.tempPopup && gpuTempAvail
    readonly property bool popupCpuPower: cfg.powerPopup && avail(cpuPowerMisses)
    readonly property bool popupGpuPower: cfg.powerPopup && avail(gpuPowerMisses)
    readonly property bool popupFreq: cfg.freqPopup
    readonly property bool popupThreads: cfg.threadsPopup && threadsTotal > 0
    readonly property bool popupDisk: cfg.diskPopup && popupDisks.length > 0
    readonly property bool popupNet: cfg.netPopup && netAvail

    // ---- storage: detected partitions + tracked folders / mount points ----
    function parseJson(text, fallback) {
        try { var v = JSON.parse(text); return v === null || v === undefined ? fallback : v }
        catch (e) { return fallback }
    }
    readonly property var diskPrefs: parseJson(cfg.diskPrefs, {})
    readonly property var tracked: parseJson(cfg.customPaths, []).filter(function (e) { return e && e.path })
    property var trackedData: []   // per tracked entry: { a, b, age } from the script (KiB)
    property string home: ""

    function shortName(path) {
        if (path === "/") return "/"
        var p = path.replace(/\/+$/, "")
        return p.substring(p.lastIndexOf("/") + 1) || p
    }
    function displayPath(path) {
        return home && path.indexOf(home) === 0 ? "~" + path.substring(home.length) : path
    }

    // one list for both views: { label, short, kind, used, total, size, pct, state, panel, popup }
    // sizes in MiB; pct -1 when there is no capacity (folder not measured yet);
    // base (folders): "quota" or "disk", what total and pct refer to;
    // state: "ok", "pending" (first measure running) or "error"
    readonly property var storageItems: {
        var out = []
        for (var i = 0; i < disks.length; i++) {
            var dk = disks[i], pref = diskPrefs[dk.mount]
            out.push({ label: dk.mount, short: shortName(dk.mount), kind: "mount", state: "ok",
                       used: dk.used, total: dk.total, size: dk.used, pct: dk.pct,
                       panel: pref ? !!pref.panel : dk.mount === "/",
                       popup: pref ? pref.popup !== false : true })
        }
        for (var j = 0; j < tracked.length; j++) {
            var t = tracked[j], r = trackedData[j] || { a: -1, b: -1 }
            var it = { label: displayPath(t.path), short: shortName(t.path), kind: t.kind === "mount" ? "mount" : "folder",
                       state: r.a === -1 ? "pending" : (r.a < 0 ? "error" : "ok"),
                       used: -1, total: -1, size: -1, pct: -1, base: "",
                       panel: !!t.panel, popup: t.popup !== false }
            if (it.state === "ok" && it.kind === "mount") {
                it.used = r.a / 1024; it.total = (r.a + r.b) / 1024; it.size = it.used
                it.pct = it.total > 0 ? 100 * it.used / it.total : -1
            } else if (it.state === "ok") {
                it.size = r.a / 1024
                // share of the quota if set, else of the disk that holds the folder
                if (t.quota > 0) { it.total = t.quota * 1024; it.base = "quota" }
                else if (r.b > 0) { it.total = r.b / 1024; it.base = "disk" }
                if (it.total > 0) it.pct = 100 * it.size / it.total
            }
            out.push(it)
        }
        return out
    }
    readonly property var panelDisks: storageItems.filter(function (d) { return d.panel })
    readonly property var popupDisks: storageItems.filter(function (d) { return d.popup })

    // shell argument: single quotes, embedded quotes escaped
    function shellQuote(str) { return "'" + str.replace(/'/g, "'\\''") + "'" }
    readonly property string trackedSpec: tracked.map(function (t) {
        return (t.kind === "mount" ? "m|" : "f|") + t.path.replace(/[\r\n]/g, "")
    }).join("\n")

    // usage history for the popup sparklines (percent, oldest first)
    readonly property int historyLength: 60
    property var cpuHistory: []
    property var gpuHistory: []
    property var downHistory: []
    property var upHistory: []

    readonly property real ramPct: memTotal > 0 ? 100 * memUsed / memTotal : -1
    readonly property real vramPct: vramTotal > 0 && vramUsed >= 0 ? 100 * vramUsed / vramTotal : -1

    readonly property string scriptPath: Qt.resolvedUrl("../scripts/sysstats.sh").toString().replace(/^file:\/\//, "")
    readonly property string command: "bash " + shellQuote(scriptPath) + " " + shellQuote(gpuSource) + " " + shellQuote(netInterface)
                                      + " " + shellQuote(trackedSpec) + " " + Math.max(60, cfg.folderRefresh * 60)

    function pushHistory(list, v) {
        var a = list.slice(Math.max(0, list.length - historyLength + 1))
        a.push(v)
        return a
    }

    function parse(out) {
        var d = {}
        var parts = out.trim().split(";")
        for (var i = 0; i < parts.length; i++) {
            var p = parts[i]
            var k = p.indexOf("=")
            if (k > 0) d[p.substring(0, k)] = p.substring(k + 1)
        }
        if (d.cpuTotal === undefined) return
        var tot = parseFloat(d.cpuTotal), idl = parseFloat(d.cpuIdle)
        if (prevTotal >= 0 && tot > prevTotal)
            cpuPct = Math.max(0, Math.min(100, 100 * (1 - (idl - prevIdle) / (tot - prevTotal))))
        prevTotal = tot; prevIdle = idl
        // hardware threads above 50 % over the last interval
        var th = (d.cpuThreads || "").split("|"), cur = [], busy = 0, pcts = []
        for (var n = 0; n < th.length; n++) {
            var tv = th[n].split(","), tt = parseFloat(tv[0]), ti = parseFloat(tv[1])
            if (isNaN(tt) || isNaN(ti)) continue
            cur.push([tt, ti])
            var pv = prevThreads[cur.length - 1], tp = -1
            if (pv) tp = tt > pv[0] ? Math.max(0, Math.min(100, 100 * (1 - (ti - pv[1]) / (tt - pv[0])))) : 0
            if (tp > 50) busy++
            pcts.push(tp)
        }
        var sameThreads = prevThreads.length === cur.length
        threadsBusy = sameThreads ? busy : -1
        threadsTotal = cur.length
        prevThreads = cur
        // the histories restart from zero when the number of threads changes
        threadPct = sameThreads ? pcts : pcts.map(function () { return -1 })
        threadHistory = sameThreads ? threadHistory.map(function (h, i) { return pushHistory(h, pcts[i]) })
                                    : cur.map(function () { return [] })
        cpuTemp = parseFloat(d.cpuTemp)
        cpuFreq = d.cpuFreq !== undefined ? parseFloat(d.cpuFreq) : -1
        gpuFreq = d.gpuFreq !== undefined ? parseFloat(d.gpuFreq) : -1
        gpuPower = d.gpuPower !== undefined ? parseFloat(d.gpuPower) : -1
        // CPU power: energy delta over the script's own timestamps; a counter
        // that went backwards (wrap) skips the sample and keeps the last value
        var en = d.cpuEnergy !== undefined ? parseFloat(d.cpuEnergy) : -1
        var enMs = parseFloat(d.cpuEnergyMs)
        if (isNaN(en) || en < 0) {
            cpuPower = -1
            prevEnergy = -1
        } else {
            if (prevEnergy >= 0 && en >= prevEnergy && enMs > prevEnergyMs)
                cpuPower = (en - prevEnergy) / (enMs - prevEnergyMs) / 1000
            prevEnergy = en
            prevEnergyMs = enMs
        }
        memTotal = parseFloat(d.memTotal)
        memUsed = memTotal - parseFloat(d.memAvail)
        gpuPct = parseFloat(d.gpuUse)
        gpuTemp = parseFloat(d.gpuTemp)
        vramUsed = parseFloat(d.vramUsed)
        vramTotal = parseFloat(d.vramTotal)
        gpuName = d.gpuName || ""
        cpuName = cleanCpuName(d.cpuName || "")
        var list = []
        var entries = (d.disks || "").split("|")
        for (var e = 0; e < entries.length; e++) {
            var f = entries[e].split(":")
            if (f.length < 3) continue
            var used = parseFloat(f[1]) / 1024, total = used + parseFloat(f[2]) / 1024
            if (total > 0) list.push({ mount: f[0], used: used, total: total, pct: 100 * used / total })
        }
        disks = list
        diskMisses = list.length > 0 ? 0 : diskMisses + 1
        home = d.home || ""
        var td = []
        var rows = (d.custom || "").split("|")
        for (var c = 0; c < rows.length; c++) {
            var g = rows[c].split(":")
            if (g.length >= 4) td[parseInt(g[0])] = { a: parseFloat(g[1]), b: parseFloat(g[2]), age: parseFloat(g[3]) }
        }
        trackedData = td
        gpuMisses = d.gpuKind ? 0 : gpuMisses + 1
        vramMisses = vramTotal > 0 ? 0 : vramMisses + 1
        cpuTempMisses = valid(cpuTemp) ? 0 : cpuTempMisses + 1
        gpuTempMisses = valid(gpuTemp) ? 0 : gpuTempMisses + 1
        cpuPowerMisses = valid(cpuPower) ? 0 : cpuPowerMisses + 1
        gpuPowerMisses = valid(gpuPower) ? 0 : gpuPowerMisses + 1
        if (cpuPct >= 0) cpuHistory = pushHistory(cpuHistory, cpuPct)
        if (gpuPct >= 0) gpuHistory = pushHistory(gpuHistory, gpuPct)

        netIf = d.netIf || ""
        var rx = parseFloat(d.netRx), tx = parseFloat(d.netTx), now = Date.now()
        if (netIf === "") {
            netDown = netUp = -1
        } else if (prevRx >= 0 && rx >= prevRx && tx >= prevTx && now > prevNetTime) {
            var dt = (now - prevNetTime) / 1000
            netDown = (rx - prevRx) / dt
            netUp = (tx - prevTx) / dt
            downHistory = pushHistory(downHistory, netDown)
            upHistory = pushHistory(upHistory, netUp)
        }
        netMisses = netIf !== "" ? 0 : netMisses + 1
        netRxTotal = netIf !== "" ? rx : -1
        netTxTotal = netIf !== "" ? tx : -1
        prevRx = netIf === "" ? -1 : rx
        prevTx = tx
        prevNetTime = now
    }

    PlasmaCore.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: {
            if (data["exit code"] === 0 || data["stdout"])
                root.parse(data["stdout"] || "")
            disconnectSource(sourceName)
        }
    }

    Timer {
        interval: root.updateInterval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: executable.connectSource(root.command)
    }

    // ---- helpers ----
    function valid(v) { return v >= 0 && !isNaN(v) }
    function num(v) { return valid(v) ? Math.round(v).toString() : "--" }
    // compact form: one decimal below 100 Gio, integer above (fixed width)
    function gioShort(mib) {
        if (!valid(mib)) return "--"
        var v = mib / 1024
        return v < 99.95 ? v.toFixed(1) : Math.round(v).toString()
    }
    // capacity: integer from 10 Gio (60, 32), one decimal below (2.0)
    function gioTotal(mib) {
        if (!(mib > 0)) return "--"
        var v = mib / 1024
        return v >= 10 ? Math.round(v).toString() : v.toFixed(1)
    }
    // "AMD Ryzen 9 9950X3D 16-Core Processor" -> "AMD Ryzen 9 9950X3D"
    // "Intel(R) Core(TM) i7-9700K CPU @ 3.60GHz" -> "Intel Core i7-9700K"
    function cleanCpuName(n) {
        return n.replace(/\((R|TM)\)/gi, "")
                .replace(/\s+@\s+.*$/, "")
                .replace(/\s+w\/\s.*$/i, "")
                .replace(/\s+\d+-Cores?( Processor)?$/i, "")
                .replace(/\s+(CPU|Processor)$/i, "")
                .replace(/\s+/g, " ").trim()
    }
    // disk sizes: used and total share the unit of the total, so the two
    // numbers compare at a glance (Gio below 1024 Gio, Tio from there)
    function diskUnitTio(totalMib) { return totalMib >= 1024 * 1024 }
    function sizeNum(mib, totalMib) {
        var g = mib / 1024
        // two decimals below 10 Tio, so "0.35 / 1.30" keeps Gio-level detail
        if (diskUnitTio(totalMib)) return (g / 1024).toFixed(totalMib < 10 * 1024 * 1024 ? 2 : 1)
        return g < 99.95 ? g.toFixed(1) : Math.round(g).toString()
    }
    function sizeText(mib) { return sizeNum(mib, mib) + (diskUnitTio(mib) ? " Tio" : " Gio") }
    // panel size: "42.0G" below 1024 Gio, "1.3T" from there
    function sizeShortNum(mib) {
        var g = mib / 1024
        if (diskUnitTio(mib)) return (g / 1024).toFixed(1)
        return g < 99.95 ? g.toFixed(1) : Math.round(g).toString()
    }
    function sizeShortUnit(mib) { return diskUnitTio(mib) ? "T" : "G" }
    function sizeShort(mib) { return sizeShortNum(mib) + sizeShortUnit(mib) }
    function gio(mib) { return (mib / 1024).toFixed(1) }
    function withAlpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

    // temperatures and memory pressure are states -> theme status colors;
    // plain usage stays on the accent color (a busy GPU is not an alarm)
    function tempColor(v) {
        if (v >= critTemp) return PlasmaCore.Theme.negativeTextColor
        if (v >= warnTemp) return PlasmaCore.Theme.neutralTextColor
        return PlasmaCore.Theme.textColor
    }
    function tempDotColor(v) {
        if (!valid(v)) return withAlpha(PlasmaCore.Theme.textColor, 0.3)
        if (v >= critTemp) return PlasmaCore.Theme.negativeTextColor
        if (v >= warnTemp) return PlasmaCore.Theme.neutralTextColor
        return PlasmaCore.Theme.positiveTextColor
    }
    // usage bars and gauges: blue < 25 %, green < 50 %, orange < 80 %, red from 80 %
    function usageColor(v) {
        if (v >= 80) return PlasmaCore.Theme.negativeTextColor
        if (v >= 50) return PlasmaCore.Theme.neutralTextColor
        if (v >= 25) return PlasmaCore.Theme.positiveTextColor
        return PlasmaCore.Theme.highlightColor
    }

    // adds the curve of a history to the path: the points are at x0 + i * step, at the height yOf(v[i]).
    // Each segment is a cubic Bezier whose two control points are halfway in x, at the height of each
    // end: the curve never goes beyond its neighbouring values (no dip under 0, no peak over 100 %).
    // join: continue the current path instead of starting a new one. Under 2 px between two points the
    // curve would bring nothing and cost thousands of segments: straight lines then.
    function tracePath(ctx, v, x0, step, yOf, join) {
        var px = x0, py = yOf(v[0])
        if (join) ctx.lineTo(px, py)
        else ctx.moveTo(px, py)
        for (var i = 1; i < v.length; i++) {
            var x = x0 + i * step, y = yOf(v[i])
            if (step >= 2) {
                var xm = (px + x) / 2
                ctx.bezierCurveTo(xm, py, xm, y, x, y)
            } else {
                ctx.lineTo(x, y)
            }
            px = x
            py = y
        }
    }

    // blocks under the CPU gauge, one per thread: the largest square size (8 px down to 3 px,
    // times unit) whose rows stay under maxHeight, so 128 threads shrink instead of lengthening the card
    function threadBlockLayout(count, width, maxHeight, unit) {
        var size = 8, gap = 2, cols = 1, rows = 1
        for (var s = 8; s >= 3; s--) {
            size = Math.round(s * unit)
            gap = Math.max(1, Math.round((s >= 5 ? 2 : 1) * unit))
            // never more columns than threads, so that a few blocks stay centered
            cols = Math.max(1, Math.min(count, Math.floor((width + gap) / (size + gap))))
            rows = Math.max(1, Math.ceil(count / cols))
            if (rows * (size + gap) - gap <= maxHeight) break
        }
        return { size: size, gap: gap, cols: cols, rows: rows,
                 width: cols * (size + gap) - gap, height: rows * (size + gap) - gap }
    }
    // columns of the grid of mini graphs: cells a bit wider than high (aspect 1.6), and few
    // empty cells in the last row, whatever the number of threads (4 to 128)
    function threadGridColumns(count, width, height, gap) {
        var best = 1, bestScore = Infinity
        for (var cols = 1; cols <= count; cols++) {
            var rows = Math.ceil(count / cols)
            var cw = (width - (cols - 1) * gap) / cols, ch = (height - (rows - 1) * gap) / rows
            if (cw < 2 || ch < 2) continue
            var aspect = cw / ch
            var score = Math.abs(Math.log(aspect / 1.6)) + (aspect < 1.2 ? 0.6 : 0)
                        + 1.5 * (cols * rows - count) / (cols * rows)
            if (score < bestScore) { bestScore = score; best = cols }
        }
        return best
    }

    function ramDetail() {
        return memTotal > 0 ? gio(memUsed) + " / " + gio(memTotal) + " Gio" : "--"
    }
    function vramDetail() {
        return valid(vramPct) ? gio(vramUsed) + " / " + gio(vramTotal) + " Gio" : "--"
    }
    function freqDetail(mhz) { return valid(mhz) || !autoHide ? ghz(mhz) : " " }
    function threadsText() { return (threadsBusy >= 0 ? threadsBusy : "--") + "/" + threadsTotal + " threads" }
    function ghz(mhz) { return valid(mhz) ? (mhz / 1000).toFixed(2) + " GHz" : "-- GHz" }
    function tempText(v) { return valid(v) ? Math.round(v) + " °C" : "-- °C" }
    function powerText(v) { return valid(v) ? Math.round(v) + " W" : "-- W" }

    // network rates: decimal units, Ko/s minimum, 3 significant chars
    readonly property color downColor: PlasmaCore.Theme.highlightColor
    readonly property color upColor: "#d2608c"
    function rateNum(bps) {
        if (!valid(bps)) return "--"
        var v = bps / 1000, i = 0
        while (v >= 999.5 && i < 3) { v /= 1000; i++ }
        return v < 9.95 ? v.toFixed(1) : Math.round(v).toString()
    }
    function rateUnit(bps) {
        var units = ["Ko/s", "Mo/s", "Go/s", "To/s"]
        if (!valid(bps)) return units[0]
        var v = bps / 1000, i = 0
        while (v >= 999.5 && i < 3) { v /= 1000; i++ }
        return units[i]
    }
    // panel form: the arrows already say "per second"
    function rateUnitShort(bps) { return rateUnit(bps).charAt(0).replace("o", "K") }
    function rateText(bps) { return rateNum(bps) + " " + rateUnit(bps) }
    function bytesText(b) {
        if (!valid(b)) return "--"
        var units = ["o", "Ko", "Mo", "Go", "To"], i = 0
        while (b >= 1000 && i < 4) { b /= 1000; i++ }
        return (b < 9.95 ? b.toFixed(1) : Math.round(b)) + " " + units[i]
    }

    Plasmoid.toolTipMainText: "System Monitor"
    Plasmoid.toolTipSubText: {
        var lines = []
        var t = function (on, v) { return on ? " · " + tempText(v) : "" }
        var w = function (on, v) { return on ? " · " + powerText(v) : "" }
        var f = function (v) { return popupFreq && (valid(v) || !autoHide) ? " · " + ghz(v) : "" }
        if (popupCpu) lines.push("CPU  " + num(cpuPct) + " %" + t(popupCpuTemp, cpuTemp) + w(popupCpuPower, cpuPower) + f(cpuFreq)
                                 + (popupThreads ? " · " + threadsText() : ""))
        if (popupRam) lines.push("RAM  " + num(ramPct) + " % · " + ramDetail())
        if (popupGpu) lines.push("GPU  " + num(gpuPct) + " %" + t(popupGpuTemp, gpuTemp) + w(popupGpuPower && gpuAvail, gpuPower) + f(gpuFreq))
        if (popupVram) lines.push("VRAM  " + num(vramPct) + " % · " + vramDetail())
        if (popupNet) lines.push("Réseau  ↓ " + rateText(netDown) + " · ↑ " + rateText(netUp))
        if (popupDisk) lines.push("Stockage  " + popupDisks.map(function (d) {
            return d.short + " " + (d.pct >= 0 ? Math.round(d.pct) + " %" : (d.size >= 0 ? sizeShort(d.size) : "--"))
        }).join(" · "))
        return lines.join("\n")
    }


    // ======================================================================
    // Floating window and process panel
    // The state lives here (not in the popup content) so that it survives
    // the switch between popup and window.
    // ======================================================================
    readonly property bool floating: plasmoid.configuration.floating
    property bool floatShown: true       // the panel click shows / hides the floating window
    // someone can see the content: the data of the process panel is only fetched then
    readonly property bool contentVisible: floating ? floatWindow.visible : plasmoid.expanded
    readonly property int floatNone: -99999   // "no saved position yet"

    function detach() {
        floatShown = true
        plasmoid.configuration.floating = true
        plasmoid.expanded = false
    }
    function attach() { plasmoid.configuration.floating = false }

    // CPU graph: the total curve, or one mini graph per hardware thread (kept in the settings)
    readonly property bool threadGraph: plasmoid.configuration.threadGraph
    function toggleThreadGraph() { plasmoid.configuration.threadGraph = !threadGraph }
    // panel click or global shortcut
    function activate() {
        if (floating) floatShown = !floatShown
        else plasmoid.expanded = !plasmoid.expanded
    }
    Connections {
        target: plasmoid
        // the shortcut expands the popup directly: show / hide the window instead
        function onExpandedChanged() {
            if (plasmoid.expanded && root.floating) {
                plasmoid.expanded = false
                root.floatShown = !root.floatShown
            }
        }
    }

    // a saved position is only used if the window would still be on a screen
    function floatPosValid() {
        var x = plasmoid.configuration.floatX, y = plasmoid.configuration.floatY
        if (x === floatNone || y === floatNone) return false
        var scr = Qt.application.screens
        for (var i = 0; i < scr.length; i++) {
            var s = scr[i]
            if (x + 80 < s.virtualX + s.width && x + floatWindow.width - 80 > s.virtualX
                && y >= s.virtualY - 20 && y + 40 < s.virtualY + s.height) return true
        }
        return false
    }
    function syncFloat() {
        var want = floating && floatShown
        if (want && !floatWindow.visible && floatPosValid()) {
            floatWindow.x = plasmoid.configuration.floatX
            floatWindow.y = plasmoid.configuration.floatY
        }
        floatWindow.visible = want
    }
    // the window content is built on first use and then kept: a Loader that is emptied
    // while its items are alive in a handler crashes Qt 5.15 (seen in the JS garbage collector)
    property bool floatBuilt: false
    onFloatingChanged: { if (floating) floatBuilt = true; syncFloat() }
    onFloatShownChanged: syncFloat()
    Component.onCompleted: { floatBuilt = floating; syncFloat() }

    // a real X11 window (decorated by the window manager: move, close, keep above)
    // with the same content as the popup
    Window {
        id: floatWindow
        readonly property real margin: PlasmaCore.Units.largeSpacing
        readonly property var content: floatLoader.item
        title: "System Monitor"
        color: PlasmaCore.Theme.backgroundColor
        // the window follows the size of the content (the side panel opens to the right):
        // fixed size, the limits come first so they never clamp the new size
        readonly property real wantW: (content ? content.implicitWidth : PlasmaCore.Units.gridUnit * 24) + 2 * margin
        readonly property real wantH: (content ? content.implicitHeight : PlasmaCore.Units.gridUnit * 20) + 2 * margin
        minimumWidth: wantW
        maximumWidth: wantW
        minimumHeight: wantH
        maximumHeight: wantH
        width: wantW
        height: wantH
        onXChanged: floatPosTimer.restart()
        onYChanged: floatPosTimer.restart()
        // closing the window goes back to the popup
        onClosing: root.attach()

        Loader {
            id: floatLoader
            anchors.fill: parent
            anchors.margins: floatWindow.margin
            active: root.floatBuilt
            sourceComponent: root.popupContent
            onLoaded: item.windowMode = true
        }
    }
    // remember where the user left the window (debounced: dragging fires a lot of moves)
    Timer {
        id: floatPosTimer
        interval: 600
        onTriggered: {
            if (!floatWindow.visible) return
            if (plasmoid.configuration.floatX !== floatWindow.x) plasmoid.configuration.floatX = floatWindow.x
            if (plasmoid.configuration.floatY !== floatWindow.y) plasmoid.configuration.floatY = floatWindow.y
        }
    }

    // ---- process list (side panel): "cpu", "gpu" or "" (closed) ----
    property string procMode: ""
    property string procKind: ""      // "cpu", "nvidia", "amd", "none"; "" until the first result
    property var procRows: []         // [{ pid, killable, use, mem, pname, command }]
    property int selectedPid: -1      // the selection follows the PID: the list is sorted again on each refresh
    property string procRunning: ""   // command being run, "" when idle (no overlapping runs)
    readonly property bool procActive: procMode !== "" && contentVisible
    readonly property string procScriptPath: Qt.resolvedUrl("../scripts/procstats.sh").toString().replace(/^file:\/\//, "")
    readonly property string procCommand: procMode === "" ? ""
        : "bash " + shellQuote(procScriptPath) + (procMode === "gpu" ? " gpu " + shellQuote(gpuSource) : " cpu")
    ListModel { id: procModel }
    function procRow(pid) {
        for (var i = 0; i < procRows.length; i++) if (procRows[i].pid === pid) return procRows[i]
        return null
    }

    function setProcMode(mode) {
        procMode = procMode === mode ? "" : mode
        procKind = ""
        procRows = []
        procModel.clear()
        selectedPid = -1
        killStatus = ""
        procRefresh()
    }
    function selectProc(pid) {
        if (procMode !== "cpu") return
        if (pid !== selectedPid) killStatus = ""
        selectedPid = pid
    }
    function procRefresh() {
        if (!procActive || procRunning !== "") return
        procRunning = procCommand
        procSource.connectSource(procRunning)
    }

    // "pid|killable|use|mem|name|command": the command may hold "|", split on the first five only
    function parseProc(out) {
        var lines = out.split("\n")
        if (lines[0].charAt(0) !== "#") return
        var rows = []
        for (var i = 1; i < lines.length; i++) {
            var rest = lines[i], f = []
            for (var k = 0; k < 5; k++) {
                var cut = rest.indexOf("|")
                if (cut < 0) break
                f.push(rest.substring(0, cut))
                rest = rest.substring(cut + 1)
            }
            if (f.length < 5) continue
            rows.push({ pid: parseInt(f[0]), killable: f[1] === "1", use: parseFloat(f[2]),
                        mem: parseFloat(f[3]), pname: f[4], command: rest })
        }
        procKind = lines[0].substring(1)
        procRows = rows
        // updated in place, so the list keeps its scroll position
        for (var r = 0; r < rows.length; r++) {
            if (r < procModel.count) procModel.set(r, rows[r])
            else procModel.append(rows[r])
        }
        if (procModel.count > rows.length) procModel.remove(rows.length, procModel.count - rows.length)
        // a PID that is gone leaves the selection and the "forced stop" state
        if (selectedPid > 0 && !procRow(selectedPid)) selectedPid = -1
        killForced = killForced.filter(function (p) { return !!procRow(p) })
    }

    PlasmaCore.DataSource {
        id: procSource
        engine: "executable"
        connectedSources: []
        onNewData: {
            disconnectSource(sourceName)
            root.procRunning = ""
            // the mode changed during the run: drop the result and measure the new one
            if (sourceName === root.procCommand) root.parseProc(data["stdout"] || "")
            else root.procRefresh()
        }
    }
    Timer {
        interval: Math.max(2000, root.updateInterval)
        running: root.procActive
        repeat: true
        triggeredOnStart: true
        onTriggered: root.procRefresh()
    }

    // ---- end of task (CPU list only) ----
    property var killWaiting: []     // [{ pid, name, due }]: TERM sent, waiting to see the process leave
    property var killForced: []      // PIDs that ignored TERM: the next click sends KILL
    property var killJobs: ({})      // command -> { pid, name, signal, check }
    property string killStatus: ""
    property bool killFailed: false
    readonly property int killGrace: 3000

    function isWaiting(pid) { return killWaiting.some(function (w) { return w.pid === pid }) }
    function canKill(pid) {
        var row = procMode === "cpu" ? procRow(pid) : null
        return !!row && row.killable && Number.isInteger(pid) && pid > 1
    }
    function runKill(signal, pid, name, check) {
        var cmd = "kill -" + signal + " " + pid
        killJobs[cmd] = { pid: pid, name: name, signal: signal, check: check }
        killSource.connectSource(cmd)
    }
    function killSelected() {
        var pid = selectedPid
        if (!canKill(pid) || isWaiting(pid)) return
        var forced = killForced.indexOf(pid) >= 0
        var name = procRow(pid).pname
        killFailed = false
        killStatus = forced ? "Arrêt forcé de " + name + "…" : "Arrêt de " + name + "…"
        runKill(forced ? "KILL" : "TERM", pid, name, false)
    }
    function killResult(job, code) {
        var label = job.name + " (PID " + job.pid + ")"
        if (job.check) {
            // kill -0: exit code 0 means the process is still there
            killWaiting = killWaiting.filter(function (w) { return w.pid !== job.pid })
            if (code === 0) {
                if (killForced.indexOf(job.pid) < 0) killForced = killForced.concat([job.pid])
                killFailed = false
                killStatus = label + " ne répond pas"
            } else {
                killFailed = false
                killStatus = label + " arrêté"
            }
        } else if (code !== 0) {
            killFailed = true
            killStatus = "Impossible d'arrêter " + label
        } else if (job.signal === "KILL") {
            killForced = killForced.filter(function (p) { return p !== job.pid })
            killFailed = false
            killStatus = label + " arrêté"
        } else {
            killWaiting = killWaiting.concat([{ pid: job.pid, name: job.name, due: Date.now() + killGrace }])
        }
    }
    PlasmaCore.DataSource {
        id: killSource
        engine: "executable"
        connectedSources: []
        onNewData: {
            disconnectSource(sourceName)
            var job = root.killJobs[sourceName]
            delete root.killJobs[sourceName]
            if (job) root.killResult(job, data["exit code"])
        }
    }
    // after the grace period, check whether each process left
    Timer {
        interval: 500
        running: root.killWaiting.length > 0
        repeat: true
        onTriggered: {
            var now = Date.now()
            root.killWaiting.forEach(function (w) {
                if (w.due > now || w.checking) return
                w.checking = true
                root.runKill("0", w.pid, w.name, true)
            })
        }
    }


    // ======================================================================
    // Compact representation (panel)
    // ======================================================================
    Plasmoid.compactRepresentation: MouseArea {
        id: compact
        readonly property bool vertical: plasmoid.formFactor === PlasmaCore.Types.Vertical
        // thick panels get the label stacked above the value
        readonly property bool tall: vertical || height >= PlasmaCore.Units.gridUnit * 2.3
        readonly property bool systemGroup: root.panelCpu || root.panelRam
        readonly property bool gpuGroup: root.panelGpu || root.panelVram

        Layout.minimumWidth: vertical ? 0 : grid.implicitWidth
        Layout.preferredWidth: grid.implicitWidth
        Layout.minimumHeight: vertical ? grid.implicitHeight : 0
        Layout.preferredHeight: grid.implicitHeight
        hoverEnabled: true
        onClicked: root.activate()

        TextMetrics { id: tmNum; font: PlasmaCore.Theme.defaultFont; text: "100" }
        TextMetrics { id: tmUnit; font: PlasmaCore.Theme.smallestFont; text: "%" }
        TextMetrics { id: tmTemp; font: PlasmaCore.Theme.defaultFont; text: "100°" }
        TextMetrics { id: tmAmount; font: PlasmaCore.Theme.defaultFont; text: "99.9" }
        TextMetrics { id: tmRate; font: PlasmaCore.Theme.defaultFont; text: "999" }
        TextMetrics { id: tmRateUnit; font: PlasmaCore.Theme.smallestFont; text: "M" }

        // one direction of network traffic: colored arrow, value, unit
        component Rate: ColumnLayout {
            id: rate
            property string arrow
            property color arrowColor
            property real value: -1
            spacing: 2
            Layout.alignment: Qt.AlignTop
            Row {
                spacing: 1
                PlasmaComponents3.Label {
                    text: rate.arrow
                    color: rate.arrowColor
                    font: PlasmaCore.Theme.smallestFont
                    height: rateNum.height
                    verticalAlignment: Text.AlignVCenter
                }
                PlasmaComponents3.Label {
                    id: rateNum
                    text: root.rateNum(rate.value)
                    width: tmRate.width
                    horizontalAlignment: Text.AlignRight
                }
                PlasmaComponents3.Label {
                    text: root.rateUnitShort(rate.value)
                    font: PlasmaCore.Theme.smallestFont
                    opacity: 0.6
                    width: tmRateUnit.width + 2
                    horizontalAlignment: Text.AlignRight
                    height: rateNum.height
                    verticalAlignment: Text.AlignVCenter
                }
            }
            // keeps the text on the same line as the cells that have a usage bar
            Item { implicitHeight: 2 }
        }

        // one disk / folder in the panel: percent with bar, or size while a folder has no capacity yet
        component DiskCell: GridLayout {
            id: dcell
            property var item
            readonly property bool hasPct: item.pct >= 0
            columns: compact.tall ? 1 : 2
            rowSpacing: 0
            columnSpacing: PlasmaCore.Units.smallSpacing

            PlasmaComponents3.Label {
                text: dcell.item.short
                font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                font.letterSpacing: 0.6
                opacity: 0.6
                Layout.preferredHeight: dNum.implicitHeight
                Layout.alignment: compact.tall ? Qt.AlignLeft : (Qt.AlignTop | Qt.AlignLeft)
                verticalAlignment: Text.AlignVCenter
            }
            ColumnLayout {
                spacing: 2
                Layout.alignment: Qt.AlignTop
                Row {
                    PlasmaComponents3.Label {
                        id: dNum
                        text: dcell.hasPct ? root.num(dcell.item.pct)
                                           : (dcell.item.size >= 0 ? root.sizeShortNum(dcell.item.size) : "--")
                        width: dcell.hasPct ? tmNum.width : tmAmount.width
                        horizontalAlignment: Text.AlignRight
                    }
                    PlasmaComponents3.Label {
                        text: dcell.hasPct || dcell.item.size < 0 ? "%" : root.sizeShortUnit(dcell.item.size)
                        font: PlasmaCore.Theme.smallestFont
                        opacity: 0.6
                        leftPadding: dcell.hasPct ? 0 : 1
                        width: dcell.hasPct ? tmUnit.width + 2 : implicitWidth
                        height: dNum.height
                        horizontalAlignment: Text.AlignRight
                        verticalAlignment: Text.AlignVCenter
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 2
                    radius: 1
                    color: root.withAlpha(PlasmaCore.Theme.textColor, dcell.hasPct ? 0.15 : 0)
                    Rectangle {
                        height: parent.height
                        radius: 1
                        width: parent.width * Math.max(0, Math.min(100, dcell.item.pct)) / 100
                        color: root.usageColor(dcell.item.pct)
                    }
                }
            }
        }

        component NetCell: GridLayout {
            columns: compact.tall ? 1 : 2
            rowSpacing: 0
            columnSpacing: PlasmaCore.Units.smallSpacing

            PlasmaComponents3.Label {
                text: "NET"
                font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                font.letterSpacing: 0.6
                opacity: 0.6
                Layout.preferredHeight: tmRate.height
                Layout.alignment: compact.tall ? Qt.AlignLeft : (Qt.AlignTop | Qt.AlignLeft)
                verticalAlignment: Text.AlignVCenter
            }
            RowLayout {
                spacing: PlasmaCore.Units.smallSpacing * 1.5
                Rate { arrow: "↓"; arrowColor: root.downColor; value: root.netDown }
                Rate { arrow: "↑"; arrowColor: root.upColor; value: root.netUp }
            }
        }

        component Cell: GridLayout {
            id: cell
            property string label
            property real value: -1
            property color barColor: root.usageColor(value)
            property bool hasTemp: false
            property real temp: -1
            property string amount: ""   // used memory, shown in Gio after the percent
            property string amountTotal: ""

            columns: compact.tall ? 1 : 2
            rowSpacing: 0
            columnSpacing: PlasmaCore.Units.smallSpacing

            PlasmaComponents3.Label {
                text: cell.label
                font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                font.letterSpacing: 0.6
                opacity: 0.6
                Layout.preferredHeight: numLabel.implicitHeight
                Layout.alignment: compact.tall ? Qt.AlignLeft : (Qt.AlignTop | Qt.AlignLeft)
                verticalAlignment: Text.AlignVCenter
            }

            RowLayout {
                spacing: PlasmaCore.Units.smallSpacing

                ColumnLayout {
                    spacing: 2
                    Layout.alignment: Qt.AlignTop

                    Row {
                        PlasmaComponents3.Label {
                            id: numLabel
                            text: root.num(cell.value)
                            width: tmNum.width
                            horizontalAlignment: Text.AlignRight
                        }
                        PlasmaComponents3.Label {
                            text: "%"
                            font: PlasmaCore.Theme.smallestFont
                            opacity: 0.6
                            width: tmUnit.width + 2
                            height: numLabel.height
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    // thin usage bar
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 2
                        radius: 1
                        color: root.withAlpha(PlasmaCore.Theme.textColor, 0.15)
                        Rectangle {
                            height: parent.height
                            radius: 1
                            width: parent.width * Math.max(0, Math.min(100, cell.value)) / 100
                            color: cell.barColor
                            Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                        }
                    }
                }

                PlasmaComponents3.Label {
                    visible: cell.hasTemp
                    Layout.alignment: Qt.AlignTop
                    Layout.preferredWidth: tmTemp.width
                    Layout.preferredHeight: numLabel.implicitHeight
                    text: root.valid(cell.temp) ? Math.round(cell.temp) + "°" : "--°"
                    color: root.tempColor(cell.temp)
                    opacity: cell.temp >= root.warnTemp ? 1 : 0.75
                    verticalAlignment: Text.AlignVCenter
                    horizontalAlignment: Text.AlignRight
                }

                Row {
                    visible: cell.amount !== ""
                    Layout.alignment: Qt.AlignTop
                    PlasmaComponents3.Label {
                        id: amountNum
                        text: cell.amount
                        width: tmAmount.width
                        horizontalAlignment: Text.AlignRight
                        opacity: 0.75
                    }
                    PlasmaComponents3.Label {
                        visible: cell.amountTotal !== ""
                        text: "/" + cell.amountTotal
                        opacity: 0.5
                    }
                    PlasmaComponents3.Label {
                        text: "G"
                        leftPadding: 1
                        font: PlasmaCore.Theme.smallestFont
                        opacity: 0.6
                        height: amountNum.height
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }

        // background highlight on hover / when popup is open
        Rectangle {
            anchors.fill: parent
            radius: PlasmaCore.Units.smallSpacing
            color: PlasmaCore.Theme.textColor
            opacity: root.contentVisible ? 0.10 : (compact.containsMouse ? 0.06 : 0)
            Behavior on opacity { NumberAnimation { duration: 150 } }
        }

        Grid {
            id: grid
            anchors.centerIn: parent
            flow: compact.vertical ? Grid.TopToBottom : Grid.LeftToRight
            rows: compact.vertical ? -1 : 1
            columns: compact.vertical ? 1 : -1
            columnSpacing: PlasmaCore.Units.smallSpacing * 2
            rowSpacing: PlasmaCore.Units.smallSpacing * 2
            verticalItemAlignment: Grid.AlignVCenter
            horizontalItemAlignment: Grid.AlignHCenter
            leftPadding: PlasmaCore.Units.smallSpacing
            rightPadding: PlasmaCore.Units.smallSpacing

            Cell {
                visible: root.panelCpu
                label: "CPU"; value: root.cpuPct
                hasTemp: root.panelCpuTemp; temp: root.cpuTemp
            }
            Cell {
                visible: root.panelRam
                label: "RAM"; value: root.ramPct
                amount: root.panelAmounts ? root.gioShort(root.memTotal > 0 ? root.memUsed : -1) : ""
                amountTotal: root.gioTotal(root.memTotal)
            }

            // separator between the system group and the graphics group
            Rectangle {
                visible: compact.gpuGroup && compact.systemGroup
                width: compact.vertical ? compact.width * 0.5 : 1
                height: compact.vertical ? 1 : compact.height * 0.5
                color: PlasmaCore.Theme.textColor
                opacity: 0.18
            }

            Cell {
                visible: root.panelGpu
                label: "GPU"; value: root.gpuPct
                hasTemp: root.panelGpuTemp; temp: root.gpuTemp
            }
            Cell {
                visible: root.panelVram
                label: "VRAM"; value: root.vramPct
                amount: root.panelAmounts ? root.gioShort(root.valid(root.vramPct) ? root.vramUsed : -1) : ""
                amountTotal: root.gioTotal(root.vramTotal)
            }

            Rectangle {
                visible: root.panelNet && (compact.systemGroup || compact.gpuGroup)
                width: compact.vertical ? compact.width * 0.5 : 1
                height: compact.vertical ? 1 : compact.height * 0.5
                color: PlasmaCore.Theme.textColor
                opacity: 0.18
            }

            NetCell { visible: root.panelNet }

            Rectangle {
                visible: root.panelDisk && (compact.systemGroup || compact.gpuGroup || root.panelNet)
                width: compact.vertical ? compact.width * 0.5 : 1
                height: compact.vertical ? 1 : compact.height * 0.5
                color: PlasmaCore.Theme.textColor
                opacity: 0.18
            }

            Repeater {
                model: root.panelDisk ? root.panelDisks : []
                delegate: DiskCell { item: modelData }
            }
        }
    }

    // ======================================================================
    // Full representation (popup)
    // ======================================================================
    // the popup only hosts the content (a Loader), which is shared with the floating window;
    // the sizes are exposed here, the popup is sized from them
    Plasmoid.fullRepresentation: Item {
        readonly property var content: popupLoader.item
        Layout.minimumWidth: content ? content.minWidth : PlasmaCore.Units.gridUnit * 22
        Layout.preferredWidth: content ? content.implicitWidth : PlasmaCore.Units.gridUnit * 24
        Layout.minimumHeight: content ? content.implicitHeight : 0
        Layout.preferredHeight: content ? content.implicitHeight : 0

        Loader {
            id: popupLoader
            anchors.fill: parent
            sourceComponent: root.popupContent
        }
    }

    // shared content: cards on the left, process panel on the right when open
    property Component popupContent: ColumnLayout {
        id: full
        property bool windowMode: false   // in the floating window (no detach button)
        // the side panel is open (and its card is displayed)
        readonly property bool sideOpen: root.procMode === "cpu" ? cpuCard.visible
                                         : root.procMode === "gpu" ? gpuCard.visible : false
        readonly property real sideWidth: sideOpen ? PlasmaCore.Units.gridUnit * 22 + spacing : 0
        readonly property real minWidth: PlasmaCore.Units.gridUnit * 22 + sideWidth
        spacing: PlasmaCore.Units.largeSpacing

        // ring gauge: 270° arc, value in the middle, caption below
        component Gauge: ColumnLayout {
            id: gauge
            property string label
            property string detail
            property var threads: []   // % of each hardware thread: one block each, or none
            property real value: -1
            property color color: PlasmaCore.Theme.highlightColor
            spacing: PlasmaCore.Units.smallSpacing

            Item {
                Layout.alignment: Qt.AlignHCenter
                implicitWidth: PlasmaCore.Units.gridUnit * 4
                implicitHeight: implicitWidth

                property real shown: Math.max(0, Math.min(100, gauge.value))
                Behavior on shown { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                onShownChanged: ring.requestPaint()

                Canvas {
                    id: ring
                    anchors.fill: parent
                    antialiasing: true
                    onWidthChanged: requestPaint()
                    property color trackColor: root.withAlpha(PlasmaCore.Theme.textColor, 0.12)
                    property color fillColor: gauge.color
                    onFillColorChanged: requestPaint()
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.reset()
                        var lw = Math.max(4, width * 0.08)
                        var r = (Math.min(width, height) - lw) / 2
                        var cx = width / 2, cy = height / 2
                        var start = 0.75 * Math.PI, sweep = 1.5 * Math.PI
                        ctx.lineCap = "round"
                        ctx.lineWidth = lw
                        ctx.strokeStyle = trackColor
                        ctx.beginPath()
                        ctx.arc(cx, cy, r, start, start + sweep, false)
                        ctx.stroke()
                        var f = parent.shown / 100
                        if (f > 0.005) {
                            ctx.strokeStyle = fillColor
                            ctx.beginPath()
                            ctx.arc(cx, cy, r, start, start + sweep * f, false)
                            ctx.stroke()
                        }
                    }
                }

                Row {
                    anchors.centerIn: parent
                    PlasmaComponents3.Label {
                        id: bigNum
                        text: root.num(gauge.value)
                        font.pixelSize: PlasmaCore.Theme.defaultFont.pixelSize * 1.6
                        font.weight: Font.DemiBold
                    }
                    PlasmaComponents3.Label {
                        text: "%"
                        font: PlasmaCore.Theme.smallestFont
                        opacity: 0.6
                        anchors.baseline: bigNum.baseline
                    }
                }
            }

            PlasmaComponents3.Label {
                Layout.alignment: Qt.AlignHCenter
                text: gauge.label
                font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                font.letterSpacing: 0.8
                opacity: 0.6
            }
            PlasmaComponents3.Label {
                Layout.alignment: Qt.AlignHCenter
                visible: gauge.detail !== ""
                text: gauge.detail
                font: PlasmaCore.Theme.smallestFont
                opacity: 0.8
            }

            // one block per hardware thread, colored like the usage bars; a single surface
            Canvas {
                id: blocks
                readonly property real unit: PlasmaCore.Units.gridUnit / 18
                readonly property var lay: root.threadBlockLayout(gauge.threads.length,
                                           PlasmaCore.Units.gridUnit * 4, PlasmaCore.Units.gridUnit * 5.5, unit)
                visible: gauge.threads.length > 0
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: PlasmaCore.Units.gridUnit * 4
                Layout.preferredHeight: lay.height
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onVisibleChanged: if (visible) requestPaint()
                Connections {
                    target: gauge
                    onThreadsChanged: if (blocks.visible) blocks.requestPaint()
                }
                Connections {
                    target: PlasmaCore.Theme
                    onThemeChanged: if (blocks.visible) blocks.requestPaint()
                }
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var t = gauge.threads, L = lay
                    var step = L.size + L.gap, x0 = Math.round((width - L.width) / 2)
                    // below 1 % (or no data yet) the block is hollow: a 1 px outline of the same
                    // outer size, on whole pixels so that it stays sharp
                    var hollow = root.withAlpha(PlasmaCore.Theme.textColor, 0.35)
                    var rad = L.size > 5 ? 1.5 : 0.5
                    ctx.lineWidth = 1
                    for (var i = 0; i < t.length; i++) {
                        var bx = x0 + (i % L.cols) * step, by = Math.floor(i / L.cols) * step
                        ctx.beginPath()
                        if (t[i] >= 1) {
                            ctx.fillStyle = root.usageColor(t[i])
                            ctx.roundedRect(bx, by, L.size, L.size, rad, rad)
                            ctx.fill()
                        } else {
                            ctx.strokeStyle = hollow
                            ctx.roundedRect(bx + 0.5, by + 0.5, L.size - 1, L.size - 1, rad, rad)
                            ctx.stroke()
                        }
                    }
                }
            }
        }

        // area sparkline of a history (one or two series, single y-axis).
        // maxValue > 0: fixed scale (percent); 0: auto-scale to the peak.
        component Sparkline: Item {
            id: spark
            property var values: []
            property var values2: []
            property color color: PlasmaCore.Theme.highlightColor
            property color color2: PlasmaCore.Theme.highlightColor
            property real maxValue: 100
            property real minScale: 1
            property string caption
            // CPU graph: a button on the legend line swaps the curve for one mini graph per thread
            property bool canToggle: false
            property bool threadMode: false
            property var threads: []   // history of each thread (percent, oldest first)
            signal toggled()
            readonly property real chartMax: {
                if (maxValue > 0) return maxValue
                var m = minScale, all = values.concat(values2)
                for (var i = 0; i < all.length; i++) m = Math.max(m, all[i])
                return m * 1.1
            }
            // a hidden surface is not redrawn: it is when it comes back
            onValuesChanged: if (canvas.visible) canvas.requestPaint()
            onValues2Changed: if (canvas.visible) canvas.requestPaint()
            onThreadsChanged: if (threadGrid.visible) threadGrid.requestPaint()

            PlasmaComponents3.Label {
                id: capLabel
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: toggle.visible ? toggle.left : parent.right
                text: spark.caption
                elide: Text.ElideRight
                font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                font.letterSpacing: 0.6
                opacity: 0.6
            }

            // taller than the text but not than the gap around it: the graph doesn't move
            PlasmaComponents3.ToolButton {
                id: toggle
                visible: spark.canToggle
                anchors.right: parent.right
                anchors.verticalCenter: capLabel.verticalCenter
                width: height
                height: capLabel.height + PlasmaCore.Units.smallSpacing * 2
                padding: 0
                highlighted: spark.threadMode
                icon.name: "view-grid"
                icon.width: PlasmaCore.Units.iconSizes.small
                icon.height: PlasmaCore.Units.iconSizes.small
                onClicked: spark.toggled()
                PlasmaComponents3.ToolTip.text: spark.threadMode ? "Afficher le total" : "Afficher chaque thread"
                PlasmaComponents3.ToolTip.visible: hovered
                PlasmaComponents3.ToolTip.delay: 400
            }

            Canvas {
                id: canvas
                anchors.top: capLabel.bottom
                anchors.topMargin: PlasmaCore.Units.smallSpacing
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                antialiasing: true
                visible: !spark.threadMode
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onVisibleChanged: if (visible) requestPaint()
                property color grid: root.withAlpha(PlasmaCore.Theme.textColor, 0.10)

                function drawSeries(ctx, v, c, w, h, pad) {
                    if (!v || v.length < 2) return
                    var step = w / (root.historyLength - 1)
                    var x0 = w - (v.length - 1) * step
                    var sc = spark.chartMax
                    function yOf(p) { return pad + (h - 2 * pad) * (1 - Math.max(0, Math.min(sc, p)) / sc) }

                    ctx.beginPath()
                    ctx.moveTo(x0, h)
                    root.tracePath(ctx, v, x0, step, yOf, true)
                    ctx.lineTo(w, h)
                    ctx.closePath()
                    var grad = ctx.createLinearGradient(0, 0, 0, h)
                    grad.addColorStop(0, Qt.rgba(c.r, c.g, c.b, 0.30))
                    grad.addColorStop(1, Qt.rgba(c.r, c.g, c.b, 0.02))
                    ctx.fillStyle = grad
                    ctx.fill()

                    ctx.beginPath()
                    root.tracePath(ctx, v, x0, step, yOf, false)
                    ctx.lineWidth = 2
                    ctx.lineJoin = "round"
                    ctx.strokeStyle = c
                    ctx.stroke()
                }

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var w = width, h = height, pad = 1
                    // recessive gridlines at 0 / 50 / 100 % of the scale
                    ctx.strokeStyle = grid
                    ctx.lineWidth = 1
                    for (var g = 0; g <= 2; g++) {
                        var gy = Math.round(pad + (h - 2 * pad) * g / 2) + 0.5
                        ctx.beginPath(); ctx.moveTo(0, gy); ctx.lineTo(w, gy); ctx.stroke()
                    }
                    drawSeries(ctx, spark.values, spark.color, w, h, pad)
                    drawSeries(ctx, spark.values2, spark.color2, w, h, pad)
                }
            }

            // all the threads on one surface: fixed 0-100 % scale, the color of each curve
            // follows the last value of its thread
            Canvas {
                id: threadGrid
                anchors.fill: canvas
                antialiasing: true
                visible: spark.threadMode
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                onVisibleChanged: if (visible) requestPaint()
                Connections {
                    target: PlasmaCore.Theme
                    onThemeChanged: if (threadGrid.visible) threadGrid.requestPaint()
                }

                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    var hs = spark.threads, n = hs.length
                    if (n === 0) return
                    var gap = Math.max(1, Math.round(2 * PlasmaCore.Units.gridUnit / 18))
                    var cols = root.threadGridColumns(n, width, height, gap)
                    var rows = Math.ceil(n / cols)
                    var cw = (width - (cols - 1) * gap) / cols, ch = (height - (rows - 1) * gap) / rows
                    var back = root.withAlpha(PlasmaCore.Theme.textColor, 0.06)
                    var none = root.withAlpha(PlasmaCore.Theme.textColor, 0.15)
                    var pad = 1
                    for (var i = 0; i < n; i++) {
                        // pixel-aligned cell
                        var c = i % cols, r = Math.floor(i / cols)
                        var x = Math.round(c * (cw + gap)), y = Math.round(r * (ch + gap))
                        var w = Math.round(c * (cw + gap) + cw) - x, h = Math.round(r * (ch + gap) + ch) - y
                        ctx.fillStyle = back
                        ctx.fillRect(x, y, w, h)

                        var v = hs[i]
                        if (v.length < 2) continue
                        var col = v[v.length - 1] >= 0 ? root.usageColor(v[v.length - 1]) : none
                        var step = w / (root.historyLength - 1)
                        var x0 = x + w - (v.length - 1) * step
                        var yOf = function (p) { return y + pad + (h - 2 * pad) * (1 - Math.max(0, Math.min(100, p)) / 100) }
                        ctx.beginPath()
                        ctx.moveTo(x0, y + h)
                        root.tracePath(ctx, v, x0, step, yOf, true)
                        ctx.lineTo(x + w, y + h)
                        ctx.closePath()
                        ctx.fillStyle = Qt.rgba(col.r, col.g, col.b, 0.25)
                        ctx.fill()

                        ctx.beginPath()
                        root.tracePath(ctx, v, x0, step, yOf, false)
                        ctx.lineWidth = 1
                        ctx.lineJoin = "round"
                        ctx.strokeStyle = col
                        ctx.stroke()
                    }
                }
            }
        }

        // network: legend + current rate for one direction
        component RateStat: ColumnLayout {
            id: stat
            property string label
            property color markColor
            property real value: -1
            spacing: 0
            Row {
                spacing: PlasmaCore.Units.smallSpacing * 1.5
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8; height: 8; radius: 2
                    color: stat.markColor
                }
                PlasmaComponents3.Label {
                    text: stat.label
                    font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                    font.letterSpacing: 0.8
                    opacity: 0.6
                }
            }
            Row {
                spacing: PlasmaCore.Units.smallSpacing
                PlasmaComponents3.Label {
                    id: statNum
                    text: root.rateNum(stat.value)
                    font.pixelSize: PlasmaCore.Theme.defaultFont.pixelSize * 1.6
                    font.weight: Font.DemiBold
                }
                PlasmaComponents3.Label {
                    text: root.rateUnit(stat.value)
                    font: PlasmaCore.Theme.smallestFont
                    opacity: 0.6
                    anchors.baseline: statNum.baseline
                }
            }
        }

        // storage: one row per local filesystem
        component DiskCard: Rectangle {
            Layout.fillWidth: true
            implicitHeight: diskBody.implicitHeight + PlasmaCore.Units.largeSpacing * 2
            radius: PlasmaCore.Units.smallSpacing * 2
            color: root.withAlpha(PlasmaCore.Theme.textColor, 0.04)
            border.width: 1
            border.color: root.withAlpha(PlasmaCore.Theme.textColor, 0.08)

            ColumnLayout {
                id: diskBody
                anchors.fill: parent
                anchors.margins: PlasmaCore.Units.largeSpacing
                spacing: PlasmaCore.Units.smallSpacing * 2

                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: PlasmaCore.Units.smallSpacing
                    spacing: PlasmaCore.Units.smallSpacing * 2
                    PlasmaComponents3.Label {
                        text: "Stockage"
                        font.weight: Font.DemiBold
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: {
                            var n = root.popupDisks.length
                            return n + (n > 1 ? " éléments suivis" : " élément suivi")
                        }
                        elide: Text.ElideRight
                        opacity: 0.6
                        font: PlasmaCore.Theme.smallestFont
                    }
                }

                Repeater {
                    model: root.popupDisks
                    delegate: RowLayout {
                        id: diskRow
                        readonly property bool hasPct: modelData.pct >= 0
                        Layout.fillWidth: true
                        spacing: PlasmaCore.Units.largeSpacing
                        PlasmaComponents3.Label {
                            Layout.preferredWidth: PlasmaCore.Units.gridUnit * 5
                            text: modelData.label
                            elide: Text.ElideMiddle
                            PlasmaComponents3.ToolTip.text: modelData.label
                                + (modelData.kind !== "folder" ? ""
                                   : modelData.base === "quota" ? " (taille du dossier / quota)"
                                   : modelData.base === "disk" ? " (taille du dossier / taille du disque)"
                                   : " (taille du dossier)")
                            PlasmaComponents3.ToolTip.visible: rowHover.containsMouse
                            MouseArea { id: rowHover; anchors.fill: parent; hoverEnabled: true }
                        }
                        // a folder without capacity yet (old cache, df failed): no track, just the size
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            implicitHeight: 6
                            radius: 3
                            color: root.withAlpha(PlasmaCore.Theme.textColor, diskRow.hasPct ? 0.12 : 0)
                            Rectangle {
                                visible: diskRow.hasPct
                                height: parent.height
                                radius: 3
                                width: Math.max(height, parent.width * Math.min(100, modelData.pct) / 100)
                                color: root.usageColor(modelData.pct)
                            }
                        }
                        Row {
                            Layout.preferredWidth: PlasmaCore.Units.gridUnit * 6
                            layoutDirection: Qt.RightToLeft
                            PlasmaComponents3.Label {
                                text: modelData.state !== "ok" ? ""
                                      : modelData.total > 0 ? " / " + root.sizeText(modelData.total)
                                      : " " + (root.diskUnitTio(modelData.size) ? "Tio" : "Gio")
                                font: PlasmaCore.Theme.smallestFont
                                opacity: 0.6
                                anchors.baseline: diskUsed.baseline
                            }
                            PlasmaComponents3.Label {
                                id: diskUsed
                                text: modelData.state === "pending" ? "calcul…"
                                      : modelData.state === "error" ? "indisponible"
                                      : root.sizeNum(modelData.size, modelData.total > 0 ? modelData.total : modelData.size)
                                opacity: modelData.state === "ok" ? 1 : 0.6
                            }
                        }
                        PlasmaComponents3.Label {
                            Layout.preferredWidth: PlasmaCore.Units.gridUnit * 2
                            horizontalAlignment: Text.AlignRight
                            text: diskRow.hasPct ? Math.round(modelData.pct) + " %" : ""
                            font.weight: Font.DemiBold
                        }
                    }
                }
            }
        }

        component NetCard: Rectangle {
            id: netCard
            Layout.fillWidth: true
            implicitHeight: netBody.implicitHeight + PlasmaCore.Units.largeSpacing * 2
            radius: PlasmaCore.Units.smallSpacing * 2
            color: root.withAlpha(PlasmaCore.Theme.textColor, 0.04)
            border.width: 1
            border.color: root.withAlpha(PlasmaCore.Theme.textColor, 0.08)

            ColumnLayout {
                id: netBody
                anchors.fill: parent
                anchors.margins: PlasmaCore.Units.largeSpacing
                spacing: PlasmaCore.Units.largeSpacing

                RowLayout {
                    Layout.fillWidth: true
                    spacing: PlasmaCore.Units.smallSpacing * 2
                    PlasmaComponents3.Label {
                        text: "Réseau"
                        font.weight: Font.DemiBold
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: root.netIf || "aucune interface"
                        elide: Text.ElideRight
                        opacity: 0.6
                        font: PlasmaCore.Theme.smallestFont
                    }
                    PlasmaComponents3.Label {
                        text: "depuis le démarrage  ↓ " + root.bytesText(root.netRxTotal)
                              + "  ↑ " + root.bytesText(root.netTxTotal)
                        font: PlasmaCore.Theme.smallestFont
                        opacity: 0.6
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: PlasmaCore.Units.largeSpacing * 1.5
                    ColumnLayout {
                        // same width as the two gauges, so the charts line up
                        Layout.preferredWidth: PlasmaCore.Units.gridUnit * 8 + PlasmaCore.Units.largeSpacing * 1.5
                        Layout.alignment: Qt.AlignTop
                        spacing: PlasmaCore.Units.largeSpacing
                        RateStat { label: "RÉCEPTION"; markColor: root.downColor; value: root.netDown }
                        RateStat { label: "ENVOI"; markColor: root.upColor; value: root.netUp }
                    }
                    Sparkline {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumWidth: PlasmaCore.Units.gridUnit * 6
                        values: root.downHistory
                        values2: root.upHistory
                        color: root.downColor
                        color2: root.upColor
                        maxValue: 0
                        minScale: 10000   // 10 Ko/s, so idle noise stays flat
                        caption: "Débit · " + full.historySpan
                                 + (values.length >= 2 ? " · échelle " + root.rateText(chartMax) : "")
                    }
                }
            }
        }

        component Card: Rectangle {
            id: card
            property string title
            property string subtitle
            property real temp: -1
            property bool showTemp: true
            property real power: -1
            property bool showPower: false
            property bool aVisible: true
            property string aLabel
            property real aValue: -1
            property string aDetail
            property bool bVisible: true
            property string bLabel
            property real bValue: -1
            property string bDetail
            property color bColor: root.usageColor(bValue)
            property var history: []
            property string historyCaption
            property var aThreads: []           // % of each hardware thread: blocks under the first gauge
            property var threadHistory: []      // histories of the threads, for the mini graphs
            property bool threadToggle: false   // shows the button that swaps the curve for the mini graphs
            property bool threadView: false
            property string procTarget   // "cpu" / "gpu": shows the arrow that opens the process panel

            Layout.fillWidth: true
            implicitHeight: body.implicitHeight + PlasmaCore.Units.largeSpacing * 2
            radius: PlasmaCore.Units.smallSpacing * 2
            color: root.withAlpha(PlasmaCore.Theme.textColor, 0.04)
            border.width: 1
            border.color: root.withAlpha(PlasmaCore.Theme.textColor, 0.08)

            ColumnLayout {
                id: body
                anchors.fill: parent
                anchors.margins: PlasmaCore.Units.largeSpacing
                spacing: PlasmaCore.Units.largeSpacing

                // header: title, subtitle, power pill, temperature pill
                RowLayout {
                    Layout.fillWidth: true
                    spacing: PlasmaCore.Units.smallSpacing * 2
                    PlasmaComponents3.Label {
                        text: card.title
                        font.weight: Font.DemiBold
                    }
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: card.subtitle
                        elide: Text.ElideRight
                        opacity: 0.6
                        font: PlasmaCore.Theme.smallestFont
                    }
                    Rectangle {
                        visible: card.showPower
                        implicitWidth: powerLabel.implicitWidth + PlasmaCore.Units.smallSpacing * 4
                        implicitHeight: powerLabel.implicitHeight + PlasmaCore.Units.smallSpacing
                        radius: height / 2
                        color: root.withAlpha(PlasmaCore.Theme.textColor, 0.07)
                        PlasmaComponents3.Label {
                            id: powerLabel
                            anchors.centerIn: parent
                            text: root.powerText(card.power)
                            font.weight: Font.DemiBold
                        }
                    }
                    Rectangle {
                        visible: card.showTemp
                        implicitWidth: pill.implicitWidth + PlasmaCore.Units.smallSpacing * 4
                        implicitHeight: pill.implicitHeight + PlasmaCore.Units.smallSpacing
                        radius: height / 2
                        color: card.temp >= root.warnTemp
                               ? root.withAlpha(root.tempDotColor(card.temp), 0.18)
                               : root.withAlpha(PlasmaCore.Theme.textColor, 0.07)
                        Row {
                            id: pill
                            anchors.centerIn: parent
                            spacing: PlasmaCore.Units.smallSpacing * 1.5
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 7; height: 7; radius: 3.5
                                color: root.tempDotColor(card.temp)
                            }
                            PlasmaComponents3.Label {
                                text: root.tempText(card.temp)
                                font.weight: Font.DemiBold
                            }
                        }
                    }
                    // opens / closes the process list of this card
                    PlasmaComponents3.ToolButton {
                        id: procArrow
                        readonly property bool open: root.procMode === card.procTarget
                        visible: card.procTarget !== ""
                        Layout.preferredWidth: height
                        Layout.preferredHeight: PlasmaCore.Units.iconSizes.smallMedium + PlasmaCore.Units.smallSpacing * 2
                        Layout.alignment: Qt.AlignVCenter
                        icon.name: open ? "go-previous" : "go-next"
                        icon.width: PlasmaCore.Units.iconSizes.small
                        icon.height: PlasmaCore.Units.iconSizes.small
                        onClicked: root.setProcMode(card.procTarget)
                        PlasmaComponents3.ToolTip.text: (open ? "Masquer" : "Afficher") + " les processus " + card.procTarget.toUpperCase()
                        PlasmaComponents3.ToolTip.visible: hovered
                        PlasmaComponents3.ToolTip.delay: 400
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: PlasmaCore.Units.largeSpacing * 1.5
                    Gauge {
                        Layout.alignment: Qt.AlignTop
                        visible: card.aVisible
                        label: card.aLabel; value: card.aValue; detail: card.aDetail; threads: card.aThreads
                        color: root.usageColor(card.aValue)
                    }
                    Gauge {
                        Layout.alignment: Qt.AlignTop
                        visible: card.bVisible
                        label: card.bLabel; value: card.bValue; detail: card.bDetail
                        color: card.bColor
                    }
                    Sparkline {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumWidth: PlasmaCore.Units.gridUnit * 6
                        values: card.history
                        caption: card.historyCaption
                        canToggle: card.threadToggle
                        threadMode: card.threadView
                        threads: card.threadHistory
                        onToggled: root.toggleThreadGraph()
                    }
                }
            }
        }

        // side panel: busiest processes of the CPU or of the GPU
        component ProcPanel: Rectangle {
            id: panel
            readonly property bool isCpu: root.procMode === "cpu"
            readonly property var sel: isCpu ? root.procRow(root.selectedPid) : null
            readonly property real pidWidth: PlasmaCore.Units.gridUnit * 3.6
            readonly property real useWidth: PlasmaCore.Units.gridUnit * 3.4
            readonly property real memWidth: PlasmaCore.Units.gridUnit * 4.2
            // room for the scroll bar plus a gap, so the last column never touches it;
            // used by the header and the rows alike, so they stay aligned
            readonly property real scrollRoom: procBar.implicitWidth + PlasmaCore.Units.smallSpacing * 3
            // the height follows the cards (preferred 0, then it fills the row)
            Layout.preferredWidth: PlasmaCore.Units.gridUnit * 22
            Layout.minimumWidth: PlasmaCore.Units.gridUnit * 18
            Layout.preferredHeight: 0
            Layout.minimumHeight: 0
            Layout.fillHeight: true
            radius: PlasmaCore.Units.smallSpacing * 2
            color: root.withAlpha(PlasmaCore.Theme.textColor, 0.04)
            border.width: 1
            border.color: root.withAlpha(PlasmaCore.Theme.textColor, 0.08)

            function memText(mib) {
                return mib >= 1024 ? (mib / 1024).toFixed(1) + " Gio" : Math.round(mib) + " Mio"
            }
            // message instead of the list: no data yet, nothing to show
            readonly property string message: root.procKind === "" ? "Chargement…"
                : root.procKind === "none" ? "Aucune donnée par processus pour ce GPU"
                : root.procRows.length === 0 ? "Aucun processus" : ""

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: PlasmaCore.Units.largeSpacing
                spacing: PlasmaCore.Units.smallSpacing * 2

                PlasmaComponents3.Label {
                    text: panel.isCpu ? "Processus CPU" : "Processus GPU"
                    font.weight: Font.DemiBold
                }

                // column titles
                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: PlasmaCore.Units.smallSpacing * 2
                    Layout.rightMargin: panel.scrollRoom
                    spacing: PlasmaCore.Units.smallSpacing * 2
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: "Nom"
                        font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                        font.letterSpacing: 0.6
                        opacity: 0.6
                    }
                    PlasmaComponents3.Label {
                        Layout.preferredWidth: panel.pidWidth
                        horizontalAlignment: Text.AlignRight
                        text: "PID"
                        font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                        font.letterSpacing: 0.6
                        opacity: 0.6
                    }
                    PlasmaComponents3.Label {
                        Layout.preferredWidth: panel.useWidth
                        horizontalAlignment: Text.AlignRight
                        text: panel.isCpu ? "CPU %" : "GPU %"
                        font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                        font.letterSpacing: 0.6
                        opacity: 0.6
                    }
                    PlasmaComponents3.Label {
                        Layout.preferredWidth: panel.memWidth
                        horizontalAlignment: Text.AlignRight
                        text: panel.isCpu ? "Mémoire" : "VRAM"
                        font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                        font.letterSpacing: 0.6
                        opacity: 0.6
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 1
                    color: root.withAlpha(PlasmaCore.Theme.textColor, 0.10)
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 0

                    ListView {
                        id: procList
                        anchors.fill: parent
                        clip: true
                        visible: panel.message === ""
                        model: procModel
                        boundsBehavior: Flickable.StopAtBounds
                        PlasmaComponents3.ScrollBar.vertical: PlasmaComponents3.ScrollBar { id: procBar }
                        delegate: Rectangle {
                            id: rowItem
                            readonly property bool selected: panel.isCpu && model.pid === root.selectedPid
                            width: procList.width
                            height: PlasmaCore.Units.gridUnit * 1.5
                            radius: PlasmaCore.Units.smallSpacing
                            color: selected ? root.withAlpha(PlasmaCore.Theme.highlightColor, 0.30)
                                            : root.withAlpha(PlasmaCore.Theme.textColor, rowMouse.containsMouse ? 0.07 : 0)

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: PlasmaCore.Units.smallSpacing * 2
                                anchors.rightMargin: panel.scrollRoom
                                spacing: PlasmaCore.Units.smallSpacing * 2
                                // processes of the system or of another user are dimmed
                                opacity: model.killable ? 1 : 0.5
                                PlasmaComponents3.Label {
                                    Layout.fillWidth: true
                                    text: model.pname
                                    elide: Text.ElideRight
                                }
                                PlasmaComponents3.Label {
                                    Layout.preferredWidth: panel.pidWidth
                                    horizontalAlignment: Text.AlignRight
                                    text: model.pid
                                    font: PlasmaCore.Theme.smallestFont
                                    opacity: 0.7
                                }
                                PlasmaComponents3.Label {
                                    Layout.preferredWidth: panel.useWidth
                                    horizontalAlignment: Text.AlignRight
                                    text: model.use.toFixed(panel.isCpu ? 1 : 0)
                                }
                                PlasmaComponents3.Label {
                                    Layout.preferredWidth: panel.memWidth
                                    horizontalAlignment: Text.AlignRight
                                    text: panel.memText(model.mem)
                                    opacity: 0.8
                                }
                            }

                            MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.selectProc(model.pid)
                                PlasmaComponents3.ToolTip.visible: containsMouse
                                PlasmaComponents3.ToolTip.delay: 500
                                PlasmaComponents3.ToolTip.text: (model.command || model.pname)
                                    + (model.killable ? "" : "\nProcessus système ou d'un autre utilisateur")
                            }
                        }
                    }

                    PlasmaComponents3.Label {
                        anchors.centerIn: parent
                        width: parent.width - PlasmaCore.Units.largeSpacing * 2
                        visible: panel.message !== ""
                        text: panel.message
                        wrapMode: Text.Wrap
                        horizontalAlignment: Text.AlignHCenter
                        opacity: 0.6
                    }
                }

                // end of task: CPU list only
                Rectangle {
                    visible: panel.isCpu
                    Layout.fillWidth: true
                    implicitHeight: 1
                    color: root.withAlpha(PlasmaCore.Theme.textColor, 0.10)
                }
                RowLayout {
                    visible: panel.isCpu
                    Layout.fillWidth: true
                    spacing: PlasmaCore.Units.smallSpacing * 2
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        text: panel.sel ? panel.sel.pname + " · PID " + panel.sel.pid : "Aucun processus sélectionné"
                        elide: Text.ElideRight
                        opacity: panel.sel ? 1 : 0.6
                    }
                    PlasmaComponents3.Button {
                        readonly property bool forced: panel.sel !== null && root.killForced.indexOf(panel.sel.pid) >= 0
                        text: forced ? "Forcer l'arrêt" : "Fin de tâche"
                        icon.name: "process-stop"
                        enabled: !!panel.sel && root.canKill(panel.sel.pid) && !root.isWaiting(panel.sel.pid)
                        onClicked: root.killSelected()
                    }
                }
                PlasmaComponents3.Label {
                    visible: panel.isCpu
                    Layout.fillWidth: true
                    // one line is always reserved, so the list doesn't jump
                    text: root.killStatus || " "
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    font: PlasmaCore.Theme.smallestFont
                    color: root.killFailed ? PlasmaCore.Theme.negativeTextColor : PlasmaCore.Theme.textColor
                    opacity: root.killFailed ? 1 : 0.7
                }
            }
        }

        readonly property string historySpan: {
            var s = Math.round(root.historyLength * root.updateInterval / 1000)
            return s >= 60 ? Math.round(s / 60) + " min" : s + " s"
        }

        // detach into a window (the popup closes)
        RowLayout {
            visible: !full.windowMode
            Layout.fillWidth: true
            Layout.bottomMargin: -PlasmaCore.Units.smallSpacing
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: "SYSTEM MONITOR"
                font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                font.letterSpacing: 0.8
                opacity: 0.45
            }
            PlasmaComponents3.ToolButton {
                Layout.preferredWidth: height
                icon.name: "window-new"
                icon.width: PlasmaCore.Units.iconSizes.small
                icon.height: PlasmaCore.Units.iconSizes.small
                onClicked: root.detach()
                PlasmaComponents3.ToolTip.text: "Détacher dans une fenêtre"
                PlasmaComponents3.ToolTip.visible: hovered
                PlasmaComponents3.ToolTip.delay: 400
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: full.spacing

            ColumnLayout {
                Layout.alignment: Qt.AlignTop
                Layout.fillWidth: true
                Layout.minimumWidth: PlasmaCore.Units.gridUnit * 22
                Layout.preferredWidth: PlasmaCore.Units.gridUnit * 24
                spacing: full.spacing

                Card {
                    id: cpuCard
                    visible: root.popupCpu || root.popupRam
                    procTarget: "cpu"
                    showTemp: root.popupCpuTemp
                    showPower: root.popupCpuPower
                    power: root.cpuPower
                    subtitle: root.cpuName
                    title: "Processeur"
                    temp: root.cpuTemp
                    aVisible: root.popupCpu
                    aLabel: "CPU"
                    aValue: root.cpuPct
                    aDetail: root.popupFreq ? root.freqDetail(root.cpuFreq) : " "
                    aThreads: root.popupThreads ? root.threadPct : []
                    bVisible: root.popupRam
                    bLabel: "RAM"
                    bValue: root.ramPct
                    bDetail: root.ramDetail()
                    history: root.cpuHistory
                    threadHistory: root.threadHistory
                    threadToggle: root.threadsTotal > 0
                    threadView: root.threadGraph && root.threadHistory.length > 0
                    historyCaption: (threadView ? "Threads · " : "CPU · ") + full.historySpan
                }

                Card {
                    id: gpuCard
                    visible: root.popupGpu || root.popupVram
                    procTarget: "gpu"
                    showTemp: root.popupGpuTemp && root.gpuAvail
                    showPower: root.popupGpuPower && root.gpuAvail
                    power: root.gpuPower
                    title: "Carte graphique"
                    subtitle: root.gpuName
                    temp: root.gpuTemp
                    aVisible: root.popupGpu
                    aLabel: "GPU"
                    aValue: root.gpuPct
                    aDetail: root.popupFreq ? root.freqDetail(root.gpuFreq) : " "
                    bVisible: root.popupVram
                    bLabel: "VRAM"
                    bValue: root.vramPct
                    bDetail: root.vramDetail()
                    history: root.gpuHistory
                    historyCaption: "GPU · " + full.historySpan
                }

                NetCard { visible: root.popupNet }

                DiskCard { visible: root.popupDisk }
            }

            ProcPanel { visible: full.sideOpen }
        }
    }
}
