import QtQuick
import Quickshell
import Quickshell.Io
import "ContributionState.js" as ContributionState

QtObject {
    id: root

    readonly property int defaultRefreshInterval: 900000
    property int refreshInterval: defaultRefreshInterval
    property string helperExecutable: {
        var testHelper = Quickshell.env("COMMITPULSE_TEST_HELPER") || "";
        if (testHelper !== "")
            return testHelper;
        return root.localFilePath(Qt.resolvedUrl("../bin/commitpulse-data"));
    }
    property bool fixtureMode: Quickshell.env("COMMITPULSE_TEST_FIXTURE") === "1"

    readonly property var periods: _model.periods
    readonly property bool hasTotals: periods.length === 4
    readonly property string state: _model.state
    readonly property bool stale: _model.stale
    readonly property string attemptedAt: _model.attemptedAt
    readonly property string lastUpdated: _model.lastUpdated
    readonly property string retryAt: _model.retryAt
    readonly property string effectiveTimezone: _model.effectiveTimezone
    readonly property string privateContributions: _model.privateContributions
    readonly property string errorKind: _model.errorKind
    readonly property string errorCategory: _model.errorCategory
    readonly property string errorDetail: _model.errorDetail
    readonly property bool loading: running
    readonly property bool canRefresh: !running && ContributionState.retryAllowed(retryAt, _eligibilityTime)

    // These counters make the process invariant observable to runtime tests.
    readonly property int activeProcessCount: _activeProcessCount
    readonly property int maximumActiveProcesses: _maximumActiveProcesses
    readonly property int completedRunCount: _completedRunCount
    readonly property int rejectedRefreshCount: _rejectedRefreshCount
    property bool running: false

    property var _model: ContributionState.initialState()
    property string _runStartedAt: ""
    property string _runStdout: ""
    property int _activeProcessCount: 0
    property int _maximumActiveProcesses: 0
    property int _completedRunCount: 0
    property int _rejectedRefreshCount: 0
    property double _eligibilityTime: Date.now()

    function localFilePath(url) {
        var value = String(url);
        if (value.indexOf("file://") === 0)
            value = value.slice(7);
        return decodeURIComponent(value);
    }

    function refresh() {
        // This guard is raised synchronously, before Process.running changes,
        // so startup, timer, and manual calls cannot race into a second launch.
        root._eligibilityTime = Date.now();
        if (root.running || !ContributionState.retryAllowed(root.retryAt, root._eligibilityTime)) {
            root._rejectedRefreshCount++;
            return false;
        }

        root.running = true;
        root._runStartedAt = new Date().toISOString();
        root._runStdout = "";
        root._activeProcessCount++;
        root._maximumActiveProcesses = Math.max(root._maximumActiveProcesses, root._activeProcessCount);

        var arguments = [root.helperExecutable];
        if (root.fixtureMode)
            arguments.push("-fixture");
        helperProcess.command = arguments;
        helperProcess.running = true;
        return true;
    }

    function completeRun(exitCode) {
        if (!root.running)
            return;

        // waitForEnd makes the collector's current-run text complete here.
        // Copy it once, reject oversized output in the Qt-free reducer, then
        // discard the captured value without ever logging subprocess output.
        root._runStdout = String(helperStdout.text || "");
        root._model = ContributionState.applyOutput(root._model, root._runStdout, exitCode, root._runStartedAt);
        root._runStdout = "";
        root._completedRunCount++;
        root._activeProcessCount = Math.max(0, root._activeProcessCount - 1);
        root.running = false;
    }

    Component.onCompleted: startupTimer.start()

    property Timer _startupTimer: Timer {
        id: startupTimer
        interval: 0
        repeat: false
        onTriggered: root.refresh()
    }

    property Timer _refreshTimer: Timer {
        id: refreshTimer
        interval: root.refreshInterval
        repeat: true
        running: true
        onTriggered: root.refresh()
    }

    // Re-evaluate canRefresh when a validated retry deadline passes instead of
    // leaving a disabled manual action bound to an old Date.now() result.
    property Timer _retryTimer: Timer {
        interval: root.retryAt === "" ? 1 : Math.max(1, Date.parse(root.retryAt) - Date.now())
        repeat: false
        running: root.retryAt !== "" && !ContributionState.retryAllowed(root.retryAt, root._eligibilityTime)
        onTriggered: root._eligibilityTime = Date.now()
    }

    property Process _helperProcess: Process {
        id: helperProcess
        running: false

        stdout: StdioCollector {
            id: helperStdout
            waitForEnd: true
        }

        onExited: function (exitCode) {
            root.completeRun(exitCode);
        }

        // A failed exec can lower Process.running without an exited signal on
        // some Quickshell/Qt combinations. Defer the fallback so a normal
        // onExited gets first chance; completeRun's guard releases once only.
        onRunningChanged: {
            if (root.running && !helperProcess.running)
                Qt.callLater(function () {
                    root.completeRun(-1);
                });
        }
    }
}
