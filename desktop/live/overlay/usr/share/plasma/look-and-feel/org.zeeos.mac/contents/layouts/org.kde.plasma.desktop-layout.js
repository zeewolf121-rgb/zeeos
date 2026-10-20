// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 ZeeOS contributors
// Mac mode: top panel (Kickoff, Global Menu, tray, clock) and a floating bottom dock (Icons-only Task Manager).
var top = new Panel;
top.location = "top";
top.height = 2 * Math.round(gridUnit * 1.5 / 2);
top.addWidget("org.kde.plasma.kickoff");
top.addWidget("org.kde.plasma.appmenu");
top.addWidget("org.kde.plasma.panelspacer");
top.addWidget("org.kde.plasma.systemtray");
top.addWidget("org.kde.plasma.digitalclock");

var dock = new Panel;
dock.location = "bottom";
dock.height = 2 * Math.round(gridUnit * 3 / 2);
dock.alignment = "center";
dock.lengthMode = "fit";
dock.floating = true;
dock.addWidget("org.kde.plasma.icontasks");
