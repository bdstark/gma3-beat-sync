# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 gma3-beat-sync contributors
#
# Test tools built from the Link library in modules/link:
#   gbs-test-peer  a command-line peer: joins a session, sets the tempo, starts and stops, prints its beat time
#   gbs-capture    records the session's packets (and ping/pong exchanges) as harness fixtures, decoded by Link
#   gbs-vectors    prints reference values of Link's timeline arithmetic for the Lua harness
cmake_minimum_required(VERSION 3.16)
project(gma3_beat_sync_tools CXX)

set(LINK_DIR ${CMAKE_CURRENT_LIST_DIR}/../../modules/link)
if(NOT EXISTS ${LINK_DIR}/AbletonLinkConfig.cmake)
  message(FATAL_ERROR "modules/link is empty; run: git submodule update --init --recursive")
endif()
include(${LINK_DIR}/AbletonLinkConfig.cmake)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

foreach(tool test_peer capture vectors)
  string(REPLACE "_" "-" name "gbs-${tool}")
  add_executable(${name} ${tool}.cpp)
  target_link_libraries(${name} Ableton::Link)
  if(NOT MSVC)
    target_compile_options(${name} PRIVATE -Wall -Wextra)
  endif()
endforeach()
