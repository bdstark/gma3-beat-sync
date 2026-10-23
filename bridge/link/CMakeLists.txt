# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 gma3-beat-sync contributors
#
# Ableton's C wrapper for the Link library, abl_link, built from the submodule in modules/link as a static library
# for the bridge. bridge/build.rs runs this through the cmake crate and links the result.
cmake_minimum_required(VERSION 3.16)
project(link_bridge_abl_link C CXX)

set(LINK_DIR ${CMAKE_CURRENT_LIST_DIR}/../../modules/link)
if(NOT EXISTS ${LINK_DIR}/AbletonLinkConfig.cmake)
  message(FATAL_ERROR "modules/link is empty; run: git submodule update --init --recursive")
endif()
include(${LINK_DIR}/AbletonLinkConfig.cmake)
include(${LINK_DIR}/extensions/abl_link/abl_link.cmake)

install(TARGETS abl_link ARCHIVE DESTINATION lib)
