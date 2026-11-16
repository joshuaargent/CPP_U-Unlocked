#include "host/controller_profiles.h"

#include <SDL3/SDL.h>

#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
#include <string>

using namespace cafe::host::controller_profiles;

namespace {
int failures = 0;

void expect_near(const char* name, float actual, float expected, float tolerance = 0.0005f) {
    if (!std::isfinite(actual) || std::fabs(actual - expected) > tolerance) {
        std::cerr << "FAIL: " << name << " (expected " << expected << ", got " << actual << ")\n";
        ++failures;
    }
}

void expect_true(const char* name, bool value) {
    if (!value) {
        std::cerr << "FAIL: " << name << "\n";
        ++failures;
    }
}
} // namespace

int main() {
    if (!SDL_Init(0)) {
        std::cerr << "SDL_Init failed: " << SDL_GetError() << "\n";
        return 1;
    }

    Profile profile = default_profile();
    profile.dead_zones[static_cast<size_t>(AxisAction::kLeftX)] = 0.2f;
    expect_near("stick inside dead zone", normalize_axis_value(0.1f, profile, AxisAction::kLeftX), 0.0f);
    expect_near("stick positive scaled outside dead zone", normalize_axis_value(0.6f, profile, AxisAction::kLeftX), 0.5f);
    expect_near("stick negative scaled outside dead zone", normalize_axis_value(-0.6f, profile, AxisAction::kLeftX), -0.5f);

    profile.axis_inverted[static_cast<size_t>(AxisAction::kLeftX)] = true;
    expect_near("stick inversion", normalize_axis_value(0.6f, profile, AxisAction::kLeftX), -0.5f);
    profile.axis_inverted[static_cast<size_t>(AxisAction::kLeftX)] = false;

    profile.dead_zones[static_cast<size_t>(AxisAction::kLeftTrigger)] = 0.1f;
    expect_near("trigger below dead zone", normalize_axis_value(0.05f, profile, AxisAction::kLeftTrigger), 0.0f);
    expect_near("trigger scaled above dead zone", normalize_axis_value(0.55f, profile, AxisAction::kLeftTrigger), 0.5f);
    expect_near("trigger negative values clamp to zero", normalize_axis_value(-0.5f, profile, AxisAction::kLeftTrigger), 0.0f);
    profile.axis_inverted[static_cast<size_t>(AxisAction::kLeftTrigger)] = true;
    expect_near("trigger inversion is ignored", normalize_axis_value(0.55f, profile, AxisAction::kLeftTrigger), 0.5f);
    profile.axis_inverted[static_cast<size_t>(AxisAction::kLeftTrigger)] = false;
    expect_near("axis clamps values above range", normalize_axis_value(2.0f, profile, AxisAction::kRightX), 1.0f);
    expect_near("axis rejects NaN", normalize_axis_value(std::numeric_limits<float>::quiet_NaN(), profile, AxisAction::kRightX), 0.0f);

    const std::string test_guid = "u-unlocked-controller-profile-test";
    const std::string path = profile_path_for_guid(test_guid);
    expect_true("profile path is available", !path.empty());
    if (!path.empty()) {
        profile = default_profile();
        profile.name = "Persistence Test";
        profile.player_slot = 3;
        profile.dead_zones[static_cast<size_t>(AxisAction::kLeftX)] = 0.27f;
        std::string error;
        expect_true("valid profile saves", save_to_file(test_guid, profile, &error));
        std::ifstream saved(path, std::ios::binary);
        const std::string json{std::istreambuf_iterator<char>(saved), {}};
        expect_true("saved profile contains its name", json.find("Persistence Test") != std::string::npos);
        expect_true("saved profile contains its player slot", json.find("\"player_slot\": 3") != std::string::npos);
        expect_true("saved profile contains its dead zone", json.find("0.270000") != std::string::npos);

        Profile invalid = profile;
        invalid.dead_zones[static_cast<size_t>(AxisAction::kLeftX)] = 0.95f;
        error.clear();
        expect_true("invalid dead zone is rejected", !save_to_file(test_guid, invalid, &error));
        invalid = profile;
        invalid.player_slot = 8;
        expect_true("invalid player slot is rejected", !save_to_file(test_guid, invalid, &error));
        std::ifstream after(path, std::ios::binary);
        const std::string unchanged{std::istreambuf_iterator<char>(after), {}};
        expect_true("invalid save leaves last valid file intact", unchanged == json);
        std::error_code ec;
        std::filesystem::remove(path, ec);
    }

    SDL_Quit();
    if (failures != 0) {
        std::cerr << failures << " controller profile test(s) failed.\n";
        return 1;
    }
    std::cout << "Controller profile tests passed.\n";
    return 0;
}
