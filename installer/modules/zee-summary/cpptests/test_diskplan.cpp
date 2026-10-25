/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Unit tests for DiskPlan (no Qt, no Calamares). Run:
 *   g++ -std=c++17 -Wall -Wextra -Werror -I installer/modules/zee-summary \
 *       installer/modules/zee-summary/DiskPlan.cpp installer/modules/zee-summary/cpptests/test_diskplan.cpp \
 *       -o /tmp/test_diskplan && /tmp/test_diskplan
 */
#include "DiskPlan.h"

#include <iostream>
#include <string>

using namespace ZeeSummary;

static int failures = 0;

static void
expect( bool ok, const std::string& what )
{
    std::cout << ( ok ? "ok   " : "FAIL " ) << what << '\n';
    failures += ok ? 0 : 1;
}

static void
expectEq( const std::string& got, const std::string& want, const std::string& what )
{
    expect( got == want, what + " (got '" + got + "', want '" + want + "')" );
}

int
main()
{
    expectEq( parentDisk( "/dev/sda2" ), "/dev/sda", "sata partition" );
    expectEq( parentDisk( "/dev/sda" ), "/dev/sda", "sata disk" );
    expectEq( parentDisk( "/dev/vdb13" ), "/dev/vdb", "virtio partition" );
    expectEq( parentDisk( "/dev/xvda1" ), "/dev/xvda", "xen partition" );
    expectEq( parentDisk( "/dev/nvme0n1p3" ), "/dev/nvme0n1", "nvme partition" );
    expectEq( parentDisk( "/dev/nvme0n1" ), "/dev/nvme0n1", "nvme disk" );
    expectEq( parentDisk( "/dev/mmcblk0p1" ), "/dev/mmcblk0", "mmc partition" );
    expectEq( parentDisk( "/dev/mmcblk0" ), "/dev/mmcblk0", "mmc disk" );
    expectEq( parentDisk( "/dev/loop0p1" ), "/dev/loop0", "loop partition" );
    expectEq( parentDisk( "/dev/md127" ), "/dev/md127", "md device" );
    expectEq( parentDisk( "/dev/mapper/luks-1" ), "/dev/mapper/luks-1", "mapper device" );

    expectEq( stripMarkup( "Format partition <strong>/dev/sda1</strong>&nbsp;(fat32)" ),
              "Format partition /dev/sda1 (fat32)",
              "tags and nbsp" );
    expectEq( stripMarkup( "a &amp;lt; b" ), "a &lt; b", "amp decoded last" );
    expectEq( stripMarkup( "  <b> </b> " ), "", "markup only is empty" );

    expectEq( firstDevice( "Create new partition on /dev/nvme0n1 (Samsung)." ), "/dev/nvme0n1", "device before space" );
    expectEq( firstDevice( "Set flags on <b>/dev/sda1</b>." ), "/dev/sda1", "device before tag" );
    expectEq( firstDevice( "Install boot loader." ), "", "no device" );
    expectEq( firstDevice( "on /dev/ only" ), "", "bare /dev/" );

    const auto groups = groupByDisk( {
        "Create new <strong>GPT</strong> partition table on <strong>/dev/sda</strong> (QEMU HARDDISK).",
        "Create new <strong>600MiB</strong> partition on <strong>/dev/sda</strong> with file system <strong>fat32</strong>.",
        "Resize partition <strong>/dev/nvme0n1p3</strong> from 200GiB to 120GiB.",
        "Set up the new encrypted root.",
        "",
        "Format partition <strong>/dev/sda2</strong> (file system: ext4, size: 2048 MiB) on /dev/sda.",
    } );
    expect( groups.size() == 3, "three groups (sda, nvme0n1, other)" );
    if ( groups.size() == 3 )
    {
        expectEq( groups[ 0 ].disk, "/dev/sda", "first-seen disk first" );
        expect( groups[ 0 ].changes.size() == 3, "sda has three changes in job order" );
        expectEq( groups[ 0 ].changes[ 2 ],
                  "Format partition /dev/sda2 (file system: ext4, size: 2048 MiB) on /dev/sda.",
                  "partition job lands on its disk" );
        expectEq( groups[ 1 ].disk, "/dev/nvme0n1", "nvme group" );
        expectEq( groups[ 2 ].disk, "", "deviceless group last" );
        expect( groups[ 2 ].changes.size() == 1, "empty description dropped" );
    }
    expect( groupByDisk( {} ).empty(), "no jobs, no groups" );

    std::cout << ( failures ? "FAILED: " : "all passed: " ) << failures << " failure(s)\n";
    return failures ? 1 : 0;
}
