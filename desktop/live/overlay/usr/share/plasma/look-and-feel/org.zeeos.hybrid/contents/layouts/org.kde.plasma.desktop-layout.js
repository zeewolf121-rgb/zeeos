// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 ZeeOS contributors
// Hybrid mode (default): top panel (Global Menu, tray, clock) and a floating bottom panel
// (Kickoff, centered Icons-only Task Manager).
var top = new Panel;
top.location = "top";
top.height = 2 * Math.round(gridUnit * 1.5 / 2);
top.addWidget("org.kde.plasma.appmenu");
top.addWidget("org.kde.plasma.panelspacer");
top.addWidget("org.kde.plasma.systemtray");
top.addWidget("org.kde.plasma.digitalclock");

var bottom = new Panel;
bottom.location = "bottom";
bottom.height = 2 * Math.round(gridUnit * 2.5 / 2);
bottom.alignment = "center";
bottom.floating = true;
bottom.addWidget("org.kde.plasma.kickoff");
bottom.addWidget("org.kde.plasma.panelspacer");
bottom.addWidget("org.kde.plasma.icontasks");
bottom.addWidget("org.kde.plasma.panelspacer");

// --resetLayout rebuilds the desktops with Plasma's stock wallpaper, and the once-per-user
// zeeos-wallpaper.js update doesn't run again: set the ZeeOS package here too (light/dark aware).
desktops().forEach(function (d) {
    d.wallpaperPlugin = "org.kde.image";
    d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    d.writeConfig("Image", "/usr/share/wallpapers/ZeeOS/");
});
