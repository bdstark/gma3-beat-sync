// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// gbs-test-peer: a minimal command-line peer built from the Link library (modules/link), so gma3-beat-sync can be
// tested without Ableton Live. It joins a session, sets the tempo, starts and stops, and prints its beat time as
// JSON lines on stdout. Commands are read from stdin, one per line:
//
//   tempo <bpm>      propose a tempo to the session
//   play | stop      start or stop (start/stop sync is on unless --no-start-stop-sync)
//   quantum <beats>  quantum for beat and phase in the samples, and for starting
//   enable | disable join or leave the session
//   sample           print one sample now
//   quit             leave the session and exit
//
// Each sample has the wall clock (wall_us, microseconds since the Unix epoch) next to Link's host clock (host_us),
// so a follower on the same machine can compare its own beat time at a wall-clock instant.

#include <ableton/Link.hpp>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>

namespace
{

std::atomic<bool> gRunning{true};
std::mutex gOutMutex;

void onSignal(int) { gRunning = false; }

long long wallMicros()
{
  using namespace std::chrono;
  return duration_cast<microseconds>(system_clock::now().time_since_epoch()).count();
}

void emit(const std::string& line)
{
  std::lock_guard<std::mutex> lock(gOutMutex);
  std::cout << line << std::endl;
}

struct Options
{
  double tempo = 120.0;
  double quantum = 4.0;
  int intervalMs = 20;
  double durationS = 0.0; // 0 = until quit, EOF on stdin does not stop the peer
  bool play = false;
  bool startStopSync = true;
  bool enabled = true;
};

void usage()
{
  std::cerr << "usage: gbs-test-peer [--tempo BPM] [--quantum BEATS] [--interval-ms MS] [--duration-s S]\n"
               "                     [--play] [--no-start-stop-sync] [--disabled]\n";
}

bool parseOptions(int argc, char** argv, Options& o)
{
  for (int i = 1; i < argc; ++i)
  {
    const std::string a = argv[i];
    auto value = [&](const char* name) -> const char*
    {
      if (i + 1 >= argc)
      {
        std::cerr << name << " needs a value\n";
        return nullptr;
      }
      return argv[++i];
    };
    const char* v = nullptr;
    if (a == "--tempo" && (v = value("--tempo")))
      o.tempo = std::atof(v);
    else if (a == "--quantum" && (v = value("--quantum")))
      o.quantum = std::atof(v);
    else if (a == "--interval-ms" && (v = value("--interval-ms")))
      o.intervalMs = std::atoi(v);
    else if (a == "--duration-s" && (v = value("--duration-s")))
      o.durationS = std::atof(v);
    else if (a == "--play")
      o.play = true;
    else if (a == "--no-start-stop-sync")
      o.startStopSync = false;
    else if (a == "--disabled")
      o.enabled = false;
    else
    {
      usage();
      return false;
    }
  }
  return o.quantum > 0 && o.tempo > 0;
}

std::string sample(ableton::Link& link, double quantum, const char* ev)
{
  const auto host = link.clock().micros();
  const auto wall = wallMicros();
  const auto state = link.captureAppSessionState();
  char buf[512];
  std::snprintf(buf, sizeof buf,
                "{\"ev\":\"%s\",\"wall_us\":%lld,\"host_us\":%lld,\"bpm\":%.6f,\"beat\":%.6f,\"phase\":%.6f,"
                "\"quantum\":%g,\"playing\":%s,\"peers\":%zu,\"enabled\":%s}",
                ev, wall, static_cast<long long>(host.count()), state.tempo(),
                state.beatAtTime(host, quantum), state.phaseAtTime(host, quantum), quantum,
                state.isPlaying() ? "true" : "false", link.numPeers(), link.isEnabled() ? "true" : "false");
  return buf;
}

// A JSON string literal: quotes, backslashes and control characters escaped (RFC 8259). Other bytes, UTF-8
// included, pass through.
std::string jsonString(const std::string& v)
{
  std::string out = "\"";
  for (const unsigned char c : v)
  {
    switch (c)
    {
    case '"': out += "\\\""; break;
    case '\\': out += "\\\\"; break;
    case '\n': out += "\\n"; break;
    case '\r': out += "\\r"; break;
    case '\t': out += "\\t"; break;
    case '\b': out += "\\b"; break;
    case '\f': out += "\\f"; break;
    default:
      if (c < 0x20 || c == 0x7f)
      {
        char buf[8];
        std::snprintf(buf, sizeof buf, "\\u%04x", c);
        out += buf;
      }
      else
        out += static_cast<char>(c);
    }
  }
  return out + "\"";
}

std::string ack(const std::string& cmd, bool ok, const std::string& detail = "")
{
  std::ostringstream s;
  s << "{\"ev\":\"" << (ok ? "ack" : "error") << "\",\"cmd\":" << jsonString(cmd) << ",\"wall_us\":" << wallMicros();
  if (!detail.empty())
    s << ",\"detail\":" << jsonString(detail);
  s << "}";
  return s.str();
}

} // namespace

int main(int argc, char** argv)
{
  Options opt;
  if (!parseOptions(argc, argv, opt))
    return 2;

  std::signal(SIGINT, onSignal);
  std::signal(SIGTERM, onSignal);

  ableton::Link link(opt.tempo);
  std::atomic<double> quantum{opt.quantum};
  link.enableStartStopSync(opt.startStopSync);
  link.setNumPeersCallback([&](std::size_t n)
                           { emit("{\"ev\":\"peers\",\"wall_us\":" + std::to_string(wallMicros())
                                  + ",\"peers\":" + std::to_string(n) + "}"); });
  link.setTempoCallback([&](double bpm)
                        { emit("{\"ev\":\"tempo\",\"wall_us\":" + std::to_string(wallMicros())
                               + ",\"bpm\":" + std::to_string(bpm) + "}"); });
  link.setStartStopCallback([&](bool playing)
                            { emit("{\"ev\":\"startstop\",\"wall_us\":" + std::to_string(wallMicros())
                                   + ",\"playing\":" + (playing ? "true" : "false") + "}"); });
  link.enable(opt.enabled);

  auto setPlaying = [&](bool playing)
  {
    auto state = link.captureAppSessionState();
    const auto now = link.clock().micros();
    if (playing)
      state.setIsPlayingAndRequestBeatAtTime(true, now, 0., quantum.load());
    else
      state.setIsPlaying(false, now);
    link.commitAppSessionState(state);
  };
  emit(sample(link, quantum.load(), "start"));

  std::thread input(
    [&]
    {
      std::string line;
      while (gRunning && std::getline(std::cin, line))
      {
        std::istringstream in(line);
        std::string cmd;
        in >> cmd;
        if (cmd.empty())
          continue;
        if (cmd == "tempo")
        {
          double bpm = 0;
          if (!(in >> bpm) || bpm <= 0)
          {
            emit(ack(cmd, false, "tempo needs a positive bpm"));
            continue;
          }
          auto state = link.captureAppSessionState();
          state.setTempo(bpm, link.clock().micros());
          link.commitAppSessionState(state);
          emit(ack(cmd, true));
        }
        else if (cmd == "play" || cmd == "stop")
        {
          setPlaying(cmd == "play");
          emit(ack(cmd, true));
        }
        else if (cmd == "quantum")
        {
          double q = 0;
          if (!(in >> q) || q <= 0)
          {
            emit(ack(cmd, false, "quantum needs a positive number of beats"));
            continue;
          }
          quantum = q;
          emit(ack(cmd, true));
        }
        else if (cmd == "enable" || cmd == "disable")
        {
          link.enable(cmd == "enable");
          emit(ack(cmd, true));
        }
        else if (cmd == "sample")
          emit(sample(link, quantum.load(), "sample"));
        else if (cmd == "quit")
        {
          emit(ack(cmd, true));
          gRunning = false;
        }
        else
          emit(ack(cmd, false, "unknown command"));
      }
    });
  input.detach(); // getline may block until the process exits

  // --play is applied 1 s after enabling. Enabling resets the session's start/stop state on Link's own thread
  // (link/Controller.hpp, resetState()), and a play committed before that is lost: in a test on 2026-10-15 a play
  // 200 ms after enable() was never announced, while plays 600 ms and 1.1 s after it were.
  bool playPending = opt.play;
  const auto t0 = std::chrono::steady_clock::now();
  while (gRunning)
  {
    if (playPending && std::chrono::steady_clock::now() - t0 >= std::chrono::milliseconds(1000))
    {
      setPlaying(true);
      playPending = false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(opt.intervalMs > 0 ? opt.intervalMs : 20));
    if (opt.intervalMs > 0)
      emit(sample(link, quantum.load(), "sample"));
    if (opt.durationS > 0
        && std::chrono::steady_clock::now() - t0 >= std::chrono::duration<double>(opt.durationS))
      gRunning = false;
  }
  emit(sample(link, quantum.load(), "end"));
  link.enable(false); // sends the leave (ByeBye) message from Link's own thread
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  std::fflush(stdout);
  std::_Exit(0); // the input thread may still be blocked in getline
}
