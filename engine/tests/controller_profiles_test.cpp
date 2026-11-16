#include "host/controller_profiles.h"
#include "host/controller_profile_import.h"

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

    const std::string cemu_xml = R"xml(
<emulated_controller>
  <type>
    Wii U Pro Controller
  </type>
  <profile> Xbox Layout </profile>
  <controller>
    <api>SDLController</api>
    <uuid>0_030000005e0400008e02000000000000</uuid>
    <display_name>Xbox Controller</display_name>
    <axis><deadzone>
      0.18
    </deadzone><range>1.0</range></axis>
    <rotation><deadzone>0.22</deadzone><range>1.0</range></rotation>
    <trigger><deadzone>0.05</deadzone><range>1.0</range></trigger>
    <rumble>0.5</rumble>
    <motion>false</motion>
    <mappings>
      <entry><mapping>1</mapping><button>1</button></entry>
      <entry><mapping>11</mapping><button>5</button></entry>
      <entry><mapping>12</mapping><button>11</button></entry>
      <entry><mapping>7</mapping><button>42</button></entry>
      <entry><mapping>8</mapping><button>43</button></entry>
      <entry><mapping>18</mapping><button>45</button></entry>
      <entry><mapping>19</mapping><button>39</button></entry>
      <entry><mapping>20</mapping><button>44</button></entry>
      <entry><mapping>21</mapping><button>38</button></entry>
      <entry><mapping>22</mapping><button>47</button></entry>
      <entry><mapping>23</mapping><button>41</button></entry>
      <entry><mapping>24</mapping><button>46</button></entry>
      <entry><mapping>25</mapping><button>40</button></entry>
      <entry><mapping>999</mapping><button>999</button></entry>
    </mappings>
  </controller>
</emulated_controller>
)xml";
    Profile selected_profile = default_profile();
    selected_profile.device_guid = "030000005e0400008e02000000000000";
    selected_profile.player_slot = 2;
    Profile imported_profile;
    CemuImportReport import_report;
    std::string import_error;
    expect_true("Cemu SDL profile imports", import_cemu_profile_xml(
        cemu_xml, selected_profile, imported_profile, import_report, &import_error));
    expect_true("Cemu profile name imports", imported_profile.name == "Xbox Layout");
    expect_true("Cemu player slot is preserved", imported_profile.player_slot == 2);
    expect_true("Cemu A mapping translates to SDL button", imported_profile.buttons[static_cast<size_t>(ButtonAction::kA)] == SDL_GAMEPAD_BUTTON_EAST);
    expect_true("Cemu Home mapping translates", imported_profile.buttons[static_cast<size_t>(ButtonAction::kHome)] == SDL_GAMEPAD_BUTTON_GUIDE);
    expect_true("Cemu d-pad mapping translates", imported_profile.buttons[static_cast<size_t>(ButtonAction::kDpadUp)] == SDL_GAMEPAD_BUTTON_DPAD_UP);
    expect_true("Cemu left stick X mapping translates", imported_profile.axes[static_cast<size_t>(AxisAction::kLeftX)] == SDL_GAMEPAD_AXIS_LEFTX);
    expect_true("Cemu left stick Y mapping translates", imported_profile.axes[static_cast<size_t>(AxisAction::kLeftY)] == SDL_GAMEPAD_AXIS_LEFTY);
    expect_true("Cemu right stick X mapping translates", imported_profile.axes[static_cast<size_t>(AxisAction::kRightX)] == SDL_GAMEPAD_AXIS_RIGHTX);
    expect_true("Cemu right stick Y mapping translates", imported_profile.axes[static_cast<size_t>(AxisAction::kRightY)] == SDL_GAMEPAD_AXIS_RIGHTY);
    expect_true("Cemu trigger mappings translate", imported_profile.axes[static_cast<size_t>(AxisAction::kLeftTrigger)] == SDL_GAMEPAD_AXIS_LEFT_TRIGGER &&
        imported_profile.axes[static_cast<size_t>(AxisAction::kRightTrigger)] == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER);
    expect_near("Cemu left stick dead zone imports", imported_profile.dead_zones[static_cast<size_t>(AxisAction::kLeftX)], 0.18f);
    expect_near("Cemu right stick dead zone imports", imported_profile.dead_zones[static_cast<size_t>(AxisAction::kRightY)], 0.22f);
    expect_near("Cemu trigger dead zone imports", imported_profile.dead_zones[static_cast<size_t>(AxisAction::kLeftTrigger)], 0.05f);
    expect_true("Cemu unsupported mappings are reported", import_report.skipped_mappings == 1 && !import_report.warnings.empty());
    expect_true("Cemu axis bindings are counted uniquely", import_report.imported_axis_bindings == 6);

    std::string reversed_xml = cemu_xml;
    const std::string normal_left = "<entry><mapping>20</mapping><button>44</button></entry>";
    const std::string reversed_left = "<entry><mapping>20</mapping><button>38</button></entry>";
    const std::string normal_right = "<entry><mapping>21</mapping><button>38</button></entry>";
    const std::string reversed_right = "<entry><mapping>21</mapping><button>44</button></entry>";
    reversed_xml.replace(reversed_xml.find(normal_left), normal_left.size(), reversed_left);
    reversed_xml.replace(reversed_xml.find(normal_right), normal_right.size(), reversed_right);
    expect_true("Cemu reversed stick axes import", import_cemu_profile_xml(
        reversed_xml, selected_profile, imported_profile, import_report, &import_error));
    expect_true("Cemu reversed stick axis is inverted", imported_profile.axis_inverted[static_cast<size_t>(AxisAction::kLeftX)]);

    const std::string unsupported_api_xml = cemu_xml;
    std::string unsupported_copy = unsupported_api_xml;
    const size_t api_position = unsupported_copy.find("SDLController");
    unsupported_copy.replace(api_position, std::string("SDLController").size(), "XInput");
    expect_true("unsupported Cemu API is rejected", !import_cemu_profile_xml(
        unsupported_copy, selected_profile, imported_profile, import_report, &import_error));
    expect_true("malformed Cemu XML is rejected", !import_cemu_profile_xml(
        "<emulated_controller>", selected_profile, imported_profile, import_report, &import_error));
    std::string unsupported_type = cemu_xml;
    const size_t type_position = unsupported_type.find("Wii U Pro Controller");
    unsupported_type.replace(type_position, std::string("Wii U Pro Controller").size(), "Wiimote");
    expect_true("unsupported Cemu controller type is rejected", !import_cemu_profile_xml(
        unsupported_type, selected_profile, imported_profile, import_report, &import_error));

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
        after.close();
        saved.close();
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
