#pragma once

// Optional U Unlocked room-directory protocol for listing hosts and introducing guests. The service is opt-in;
// no third-party room directory is contacted by default.

#include <cstdint>
#include <string>
#include <vector>

namespace cafe::host::netplay {

// Set U_UNLOCKED_ROOM_SERVER to an explicitly deployed, compatible U Unlocked room directory.
// Empty by default: direct IP / LAN / VPN connections remain available without a hosted service.
constexpr const char* kRoomServer = "";
// Rooms of other U Unlocked protocol builds are not listed.
constexpr const char* kRoomBuild = "u-unlocked-1";
constexpr int kMaxPlayers = 8;

struct Room {
    uint32_t id = 0; // 24 bits; smash.exe --join room:<id in hex>
    std::string name;
    int players = 0, max = kMaxPlayers;
};

// A UDP address (IPv4, host byte order).
struct Endpoint {
    uint32_t ip = 0;
    uint16_t port = 0;
    bool operator==(const Endpoint&) const = default;
};

// One check-in. `room` (players > 0): this game hosts it; `want`: a game to be introduced to; `list`: the rooms.
struct CheckIn {
    uint32_t id = 0;
    Endpoint pub, lan; // as STUN saw this game (ip 0: not yet), and on its own network
    Room room;
    uint32_t want = 0;
    bool list = false;
};
struct Introduction {
    uint32_t id = 0;
    Endpoint pub, lan;
};
struct CheckInReply {
    bool ok = false;
    std::vector<Introduction> peers; // games to send to (wanted, or wanting this one)
    std::vector<Room> rooms;         // kRoomBuild's only
};
CheckInReply check_in(const CheckIn& c);

// The open rooms, for the launcher; false if the server could not be reached.
bool list_rooms(std::vector<Room>& rooms);

std::string room_server();
uint32_t random_id();
std::string ip_text(uint32_t ip);

} // namespace cafe::host::netplay
