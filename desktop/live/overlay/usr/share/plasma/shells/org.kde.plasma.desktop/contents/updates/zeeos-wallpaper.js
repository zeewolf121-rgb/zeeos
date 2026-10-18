// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 ZeeOS contributors
// Plasma update script: plasmashell runs it once per user (it records the run in plasmashellrc),
// so it sets the ZeeOS wallpaper on first login and never overrides a later user choice.
// The package has images/ and images_dark/, so Plasma follows the light/dark colour scheme.
desktops().forEach(function (d) {
    d.wallpaperPlugin = "org.kde.image";
    d.currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    d.writeConfig("Image", "/usr/share/wallpapers/ZeeOS/");
});
