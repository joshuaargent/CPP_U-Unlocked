#include "host/controller_profiles.h"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <utility>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <string>
#include <system_error>
#include <unordered_map>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace cafe::host::controller_profiles {
namespace {

namespace fs = std::filesystem;
constexpr uint64_t kMaximumProfileBytes = 64 * 1024;

int16_t bounded_button(int value) {
    return value >= -1 && value < SDL_GAMEPAD_BUTTON_COUNT ? static_cast<int16_t>(value) : -2;
}
int8_t bounded_axis(int value) {
    return value >= -1 && value < SDL_GAMEPAD_AXIS_COUNT ? static_cast<int8_t>(value) : -2;
}

std::string escape_json(std::string_view value) {
    std::string result;
    result.reserve(value.size() + 8);
    for (const unsigned char c : value) {
        switch (c) {
        case '"': result += "\\\""; break;
        case '\\': result += "\\\\"; break;
        case '\n': result += "\\n"; break;
        case '\r': result += "\\r"; break;
        case '\t': result += "\\t"; break;
        default:
            if (c < 0x20) return {};
            result.push_back(static_cast<char>(c));
        }
    }
    return result;
}

std::string make_json(const Profile& profile) {
    std::string out;
    out.reserve(1024);
    out += "{\n  \"schema_version\": " + std::to_string(kSchemaVersion);
    out += ",\n  \"name\": \"" + escape_json(profile.name) + "\"";
    out += ",\n  \"device_guid\": \"" + escape_json(profile.device_guid) + "\"";
    out += ",\n  \"player_slot\": " + std::to_string(profile.player_slot);
    out += ",\n  \"buttons\": [";
    for (size_t i = 0; i < profile.buttons.size(); ++i) {
        if (i) out += ", ";
        out += std::to_string(profile.buttons[i]);
    }
    out += "],\n  \"axes\": [";
    for (size_t i = 0; i < profile.axes.size(); ++i) {
        if (i) out += ", ";
        out += std::to_string(profile.axes[i]);
    }
    out += "],\n  \"axis_inverted\": [";
    for (size_t i = 0; i < profile.axis_inverted.size(); ++i) {
        if (i) out += ", ";
        out += profile.axis_inverted[i] ? "true" : "false";
    }
    out += "],\n  \"dead_zones\": [";
    for (size_t i = 0; i < profile.dead_zones.size(); ++i) {
        if (i) out += ", ";
        out += std::to_string(profile.dead_zones[i]);
    }
    out += "],\n  \"trigger_threshold\": " + std::to_string(profile.trigger_threshold) + "\n}\n";
    return out;
}

size_t value_start(std::string_view json, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\"";
    const size_t key_pos = json.find(needle);
    if (key_pos == std::string_view::npos) return key_pos;
    const size_t colon = json.find(':', key_pos + needle.size());
    if (colon == std::string_view::npos) return colon;
    size_t pos = colon + 1;
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\r' || json[pos] == '\n')) ++pos;
    return pos;
}

bool parse_string(std::string_view json, std::string_view key, std::string& value) {
    size_t pos = value_start(json, key);
    if (pos == std::string_view::npos || pos >= json.size() || json[pos] != '"') return false;
    ++pos;
    value.clear();
    while (pos < json.size()) {
        char c = json[pos++];
        if (c == '"') return true;
        if (c == '\\') {
            if (pos >= json.size()) return false;
            c = json[pos++];
            switch (c) {
            case '"': value.push_back('"'); break;
            case '\\': value.push_back('\\'); break;
            case 'n': value.push_back('\n'); break;
            case 'r': value.push_back('\r'); break;
            case 't': value.push_back('\t'); break;
            default: return false;
            }
        } else {
            if (static_cast<unsigned char>(c) < 0x20) return false;
            value.push_back(c);
        }
    }
    return false;
}

template <typename T, typename Parse>
bool parse_array(std::string_view json, std::string_view key, std::array<T, 0>&, Parse) = delete;

template <typename T, size_t N, typename Parse>
bool parse_array(std::string_view json, std::string_view key, std::array<T, N>& values, Parse parse_item) {
    size_t pos = value_start(json, key);
    if (pos == std::string_view::npos || pos >= json.size() || json[pos++] != '[') return false;
    for (size_t i = 0; i < N; ++i) {
        while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\r' || json[pos] == '\n')) ++pos;
        const size_t start = pos;
        while (pos < json.size() && json[pos] != ',' && json[pos] != ']' && json[pos] != ' ' && json[pos] != '\n' && json[pos] != '\r' && json[pos] != '\t') ++pos;
        if (start == pos || !parse_item(json.substr(start, pos - start), values[i])) return false;
        while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\r' || json[pos] == '\n')) ++pos;
        if (i + 1 < N) {
            if (pos >= json.size() || json[pos++] != ',') return false;
        }
    }
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\r' || json[pos] == '\n')) ++pos;
    return pos < json.size() && json[pos] == ']';
}

bool parse_integer(std::string_view text, int& value) {
    const auto [end, error] = std::from_chars(text.data(), text.data() + text.size(), value);
    return error == std::errc{} && end == text.data() + text.size();
}
bool parse_boolean(std::string_view text, bool& value) {
    if (text == "true") { value = true; return true; }
    if (text == "false") { value = false; return true; }
    return false;
}
bool parse_float(std::string_view text, float& value) {
    std::string copy(text);
    char* end = nullptr;
    value = std::strtof(copy.c_str(), &end);
    return end == copy.c_str() + copy.size() && std::isfinite(value);
}
bool parse_integer_field(std::string_view json, std::string_view key, int& value) {
    const size_t pos = value_start(json, key);
    if (pos == std::string_view::npos) return false;
    size_t end = pos;
    while (end < json.size() && json[end] != ',' && json[end] != '}' &&
           json[end] != ' ' && json[end] != '\n' && json[end] != '\r' && json[end] != '\t') ++end;
    return parse_integer(json.substr(pos, end - pos), value);
}
bool parse_number_field(std::string_view json, std::string_view key, float& value) {
    const size_t pos = value_start(json, key);
    if (pos == std::string_view::npos) return false;
    size_t end = pos;
    while (end < json.size() && json[end] != ',' && json[end] != '}' && json[end] != ' ' &&
           json[end] != '\n' && json[end] != '\r' && json[end] != '\t') ++end;
    return parse_float(json.substr(pos, end - pos), value);
}
bool parse_version(std::string_view json, uint32_t& version) {
    const size_t pos = value_start(json, "schema_version");
    if (pos == std::string_view::npos) return false;
    unsigned value = 0;
    const char* first = json.data() + pos;
    const char* last = json.data() + json.size();
    const auto [end, error] = std::from_chars(first, last, value);
    if (error != std::errc{} || end == first) return false;
    version = value;
    return true;
}

bool parse_profile(std::string_view json, Profile& profile, std::string& error) {
    if (json.size() > kMaximumProfileBytes) { error = "Profile exceeds 64 KiB."; return false; }
    Profile parsed = default_profile();
    std::array<int, kButtonCount> button_values{};
    std::array<int, kAxisCount> axis_values{};
    const auto int_parser = [](std::string_view s, int& v) { return parse_integer(s, v); };
    const auto bool_parser = [](std::string_view s, bool& v) { return parse_boolean(s, v); };
    const auto float_parser = [](std::string_view s, float& v) { return parse_float(s, v); };

    int player_slot = -1;
    if (!parse_version(json, parsed.schema_version) || parsed.schema_version != kSchemaVersion ||
        !parse_string(json, "name", parsed.name) || !parse_string(json, "device_guid", parsed.device_guid) ||
        !parse_integer_field(json, "player_slot", player_slot) || player_slot < -1 || player_slot > 7 ||
        !parse_array(json, "buttons", button_values, int_parser) ||
        !parse_array(json, "axes", axis_values, int_parser) ||
        !parse_array(json, "axis_inverted", parsed.axis_inverted, bool_parser) ||
        !parse_array(json, "dead_zones", parsed.dead_zones, float_parser) ||
        !parse_number_field(json, "trigger_threshold", parsed.trigger_threshold)) {
        error = "Profile is malformed or uses an unsupported schema.";
        return false;
    }

    if (parsed.name.empty() || parsed.name.size() > 64) { error = "Profile name must contain 1 to 64 characters."; return false; }
    parsed.player_slot = static_cast<int8_t>(player_slot);
    for (size_t i = 0; i < button_values.size(); ++i) {
        parsed.buttons[i] = bounded_button(button_values[i]);
        if (parsed.buttons[i] == -2) { error = "Profile contains an invalid gamepad button binding."; return false; }
    }
    for (size_t i = 0; i < axis_values.size(); ++i) {
        parsed.axes[i] = bounded_axis(axis_values[i]);
        if (parsed.axes[i] == -2) { error = "Profile contains an invalid gamepad axis binding."; return false; }
        if (!std::isfinite(parsed.dead_zones[i]) || parsed.dead_zones[i] < 0.0f || parsed.dead_zones[i] > 0.9f) {
            error = "Dead zones must be between 0.0 and 0.9.";
            return false;
        }
    }
    if (parsed.trigger_threshold < 0.05f || parsed.trigger_threshold > 0.95f) {
        error = "Trigger threshold must be between 0.05 and 0.95.";
        return false;
    }
    profile = std::move(parsed);
    return true;
}

fs::path profile_directory() {
    char* base = SDL_GetPrefPath("UUnlocked", "UUnlocked");
    if (!base) return {};
    fs::path path = fs::path(base) / "controllers";
    SDL_free(base);
    std::error_code ec;
    fs::create_directories(path, ec);
    return ec ? fs::path{} : path;
}

std::string safe_guid(std::string_view guid) {
    std::string safe;
    safe.reserve(guid.size());
    for (const unsigned char c : guid) {
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '-') {
            safe.push_back(static_cast<char>(c));
        }
    }
    return safe.empty() ? "default" : safe;
}

std::unordered_map<std::string, Profile> g_profiles;

} // namespace

Profile default_profile() {
    Profile p;
    p.buttons = {
        SDL_GAMEPAD_BUTTON_EAST, SDL_GAMEPAD_BUTTON_SOUTH, SDL_GAMEPAD_BUTTON_NORTH, SDL_GAMEPAD_BUTTON_WEST,
        SDL_GAMEPAD_BUTTON_DPAD_UP, SDL_GAMEPAD_BUTTON_DPAD_DOWN, SDL_GAMEPAD_BUTTON_DPAD_LEFT,
        SDL_GAMEPAD_BUTTON_DPAD_RIGHT, SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER,
        -1, -1, SDL_GAMEPAD_BUTTON_START, SDL_GAMEPAD_BUTTON_BACK, SDL_GAMEPAD_BUTTON_GUIDE,
        SDL_GAMEPAD_BUTTON_LEFT_STICK, SDL_GAMEPAD_BUTTON_RIGHT_STICK
    };
    p.axes = {
        SDL_GAMEPAD_AXIS_LEFTX, SDL_GAMEPAD_AXIS_LEFTY, SDL_GAMEPAD_AXIS_RIGHTX,
        SDL_GAMEPAD_AXIS_RIGHTY, SDL_GAMEPAD_AXIS_LEFT_TRIGGER, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER
    };
    p.dead_zones.fill(0.15f);
    p.dead_zones[static_cast<size_t>(AxisAction::kLeftTrigger)] = 0.0f;
    p.dead_zones[static_cast<size_t>(AxisAction::kRightTrigger)] = 0.0f;
    return p;
}

DeviceInfo device_info(SDL_Gamepad* gamepad) {
    DeviceInfo info;
    if (!gamepad) return info;
    SDL_Joystick* joystick = SDL_GetGamepadJoystick(gamepad);
    if (joystick) {
        char guid[64]{};
        SDL_GUIDToString(SDL_GetJoystickGUID(joystick), guid, static_cast<int>(sizeof(guid)));
        info.guid = guid;
    }
    if (const char* name = SDL_GetGamepadName(gamepad)) info.name = name;
    info.vendor = SDL_GetGamepadVendor(gamepad);
    info.product = SDL_GetGamepadProduct(gamepad);
    return info;
}

std::string profile_path_for_guid(std::string_view guid) {
    const fs::path directory = profile_directory();
    if (directory.empty()) return {};
    return (directory / (safe_guid(guid) + ".json")).string();
}

const Profile& for_device(SDL_Gamepad* gamepad) {
    static const Profile fallback = default_profile();
    if (!gamepad) return fallback;
    const DeviceInfo info = device_info(gamepad);
    const std::string key = info.guid.empty() ? "default" : info.guid;
    auto found = g_profiles.find(key);
    if (found != g_profiles.end()) return found->second;

    Profile profile = default_profile();
    profile.device_guid = info.guid;
    const std::string path = profile_path_for_guid(info.guid);
    if (!path.empty()) {
        std::error_code ec;
        const uintmax_t size = fs::file_size(path, ec);
        if (!ec && size <= kMaximumProfileBytes) {
            std::ifstream file(path, std::ios::binary);
            const std::string text{std::istreambuf_iterator<char>(file), {}};
            std::string error;
            if (!parse_profile(text, profile, error)) {
                std::fprintf(stderr, "u-unlocked: controller profile %s: %s\n", path.c_str(), error.c_str());
                profile = default_profile();
                profile.device_guid = info.guid;
            }
        }
    }
    return g_profiles.emplace(key, std::move(profile)).first->second;
}

void clear_cache() { g_profiles.clear(); }

bool button_pressed(SDL_Gamepad* gamepad, const Profile& profile, ButtonAction action) {
    const int binding = profile.buttons[static_cast<size_t>(action)];
    return gamepad && binding >= 0 && binding < SDL_GAMEPAD_BUTTON_COUNT &&
           SDL_GetGamepadButton(gamepad, static_cast<SDL_GamepadButton>(binding));
}

float normalize_axis_value(float raw_value, const Profile& profile, AxisAction action) {
    const size_t index = static_cast<size_t>(action);
    if (index >= kAxisCount || !std::isfinite(raw_value)) return 0.0f;

    float value = std::clamp(raw_value, -1.0f, 1.0f);
    const bool trigger = action == AxisAction::kLeftTrigger || action == AxisAction::kRightTrigger;
    if (trigger) {
        value = std::clamp(value, 0.0f, 1.0f);
    } else if (profile.axis_inverted[index]) {
        value = -value;
    }

    const float dead_zone = std::clamp(profile.dead_zones[index], 0.0f, 0.9f);
    if (trigger) {
        if (value <= dead_zone) return 0.0f;
        return std::clamp((value - dead_zone) / (1.0f - dead_zone), 0.0f, 1.0f);
    }

    const float magnitude = std::fabs(value);
    if (magnitude <= dead_zone) return 0.0f;
    const float scaled = (magnitude - dead_zone) / (1.0f - dead_zone);
    return std::copysign(std::clamp(scaled, 0.0f, 1.0f), value);
}

float axis_value(SDL_Gamepad* gamepad, const Profile& profile, AxisAction action) {
    const size_t index = static_cast<size_t>(action);
    if (!gamepad || index >= kAxisCount) return 0.0f;
    const int binding = profile.axes[index];
    if (binding < 0 || binding >= SDL_GAMEPAD_AXIS_COUNT) return 0.0f;
    const float raw = static_cast<float>(SDL_GetGamepadAxis(gamepad, static_cast<SDL_GamepadAxis>(binding))) / 32767.0f;
    return normalize_axis_value(raw, profile, action);
}

bool save_for_device(SDL_Gamepad* gamepad, const Profile& profile, std::string* error) {
    if (!gamepad) { if (error) *error = "No controller is selected."; return false; }
    Profile copy = profile;
    copy.device_guid = device_info(gamepad).guid;
    return save_to_file(copy.device_guid, copy, error);
}

bool save_to_file(const std::string& guid, const Profile& profile, std::string* error) {
    Profile validated = profile;
    validated.device_guid = guid;
    if (validated.schema_version != kSchemaVersion || validated.name.empty() || validated.name.size() > 64 ||
        validated.trigger_threshold < 0.05f || validated.trigger_threshold > 0.95f ||
        validated.player_slot < -1 || validated.player_slot > 7) {
        if (error) *error = "Profile metadata is invalid.";
        return false;
    }
    for (size_t i = 0; i < kButtonCount; ++i) {
        if (bounded_button(validated.buttons[i]) == -2) { if (error) *error = "A button binding is invalid."; return false; }
    }
    for (size_t i = 0; i < kAxisCount; ++i) {
        if (bounded_axis(validated.axes[i]) == -2 || !std::isfinite(validated.dead_zones[i]) ||
            validated.dead_zones[i] < 0.0f || validated.dead_zones[i] > 0.9f) {
            if (error) *error = "An axis binding or dead zone is invalid.";
            return false;
        }
    }

    const std::string path = profile_path_for_guid(guid);
    if (path.empty()) { if (error) *error = "Unable to create the controller profile directory."; return false; }
    const fs::path destination(path);
    const fs::path temporary = destination.string() + ".tmp";
    const std::string json = make_json(validated);
    {
        std::ofstream file(temporary, std::ios::binary | std::ios::trunc);
        if (!file || !(file << json) || !file.flush()) {
            if (error) *error = "Unable to write the temporary controller profile.";
            return false;
        }
    }
#ifdef _WIN32
    if (!MoveFileExW(temporary.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        if (error) *error = "Unable to atomically replace the controller profile (Windows error " +
                            std::to_string(GetLastError()) + ").";
        return false;
    }
#else
    std::error_code ec;
    fs::rename(temporary, destination, ec);
    if (ec) { if (error) *error = "Unable to atomically replace the controller profile: " + ec.message(); return false; }
#endif
    g_profiles[guid.empty() ? "default" : guid] = validated;
    return true;
}

} // namespace cafe::host::controller_profiles
