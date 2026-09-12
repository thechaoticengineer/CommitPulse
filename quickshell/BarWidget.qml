import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ContributionFixture.js" as Fixture

// Compact contribution readout for the bar. The nested popup owns its layer
// surface; this widget remains the host identity that the bar coordinates.
BarWidget {
    id: root
    moduleName: "dev.commitpulse"

    readonly property var periods: Fixture.fixturePeriods()
    readonly property var todayPeriod: periods.length > 0 ? periods[0] : ({
            label: "Today",
            total: 0
        })
    readonly property string horizontalSummary: todayPeriod.total + " contributions"

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
    }

    readonly property real openPanelIndicatorWidth: vertical ? button.width : button.labelWidth
    readonly property real openPanelIndicatorHeight: vertical ? Style.bar.iconSlot : Math.max(Style.space(8), Math.round(Style.bar.iconSlot * 0.45))

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()

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
        tooltipText: root.todayPeriod.label + ": " + root.todayPeriod.total + " contributions\nOpen contribution totals"

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
                text: String(root.todayPeriod.total)
                color: button.active ? button.activeColor : button.foreground
                font.family: button.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
            }

            Text {
                width: parent.width
                textFormat: Text.PlainText
                horizontalAlignment: Text.AlignHCenter
                text: root.todayPeriod.label.toUpperCase()
                color: button.active ? button.activeColor : button.foreground
                font.family: button.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
            }
        }
    }
}
