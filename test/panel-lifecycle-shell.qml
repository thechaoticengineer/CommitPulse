import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "../quickshell" as CommitPulse

// Isolated compositor-backed harness for the production widget and nested
// panel. The bar host supplies only the installed BarWidget/KeyboardPanel API;
// the popup itself is always CommitPulse's real Popup.qml.
ShellRoot {
    id: root

    function panelLoader() {
        for (var index = 0; index < widget.children.length; index++) {
            var candidate = widget.children[index];
            if (candidate && "status" in candidate && "item" in candidate)
                return candidate;
        }
        return null;
    }

    function panel() {
        var loader = panelLoader();
        return loader ? loader.item : null;
    }

    function state() {
        var loader = panelLoader();
        var detail = loader ? loader.item : null;
        var anchor = detail ? detail.anchorItem : null;
        var anchorWindow = anchor ? anchor.QsWindow.window : null;
        var controllerOpen = detail && detail.controller ? detail.controller.open === true : false;
        return JSON.stringify({
            loaderReady: loader ? loader.status === Loader.Ready : false,
            realPanel: detail ? detail.moduleName === "dev.commitpulse" && detail.ipcTarget === "dev.commitpulse" : false,
            controllerOpen: controllerOpen,
            opened: widget.opened,
            anchorValid: anchor ? anchor === demoBar.clickTargets[0] && anchor.visible && anchor.width > 0 && anchor.height > 0 && anchorWindow === hostWindow : false,
            hostReady: hostWindow.visible && hostWindow.backingWindowVisible && hostWindow.screen !== null && hostWindow.width > 0 && hostWindow.height > 0,
            hostScreen: hostWindow.screen ? hostWindow.screen.name : "",
            hostWidth: hostWindow.width,
            hostHeight: hostWindow.height,
            hasTotals: detail && detail.dataController ? detail.dataController.hasTotals : false,
            dataRunning: detail && detail.dataController ? detail.dataController.running : true,
            completedRuns: detail && detail.dataController ? detail.dataController.completedRunCount : 0
        });
    }

    function pressWidget() {
        if (demoBar.clickTargets.length !== 1)
            throw new Error("expected exactly one registered widget action");
        demoBar.clickTargets[0].triggerPress(Qt.LeftButton);
    }

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
        function itemPosition(item) {
            return item.mapToItem(hostWindow.contentItem, 0, 0);
        }
    }

    PanelWindow {
        id: hostWindow
        visible: true
        color: Color.bar.background
        implicitWidth: Math.max(Style.space(220), widget.implicitWidth + Style.space(24))
        implicitHeight: Math.max(Style.bar.sizeHorizontal, widget.implicitHeight + Style.space(12))

        anchors {
            top: true
            left: true
        }

        WlrLayershell.namespace: "commitpulse-lifecycle-host"
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        CommitPulse.Widget {
            id: widget
            anchors.centerIn: parent
            bar: demoBar
        }
    }

    IpcHandler {
        target: "commitpulse.lifecycle"

        function state(): string {
            return root.state();
        }
        function press(): void {
            root.pressWidget();
        }
        function quit(): void {
            Qt.quit();
        }
    }
}
