#pragma once

#include <SDL3/SDL.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace cafe::host::controller_profiles {

enum class ButtonAction : size_t {
    kA, kB, kX, kY,
    kDpadUp, kDpadDown, kDpadLeft, kDpadRight,
    kL, kR, kZL, kZR,
    kPlus, kMinus, kHome,
    kLeftStick, kRightStick,
    kCount
};

enum class AxisAction : size_t {
    kLeftX, kLeftY, kRightX, kRightY, kLeftTrigger, kRightTrigger, kCount
};

inline constexpr size_t kButtonCount = static_cast<size_t>(ButtonAction::kCount);
inline constexpr size_t kAxisCount = static_cast<size_t>(AxisAction::kCount);
inline constexpr uint32_t kSchemaVersion = 1;

struct Profile {
    uint32_t schema_version = kSchemaVersion;
    std::string name = "Default";
    std::string device_guid;
    std::array<int16_t, kButtonCount> buttons{};
    std::array<int8_t, kAxisCount> axes{};
    std::array<bool, kAxisCount> axis_inverted{};
    std::array<float, kAxisCount> dead_zones{};
    float trigger_threshold = 0.5f;
};

struct DeviceInfo {
    std::string guid;
    std::string name;
    uint16_t vendor = 0;
    uint16_t product = 0;
};

Profile default_profile();
DeviceInfo device_info(SDL_Gamepad* gamepad);
const Profile& for_device(SDL_Gamepad* gamepad);
void clear_cache();

bool button_pressed(SDL_Gamepad* gamepad, const Profile& profile, ButtonAction action);
float axis_value(SDL_Gamepad* gamepad, const Profile& profile, AxisAction action);

bool save_for_device(SDL_Gamepad* gamepad, const Profile& profile, std::string* error = nullptr);
bool save_to_file(const std::string& guid, const Profile& profile, std::string* error = nullptr);
std::string profile_path_for_guid(std::string_view guid);

} // namespace cafe::host::controller_profiles
