// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 gma3-beat-sync contributors
//
// gbs-capture: records the packets of the Link sessions on the network as fixtures for the Lua harness, and labels
// every packet with what Link's own parser makes of it, so the harness can compare its parser with Link's.
//
//   gbs-capture [--seconds S] [--ping N] [--note TEXT]   capture discovery packets for S seconds (default 3); with
//                                                         --ping, also run N ping/pong exchanges with the first peer
//                                                         that announces an IPv4 measurement endpoint
//   gbs-capture --decode                                 read fixture lines on stdin and (re)write their expect lines
//
// Fixture format, one record per line:
//   # comment
//   packet <discovery|ping|pong> <hex bytes>
//   expect <fields>    what Link's parser makes of the packet above (see describe*() below)
//
// The parsing below uses Link's own types:
//   include/ableton/discovery/v1/Messages.hpp  discovery header "_asdp_v\x01", message types, group id
//   include/ableton/link/v1/Messages.hpp       measurement header "_link_v\x01", ping and pong
//   include/ableton/discovery/Payload.hpp      payload entries: 4-byte key, 4-byte size, value
//   include/ableton/link/PeerState.hpp, NodeState.hpp, Timeline.hpp, SessionId.hpp, StartStopState.hpp,
//   PayloadEntries.hpp                         entry keys and value layouts

#include <ableton/discovery/Payload.hpp>
#include <ableton/discovery/v1/Messages.hpp>
#include <ableton/link/NodeId.hpp>
#include <ableton/link/PayloadEntries.hpp>
#include <ableton/link/PeerState.hpp>
#include <ableton/link/SessionId.hpp>
#include <ableton/link/StartStopState.hpp>
#include <ableton/link/Timeline.hpp>
#include <ableton/link/v1/Messages.hpp>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace
{

using namespace ableton;
using Bytes = std::vector<uint8_t>;

std::string hex(const uint8_t* p, std::size_t n)
{
  static const char* digits = "0123456789abcdef";
  std::string s;
  for (std::size_t i = 0; i < n; ++i)
  {
    s += digits[p[i] >> 4];
    s += digits[p[i] & 15];
  }
  return s;
}

std::string hex(const Bytes& b) { return hex(b.data(), b.size()); }

std::optional<Bytes> unhex(const std::string& s)
{
  if (s.size() % 2)
    return std::nullopt;
  Bytes b;
  for (std::size_t i = 0; i < s.size(); i += 2)
  {
    char* end = nullptr;
    const std::string byte = s.substr(i, 2);
    const long v = std::strtol(byte.c_str(), &end, 16);
    if (*end)
      return std::nullopt;
    b.push_back(static_cast<uint8_t>(v));
  }
  return b;
}

std::string idString(const link::NodeId& id) { return hex(id.data(), id.size()); }

std::string endpointString(const discovery::UdpEndpoint& ep)
{
  if (ep.address().is_v6())
    return "[" + ep.address().to_string() + "]:" + std::to_string(ep.port());
  return ep.address().to_string() + ":" + std::to_string(ep.port());
}

long long micros() // the capture's own clock for ping host times
{
  using namespace std::chrono;
  return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count();
}

// A discovery message as Link's UdpMessenger and PeerState::fromPayload read it.
std::string describeDiscovery(const Bytes& b)
{
  using namespace discovery;
  const auto res = v1::parseMessageHeader<link::NodeId>(b.begin(), b.end());
  const auto& h = res.first;
  std::ostringstream s;
  s << "type=" << int(h.messageType);
  if (h.messageType == v1::kInvalid)
    return s.str() + " rejected=header"; // too short, or not "_asdp_v\x01"
  s << " ttl=" << int(h.ttl) << " group=" << h.groupId << " node=" << idString(h.ident);
  if (h.groupId != 0)
    return s.str() + " ignored=group"; // UdpMessenger ignores other groups
  if (h.messageType == v1::kByeBye)
    return s.str(); // the payload of a ByeBye is not read
  if (h.messageType != v1::kAlive && h.messageType != v1::kResponse)
    return s.str() + " rejected=type";

  std::optional<link::Timeline> tl;
  std::optional<link::SessionId> sess;
  std::optional<link::StartStopState> stst;
  std::optional<discovery::UdpEndpoint> mep4, mep6, aep4, aep6;
  try
  {
    parsePayload<link::Timeline, link::SessionMembership, link::StartStopState,
                 link::PeerState::MeasurementEndpointV4, link::PeerState::MeasurementEndpointV6,
                 link::PeerState::AudioEndpointV4, link::PeerState::AudioEndpointV6>(
      res.second, b.end(), [&](link::Timeline v) { tl = v; },
      [&](link::SessionMembership v) { sess = v.sessionId; }, [&](link::StartStopState v) { stst = v; },
      [&](link::PeerState::MeasurementEndpointV4 v) { mep4 = v.ep; },
      [&](link::PeerState::MeasurementEndpointV6 v) { mep6 = v.ep; },
      [&](link::PeerState::AudioEndpointV4 v) { aep4 = v.ep; },
      [&](link::PeerState::AudioEndpointV6 v) { aep6 = v.ep; });
  }
  catch (const std::exception&)
  {
    return s.str() + " rejected=payload"; // UdpMessenger::receivePeerState drops the message
  }
  s << " tmln=";
  if (tl)
    s << tl->tempo.microsPerBeat().count() << "," << tl->beatOrigin.microBeats() << ","
      << tl->timeOrigin.count();
  else
    s << "absent";
  s << " sess=" << (sess ? idString(*sess) : "absent");
  s << " stst=";
  if (stst)
    s << (stst->isPlaying ? 1 : 0) << "," << stst->beats.microBeats() << "," << stst->timestamp.count();
  else
    s << "absent";
  s << " mep4=" << (mep4 ? endpointString(*mep4) : "absent");
  s << " mep6=" << (mep6 ? endpointString(*mep6) : "absent");
  s << " aep4=" << (aep4 ? endpointString(*aep4) : "absent");
  s << " aep6=" << (aep6 ? endpointString(*aep6) : "absent");
  return s.str();
}

// A measurement message as Link's Measurement (pong) and PingResponder (ping) read it.
std::string describeMeasurement(const Bytes& b)
{
  using namespace discovery;
  const auto res = link::v1::parseMessageHeader(b.begin(), b.end());
  const auto type = int(res.first.messageType);
  std::ostringstream s;
  s << "type=" << type;
  if (type == 0)
    return s.str() + " rejected=header"; // too short, or not "_link_v\x01"
  if (type == link::v1::kPing)
  {
    // PingResponder answers a ping whose payload is at most the size of HostTime + PrevGHostTime
    const auto size = static_cast<std::size_t>(std::distance(res.second, b.end()));
    const auto maxSize = sizeInByteStream(makePayload(link::HostTime{}, link::PrevGHostTime{}));
    s << " payload=" << size << (size <= maxSize ? " answered=1" : " answered=0");
    return s.str();
  }
  if (type != link::v1::kPong)
    return s.str() + " rejected=type";
  std::optional<link::SessionId> sess;
  std::optional<long long> gt, pgt, ht;
  try
  {
    parsePayload<link::SessionMembership, link::GHostTime, link::PrevGHostTime, link::HostTime>(
      res.second, b.end(), [&](link::SessionMembership v) { sess = v.sessionId; },
      [&](link::GHostTime v) { gt = v.time.count(); }, [&](link::PrevGHostTime v) { pgt = v.time.count(); },
      [&](link::HostTime v) { ht = v.time.count(); });
  }
  catch (const std::exception&)
  {
    return s.str() + " rejected=payload";
  }
  auto opt = [](const std::optional<long long>& v) { return v ? std::to_string(*v) : std::string("absent"); };
  s << " sess=" << (sess ? idString(*sess) : "absent") << " ghost=" << opt(gt) << " prev_ghost=" << opt(pgt)
    << " host=" << opt(ht);
  return s.str();
}

std::string describe(const std::string& kind, const Bytes& b)
{
  return kind == "discovery" ? describeDiscovery(b) : describeMeasurement(b);
}

Bytes encodePing(long long hostTime, std::optional<long long> prevGhost)
{
  link::v1::MessageBuffer buf;
  auto end = prevGhost ? link::v1::pingMessage(
                           discovery::makePayload(link::HostTime{std::chrono::microseconds{hostTime}},
                                                  link::PrevGHostTime{std::chrono::microseconds{*prevGhost}}),
                           buf.begin())
                       : link::v1::pingMessage(
                           discovery::makePayload(link::HostTime{std::chrono::microseconds{hostTime}}),
                           buf.begin());
  return Bytes(buf.begin(), end);
}

int decodeMode()
{
  std::string line;
  while (std::getline(std::cin, line))
  {
    if (line.rfind("expect", 0) == 0)
      continue; // rewritten below
    std::cout << line << "\n";
    std::istringstream in(line);
    std::string tag, kind, h;
    in >> tag >> kind >> h;
    if (tag != "packet")
      continue;
    const auto bytes = unhex(h);
    if (!bytes || (kind != "discovery" && kind != "ping" && kind != "pong"))
    {
      std::cerr << "bad packet line: " << line << "\n";
      return 1;
    }
    std::cout << "expect " << describe(kind, *bytes) << "\n";
  }
  return 0;
}

int openSocket(uint16_t port, bool multicast)
{
  const int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0)
    return -1;
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
#ifdef SO_REUSEPORT
  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
#endif
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof addr) < 0)
  {
    close(fd);
    return -1;
  }
  if (multicast)
  {
    // Join the group on every IPv4 interface, as Link does (include/ableton/platforms/asio/Context.hpp joins
    // per interface address). Joining only on the default interface misses peers on the same machine, whose
    // packets arrive on the loopback interfaces.
    ip_mreq mreq{};
    inet_pton(AF_INET, "224.76.78.75", &mreq.imr_multiaddr); // discovery/IpInterface.hpp
    int joined = 0;
    ifaddrs* ifs = nullptr;
    if (getifaddrs(&ifs) == 0)
    {
      for (auto* i = ifs; i; i = i->ifa_next)
      {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || !(i->ifa_flags & IFF_UP))
          continue;
        mreq.imr_interface = reinterpret_cast<sockaddr_in*>(i->ifa_addr)->sin_addr;
        if (setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof mreq) == 0)
          ++joined;
      }
      freeifaddrs(ifs);
    }
    if (joined == 0)
    {
      close(fd);
      return -1;
    }
  }
  return fd;
}

std::optional<Bytes> receive(int fd, int timeoutMs, sockaddr_in* from)
{
  fd_set set;
  FD_ZERO(&set);
  FD_SET(fd, &set);
  timeval tv{timeoutMs / 1000, (timeoutMs % 1000) * 1000};
  if (select(fd + 1, &set, nullptr, nullptr, &tv) <= 0)
    return std::nullopt;
  uint8_t buf[2048];
  socklen_t len = sizeof *from;
  const auto n = recvfrom(fd, buf, sizeof buf, 0, reinterpret_cast<sockaddr*>(from), &len);
  if (n < 0)
    return std::nullopt;
  return Bytes(buf, buf + n);
}

std::string addrString(const sockaddr_in& a)
{
  char ip[INET_ADDRSTRLEN];
  inet_ntop(AF_INET, &a.sin_addr, ip, sizeof ip);
  return std::string(ip) + ":" + std::to_string(ntohs(a.sin_port));
}

void record(const std::string& kind, const Bytes& b, const std::string& note)
{
  std::cout << "# " << note << "\n"
            << "packet " << kind << " " << hex(b) << "\n"
            << "expect " << describe(kind, b) << "\n";
}

// Ping/pong exchanges as Link's Measurement does them: the first ping carries HostTime, each later ping
// carries HostTime and the PrevGHostTime of the last pong (include/ableton/link/Measurement.hpp).
void pingExchanges(int fd, const discovery::UdpEndpoint& to, int count)
{
  sockaddr_in dst{};
  dst.sin_family = AF_INET;
  dst.sin_port = htons(to.port());
  dst.sin_addr.s_addr = htonl(to.address().to_v4().to_uint());
  std::optional<long long> prevGhost;
  for (int i = 0; i < count; ++i)
  {
    const auto sentAt = micros();
    const auto ping = encodePing(sentAt, prevGhost);
    record("ping", ping, "ping " + std::to_string(i + 1) + " to " + endpointString(to));
    sendto(fd, ping.data(), ping.size(), 0, reinterpret_cast<sockaddr*>(&dst), sizeof dst);
    sockaddr_in from{};
    const auto pong = receive(fd, 100, &from);
    const auto receivedAt = micros();
    if (!pong)
    {
      std::cout << "# no pong within 100 ms\n";
      return;
    }
    record("pong", *pong,
           "pong " + std::to_string(i + 1) + " from " + addrString(from) + ", round trip "
             + std::to_string(receivedAt - sentAt) + " us, received at host " + std::to_string(receivedAt));
    // Remember this pong's ghost time for the next ping.
    discovery::parsePayload<link::GHostTime>(
      link::v1::parseMessageHeader(pong->begin(), pong->end()).second, pong->end(),
      [&](link::GHostTime gt) { prevGhost = gt.time.count(); });
  }
}

int captureMode(double seconds, int pings, const std::string& note)
{
  const int mc = openSocket(20808, true); // discovery/IpInterface.hpp: 224.76.78.75:20808
  const int uc = openSocket(0, false);
  if (mc < 0 || uc < 0)
  {
    std::perror("socket");
    return 1;
  }
  std::cout << "# gbs-capture fixture" << (note.empty() ? "" : ": " + note) << "\n";
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
  bool pinged = pings == 0;
  int count = 0;
  while (std::chrono::steady_clock::now() < deadline)
  {
    sockaddr_in from{};
    const auto packet = receive(mc, 10, &from);
    if (!packet)
      continue;
    ++count;
    record("discovery", *packet, "discovery from " + addrString(from));
    if (pinged)
      continue;
    // Find the peer's IPv4 measurement endpoint with Link's parser.
    const auto res = discovery::v1::parseMessageHeader<link::NodeId>(packet->begin(), packet->end());
    if (res.first.messageType != discovery::v1::kAlive && res.first.messageType != discovery::v1::kResponse)
      continue;
    std::optional<discovery::UdpEndpoint> mep4;
    try
    {
      discovery::parsePayload<link::PeerState::MeasurementEndpointV4>(
        res.second, packet->end(), [&](link::PeerState::MeasurementEndpointV4 v) { mep4 = v.ep; });
    }
    catch (const std::exception&)
    {
      continue;
    }
    if (mep4)
    {
      pingExchanges(uc, *mep4, pings);
      pinged = true;
    }
  }
  std::cout << "# " << count << " discovery packet(s)\n";
  close(mc);
  close(uc);
  return 0;
}

} // namespace

int main(int argc, char** argv)
{
  double seconds = 3;
  int pings = 0;
  std::string note;
  for (int i = 1; i < argc; ++i)
  {
    const std::string a = argv[i];
    if (a == "--decode")
      return decodeMode();
    if (a == "--seconds" && i + 1 < argc)
      seconds = std::atof(argv[++i]);
    else if (a == "--ping" && i + 1 < argc)
      pings = std::atoi(argv[++i]);
    else if (a == "--note" && i + 1 < argc)
      note = argv[++i];
    else
    {
      std::cerr << "usage: gbs-capture [--seconds S] [--ping N] [--note TEXT] | --decode\n";
      return 2;
    }
  }
  return captureMode(seconds, pings, note);
}
