import QtQuick
import Quickshell
import "../quickshell" as CommitPulse

ShellRoot {
    id: root

    property int phase: 0

    function fail(message) {
        console.error("COMMITPULSE_CONTROLLER_ERROR: " + message);
        Qt.quit();
    }

    CommitPulse.DataController {
        id: controller
        fixtureMode: true
    }

    Timer {
        interval: 20
        repeat: true
        running: true
        onTriggered: {
            if (controller.running)
                return;

            if (root.phase === 0 && controller.completedRunCount >= 1) {
                if (!controller.hasTotals || controller.periods.length !== 4)
                    return root.fail("startup fixture did not produce four totals");
                if (controller.refreshInterval !== 900000)
                    return root.fail("default interval changed");
                if (!controller.refresh())
                    return root.fail("manual refresh was rejected while idle");
                if (controller.refresh())
                    return root.fail("overlapping manual refresh was accepted");
                root.phase = 1;
                return;
            }

            if (root.phase === 1 && controller.completedRunCount >= 2) {
                if (controller.maximumActiveProcesses !== 1 || controller.activeProcessCount !== 0)
                    return root.fail("more than one helper process was active");
                if (controller.rejectedRefreshCount < 1)
                    return root.fail("the overlap guard was not observed");
                if (controller.state !== "fresh")
                    return root.fail("per-run stdout was not parsed independently");
                if (controller.periods[0].name !== "today" || controller.periods[1].name !== "week" || controller.periods[2].name !== "month" || controller.periods[3].name !== "year")
                    return root.fail("period order changed");
                console.log("COMMITPULSE_CONTROLLER_READY: asynchronous fixture refreshes completed with maximum active 1");
                Qt.quit();
            }
        }
    }

    Timer {
        interval: 8000
        repeat: false
        running: true
        onTriggered: root.fail("controller smoke timed out")
    }

    // Race an immediate manual request with the controller's deferred startup
    // timer. Both paths must converge on the same synchronous guard.
    Component.onCompleted: {
        if (!controller.refresh())
            root.fail("initial manual refresh was unexpectedly rejected");
    }
}
