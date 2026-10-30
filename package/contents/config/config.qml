import QtQuick 2.15
import org.kde.plasma.configuration 2.0

ConfigModel {
    ConfigCategory {
        name: i18n("Général")
        icon: "preferences-system"
        source: "configGeneral.qml"
    }
    ConfigCategory {
        name: i18n("Affichage")
        icon: "view-visible"
        source: "configDisplay.qml"
    }
    ConfigCategory {
        name: i18n("Stockage")
        icon: "drive-harddisk"
        source: "configStorage.qml"
    }
}
