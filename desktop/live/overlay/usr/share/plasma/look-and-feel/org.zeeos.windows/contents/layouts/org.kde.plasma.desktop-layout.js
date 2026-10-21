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
