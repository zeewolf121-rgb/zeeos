/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * zee-summary page (P4-6, #178, ADR-0003). `config` is the module's Config object (Config.h).
 * Calamares' own Install button follows config.backupConfirmed through isNextEnabled().
 * RTL: the whole page mirrors for right-to-left UI languages; device paths are isolated
 * left-to-right runs (U+2066 ... U+2069) so "/dev/sda" stays readable inside Arabic text.
 */
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Page {
    id: page

    LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
    LayoutMirroring.childrenInherit: true

    function ltr(s) { return "⁦" + s + "⁩" }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        Label {
            Layout.fillWidth: true
            text: qsTr("These changes will be made to your disks")
            font.bold: true
            font.pointSize: 14
            wrapMode: Text.WordWrap
        }

        Label {
            Layout.fillWidth: true
            text: qsTr("Nothing has been written yet. Check every line: after you click Install, these changes cannot be undone.")
            wrapMode: Text.WordWrap
        }

        ScrollView {
            id: scroll
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ColumnLayout {
                width: scroll.availableWidth
                spacing: 10

                Label {
                    visible: !config.hasChanges
                    Layout.fillWidth: true
                    color: "#b3261e"
                    text: qsTr("No disk changes are planned. Go back to the partitioning page and choose where to install ZeeOS.")
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: config.disks

                    delegate: Frame {
                        required property var modelData
                        Layout.fillWidth: true

                        ColumnLayout {
                            width: parent.width
                            spacing: 4

                            Label {
                                Layout.fillWidth: true
                                font.bold: true
                                text: modelData.disk === "" ? qsTr("Other changes")
                                                            : qsTr("Disk %1").arg(page.ltr(modelData.disk))
                            }

                            Repeater {
                                model: modelData.changes

                                delegate: Label {
                                    required property string modelData
                                    Layout.fillWidth: true
                                    Layout.leftMargin: 12
                                    wrapMode: Text.WordWrap
                                    textFormat: Text.PlainText
                                    text: "• " + modelData
                                }
                            }
                        }
                    }
                }

                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    opacity: 0.8
                    text: qsTr("The existing EFI system partition is backed up before ZeeOS adds its boot files. It is never formatted, and Windows Boot Manager is never changed.")
                }
            }
        }

        CheckBox {
            id: backup
            Layout.fillWidth: true
            text: qsTr("I have a backup of everything on these disks that I want to keep.")
            checked: config.backupConfirmed
            enabled: config.backupEditable && config.hasChanges
            onToggled: config.backupConfirmed = checked
        }

        Label {
            Layout.fillWidth: true
            visible: !config.backupConfirmed
            wrapMode: Text.WordWrap
            opacity: 0.8
            text: qsTr("Install stays disabled until you confirm that you have a backup.")
        }
    }
}
