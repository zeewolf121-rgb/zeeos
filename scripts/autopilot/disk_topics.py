# SPDX-License-Identifier: GPL-3.0-or-later
"""Shared conservative document-topic guard for the automatic low-risk lane."""
import re
import unicodedata

# Normalized ASCII letters/digits form words; underscores separate path words.
# Exact words deliberately exclude "information", "reformat" and other substrings.
# Multiword topics also accept whitespace, underscores and hyphens in filenames.
DISK_TOPIC = re.compile(
    r"(?<![^\W_])(?:partition|dual[\s_-]+boot|bootloader|grub|shim|ESP|EFI|NVRAM|"
    r"Secure[\s_-]+Boot|LUKS|BitLocker|encryption|format|wipe|"
    r"Windows[\s_-]+Boot[\s_-]+Manager|installer|"
    r"dd|mkfs|fdisk|gdisk|parted|sfdisk|diskpart|efibootmgr|bcdedit|wipefs|"
    r"cryptsetup|disk|drive|volume|UEFI|BIOS|firmware|boot|install|reinstall|"
    r"erase|overwrite|sudo)(?![^\W_])|/dev/|rm -rf",
    re.IGNORECASE | re.ASCII,
)


def hidden_characters(text: str) -> bool:
    """Reject Unicode format/control characters except newline and tab."""
    return any(unicodedata.category(char) in {"Cf", "Cc"} and char not in "\n\t"
               for char in text)


def disk_topic(text: str, original_length: int = 0) -> bool:
    """Fail closed on unsafe additions; include topics across an append boundary.

    Added text must normalize to ASCII under NFKC. This deliberately also holds
    accented text, combining marks and non-ASCII punctuation for the owner lane.
    Unchanged text is exempt, but its normalized length sets the match boundary.
    """
    added = text[original_length:]
    if hidden_characters(added) or not unicodedata.normalize("NFKC", added).isascii():
        return True
    normalized = unicodedata.normalize("NFKC", text).casefold()
    boundary = len(unicodedata.normalize("NFKC", text[:original_length]).casefold())
    return any(match.end() > boundary for match in DISK_TOPIC.finditer(normalized))
