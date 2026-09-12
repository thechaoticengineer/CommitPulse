import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Compact contribution readout for the bar. The nested popup owns its layer
// surface; this widget remains the host identity that the bar coordinates.
BarWidget {
    id: root
    moduleName: "dev.commitpulse"

    readonly property var periods: dataController.periods
    readonly property bool hasTotals: dataController.hasTotals
    readonly property var todayPeriod: hasTotals ? periods[0] : null
    readonly property string todayValue: todayPeriod && typeof todayPeriod.total === "number" ? String(todayPeriod.total) : ""
    readonly property string availabilityLabel: {
        if (dataController.loading || dataController.state === "loading")
            return "Loading…";
        if (dataController.errorCategory === "authentication")
            return "Sign in";
        if (dataController.errorCategory === "rate-limit")
            return "Rate limited";
        if (dataController.state === "error")
            return "Refresh failed";
        return "Unavailable";
    }
    readonly property string dataQualifier: {
        if (dataController.loading)
            return " · refreshing";
        if (dataController.stale)
            return " · stale";
        return "";
    }
    readonly property string horizontalSummary: todayValue !== "" ? todayValue + " today" + dataQualifier : availabilityLabel
    readonly property string verticalValue: todayValue !== "" ? todayValue : (dataController.loading || dataController.state === "loading" ? "…" : "—")
    readonly property string verticalLabel: hasTotals ? (dataController.stale ? "STALE" : "TODAY") : (dataController.loading || dataController.state === "loading" ? "LOAD" : "N/A")
    readonly property string detailTooltip: {
        if (todayValue === "")
            return availabilityLabel + "\nOpen contribution details";
        var detail = "Today: " + todayValue + " contributions";
        if (dataController.loading)
            detail += " (refreshing)";
        else if (dataController.stale)
            detail += " (stale)";
        return detail + "\nOpen contribution details";
    }

    // Shape contract for the host's panel routing.
    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

    function open() {
        if (panelLoader.item)
            panelLoader.item.open();
    }

    function close() {
        if (panelLoader.item)
            panelLoader.item.close();
    }

    function toggle() {
        togglePanel();
    }

    function togglePanel() {
        if (panelLoader.item)
            panelLoader.item.toggle();
    }

    function closeForPopoutSwitch() {
        if (panelLoader.item)
            panelLoader.item.closeForPopoutSwitch();
    }

    // The panel is created before a bar is injected. Keep all hand-off values
    // nullable until the host provides them, then update them together.
    function injectPanel() {
        var target = panelLoader.item;
        if (!target)
            return;
        if ("bar" in target)
            target.bar = root.bar;
        if ("settings" in target)
            target.settings = root.settings;
        if ("anchorItem" in target)
            target.anchorItem = button;
        if ("hostWidget" in target)
            target.hostWidget = root;
        if ("dataController" in target)
            target.dataController = dataController;
    }

    readonly property real openPanelIndicatorWidth: vertical ? button.width : button.labelWidth
    readonly property real openPanelIndicatorHeight: vertical ? Style.bar.iconSlot : Math.max(Style.space(8), Math.round(Style.bar.iconSlot * 0.45))

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

    // One controller belongs to the long-lived widget and is shared with its
    // eager popup. Neither UI surface launches the helper independently.
    DataController {
        id: dataController
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel();
            Qt.callLater(root.injectPanel);
        }
    }

    IpcHandler {
        target: "dev.commitpulse"

        function open(): void {
            root.open();
        }
        function close(): void {
            root.close();
        }
        function show(): void {
            root.open();
        }
        function hide(): void {
            root.close();
        }
        function toggle(): void {
            root.togglePanel();
        }
    }

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.vertical ? "" : root.horizontalSummary
        labelVisible: !root.vertical
        hasVisualContent: root.vertical || text !== ""
        active: root.opened
        activeColor: root.bar ? root.bar.barForeground : Color.foreground
        horizontalMargin: 8
        verticalPadding: 6
        fixedHeight: root.vertical ? Style.bar.iconSlot * 2 : -1
        tooltipText: root.detailTooltip

        onPressed: function (mouseButton) {
            if (mouseButton === Qt.LeftButton)
                root.togglePanel();
        }

        Column {
            visible: root.vertical
            anchors.fill: parent
            spacing: Style.space(2)

            Text {
                width: parent.width
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                text: root.verticalValue
                color: button.active ? button.activeColor : button.foreground
                font.family: button.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
            }

            Text {
                width: parent.width
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                text: root.verticalLabel
                color: button.active ? button.activeColor : button.foreground
                font.family: button.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
            }
        }
    }
}
