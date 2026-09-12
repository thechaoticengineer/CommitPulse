pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui
import "ContributionFixture.js" as Fixture

// Anchored detail popup. It intentionally remains valid while the eager
// loader creates it before BarWidget.qml has supplied a bar or anchor.
Panel {
    id: root
    moduleName: "dev.commitpulse"
    ipcTarget: "dev.commitpulse"
    manageIpc: false

    property var anchorItem: null
    property var hostWidget: null
    property var dataController: null
    readonly property var barIdentity: hostWidget || root
    readonly property var periods: Fixture.fixturePeriods()
    readonly property color contentForeground: bar ? bar.foreground : Color.popups.text
    readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

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
            onTabRequested: function (direction) {
                root.switchPanel(direction);
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
                    text: "Fictional fixture totals"
                    color: Qt.darker(root.contentForeground, 1.4)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                }

                Repeater {
                    model: root.periods

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
            }
        }
    }
}
