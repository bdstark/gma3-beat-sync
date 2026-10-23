// SPDX-License-Identifier: GPL-2.0-or-later

//! Builds Ableton's C wrapper `abl_link` from the Link submodule (`modules/link`) with CMake, through
//! `bridge/link/CMakeLists.txt`, and links it with the C++ runtime and the platform's network libraries.

fn main() {
    let link = std::path::Path::new("../modules/link");
    if !link.join("AbletonLinkConfig.cmake").exists() {
        panic!("modules/link is empty; run: git submodule update --init --recursive");
    }
    println!("cargo:rerun-if-changed=link/CMakeLists.txt");
    println!("cargo:rerun-if-changed=../modules/link/extensions/abl_link");
    println!("cargo:rerun-if-changed=../modules/link/include");

    // Release whatever the Rust profile: Link's timing code is what we measure, and on MSVC it keeps the C runtime
    // the same as Rust's.
    let out = cmake::Config::new("link").profile("Release").build();
    println!("cargo:rustc-link-search=native={}", out.join("lib").display());
    println!("cargo:rustc-link-lib=static=abl_link");

    let target = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    match target.as_str() {
        "macos" | "ios" => println!("cargo:rustc-link-lib=c++"),
        "windows" => {
            for lib in ["ws2_32", "mswsock", "iphlpapi", "winmm"] {
                println!("cargo:rustc-link-lib={lib}");
            }
        }
        _ => {
            for lib in ["stdc++", "atomic", "pthread"] {
                println!("cargo:rustc-link-lib={lib}");
            }
        }
    }
}
