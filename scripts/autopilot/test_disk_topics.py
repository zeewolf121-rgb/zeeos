#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fail-closed text guard tests; no network or provider calls."""
import unittest

from disk_topics import disk_topic, hidden_characters


TOPICS = (
    "dd", "mkfs", "fdisk", "gdisk", "parted", "sfdisk", "diskpart",
    "efibootmgr", "bcdedit", "wipefs", "cryptsetup", "/dev/", "disk",
    "drive", "volume", "UEFI", "BIOS", "firmware", "boot", "install",
    "reinstall", "erase", "overwrite", "sudo", "rm -rf",
)


class DiskTopicTests(unittest.TestCase):
    def test_every_new_topic_and_unicode_evasion(self):
        for topic in TOPICS:
            fullwidth = "".join(chr(ord(c) + 0xFEE0) if "!" <= c <= "~" else c for c in topic)
            for spelling in (topic, topic.swapcase(), fullwidth, topic[:1] + "\u200b" + topic[1:]):
                with self.subTest(spelling=spelling):
                    self.assertTrue(disk_topic(f"Discuss ({spelling})."))

    def test_hidden_controls_and_residual_non_ascii_hold(self):
        for char in ("\u200b", "\u202e", "\u00ad", "\x01", "\x7f", "\r"):
            with self.subTest(char=repr(char)):
                self.assertTrue(hidden_characters("note" + char))
                self.assertTrue(disk_topic("note" + char))
        for text in ("dіsk", "bοot", "d\u0338isk", "Résumé", "ß", "smart ’ quote"):
            with self.subTest(text=text):
                self.assertTrue(disk_topic(text))
        self.assertFalse(disk_topic("Ordinary\n\tnote."))
        self.assertFalse(hidden_characters("Ordinary\n\tnote."))

    def test_whole_words_and_substrings(self):
        for text in ("added", "diskette", "driven", "volumes", "reinstalled",
                     "information_reformat", "espresso", "shimmering"):
            with self.subTest(text=text):
                self.assertFalse(disk_topic(text))
        for text in ("docs/user/DISK_guide.md", "x/dev/nvme0n1", "xrm -rfx"):
            with self.subTest(text=text):
                self.assertTrue(disk_topic(text))

    def test_normalized_append_boundary_and_unchanged_text(self):
        for original in ("Résumé: for", "ﬃ: for", "ｆｏｒ", "Straße: for"):
            with self.subTest(original=original):
                self.assertTrue(disk_topic(original + "mat", len(original)))
                self.assertFalse(disk_topic(original + " a note.", len(original)))
        original = "Existing disk warning.\n"
        self.assertFalse(disk_topic(original + "Ordinary addition.\n", len(original)))


if __name__ == "__main__":
    unittest.main()
