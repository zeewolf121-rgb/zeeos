# SPDX-License-Identifier: GPL-3.0-or-later
# zee-summary (P4-6, #178): out-of-tree Calamares view module, built against calamares-devel
# (Fedora package; provides the Calamares CMake package and calamares_add_plugin):
#   cmake -S installer/modules/zee-summary -B build/zee-summary && cmake --build build/zee-summary
#   ctest --test-dir build/zee-summary          # DiskPlan unit tests, no Calamares needed to run
#   cmake --install build/zee-summary            # -> lib/calamares/modules/zee-summary/
# Without calamares-devel only the DiskPlan test is configured.
cmake_minimum_required(VERSION 3.16)
project(zee-summary LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

enable_testing()
add_executable(test_diskplan DiskPlan.cpp tests/test_diskplan.cpp)
target_include_directories(test_diskplan PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
add_test(NAME diskplan COMMAND test_diskplan)

find_package(Calamares QUIET)
if(NOT Calamares_FOUND)
    message(STATUS "calamares-devel not found: building the DiskPlan test only")
    return()
endif()

find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Qml Quick)
include(CalamaresAddPlugin)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

calamares_add_plugin(zee-summary
    TYPE viewmodule
    EXPORT_MACRO PLUGINDLLEXPORT_PRO
    SOURCES
        Config.cpp
        DiskPlan.cpp
        ZeeSummaryViewStep.cpp
    RESOURCES
        zee-summary.qrc
    SHARED_LIB
    NO_CONFIG
)
