pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

// Anchored CommitPulse detail popup. It intentionally remains valid while the eager
// loader creates it before Widget.qml has supplied a bar or anchor.
Panel {
    id: root
    moduleName: "dev.commitpulse"
    ipcTarget: "dev.commitpulse"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null
    property var dataController: null
    readonly property var barIdentity: hostWidget || root
    readonly property var periods: dataController ? dataController.periods : []
    readonly property bool hasTotals: dataController ? dataController.hasTotals : false
    readonly property bool refreshing: dataController ? dataController.loading && hasTotals : false
    readonly property bool initialLoading: dataController ? !hasTotals && (dataController.loading || dataController.state === "loading") : false
    readonly property bool showingStaleTotals: dataController ? dataController.stale && hasTotals : false
    readonly property color contentForeground: bar ? bar.foreground : Color.popups.text
    readonly property color subduedForeground: Qt.darker(contentForeground, 1.4)
    readonly property color statusForeground: {
        if (!dataController || initialLoading || refreshing || dataController.state === "fresh")
            return contentForeground;
        return bar ? bar.urgent : Color.urgent;
    }
    readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
    readonly property string githubProfileTarget: "https://github.com/"
    property date displayClock: new Date()
    property int selectedAction: 0

    readonly property string statusTitle: {
        if (!dataController)
            return "Unavailable";
        if (initialLoading)
            return "Loading contributions…";
        if (refreshing)
            return showingStaleTotals ? "Refreshing stale totals…" : "Refreshing contributions…";
        if (dataController.state === "fresh")
            return "Up to date";

        var prefix = showingStaleTotals ? "Stale · " : "";
        if (dataController.errorCategory === "authentication")
            return prefix + "Authentication required";
        if (dataController.errorCategory === "rate-limit")
            return prefix + "Rate limited";
        if (dataController.errorKind === "offline")
            return prefix + "Offline";
        if (dataController.state === "unavailable")
            return prefix + "Unavailable";
        return prefix + "Refresh failed";
    }
    readonly property string statusDetail: {
        if (!dataController)
            return "The contribution service is unavailable.";
        if (initialLoading)
            return "Waiting for GitHub contribution data.";
        if (refreshing)
            return hasTotals ? "Showing the last successful totals while the refresh completes." : "Waiting for GitHub contribution data.";
        if (dataController.state === "fresh")
            return "Contribution totals are current.";
        if (dataController.errorCategory === "authentication")
            return showingStaleTotals ? "Sign in with GitHub CLI to refresh the saved totals." : "Sign in with GitHub CLI to load contribution totals.";
        if (dataController.errorCategory === "rate-limit")
            return showingStaleTotals ? "Showing saved totals until GitHub allows another refresh." : "GitHub is temporarily suppressing refreshes.";
        if (dataController.errorKind === "offline")
            return showingStaleTotals ? "Showing saved totals while the network is offline." : "Connect to the network to load contribution totals.";
        if (showingStaleTotals)
            return "Showing saved totals because the latest refresh failed.";
        if (dataController.state === "unavailable")
            return "No contribution totals are available yet.";
        return "GitHub contributions could not be refreshed.";
    }
    readonly property string lastUpdatedText: dataController && hasTotals ? formatLastUpdated(dataController.lastUpdated) : ""
    readonly property string refreshTooltip: {
        if (!dataController)
            return "Refresh unavailable";
        if (dataController.loading)
            return "A refresh is already running";
        if (!dataController.canRefresh)
            return "Refresh is paused until " + formatTimestamp(dataController.retryAt);
        return "Refresh contribution totals";
    }

    function formatTimestamp(value) {
        var milliseconds = Date.parse(value || "");
        if (isNaN(milliseconds))
            return "the retry time";
        return Qt.formatDateTime(new Date(milliseconds), "MMM d, yyyy · HH:mm");
    }

    function formatLastUpdated(value) {
        var milliseconds = Date.parse(value || "");
        if (isNaN(milliseconds))
            return "";

        var elapsedSeconds = Math.floor((displayClock.getTime() - milliseconds) / 1000);
        if (elapsedSeconds >= 0 && elapsedSeconds < 60)
            return "Updated just now";
        if (elapsedSeconds >= 60 && elapsedSeconds < 3600) {
            var minutes = Math.floor(elapsedSeconds / 60);
            return "Updated " + minutes + (minutes === 1 ? " minute ago" : " minutes ago");
        }
        if (elapsedSeconds >= 3600 && elapsedSeconds < 86400) {
            var hours = Math.floor(elapsedSeconds / 3600);
            return "Updated " + hours + (hours === 1 ? " hour ago" : " hours ago");
        }
        return "Updated " + formatTimestamp(value);
    }

    function isTrustedProfileTarget(target) {
        return String(target || "") === githubProfileTarget;
    }

    function openGitHubProfile(target) {
        var candidate = target === undefined ? githubProfileTarget : String(target);
        if (!isTrustedProfileTarget(candidate))
            return false;
        return Qt.openUrlExternally(candidate);
    }

    function refreshContributions() {
        if (!dataController || !dataController.canRefresh)
            return false;
        return dataController.refresh();
    }

    function moveActionCursor(dx, dy) {
        var delta = dx !== 0 ? dx : dy;
        if (delta === 0)
            return;
        selectedAction = delta < 0 ? 0 : 1;
    }

    function activateSelectedAction() {
        if (selectedAction === 0)
            return refreshContributions();
        return openGitHubProfile();
    }

    function open() {
        root.controller.show();
        Qt.callLater(function () {
            if (root.opened && keyCatcher)
                keyCatcher.forceActiveFocus();
        });
    }

    function close() {
        root.controller.hide();
    }

    function toggle() {
        if (root.opened)
            root.close();
        else
            root.open();
    }

    function switchPanel(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.barIdentity, direction);
        return false;
    }

    Timer {
        interval: 60000
        repeat: true
        running: root.opened
        triggeredOnStart: true
        onTriggered: root.displayClock = new Date()
    }

    KeyboardPanel {
        id: popup
        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        centerOnBar: false
        focusTarget: keyCatcher
        contentWidth: popup.fittedContentWidth(Style.space(300), Style.space(360))
        contentHeight: popup.fittedContentHeight(contentColumn.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onMoveRequested: function (dx, dy) {
                root.moveActionCursor(dx, dy);
            }
            onActivateRequested: root.activateSelectedAction()
            onTabRequested: function (direction) {
                root.switchPanel(direction);
            }
            onTextKey: function (text) {
                if (text === "r" || text === "R")
                    root.refreshContributions();
                else if (text === "g" || text === "G")
                    root.openGitHubProfile();
            }

            Column {
                id: contentColumn
                width: parent.width
                spacing: Style.space(10)

                PanelSectionHeader {
                    width: parent.width
                    text: "CONTRIBUTIONS"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                }

                Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: root.statusTitle
                    color: root.statusForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: root.showingStaleTotals
                }

                Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: root.statusDetail
                    color: root.subduedForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                }

                Text {
                    visible: text !== ""
                    width: parent.width
                    textFormat: Text.PlainText
                    text: root.lastUpdatedText
                    color: root.subduedForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                }

                Repeater {
                    model: root.hasTotals ? root.periods : []

                    Item {
                        id: periodRow
                        required property var modelData
                        width: parent.width
                        height: Math.max(label.implicitHeight, total.implicitHeight) + Style.space(4)

                        Text {
                            id: label
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: periodRow.modelData.label
                            color: root.contentForeground
                            font.family: root.contentFontFamily
                            font.pixelSize: Style.font.body
                            font.bold: true
                        }

                        Text {
                            id: total
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: periodRow.modelData.total + " contributions"
                            color: root.contentForeground
                            font.family: root.contentFontFamily
                            font.pixelSize: Style.font.body
                        }
                    }
                }

                Row {
                    anchors.right: parent.right
                    spacing: Style.space(8)

                    Button {
                        text: dataController && dataController.loading ? "Refreshing…" : "Refresh"
                        iconText: "󰑐"
                        tooltipText: root.refreshTooltip
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                        focusable: true
                        bordered: true
                        enabled: dataController ? dataController.canRefresh : false
                        hasCursor: root.selectedAction === 0
                        onHovered: function (hovered) {
                            if (hovered)
                                root.selectedAction = 0;
                        }
                        onClicked: root.refreshContributions()
                    }

                    Button {
                        text: "Open GitHub profile"
                        iconText: "󰊤"
                        tooltipText: "Open the authenticated GitHub account"
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                        focusable: true
                        bordered: true
                        hasCursor: root.selectedAction === 1
                        onHovered: function (hovered) {
                            if (hovered)
                                root.selectedAction = 1;
                        }
                        onClicked: root.openGitHubProfile()
                    }
                }
            }
        }
    }
}
