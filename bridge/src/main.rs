// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors

//! `link-bridge`: publishes gma3-phrase-sync's timeline to a Link session.

use std::process::ExitCode;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use link_bridge::server::{Config, Server};

const USAGE: &str = "\
usage: link-bridge [--listen ADDR:PORT] [--start-stop] [--quantum N]

Receives gma3-phrase-sync's timeline (protocol LB1 or LB2) over loopback UDP and publishes it to a Link session;
reports the session to a service that speaks LB2.

  --listen ADDR:PORT  where to listen, a loopback address (default 127.0.0.1:7822)
  --start-stop        share start and stop with the session (default: tempo and phase only)
  --quantum N         the bar session reports count beats in, 1 to 16 (default 4)
  -h, --help          this text";

fn parse(args: impl Iterator<Item = String>) -> Result<Option<Config>, String> {
    let mut config = Config::default();
    let mut args = args.peekable();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--listen" => {
                let v = args.next().ok_or("--listen needs ADDR:PORT")?;
                config.listen = v.parse().map_err(|_| format!("--listen: not an address:port: {v}"))?;
            }
            "--start-stop" => config.start_stop = true,
            "--quantum" => {
                let v = args.next().ok_or("--quantum needs N")?;
                config.quantum =
                    v.parse().ok().filter(|q| (1..=16).contains(q)).ok_or(format!("--quantum: not 1 to 16: {v}"))?;
            }
            "-h" | "--help" => return Ok(None),
            other => return Err(format!("unknown argument {other}")),
        }
    }
    Ok(Some(config))
}

fn main() -> ExitCode {
    let config = match parse(std::env::args().skip(1)) {
        Ok(Some(c)) => c,
        Ok(None) => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Err(e) => {
            eprintln!("link-bridge: {e}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let mut server = match Server::bind(&config) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("link-bridge: {}: {e}", config.listen);
            return ExitCode::FAILURE;
        }
    };
    let stop = Arc::new(AtomicBool::new(false));
    let on_signal = Arc::clone(&stop);
    if let Err(e) = ctrlc::set_handler(move || on_signal.store(true, Ordering::Relaxed)) {
        eprintln!("link-bridge: no Ctrl-C handler ({e}); the session sees the bridge leave only by its timeout");
    }
    let start = Instant::now();
    let log = |line: &str| println!("{:9.3} s  {line}", start.elapsed().as_secs_f64());
    log(&format!(
        "listening on {} (LB1, LB2); in the Link session; start/stop {}; session reports in bars of {}",
        server.local_addr().unwrap_or(config.listen),
        if config.start_stop { "shared" } else { "not shared" },
        config.quantum
    ));
    let result = server.run(&stop, log);
    drop(server); // leaves the Link session
    match result {
        Ok(()) => {
            println!("link-bridge: stopped");
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("link-bridge: {e}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use link_bridge::server::DEFAULT_LISTEN;

    fn args(s: &str) -> Result<Option<Config>, String> {
        parse(s.split_whitespace().map(str::to_owned))
    }

    #[test]
    fn arguments() {
        let c = args("").unwrap().unwrap();
        assert_eq!(
            (c.listen.to_string(), c.start_stop, c.enable_link, c.quantum),
            (DEFAULT_LISTEN.to_owned(), false, true, 4)
        );
        let c = args("--listen [::1]:9000 --start-stop --quantum 16").unwrap().unwrap();
        assert_eq!((c.listen.to_string(), c.start_stop, c.quantum), ("[::1]:9000".to_owned(), true, 16));
        assert!(args("--quantum").unwrap_err().contains("needs"));
        assert!(args("--quantum 0").unwrap_err().contains("not 1 to 16"));
        assert!(args("--quantum 17").unwrap_err().contains("not 1 to 16"));
        assert!(args("--help").unwrap().is_none());
        assert!(args("--listen").unwrap_err().contains("needs"));
        assert!(args("--listen localhost:7822").unwrap_err().contains("not an address:port"));
        assert!(args("--nope").unwrap_err().contains("unknown argument"));
    }
}
