# SPDX-License-Identifier: GPL-3.0-or-later
"""Shared conservative document-topic guard for the automatic low-risk lane."""
import re

# Unicode letters/digits form words; underscores are separators in document paths.
# Exact words deliberately exclude "information", "reformat" and other substrings.
# Multiword topics also accept whitespace, underscores and hyphens in filenames.
DISK_TOPIC = re.compile(
    r"(?<![^\W_])(?:partition|dual[\s_-]+boot|bootloader|grub|shim|ESP|EFI|NVRAM|"
    r"Secure[\s_-]+Boot|LUKS|BitLocker|encryption|format|wipe|"
    r"Windows[\s_-]+Boot[\s_-]+Manager|installer)(?![^\W_])",
    re.IGNORECASE,
)


def disk_topic(text: str, original_length: int = 0) -> bool:
    """Include topics formed across an append boundary; ignore unchanged topics."""
    return any(match.end() > original_length for match in DISK_TOPIC.finditer(text))
