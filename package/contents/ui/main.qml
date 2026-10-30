import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore
import org.kde.plasma.components 3.0 as PlasmaComponents3

Item {
    id: root

    Plasmoid.preferredRepresentation: Plasmoid.compactRepresentation

    // ---- configuration ----
    readonly property int updateInterval: plasmoid.configuration.updateInterval
    readonly property string gpuSource: plasmoid.configuration.gpuSource
    readonly property bool showCpu: plasmoid.configuration.showCpu
    readonly property bool showGpu: plasmoid.configuration.showGpu
    readonly property bool showRam: plasmoid.configuration.showRam
    readonly property bool showVram: plasmoid.configuration.showVram
    readonly property bool showNet: plasmoid.configuration.showNet
    // interface name is passed to the shell: keep only safe characters
    readonly property string netInterface: (plasmoid.configuration.netInterface || "").replace(/[^A-Za-z0-9_.:@-]/g, "")
    readonly property bool showTemps: plasmoid.configuration.showTemperatures
    readonly property bool autoHide: plasmoid.configuration.autoHide
    readonly property int warnTemp: plasmoid.configuration.warningTemp
    readonly property int critTemp: plasmoid.configuration.criticalTemp

    // ---- data ----
    property real cpuPct: -1
    property real cpuTemp: -1
    property real cpuFreq: -1     // MHz, average over all threads
    property real gpuFreq: -1     // MHz, graphics clock
    property real gpuPct: -1
    property real gpuTemp: -1
    property real memTotal: 0     // MiB
    property real memUsed: 0      // MiB
    property real vramTotal: -1   // MiB
    property real vramUsed: -1    // MiB
    property string gpuName: ""
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
    property int cpuTempMisses: 0
    property int gpuTempMisses: 0
    function avail(misses) { return !autoHide || misses < missLimit }

    // what is actually displayed: user choice AND data available
    readonly property bool gpuOn: showGpu && avail(gpuMisses)
    readonly property bool vramOn: showVram && avail(gpuMisses) && avail(vramMisses)
    readonly property bool netOn: showNet && avail(netMisses)
    readonly property bool cpuTempOn: showTemps && avail(cpuTempMisses)
    readonly property bool gpuTempOn: showTemps && avail(gpuTempMisses)
    readonly property bool systemGroupOn: showCpu || showRam
    readonly property bool gpuGroupOn: gpuOn || vramOn

    // usage history for the popup sparklines (percent, oldest first)
    readonly property int historyLength: 60
    property var cpuHistory: []
    property var gpuHistory: []
    property var downHistory: []
    property var upHistory: []

    readonly property real ramPct: memTotal > 0 ? 100 * memUsed / memTotal : -1
    readonly property real vramPct: vramTotal > 0 && vramUsed >= 0 ? 100 * vramUsed / vramTotal : -1

    readonly property string scriptPath: Qt.resolvedUrl("../scripts/sysstats.sh").toString().replace(/^file:\/\//, "")
    readonly property string command: "bash '" + scriptPath + "' " + gpuSource + " '" + netInterface + "'"

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
        cpuTemp = parseFloat(d.cpuTemp)
        cpuFreq = d.cpuFreq !== undefined ? parseFloat(d.cpuFreq) : -1
        gpuFreq = d.gpuFreq !== undefined ? parseFloat(d.gpuFreq) : -1
        memTotal = parseFloat(d.memTotal)
        memUsed = memTotal - parseFloat(d.memAvail)
        gpuPct = parseFloat(d.gpuUse)
        gpuTemp = parseFloat(d.gpuTemp)
        vramUsed = parseFloat(d.vramUsed)
        vramTotal = parseFloat(d.vramTotal)
        gpuName = d.gpuName || ""
        gpuMisses = d.gpuKind ? 0 : gpuMisses + 1
        vramMisses = vramTotal > 0 ? 0 : vramMisses + 1
        cpuTempMisses = valid(cpuTemp) ? 0 : cpuTempMisses + 1
        gpuTempMisses = valid(gpuTemp) ? 0 : gpuTempMisses + 1
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
    function memColor(v) {
        if (v >= 95) return PlasmaCore.Theme.negativeTextColor
        if (v >= 85) return PlasmaCore.Theme.neutralTextColor
        return PlasmaCore.Theme.highlightColor
    }

    function ramDetail() {
        return memTotal > 0 ? gio(memUsed) + " / " + gio(memTotal) + " Gio" : "--"
    }
    function vramDetail() {
        return valid(vramPct) ? gio(vramUsed) + " / " + gio(vramTotal) + " Gio" : "--"
    }
    function freqDetail(mhz) { return valid(mhz) || !autoHide ? ghz(mhz) : " " }
    function ghz(mhz) { return valid(mhz) ? (mhz / 1000).toFixed(2) + " GHz" : "-- GHz" }
    function tempText(v) { return valid(v) ? Math.round(v) + " °C" : "-- °C" }

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
        var f = function (v) { return valid(v) || !autoHide ? " · " + ghz(v) : "" }
        if (showCpu) lines.push("CPU  " + num(cpuPct) + " %" + t(cpuTempOn, cpuTemp) + f(cpuFreq))
        if (showRam) lines.push("RAM  " + num(ramPct) + " % · " + ramDetail())
        if (gpuOn) lines.push("GPU  " + num(gpuPct) + " %" + t(gpuTempOn, gpuTemp) + f(gpuFreq))
        if (vramOn) lines.push("VRAM  " + num(vramPct) + " % · " + vramDetail())
        if (netOn) lines.push("Réseau  ↓ " + rateText(netDown) + " · ↑ " + rateText(netUp))
        return lines.join("\n")
    }

    // ======================================================================
    // Compact representation (panel)
    // ======================================================================
    Plasmoid.compactRepresentation: MouseArea {
        id: compact
        readonly property bool vertical: plasmoid.formFactor === PlasmaCore.Types.Vertical
        // thick panels get the label stacked above the value
        readonly property bool tall: vertical || height >= PlasmaCore.Units.gridUnit * 2.3

        Layout.minimumWidth: vertical ? 0 : grid.implicitWidth
        Layout.preferredWidth: grid.implicitWidth
        Layout.minimumHeight: vertical ? grid.implicitHeight : 0
        Layout.preferredHeight: grid.implicitHeight
        hoverEnabled: true
        onClicked: plasmoid.expanded = !plasmoid.expanded

        TextMetrics { id: tmNum; font: PlasmaCore.Theme.defaultFont; text: "100" }
        TextMetrics { id: tmUnit; font: PlasmaCore.Theme.smallestFont; text: "%" }
        TextMetrics { id: tmTemp; font: PlasmaCore.Theme.defaultFont; text: "100°" }
        TextMetrics { id: tmAmount; font: PlasmaCore.Theme.defaultFont; text: "99.9" }
        TextMetrics { id: tmLabel; font: PlasmaCore.Theme.smallestFont; text: "VRAM" }
        TextMetrics { id: tmRate; font: PlasmaCore.Theme.defaultFont; text: "999" }
        TextMetrics { id: tmRateUnit; font: PlasmaCore.Theme.smallestFont; text: "Mo/s" }

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
                    text: " " + root.rateUnit(rate.value)
                    font: PlasmaCore.Theme.smallestFont
                    opacity: 0.6
                    width: tmRateUnit.width + 3
                    height: rateNum.height
                    verticalAlignment: Text.AlignVCenter
                }
            }
            // keeps the text on the same line as the cells that have a usage bar
            Item { implicitHeight: 2 }
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
                Layout.preferredWidth: compact.tall ? -1 : tmLabel.width + 2
                Layout.preferredHeight: tmRate.height
                Layout.alignment: compact.tall ? Qt.AlignLeft : (Qt.AlignTop | Qt.AlignLeft)
                verticalAlignment: Text.AlignVCenter
            }
            RowLayout {
                spacing: PlasmaCore.Units.smallSpacing * 2
                Rate { arrow: "↓"; arrowColor: root.downColor; value: root.netDown }
                Rate { arrow: "↑"; arrowColor: root.upColor; value: root.netUp }
            }
        }

        component Cell: GridLayout {
            id: cell
            property string label
            property real value: -1
            property color barColor: PlasmaCore.Theme.highlightColor
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
                Layout.preferredWidth: compact.tall ? -1 : tmLabel.width + 2
                Layout.preferredHeight: numLabel.implicitHeight
                Layout.alignment: compact.tall ? Qt.AlignLeft : (Qt.AlignTop | Qt.AlignLeft)
                verticalAlignment: Text.AlignVCenter
            }

            RowLayout {
                spacing: PlasmaCore.Units.smallSpacing * 1.5

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
                        text: " / " + cell.amountTotal
                        opacity: 0.5
                    }
                    PlasmaComponents3.Label {
                        text: " Gio"
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
            opacity: plasmoid.expanded ? 0.10 : (compact.containsMouse ? 0.06 : 0)
            Behavior on opacity { NumberAnimation { duration: 150 } }
        }

        Grid {
            id: grid
            anchors.centerIn: parent
            flow: compact.vertical ? Grid.TopToBottom : Grid.LeftToRight
            rows: compact.vertical ? -1 : 1
            columns: compact.vertical ? 1 : -1
            columnSpacing: PlasmaCore.Units.largeSpacing
            rowSpacing: PlasmaCore.Units.smallSpacing * 2
            verticalItemAlignment: Grid.AlignVCenter
            horizontalItemAlignment: Grid.AlignHCenter
            leftPadding: PlasmaCore.Units.smallSpacing
            rightPadding: PlasmaCore.Units.smallSpacing

            Cell {
                visible: root.showCpu
                label: "CPU"; value: root.cpuPct
                hasTemp: root.cpuTempOn; temp: root.cpuTemp
            }
            Cell {
                visible: root.showRam
                label: "RAM"; value: root.ramPct
                barColor: root.memColor(root.ramPct)
                amount: root.gioShort(root.memTotal > 0 ? root.memUsed : -1)
                amountTotal: root.gioTotal(root.memTotal)
            }

            // separator between the system group and the graphics group
            Rectangle {
                visible: root.systemGroupOn && root.gpuGroupOn
                width: compact.vertical ? compact.width * 0.5 : 1
                height: compact.vertical ? 1 : compact.height * 0.5
                color: PlasmaCore.Theme.textColor
                opacity: 0.18
            }

            Cell {
                visible: root.gpuOn
                label: "GPU"; value: root.gpuPct
                hasTemp: root.gpuTempOn; temp: root.gpuTemp
            }
            Cell {
                visible: root.vramOn
                label: "VRAM"; value: root.vramPct
                barColor: root.memColor(root.vramPct)
                amount: root.gioShort(root.valid(root.vramPct) ? root.vramUsed : -1)
                amountTotal: root.gioTotal(root.vramTotal)
            }

            Rectangle {
                visible: root.netOn && (root.systemGroupOn || root.gpuGroupOn)
                width: compact.vertical ? compact.width * 0.5 : 1
                height: compact.vertical ? 1 : compact.height * 0.5
                color: PlasmaCore.Theme.textColor
                opacity: 0.18
            }

            NetCell { visible: root.netOn }
        }
    }

    // ======================================================================
    // Full representation (popup)
    // ======================================================================
    Plasmoid.fullRepresentation: ColumnLayout {
        id: full
        Layout.minimumWidth: PlasmaCore.Units.gridUnit * 22
        Layout.preferredWidth: PlasmaCore.Units.gridUnit * 24
        Layout.minimumHeight: implicitHeight
        Layout.preferredHeight: implicitHeight
        spacing: PlasmaCore.Units.largeSpacing

        // ring gauge: 270° arc, value in the middle, caption below
        component Gauge: ColumnLayout {
            id: gauge
            property string label
            property string detail
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
            readonly property real chartMax: {
                if (maxValue > 0) return maxValue
                var m = minScale, all = values.concat(values2)
                for (var i = 0; i < all.length; i++) m = Math.max(m, all[i])
                return m * 1.1
            }
            onValuesChanged: canvas.requestPaint()
            onValues2Changed: canvas.requestPaint()

            PlasmaComponents3.Label {
                id: capLabel
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                text: spark.caption
                elide: Text.ElideRight
                font.pixelSize: PlasmaCore.Theme.smallestFont.pixelSize
                font.letterSpacing: 0.6
                opacity: 0.6
            }

            Canvas {
                id: canvas
                anchors.top: capLabel.bottom
                anchors.topMargin: PlasmaCore.Units.smallSpacing
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                antialiasing: true
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()
                property color grid: root.withAlpha(PlasmaCore.Theme.textColor, 0.10)

                function drawSeries(ctx, v, c, w, h, pad) {
                    if (!v || v.length < 2) return
                    var step = w / (root.historyLength - 1)
                    var x0 = w - (v.length - 1) * step
                    var sc = spark.chartMax
                    function yOf(p) { return pad + (h - 2 * pad) * (1 - Math.max(0, Math.min(sc, p)) / sc) }

                    ctx.beginPath()
                    ctx.moveTo(x0, h)
                    for (var i = 0; i < v.length; i++) ctx.lineTo(x0 + i * step, yOf(v[i]))
                    ctx.lineTo(w, h)
                    ctx.closePath()
                    var grad = ctx.createLinearGradient(0, 0, 0, h)
                    grad.addColorStop(0, Qt.rgba(c.r, c.g, c.b, 0.30))
                    grad.addColorStop(1, Qt.rgba(c.r, c.g, c.b, 0.02))
                    ctx.fillStyle = grad
                    ctx.fill()

                    ctx.beginPath()
                    for (var j = 0; j < v.length; j++) {
                        var x = x0 + j * step, y = yOf(v[j])
                        if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
                    }
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
            property bool aVisible: true
            property string aLabel
            property real aValue: -1
            property string aDetail
            property bool bVisible: true
            property string bLabel
            property real bValue: -1
            property string bDetail
            property color bColor: PlasmaCore.Theme.highlightColor
            property var history: []
            property string historyCaption

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

                // header: title, subtitle, temperature pill
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
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: PlasmaCore.Units.largeSpacing * 1.5
                    Gauge {
                        Layout.alignment: Qt.AlignTop
                        visible: card.aVisible
                        label: card.aLabel; value: card.aValue; detail: card.aDetail
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
                    }
                }
            }
        }

        readonly property string historySpan: {
            var s = Math.round(root.historyLength * root.updateInterval / 1000)
            return s >= 60 ? Math.round(s / 60) + " min" : s + " s"
        }

        Card {
            visible: root.systemGroupOn
            showTemp: root.cpuTempOn
            title: "Processeur"
            temp: root.cpuTemp
            aVisible: root.showCpu
            aLabel: "CPU"
            aValue: root.cpuPct
            aDetail: root.freqDetail(root.cpuFreq)
            bVisible: root.showRam
            bLabel: "RAM"
            bValue: root.ramPct
            bDetail: root.ramDetail()
            bColor: root.memColor(root.ramPct)
            history: root.cpuHistory
            historyCaption: "CPU · " + full.historySpan
        }

        Card {
            visible: root.gpuGroupOn
            showTemp: root.gpuTempOn && root.gpuOn
            title: "Carte graphique"
            subtitle: root.gpuName
            temp: root.gpuTemp
            aVisible: root.gpuOn
            aLabel: "GPU"
            aValue: root.gpuPct
            aDetail: root.freqDetail(root.gpuFreq)
            bVisible: root.vramOn
            bLabel: "VRAM"
            bValue: root.vramPct
            bDetail: root.vramDetail()
            bColor: root.memColor(root.vramPct)
            history: root.gpuHistory
            historyCaption: "GPU · " + full.historySpan
        }

        NetCard { visible: root.netOn }
    }
}
