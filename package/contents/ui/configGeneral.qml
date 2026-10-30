import QtQuick 2.15
import QtQuick.Controls 2.15 as QQC2
import org.kde.kirigami 2.5 as Kirigami

Kirigami.FormLayout {
    id: page

    property int cfg_updateInterval
    property string cfg_gpuSource
    property alias cfg_netInterface: netIf.text
    property alias cfg_warningTemp: warnTemp.value
    property alias cfg_criticalTemp: critTemp.value

    QQC2.SpinBox {
        id: interval
        Kirigami.FormData.label: i18n("Intervalle (ms) :")
        from: 500; to: 10000; stepSize: 250
        value: page.cfg_updateInterval
        onValueModified: page.cfg_updateInterval = value
    }

    QQC2.ComboBox {
        id: gpuCombo
        Kirigami.FormData.label: i18n("Source GPU :")
        textRole: "text"
        model: [
            { text: i18n("Automatique"), value: "auto" },
            { text: "NVIDIA (nvidia-smi)", value: "nvidia" },
            { text: "AMD (sysfs)", value: "amd" }
        ]
        currentIndex: {
            for (var i = 0; i < model.length; i++)
                if (model[i].value === page.cfg_gpuSource) return i
            return 0
        }
        onActivated: page.cfg_gpuSource = model[index].value
    }

    QQC2.TextField {
        id: netIf
        Kirigami.FormData.label: i18n("Interface réseau :")
        placeholderText: i18n("auto (interfaces physiques actives)")
        validator: RegularExpressionValidator { regularExpression: /[A-Za-z0-9_.:@-]*/ }
    }

    Item { Kirigami.FormData.isSection: true }

    QQC2.SpinBox {
        id: warnTemp
        Kirigami.FormData.label: i18n("Seuil d'alerte (°C) :")
        from: 30; to: 120
    }
    QQC2.SpinBox {
        id: critTemp
        Kirigami.FormData.label: i18n("Seuil critique (°C) :")
        from: 30; to: 130
    }
}
