import QtQuick 2.15
import QtQuick.Controls 2.15 as QQC2
import QtQuick.Dialogs 1.3 as Dialogs
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.5 as Kirigami
import org.kde.plasma.core 2.0 as PlasmaCore

ColumnLayout {
    id: page
    spacing: Kirigami.Units.largeSpacing

    property string cfg_diskPrefs
    property string cfg_customPaths
    property alias cfg_folderRefresh: folderRefresh.value

    function parseJson(text, fallback) {
        try { var v = JSON.parse(text); return v === null || v === undefined ? fallback : v }
        catch (e) { return fallback }
    }

    // ---- detected partitions (read live from the data script) ----
    property var detected: []      // [{ mount, used, total }] in KiB
    property var prefs: parseJson(cfg_diskPrefs, {})

    function pref(mount) {
        var p = prefs[mount]
        return { panel: p ? !!p.panel : mount === "/", popup: p ? p.popup !== false : true }
    }
    function setPref(mount, key, value) {
        var all = parseJson(cfg_diskPrefs, {})
        var p = pref(mount)
        p[key] = value
        all[mount] = p
        cfg_diskPrefs = JSON.stringify(all)
    }

    PlasmaCore.DataSource {
        id: lister
        engine: "executable"
        connectedSources: [
            "bash '" + Qt.resolvedUrl("../scripts/sysstats.sh").toString().replace(/^file:\/\//, "") + "' amd"
        ]
        onNewData: {
            var out = data["stdout"] || ""
            var m = out.match(/(?:^|;)disks=([^;]*)/)
            var list = []
            if (m && m[1]) {
                m[1].split("|").forEach(function (e) {
                    var f = e.split(":")
                    if (f.length >= 3)
                        list.push({ mount: f[0], used: parseFloat(f[1]), total: parseFloat(f[1]) + parseFloat(f[2]) })
                })
            }
            page.detected = list
            disconnectSource(sourceName)
        }
    }

    function gio(kib) {
        var g = kib / 1048576
        return g < 99.95 ? g.toFixed(1) : Math.round(g).toString()
    }

    // ---- tracked folders and mount points ----
    property var items: parseJson(cfg_customPaths, [])

    function updateItem(index, key, value) {
        var list = parseJson(cfg_customPaths, [])
        if (index < 0 || index >= list.length) return
        list[index][key] = value
        cfg_customPaths = JSON.stringify(list)
    }
    function addItem() {
        var list = parseJson(cfg_customPaths, [])
        list.push({ kind: "folder", path: "", quota: 0, panel: false, popup: true })
        cfg_customPaths = JSON.stringify(list)
    }
    function removeItem(index) {
        var list = parseJson(cfg_customPaths, [])
        list.splice(index, 1)
        cfg_customPaths = JSON.stringify(list)
    }

    Dialogs.FileDialog {
        id: folderDialog
        property int target: -1
        title: i18n("Choisir un dossier ou un point de montage")
        selectFolder: true
        folder: shortcuts.home
        onAccepted: page.updateItem(target, "path", decodeURIComponent(fileUrl.toString().replace(/^file:\/\//, "")))
    }

    // ======================================================================
    Kirigami.Heading {
        level: 3
        text: i18n("Partitions détectées")
    }
    QQC2.Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        opacity: 0.7
        text: i18n("Partitions locales, sans /boot. Les partages réseau (NFS, SMB) s'ajoutent plus bas comme point de montage.")
    }

    GridLayout {
        columns: 4
        columnSpacing: Kirigami.Units.largeSpacing * 2
        rowSpacing: 0

        QQC2.Label { text: i18n("Point de montage"); font.bold: true }
        QQC2.Label { text: i18n("Occupé"); font.bold: true }
        QQC2.Label { text: i18n("Panneau"); font.bold: true; Layout.alignment: Qt.AlignHCenter }
        QQC2.Label { text: i18n("Popup"); font.bold: true; Layout.alignment: Qt.AlignHCenter }

        Repeater {
            model: page.detected
            delegate: QQC2.Label { Layout.row: index + 1; Layout.column: 0; text: modelData.mount }
        }
        Repeater {
            model: page.detected
            delegate: QQC2.Label {
                Layout.row: index + 1; Layout.column: 1
                opacity: 0.7
                text: page.gio(modelData.used) + " / " + page.gio(modelData.total) + " Gio"
            }
        }
        Repeater {
            model: page.detected
            delegate: QQC2.CheckBox {
                Layout.row: index + 1; Layout.column: 2
                Layout.alignment: Qt.AlignHCenter
                checked: page.pref(modelData.mount).panel
                onToggled: page.setPref(modelData.mount, "panel", checked)
            }
        }
        Repeater {
            model: page.detected
            delegate: QQC2.CheckBox {
                Layout.row: index + 1; Layout.column: 3
                Layout.alignment: Qt.AlignHCenter
                checked: page.pref(modelData.mount).popup
                onToggled: page.setPref(modelData.mount, "popup", checked)
            }
        }
    }

    // ======================================================================
    Kirigami.Heading {
        Layout.topMargin: Kirigami.Units.largeSpacing
        level: 3
        text: i18n("Dossiers et points de montage suivis")
    }
    QQC2.Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        opacity: 0.7
        text: i18n("Point de montage : espace occupé du disque ou du partage qui contient ce chemin. "
                   + "Dossier : taille de son contenu (du, sans traverser d'autres montages), calculée en arrière-plan. "
                   + "Le pourcentage d'un dossier est sa part de la taille du disque qui le contient, ou de son quota s'il en a un.")
    }

    Repeater {
        model: page.items
        delegate: RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            QQC2.ComboBox {
                model: [i18n("Dossier"), i18n("Point de montage")]
                currentIndex: modelData.kind === "mount" ? 1 : 0
                onActivated: page.updateItem(index, "kind", currentIndex === 1 ? "mount" : "folder")
            }
            QQC2.TextField {
                Layout.fillWidth: true
                Layout.minimumWidth: Kirigami.Units.gridUnit * 10
                text: modelData.path
                placeholderText: i18n("/chemin/vers/dossier")
                onEditingFinished: if (text !== modelData.path) page.updateItem(index, "path", text)
            }
            QQC2.ToolButton {
                icon.name: "document-open-folder"
                QQC2.ToolTip.text: i18n("Parcourir…")
                QQC2.ToolTip.visible: hovered
                onClicked: { folderDialog.target = index; folderDialog.open() }
            }
            QQC2.SpinBox {
                visible: modelData.kind !== "mount"
                from: 0; to: 100000
                value: modelData.quota || 0
                textFromValue: function (v) { return v === 0 ? i18n("% du disque") : v + " Gio" }
                valueFromText: function (t) { var n = parseInt(t); return isNaN(n) ? 0 : n }
                onValueModified: page.updateItem(index, "quota", value)
                QQC2.ToolTip.text: i18n("Quota en Gio : le pourcentage est calculé sur ce quota au lieu de la taille du disque")
                QQC2.ToolTip.visible: hovered
            }
            QQC2.CheckBox {
                text: i18n("Panneau")
                checked: !!modelData.panel
                onToggled: page.updateItem(index, "panel", checked)
            }
            QQC2.CheckBox {
                text: i18n("Popup")
                checked: modelData.popup !== false
                onToggled: page.updateItem(index, "popup", checked)
            }
            QQC2.ToolButton {
                icon.name: "edit-delete"
                QQC2.ToolTip.text: i18n("Retirer")
                QQC2.ToolTip.visible: hovered
                onClicked: page.removeItem(index)
            }
        }
    }

    QQC2.Button {
        icon.name: "list-add"
        text: i18n("Ajouter un dossier ou un point de montage")
        onClicked: page.addItem()
    }

    RowLayout {
        Layout.topMargin: Kirigami.Units.largeSpacing
        QQC2.Label { text: i18n("Recalculer la taille des dossiers toutes les") }
        QQC2.SpinBox { id: folderRefresh; from: 1; to: 1440 }
        QQC2.Label { text: i18n("min") }
    }

    Item { Layout.fillHeight: true }
}
