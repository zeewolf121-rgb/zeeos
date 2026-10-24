/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * zee-summary (P4-6, #178, ADR-0003): groups Calamares' planned partition jobs by disk.
 * Plain C++17, no Qt and no Calamares, so it is unit-tested on its own (tests/test_diskplan.cpp).
 */
#ifndef ZEE_SUMMARY_DISKPLAN_H
#define ZEE_SUMMARY_DISKPLAN_H

#include <string>
#include <vector>

namespace ZeeSummary
{

/// Changes for one disk, in job order. `disk` is "/dev/sda", "/dev/nvme0n1", ... or "" for
/// jobs that name no device (shown as "Other changes").
struct DiskChanges
{
    std::string disk;
    std::vector< std::string > changes;
};

/// Removes HTML tags and decodes the few entities Calamares' job descriptions use.
std::string stripMarkup( const std::string& text );

/// The first /dev/... path in @p text, or "" if there is none.
std::string firstDevice( const std::string& text );

/// The whole-disk node for a partition node: /dev/sda2 -> /dev/sda, /dev/nvme0n1p3 -> /dev/nvme0n1,
/// /dev/mmcblk0p1 -> /dev/mmcblk0. Whole disks and anything else (/dev/mapper/...) come back unchanged.
std::string parentDisk( const std::string& device );

/// Groups job descriptions (HTML allowed) by disk, keeping the order in which disks first appear.
/// Descriptions without a device go to a trailing group with an empty `disk`. Empty
/// descriptions are dropped.
std::vector< DiskChanges > groupByDisk( const std::vector< std::string >& descriptions );

}  // namespace ZeeSummary

#endif
