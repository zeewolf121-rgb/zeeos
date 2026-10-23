// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 ZeeOS contributors
// Windows mode: one bottom panel: Kickoff, centered Icons-only Task Manager, tray, clock.
var panel = new Panel;
panel.location = "bottom";
panel.height = 2 * Math.round(gridUnit * 2.5 / 2);
panel.alignment = "center";
panel.addWidget("org.kde.plasma.kickoff");
panel.addWidget("org.kde.plasma.panelspacer");
panel.addWidget("org.kde.plasma.icontasks");
panel.addWidget("org.kde.plasma.panelspacer");
panel.addWidget("org.kde.plasma.systemtray");
panel.addWidget("org.kde.plasma.digitalclock");

// --resetLayout rebuilds the desktops with Plasma's stock wallpaper, and the once-per-user
// zeeos-wallpaper.js update doesn't run again: set the ZeeOS package here too (light/dark aware).
desktops().forEach(function (d) {
    d.wallpaperPlugin = "org.kde.image";
    d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    d.writeConfig("Image", "/usr/share/wallpapers/ZeeOS/");
});
