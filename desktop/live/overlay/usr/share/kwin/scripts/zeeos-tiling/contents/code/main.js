// SPDX-License-Identifier: GPL-3.0-or-later
// ZeeOS tiling toggle. Meta+T switches master-stack auto-tiling on or off. While on, normal
// windows on the same screen and virtual desktop are laid out: the first takes the left half,
// the rest stack on the right. Off restores each window's previous geometry.
"use strict";

var enabled = false;
var saved = {}; // internalId -> frameGeometry before tiling

function tileable(w) {
    return w && w.normalWindow && w.moveable && w.resizeable && !w.fullScreen &&
        !w.minimized && !w.dock && !w.desktopWindow;
}

function key(w) {
    return String(w.internalId);
}

function layout(output, desktop) {
    var list = workspace.windowList().filter(function (w) {
        return tileable(w) && w.output === output &&
            (w.onAllDesktops || w.desktops.indexOf(desktop) >= 0);
    });
    if (list.length === 0) {
        return;
    }
    var area = workspace.clientArea(KWin.PlacementArea, output, desktop);
    var half = Math.floor(area.width / 2);
    list.forEach(function (w, i) {
        if (!saved[key(w)]) {
            var f = w.frameGeometry;
            saved[key(w)] = { x: f.x, y: f.y, width: f.width, height: f.height };
        }
        w.setMaximize(false, false);
        var g;
        if (list.length === 1) {
            g = area;
        } else if (i === 0) {
            g = { x: area.x, y: area.y, width: half, height: area.height };
        } else {
            var h = Math.floor(area.height / (list.length - 1));
            g = { x: area.x + half, y: area.y + (i - 1) * h, width: area.width - half, height: h };
        }
        w.frameGeometry = g;
    });
}

function retile() {
    if (!enabled) {
        return;
    }
    workspace.screens.forEach(function (output) {
        layout(output, workspace.currentDesktop);
    });
}

function restore() {
    workspace.windowList().forEach(function (w) {
        var g = saved[key(w)];
        if (g && tileable(w)) {
            w.frameGeometry = g;
        }
    });
    saved = {};
}

function toggle() {
    enabled = !enabled;
    if (enabled) {
        retile();
    } else {
        restore();
    }
    print("zeeos-tiling: " + (enabled ? "on" : "off"));
}

workspace.windowAdded.connect(function (w) {
    if (tileable(w)) {
        retile();
    }
});
workspace.windowRemoved.connect(function (w) {
    delete saved[key(w)];
    retile();
});
workspace.currentDesktopChanged.connect(retile);

registerShortcut("ZeeOS Toggle Tiling", "ZeeOS: Toggle Tiling", "Meta+T", toggle);
