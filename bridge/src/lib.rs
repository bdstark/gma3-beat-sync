// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors

//! The Link bridge: receives gma3-phrase-sync's timeline over loopback UDP (protocol LB1, specified in
//! gma3-phrase-sync's `docs/link-bridge.md`, its messages in the `link-bridge-protocol` crate) and publishes it to a
//! Link session through Ableton's Link library.
//!
//! - [`bridge`]: the protocol, sans-IO.
//! - [`publish`]: what a timeline does to the session state.
//! - [`link`]: the Link library (the only unsafe code).
//! - [`server`]: the socket and the loop.

pub mod bridge;
pub mod link;
pub mod publish;
pub mod server;
