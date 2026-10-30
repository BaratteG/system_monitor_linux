import QtQuick 2.15
import QtQuick.Controls 2.15 as QQC2
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.5 as Kirigami

// what is shown where: one row per measure, one column per view
ColumnLayout {
    id: page
    spacing: Kirigami.Units.largeSpacing

    property alias cfg_cpuPanel: cpuPanel.checked
    property alias cfg_cpuPopup: cpuPopup.checked
    property alias cfg_tempPanel: tempPanel.checked
    property alias cfg_tempPopup: tempPopup.checked
    property alias cfg_freqPopup: freqPopup.checked
    property alias cfg_ramPanel: ramPanel.checked
    property alias cfg_ramPopup: ramPopup.checked
    property alias cfg_amountsPanel: amountsPanel.checked
    property alias cfg_gpuPanel: gpuPanel.checked
    property alias cfg_gpuPopup: gpuPopup.checked
    property alias cfg_vramPanel: vramPanel.checked
    property alias cfg_vramPopup: vramPopup.checked
    property alias cfg_diskPanel: diskPanel.checked
    property alias cfg_diskPopup: diskPopup.checked
    property alias cfg_netPanel: netPanel.checked
    property alias cfg_netPopup: netPopup.checked
    property alias cfg_autoHide: autoHide.checked

    GridLayout {
        columns: 3
        columnSpacing: Kirigami.Units.largeSpacing * 2
        rowSpacing: 0

        QQC2.Label { text: "" }
        QQC2.Label { text: i18n("Panneau"); font.bold: true; Layout.alignment: Qt.AlignHCenter }
        QQC2.Label { text: i18n("Popup"); font.bold: true; Layout.alignment: Qt.AlignHCenter }

        QQC2.Label { text: i18n("CPU (utilisation)") }
        QQC2.CheckBox { id: cpuPanel; Layout.alignment: Qt.AlignHCenter }
        QQC2.CheckBox { id: cpuPopup; Layout.alignment: Qt.AlignHCenter }

        QQC2.Label { text: i18n("Températures CPU et GPU") }
        QQC2.CheckBox { id: tempPanel; Layout.alignment: Qt.AlignHCenter }
        QQC2.CheckBox { id: tempPopup; Layout.alignment: Qt.AlignHCenter }

        QQC2.Label { text: i18n("Fréquences CPU et GPU") }
        QQC2.Label { text: "—"; opacity: 0.5; Layout.alignment: Qt.AlignHCenter }
        QQC2.CheckBox { id: freqPopup; Layout.alignment: Qt.AlignHCenter }

        QQC2.Label { text: i18n("RAM") }
        QQC2.CheckBox { id: ramPanel; Layout.alignment: Qt.AlignHCenter }
        QQC2.CheckBox { id: ramPopup; Layout.alignment: Qt.AlignHCenter }

        QQC2.Label { text: i18n("Quantités RAM et VRAM (Gio)") }
        QQC2.CheckBox { id: amountsPanel; Layout.alignment: Qt.AlignHCenter }
        QQC2.Label { text: i18n("toujours"); opacity: 0.5; Layout.alignment: Qt.AlignHCenter }

        QQC2.Label { text: i18n("GPU (utilisation)") }
        QQC2.CheckBox { id: gpuPanel; Layout.alignment: Qt.AlignHCenter }
        QQC2.CheckBox { id: gpuPopup; Layout.alignment: Qt.AlignHCenter }

        QQC2.Label { text: i18n("VRAM") }
        QQC2.CheckBox { id: vramPanel; Layout.alignment: Qt.AlignHCenter }
        QQC2.CheckBox { id: vramPopup; Layout.alignment: Qt.AlignHCenter }

        QQC2.Label { text: i18n("Stockage") }
        QQC2.CheckBox { id: diskPanel; Layout.alignment: Qt.AlignHCenter }
        QQC2.CheckBox { id: diskPopup; Layout.alignment: Qt.AlignHCenter }

        QQC2.Label { text: i18n("Réseau (débit ↓ / ↑)") }
        QQC2.CheckBox { id: netPanel; Layout.alignment: Qt.AlignHCenter }
        QQC2.CheckBox { id: netPopup; Layout.alignment: Qt.AlignHCenter }
    }

    QQC2.Label {
        Layout.fillWidth: true
        wrapMode: Text.WordWrap
        opacity: 0.7
        text: i18n("Les disques et dossiers affichés se choisissent dans l'onglet Stockage.")
    }

    QQC2.CheckBox {
        id: autoHide
        text: i18n("Masquer les mesures indisponibles sur ce PC (pas de GPU reconnu, pas de sonde…)")
    }

    Item { Layout.fillHeight: true }
}
