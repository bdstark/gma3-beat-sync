// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// gbs-vectors: prints reference values of Link's timeline arithmetic, computed by Link's own code, for the Lua
// harness (test/lua/protocol_test.lua) to reproduce exactly. One case per line:
//
//   <function> <inputs...> = <outputs...>
//
// Integers are printed as integers; floating-point values with 17 significant digits. The inputs are fixed values
// at the edges plus pseudo-random values from std::mt19937_64 with a fixed seed (its raw output is the same on
// every platform; no std distribution is used).
//
// Functions, from the Link source:
//   include/ableton/link/Tempo.hpp                  Tempo(microseconds), bpm(), microsPerBeat()
//   include/ableton/link/Timeline.hpp               toBeats, fromBeats
//   include/ableton/link/Phase.hpp                  phase, nextPhaseMatch, closestPhaseMatch,
//                                                   toPhaseEncodedBeats, fromPhaseEncodedBeats
//   include/ableton/link/GhostXForm.hpp             hostToGhost, ghostToHost
//   include/ableton/link/Median.hpp                 median
//   include/ableton/link/ClientSessionTimelines.hpp clampTempo, updateClientTimelineFromSession

#include <ableton/link/ClientSessionTimelines.hpp>
#include <ableton/link/GhostXForm.hpp>
#include <ableton/link/Median.hpp>
#include <ableton/link/Phase.hpp>
#include <ableton/link/Timeline.hpp>

#include <cstdint>
#include <cstdio>
#include <random>
#include <vector>

namespace
{

using namespace ableton::link;
using std::chrono::microseconds;

std::mt19937_64 gRng(20261015);

// Uniform-ish integer in [lo, hi] from the raw generator output.
std::int64_t pick(std::int64_t lo, std::int64_t hi)
{
  const auto span = static_cast<std::uint64_t>(hi - lo) + 1;
  return lo + static_cast<std::int64_t>(gRng() % span);
}

long long ll(std::int64_t v) { return static_cast<long long>(v); }

Timeline timeline(std::int64_t microsPerBeat, std::int64_t beatOrigin, std::int64_t timeOrigin)
{
  return Timeline{Tempo{microseconds{microsPerBeat}}, Beats{beatOrigin}, microseconds{timeOrigin}};
}

const std::int64_t kMicrosPerBeat[] = {500000, 461538, 3000000, 60060, 1000000, 428571, 652174};
const std::int64_t kQuanta[] = {1000000, 4000000, 3000000, 3500000, 7000000, 16000000};

void tempoCases()
{
  for (const auto mpb : kMicrosPerBeat)
  {
    const auto t = Tempo{microseconds{mpb}};
    std::printf("tempo %lld = %.17g %lld\n", ll(mpb), t.bpm(), ll(t.microsPerBeat().count()));
  }
  const double bpms[] = {120.0, 130.0, 20.0, 999.0, 133.3333, 19.5, 1200.0, 87.654321};
  for (const auto bpm : bpms)
  {
    const auto tl = clampTempo(Timeline{Tempo{bpm}, Beats{INT64_C(0)}, microseconds{0}});
    std::printf("bpm %.17g = %lld %.17g\n", bpm, ll(Tempo{bpm}.microsPerBeat().count()), tl.tempo.bpm());
  }
}

void timelineCases()
{
  for (int i = 0; i < 300; ++i)
  {
    const auto mpb = i < 7 ? kMicrosPerBeat[i] : pick(60060, 3000000);
    const auto bo = i % 5 == 0 ? 0 : pick(-2000000000, 2000000000000);
    const auto to = i % 7 == 0 ? 0 : pick(-1000000000000, 4000000000000);
    const auto tl = timeline(mpb, bo, to);
    const auto t = to + pick(-3600000000, 36000000000);
    const auto b = bo + pick(-1000000000, 100000000000);
    std::printf("toBeats %lld %lld %lld %lld = %lld\n", ll(mpb), ll(bo), ll(to), ll(t),
                ll(tl.toBeats(microseconds{t}).microBeats()));
    std::printf("fromBeats %lld %lld %lld %lld = %lld\n", ll(mpb), ll(bo), ll(to), ll(b),
                ll(tl.fromBeats(Beats{b}).count()));
    const auto q = kQuanta[i % 6];
    std::printf("toPhaseEncodedBeats %lld %lld %lld %lld %lld = %lld\n", ll(mpb), ll(bo), ll(to), ll(t), ll(q),
                ll(toPhaseEncodedBeats(tl, microseconds{t}, Beats{q}).microBeats()));
    std::printf("fromPhaseEncodedBeats %lld %lld %lld %lld %lld = %lld\n", ll(mpb), ll(bo), ll(to), ll(b), ll(q),
                ll(fromPhaseEncodedBeats(tl, Beats{b}, Beats{q}).count()));
  }
}

void phaseCases()
{
  const std::int64_t edges[] = {0, 1, -1, 999999, 1000000, -1000000, 4000000, -4000000, 3999999, -3999999,
                                2000000, -2000000, 1999999, 2000001};
  for (const auto q : kQuanta)
  {
    for (const auto x : edges)
    {
      std::printf("phase %lld %lld = %lld\n", ll(x), ll(q), ll(phase(Beats{x}, Beats{q}).microBeats()));
      for (const auto target : edges)
      {
        std::printf("nextPhaseMatch %lld %lld %lld = %lld\n", ll(x), ll(target), ll(q),
                    ll(nextPhaseMatch(Beats{x}, Beats{target}, Beats{q}).microBeats()));
        std::printf("closestPhaseMatch %lld %lld %lld = %lld\n", ll(x), ll(target), ll(q),
                    ll(closestPhaseMatch(Beats{x}, Beats{target}, Beats{q}).microBeats()));
      }
    }
  }
  std::printf("phase 5000000 0 = %lld\n", ll(phase(Beats{INT64_C(5000000)}, Beats{INT64_C(0)}).microBeats()));
  for (int i = 0; i < 200; ++i)
  {
    const auto q = kQuanta[i % 6];
    const auto x = pick(-100000000000, 100000000000);
    const auto target = pick(-100000000000, 100000000000);
    std::printf("phase %lld %lld = %lld\n", ll(x), ll(q), ll(phase(Beats{x}, Beats{q}).microBeats()));
    std::printf("nextPhaseMatch %lld %lld %lld = %lld\n", ll(x), ll(target), ll(q),
                ll(nextPhaseMatch(Beats{x}, Beats{target}, Beats{q}).microBeats()));
    std::printf("closestPhaseMatch %lld %lld %lld = %lld\n", ll(x), ll(target), ll(q),
                ll(closestPhaseMatch(Beats{x}, Beats{target}, Beats{q}).microBeats()));
  }
}

void ghostCases()
{
  for (int i = 0; i < 100; ++i)
  {
    // Link measures with slope 1 (MeasurementService.hpp); other slopes check the arithmetic.
    const double slope = i < 50 ? 1.0 : 1.0 + static_cast<double>(pick(-1000, 1000)) * 1e-6;
    const auto intercept = pick(-4000000000000, 4000000000000);
    const auto x = GhostXForm{slope, microseconds{intercept}};
    const auto h = pick(0, 4000000000000);
    const auto g = pick(-4000000000000, 8000000000000);
    std::printf("hostToGhost %.17g %lld %lld = %lld\n", slope, ll(intercept), ll(h),
                ll(x.hostToGhost(microseconds{h}).count()));
    std::printf("ghostToHost %.17g %lld %lld = %lld\n", slope, ll(intercept), ll(g),
                ll(x.ghostToHost(microseconds{g}).count()));
  }
}

void medianCases()
{
  for (int n = 3; n < 40; ++n)
  {
    std::vector<double> v;
    for (int i = 0; i < n; ++i)
      v.push_back(static_cast<double>(pick(-5000000, 5000000)) + (i % 2 ? 0.5 : 0.0));
    std::printf("median");
    for (const auto d : v)
      std::printf(" %.17g", d);
    std::printf(" = %.17g\n", median(v.begin(), v.end()));
  }
}

void clientTimelineCases()
{
  for (int i = 0; i < 100; ++i)
  {
    const auto client = timeline(kMicrosPerBeat[i % 7], pick(-1000000000, 100000000000),
                                 pick(0, 4000000000000));
    const auto session = timeline(pick(60060, 3000000), pick(0, 100000000000), pick(-4000000000000, 8000000000000));
    const auto at = pick(0, 4000000000000);
    const auto x = GhostXForm{1.0, microseconds{pick(-4000000000000, 4000000000000)}};
    const auto r = updateClientTimelineFromSession(client, session, microseconds{at}, x);
    std::printf("updateClientTimelineFromSession %lld %lld %lld %lld %lld %lld %lld %lld = %lld %lld %lld\n",
                ll(client.tempo.microsPerBeat().count()), ll(client.beatOrigin.microBeats()),
                ll(client.timeOrigin.count()), ll(session.tempo.microsPerBeat().count()),
                ll(session.beatOrigin.microBeats()), ll(session.timeOrigin.count()), ll(at),
                ll(x.intercept.count()), ll(r.tempo.microsPerBeat().count()), ll(r.beatOrigin.microBeats()),
                ll(r.timeOrigin.count()));
  }
}

} // namespace

int main()
{
  std::printf("# Reference values from Link's own arithmetic, printed by gbs-vectors (tools/test-peer/vectors.cpp).\n"
              "# Regenerate with: scripts/check.sh vectors\n");
  tempoCases();
  timelineCases();
  phaseCases();
  ghostCases();
  medianCases();
  clientTimelineCases();
  return 0;
}
