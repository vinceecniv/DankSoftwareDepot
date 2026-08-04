pragma Singleton
import QtQuick
import Quickshell.Io
import qs.Common

// Plugin-local translations. DMS has no per-plugin i18n mechanism, so this
// singleton loads translations/<lang>.json from the plugin folder (keyed by
// the English source string) and follows the DMS/system locale. Lookup
// order: own catalog → DMS I18n catalog → English source string.
Item {
    id: tr

    property var catalog: ({})
    property bool loaded: false

    // Same resolution DMS uses: explicit DMS locale, else the system locale
    readonly property string localeTag: (SessionData.locale && SessionData.locale !== "") ? SessionData.locale : Qt.locale().name
    readonly property string shortLang: localeTag.split(/[_-]/)[0].toLowerCase()

    readonly property string _fileUrl: {
        if (shortLang === "" || shortLang === "c" || shortLang === "en")
            return "";
        return Qt.resolvedUrl("translations/" + shortLang + ".json");
    }

    on_FileUrlChanged: {
        loaded = false;
        catalog = {};
    }

    function t(term) {
        if (loaded) {
            const hit = catalog[term];
            if (hit !== undefined && hit !== "")
                return hit;
        }
        return I18n.tr(term);
    }

    FileView {
        id: catalogFile
        path: tr._fileUrl

        onLoaded: {
            try {
                tr.catalog = JSON.parse(text());
                tr.loaded = true;
            } catch (e) {
                tr.loaded = false;
            }
        }

        onLoadFailed: error => {
            tr.loaded = false;
        }
    }
}
