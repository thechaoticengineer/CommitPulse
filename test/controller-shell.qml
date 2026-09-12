import QtQuick
import Quickshell
import "../quickshell" as CommitPulse

ShellRoot {
    id: root

    property int phase: 0
    property bool startupOverlapAttempted: false

    function fail(message) {
        console.error("COMMITPULSE_CONTROLLER_ERROR: " + message);
        Qt.quit();
    }

    CommitPulse.DataController {
        id: controller
        fixtureMode: false
    }

    function totalsAreFictionalSnapshot() {
        return controller.hasTotals
            && controller.periods.length === 4
            && controller.periods[0].name === "today"
            && controller.periods[0].total === 7
            && controller.periods[1].name === "week"
            && controller.periods[1].total === 17
            && controller.periods[2].name === "month"
            && controller.periods[2].total === 40
            && controller.periods[3].name === "year"
            && controller.periods[3].total === 140;
    }

    Timer {
        interval: 20
        repeat: true
        running: true
        onTriggered: {
            if (root.phase === 0 && controller.running && !root.startupOverlapAttempted) {
                root.startupOverlapAttempted = true;
                if (controller.refresh())
                    return root.fail("overlapping startup refresh was accepted");
            }

            if (controller.running)
                return;

            if (root.phase === 0 && controller.completedRunCount >= 1) {
                if (!root.startupOverlapAttempted)
                    return root.fail("startup process was not observed");
                if (!root.totalsAreFictionalSnapshot() || controller.state !== "fresh")
                    return root.fail("startup fixture did not render the fresh snapshot");
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
                if (controller.state !== "stale" || !controller.stale || controller.errorKind !== "offline")
                    return root.fail("non-zero stale fixture was not accepted");
                if (!root.totalsAreFictionalSnapshot())
                    return root.fail("stale fixture did not preserve the complete snapshot");
                if (!controller.refresh())
                    return root.fail("authentication fixture refresh was rejected");
                root.phase = 2;
                return;
            }

            if (root.phase === 2 && controller.completedRunCount >= 3) {
                if (controller.state !== "unavailable" || controller.errorCategory !== "authentication" || !controller.stale)
                    return root.fail("unavailable authentication fixture was not presented truthfully");
                if (!root.totalsAreFictionalSnapshot())
                    return root.fail("unavailable result replaced the previous totals");
                if (!controller.refresh())
                    return root.fail("malformed fixture refresh was rejected");
                root.phase = 3;
                return;
            }

            if (root.phase === 3 && controller.completedRunCount >= 4) {
                if (controller.state !== "error" || controller.errorKind !== "invalid_output" || !controller.stale)
                    return root.fail("malformed output was not reduced to a stale error");
                if (!root.totalsAreFictionalSnapshot())
                    return root.fail("malformed output replaced the previous totals");
                for (var index = 0; index < controller.periods.length; index++) {
                    if (controller.periods[index].total <= 0)
                        return root.fail("an unavailable or invalid result introduced zero totals");
                }
                if (controller.maximumActiveProcesses !== 1 || controller.activeProcessCount !== 0)
                    return root.fail("more than one helper process was active");
                if (controller.rejectedRefreshCount < 2)
                    return root.fail("startup and manual overlap guards were not observed");
                console.log("COMMITPULSE_CONTROLLER_READY: fresh stale auth malformed manual startup maximum active 1");
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

}
