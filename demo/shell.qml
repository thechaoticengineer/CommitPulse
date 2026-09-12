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
    property int phase: 0
    property bool sawInitialLoading: false
    property bool sawRefreshing: false

    function fail(message) {
        console.error("COMMITPULSE_SMOKE_ERROR: " + message);
        Qt.quit();
    }

    function detailPanel() {
        for (var index = 0; index < widget.children.length; index++) {
            var candidate = widget.children[index];
            if (candidate && candidate.item && candidate.item.moduleName === "dev.commitpulse")
                return candidate.item;
        }
        return null;
    }

    function hasFictionalSnapshot(panel) {
        return panel
            && panel.hasTotals
            && panel.periods.length === 4
            && panel.periods[0].label === "Today" && panel.periods[0].total === 7
            && panel.periods[1].label === "Week" && panel.periods[1].total === 17
            && panel.periods[2].label === "Month" && panel.periods[2].total === 40
            && panel.periods[3].label === "Year" && panel.periods[3].total === 140;
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
        id: scenarioTimer
        interval: 20
        repeat: true
        running: true
        onTriggered: {
            var panel = root.detailPanel();
            if (!panel || !panel.dataController)
                return

            if (panel.dataController.running) {
                if (root.phase === 0) {
                    if (widget.horizontalSummary !== "Loading…" || panel.statusTitle !== "Loading contributions…")
                        return root.fail("initial loading state was not rendered");
                    root.sawInitialLoading = true;
                } else if (root.phase === 1) {
                    if (widget.horizontalSummary !== "7 today · refreshing" || panel.statusTitle !== "Refreshing contributions…")
                        return root.fail("refreshing state did not retain the fresh counters");
                    root.sawRefreshing = true;
                }
                return;
            }

            if (root.phase === 0 && panel.dataController.completedRunCount >= 1) {
                if (!widget.opened)
                    return root.fail("popup did not open");
                if (!root.sawInitialLoading)
                    return root.fail("startup loading process was not observed");
                if (!root.hasFictionalSnapshot(panel) || widget.horizontalSummary !== "7 today")
                    return root.fail("fresh widget counters were not rendered");
                if (panel.statusTitle !== "Up to date" || panel.lastUpdatedText === "")
                    return root.fail("fresh popup state was not rendered");
                if (!panel.refreshContributions())
                    return root.fail("manual stale refresh was rejected");
                if (panel.refreshContributions())
                    return root.fail("overlapping popup refresh was accepted");
                root.phase = 1;
                return;
            }

            if (root.phase === 1 && panel.dataController.completedRunCount >= 2) {
                if (!root.sawRefreshing)
                    return root.fail("manual refreshing process was not observed");
                if (!root.hasFictionalSnapshot(panel) || widget.horizontalSummary !== "7 today · stale")
                    return root.fail("stale widget counters were not preserved");
                if (panel.statusTitle !== "Stale · Offline" || panel.statusDetail.indexOf("saved totals") === -1)
                    return root.fail("stale popup state was not rendered");
                if (!panel.refreshContributions())
                    return root.fail("manual authentication refresh was rejected");
                root.phase = 2;
                return;
            }

            if (root.phase === 2 && panel.dataController.completedRunCount >= 3) {
                if (!root.hasFictionalSnapshot(panel) || widget.horizontalSummary !== "7 today · stale")
                    return root.fail("authentication failure replaced truthful counters");
                if (panel.statusTitle !== "Stale · Authentication required" || panel.statusDetail.indexOf("saved totals") === -1)
                    return root.fail("authentication popup state was not rendered");
                if (!panel.refreshContributions())
                    return root.fail("manual malformed refresh was rejected");
                root.phase = 3;
                return;
            }

            if (root.phase === 3 && panel.dataController.completedRunCount >= 4) {
                if (!root.hasFictionalSnapshot(panel) || widget.horizontalSummary !== "7 today · stale")
                    return root.fail("malformed output replaced truthful counters");
                if (panel.statusTitle !== "Stale · Refresh failed")
                    return root.fail("malformed-output popup state was not rendered");
                for (var index = 0; index < panel.periods.length; index++) {
                    if (panel.periods[index].total <= 0)
                        return root.fail("failure presentation introduced a zero counter");
                }
                if (panel.dataController.maximumActiveProcesses !== 1)
                    return root.fail("manual overlap prevention was not observed");
                console.log("COMMITPULSE_SMOKE_READY: fresh stale auth malformed manual maximum active 1");
                scenarioTimer.stop();
                timeoutTimer.stop();
                if (!root.interactive)
                    Qt.quit();
            }
        }
    }

    Timer {
        id: timeoutTimer
        interval: 10000
        repeat: false
        running: true
        onTriggered: root.fail("live UI scenario smoke timed out")
    }

    Component.onCompleted: {
        widget.open();
    }
}
