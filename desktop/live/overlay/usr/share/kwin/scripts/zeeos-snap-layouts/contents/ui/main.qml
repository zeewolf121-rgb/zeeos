// SPDX-License-Identifier: GPL-3.0-or-later
// ZeeOS snap-layout picker. Meta+Z opens a small picker over the active window's screen;
// clicking a zone snaps the window into it. Zones are fractions of the work area, so they
// follow the panel and screen size.
import QtQuick
import QtQuick.Window
import org.kde.kwin

Item {
    id: root

    // Each layout is a list of [x, y, w, h] fractions of the work area.
    readonly property var layouts: [
        [[0, 0, 0.5, 1], [0.5, 0, 0.5, 1]],
        [[0, 0, 0.67, 1], [0.67, 0, 0.33, 1]],
        [[0, 0, 0.33, 1], [0.33, 0, 0.34, 1], [0.67, 0, 0.33, 1]],
        [[0, 0, 0.5, 1], [0.5, 0, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]],
        [[0, 0, 0.5, 0.5], [0.5, 0, 0.5, 0.5], [0, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]]
    ]
    property var target: null

    function snap(zone) {
        const w = root.target;
        picker.visible = false;
        if (!w || !w.normalWindow || !w.moveable || !w.resizeable) {
            return;
        }
        const a = Workspace.clientArea(KWin.PlacementArea, w);
        w.setMaximize(false, false);
        w.frameGeometry = Qt.rect(Math.round(a.x + zone[0] * a.width),
                                  Math.round(a.y + zone[1] * a.height),
                                  Math.round(zone[2] * a.width),
                                  Math.round(zone[3] * a.height));
    }

    ShortcutHandler {
        name: "ZeeOS Snap Layouts"
        text: "ZeeOS: Show Snap Layouts"
        sequence: "Meta+Z"
        onActivated: {
            const w = Workspace.activeWindow;
            if (!w || !w.normalWindow) {
                return;
            }
            root.target = w;
            const a = Workspace.clientArea(KWin.PlacementArea, w);
            picker.x = a.x + (a.width - picker.width) / 2;
            picker.y = a.y + (a.height - picker.height) / 2;
            picker.visible = !picker.visible;
        }
    }

    Window {
        id: picker
        width: 5 * 128 + 6 * 12
        height: 96 + 24
        visible: false
        flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        color: "#e61f2330"

        Row {
            anchors.centerIn: parent
            spacing: 12
            Repeater {
                model: root.layouts
                delegate: Rectangle {
                    required property var modelData
                    width: 128
                    height: 96
                    color: "transparent"
                    border.color: "#8aa4d6"
                    radius: 6
                    Repeater {
                        model: parent.modelData
                        delegate: Rectangle {
                            required property var modelData
                            x: 3 + modelData[0] * (parent.width - 6)
                            y: 3 + modelData[1] * (parent.height - 6)
                            width: modelData[2] * (parent.width - 6) - 3
                            height: modelData[3] * (parent.height - 6) - 3
                            color: zoneArea.containsMouse ? "#5b8def" : "#3d4a66"
                            radius: 3
                            MouseArea {
                                id: zoneArea
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.snap(modelData)
                            }
                        }
                    }
                }
            }
        }
    }
}
