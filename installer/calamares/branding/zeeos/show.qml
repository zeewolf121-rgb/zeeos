// SPDX-License-Identifier: GPL-3.0-or-later
// ZeeOS install slideshow (slideshowAPI 2). Text only, English (ADR-0009); layout follows Qt's
// mirroring, so it needs no per-language code.
import QtQuick 2.15
import calamares.slideshow 1.0

Presentation {
    id: presentation

    function onActivate() { }
    function onLeave() { }

    Timer {
        interval: 15000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    Slide {
        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: 22
            color: "#1b1e2b"
            text: "Installing ZeeOS.\nThis takes a few minutes."
        }
    }

    Slide {
        Text {
            anchors.centerIn: parent
            width: parent.width * 0.8
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            font.pixelSize: 22
            color: "#1b1e2b"
            text: "When the installer finishes, restart and remove the install medium."
        }
    }
}
