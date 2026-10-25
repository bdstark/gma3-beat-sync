// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors

//! The Link bridge: receives gma3-phrase-sync's timeline over loopback UDP (protocols LB1 and LB2, specified and
//! encoded by the `link-bridge-protocol` crate, <https://github.com/bdstark/link-bridge-protocol>), publishes it to a
//! Link session through Ableton's Link library, and reports the session back to an LB2 service.
//!
//! - [`bridge`]: the protocol and the session report, sans-IO.
//! - [`publish`]: what a timeline does to the session state.
//! - [`link`]: the Link library (the only unsafe code).
//! - [`server`]: the socket and the loop.

pub mod bridge;
pub mod link;
pub mod publish;
pub mod server;
