import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "../quickshell" as CommitPulse

// Repository-local demo root. It intentionally supplies only the narrow bar
// contract the widget needs, so no installed plugin or live shell.json is
// consulted while exercising the fixture-backed bar and nested popup.
ShellRoot {
    id: root

    property bool interactive: Quickshell.env("COMMITPULSE_SMOKE_INTERACTIVE") === "1"

    QtObject {
        id: demoBar

        property bool vertical: false
        property int barSize: Style.bar.sizeHorizontal
        property color barForeground: Color.foreground
        property color foreground: Color.foreground
        property color urgent: Color.urgent
        property string fontFamily: Style.font.family
        property string position: "top"
        property bool foregroundAnimationEnabled: false
        property var activePopout: null
        property var clickTargets: []

        function showTooltip() {}
        function hideTooltip() {}
        function registerClickTarget(target) {
            if (clickTargets.indexOf(target) === -1)
                clickTargets = clickTargets.concat([target]);
        }
        function unregisterClickTarget(target) {
            var index = clickTargets.indexOf(target);
            if (index !== -1)
                clickTargets = clickTargets.slice(0, index).concat(clickTargets.slice(index + 1));
        }
        function requestPopout(owner) {
            activePopout = owner;
        }
        function releasePopout(owner) {
            if (activePopout === owner)
                activePopout = null;
        }
        function switchPanelFrom() {
            return false;
        }
        function targetBelongsToWindow() {
            return true;
        }
    }

    PanelWindow {
        id: previewWindow
        visible: true
        color: Color.bar.background
        implicitWidth: Math.max(Style.space(220), widget.implicitWidth + Style.space(24))
        implicitHeight: Math.max(Style.bar.sizeHorizontal, widget.implicitHeight + Style.space(12))

        anchors {
            top: true
            left: true
        }

        WlrLayershell.namespace: "commitpulse-smoke"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        CommitPulse.BarWidget {
            id: widget
            anchors.centerIn: parent
            bar: demoBar
        }
    }

    Timer {
        id: completeTimer
        interval: 700
        repeat: false
        onTriggered: {
            if (!widget.opened) {
                console.error("COMMITPULSE_SMOKE_ERROR: popup did not open")
                Qt.quit()
                return
            }

            console.log("COMMITPULSE_SMOKE_READY: BarWidget and fixture popup loaded")
            if (!root.interactive)
                Qt.quit()
        }
    }

    Component.onCompleted: {
        widget.open()
        completeTimer.start()
    }
}
