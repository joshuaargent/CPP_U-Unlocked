#include "host/controller_profile_import.h"

#include "tinyxml2.h"

#include <algorithm>
#include <array>
#include <charconv>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <initializer_list>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>

namespace cafe::host::controller_profiles {
namespace {

constexpr size_t kMaximumCemuProfileBytes = 1024 * 1024;

bool parse_unsigned(const tinyxml2::XMLElement* element, uint64_t& value) {
    if (!element || !element->GetText()) return false;
    std::string_view text(element->GetText());
    while (!text.empty() && (text.front() == ' ' || text.front() == '\t' ||
           text.front() == '\r' || text.front() == '\n')) text.remove_prefix(1);
    while (!text.empty() && (text.back() == ' ' || text.back() == '\t' ||
           text.back() == '\r' || text.back() == '\n')) text.remove_suffix(1);
    if (text.empty()) return false;
    const auto [end, ec] = std::from_chars(text.data(), text.data() + text.size(), value);
    return ec == std::errc{} && end == text.data() + text.size();
}

bool parse_float(const tinyxml2::XMLElement* parent, const char* child_name, float& value) {
    if (!parent) return false;
    const tinyxml2::XMLElement* child = parent->FirstChildElement(child_name);
    if (!child || !child->GetText()) return false;
    const char* raw = child->GetText();
    char* end = nullptr;
    const float parsed = std::strtof(raw, &end);
    if (end == raw) return false;
    while (*end && std::isspace(static_cast<unsigned char>(*end))) ++end;
    if (*end != '\0' || !std::isfinite(parsed)) return false;
    value = parsed;
    return true;
}

std::string element_text(const tinyxml2::XMLElement* parent, const char* child_name) {
    if (!parent) return {};
    const tinyxml2::XMLElement* child = parent->FirstChildElement(child_name);
    if (!child || !child->GetText()) return {};
    std::string value = child->GetText();
    const auto is_space = [](unsigned char c) { return std::isspace(c) != 0; };
    const auto first = std::find_if_not(value.begin(), value.end(), is_space);
    const auto last = std::find_if_not(value.rbegin(), value.rend(), is_space).base();
    return first < last ? std::string(first, last) : std::string{};
}

bool equal_guid(std::string_view lhs, std::string_view rhs) {
    if (lhs.size() != rhs.size()) return false;
    for (size_t i = 0; i < lhs.size(); ++i) {
        const auto lower = [](unsigned char c) { return static_cast<char>(c >= 'A' && c <= 'F' ? c + ('a' - 'A') : c); };
        if (lower(static_cast<unsigned char>(lhs[i])) != lower(static_cast<unsigned char>(rhs[i]))) return false;
    }
    return true;
}

std::string guid_from_cemu_uuid(std::string_view uuid) {
    const size_t separator = uuid.find('_');
    return separator == std::string_view::npos ? std::string{} : std::string(uuid.substr(separator + 1));
}

enum class LogicalKind { kButton, kAxis, kTrigger, kUnsupported };

struct LogicalMapping {
    LogicalKind kind = LogicalKind::kUnsupported;
    ButtonAction button = ButtonAction::kA;
    AxisAction axis = AxisAction::kLeftX;
    int expected_sign = 0;
};

bool logical_mapping(std::string_view type, uint64_t id, LogicalMapping& result) {
    const bool gamepad = type == "Wii U GamePad";
    const bool pro = type == "Wii U Pro Controller";
    if (!gamepad && !pro) return false;

    if (id >= 1 && id <= 4) {
        result.kind = LogicalKind::kButton;
        result.button = static_cast<ButtonAction>(id - 1);
        return true;
    }
    if (id >= 5 && id <= 8) {
        result.kind = id <= 8 ? LogicalKind::kButton : LogicalKind::kUnsupported;
        static constexpr ButtonAction actions[] = {ButtonAction::kL, ButtonAction::kR, ButtonAction::kZL, ButtonAction::kZR};
        result.button = actions[id - 5];
        return true;
    }
    if (id == 9 || id == 10) {
        result.kind = LogicalKind::kButton;
        result.button = id == 9 ? ButtonAction::kPlus : ButtonAction::kMinus;
        return true;
    }

    if (gamepad) {
        if (id >= 11 && id <= 14) {
            result.kind = LogicalKind::kButton;
            static constexpr ButtonAction actions[] = {
                ButtonAction::kDpadUp, ButtonAction::kDpadDown, ButtonAction::kDpadLeft, ButtonAction::kDpadRight
            };
            result.button = actions[id - 11];
            return true;
        }
        if (id == 15 || id == 16) {
            result.kind = LogicalKind::kButton;
            result.button = id == 15 ? ButtonAction::kLeftStick : ButtonAction::kRightStick;
            return true;
        }
        if (id >= 17 && id <= 24) {
            result.kind = LogicalKind::kAxis;
            static constexpr AxisAction axes[] = {
                AxisAction::kLeftY, AxisAction::kLeftY, AxisAction::kLeftX, AxisAction::kLeftX,
                AxisAction::kRightY, AxisAction::kRightY, AxisAction::kRightX, AxisAction::kRightX
            };
            result.axis = axes[id - 17];
            result.expected_sign = ((id - 17) % 2 == 0) ? -1 : 1;
            return true;
        }
        if (id == 27) {
            result.kind = LogicalKind::kButton;
            result.button = ButtonAction::kHome;
            return true;
        }
        result.kind = LogicalKind::kUnsupported;
        return true;
    }

    if (id == 11) {
        result.kind = LogicalKind::kButton;
        result.button = ButtonAction::kHome;
        return true;
    }
    if (id >= 12 && id <= 15) {
        result.kind = LogicalKind::kButton;
        static constexpr ButtonAction actions[] = {
            ButtonAction::kDpadUp, ButtonAction::kDpadDown, ButtonAction::kDpadLeft, ButtonAction::kDpadRight
        };
        result.button = actions[id - 12];
        return true;
    }
    if (id == 16 || id == 17) {
        result.kind = LogicalKind::kButton;
        result.button = id == 16 ? ButtonAction::kLeftStick : ButtonAction::kRightStick;
        return true;
    }
    if (id >= 18 && id <= 25) {
        result.kind = LogicalKind::kAxis;
        static constexpr AxisAction axes[] = {
            AxisAction::kLeftY, AxisAction::kLeftY, AxisAction::kLeftX, AxisAction::kLeftX,
            AxisAction::kRightY, AxisAction::kRightY, AxisAction::kRightX, AxisAction::kRightX
        };
        result.axis = axes[id - 18];
        result.expected_sign = ((id - 18) % 2 == 0) ? -1 : 1;
        return true;
    }
    result.kind = LogicalKind::kUnsupported;
    return true;
}

struct PhysicalMapping {
    enum class Kind { kButton, kAxis, kUnsupported } kind = Kind::kUnsupported;
    int index = -1;
    int sign = 0;
};

PhysicalMapping physical_mapping(uint64_t id) {
    if (id < SDL_GAMEPAD_BUTTON_COUNT) {
        return {PhysicalMapping::Kind::kButton, static_cast<int>(id), 0};
    }
    switch (id) {
    case 34: return {PhysicalMapping::Kind::kButton, SDL_GAMEPAD_BUTTON_DPAD_UP, 0};
    case 35: return {PhysicalMapping::Kind::kButton, SDL_GAMEPAD_BUTTON_DPAD_DOWN, 0};
    case 36: return {PhysicalMapping::Kind::kButton, SDL_GAMEPAD_BUTTON_DPAD_LEFT, 0};
    case 37: return {PhysicalMapping::Kind::kButton, SDL_GAMEPAD_BUTTON_DPAD_RIGHT, 0};
    case 38: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_LEFTX, 1};
    case 39: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_LEFTY, 1};
    case 40: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_RIGHTX, 1};
    case 41: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_RIGHTY, 1};
    case 42: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_LEFT_TRIGGER, 1};
    case 43: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, 1};
    case 44: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_LEFTX, -1};
    case 45: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_LEFTY, -1};
    case 46: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_RIGHTX, -1};
    case 47: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_RIGHTY, -1};
    case 48: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_LEFT_TRIGGER, -1};
    case 49: return {PhysicalMapping::Kind::kAxis, SDL_GAMEPAD_AXIS_RIGHT_TRIGGER, -1};
    default: return {};
    }
}

void warning(CemuImportReport& report, std::string message) {
    report.warnings.push_back(std::move(message));
}

} // namespace

bool import_cemu_profile_xml(std::string_view xml,
                             const Profile& current_profile,
                             Profile& imported_profile,
                             CemuImportReport& report,
                             std::string* error) {
    report = {};
    if (xml.empty() || xml.size() > kMaximumCemuProfileBytes) {
        if (error) *error = "Cemu profile is empty or exceeds the 1 MiB import limit.";
        return false;
    }

    tinyxml2::XMLDocument document;
    const tinyxml2::XMLError parse_result = document.Parse(xml.data(), xml.size());
    if (parse_result != tinyxml2::XML_SUCCESS) {
        if (error) *error = std::string("Invalid Cemu XML: ") + document.ErrorStr();
        return false;
    }

    const tinyxml2::XMLElement* root = document.RootElement();
    if (!root || std::string_view(root->Name()) != "emulated_controller") {
        if (error) *error = "The selected XML is not a Cemu emulated-controller profile.";
        return false;
    }

    report.emulated_controller_type = element_text(root, "type");
    if (report.emulated_controller_type != "Wii U GamePad" &&
        report.emulated_controller_type != "Wii U Pro Controller") {
        if (error) *error = "Only Wii U GamePad and Wii U Pro Controller profiles are supported.";
        return false;
    }

    report.profile_name = element_text(root, "profile");
    if (report.profile_name.empty()) report.profile_name = "Imported Cemu Profile";

    const tinyxml2::XMLElement* selected_controller = nullptr;
    const tinyxml2::XMLElement* first_sdl_controller = nullptr;
    const std::string current_guid = current_profile.device_guid;
    for (const tinyxml2::XMLElement* controller = root->FirstChildElement("controller");
         controller; controller = controller->NextSiblingElement("controller")) {
        if (element_text(controller, "api") != "SDLController") {
            warning(report, "Skipped a controller using an API other than SDLController.");
            continue;
        }
        if (!first_sdl_controller) first_sdl_controller = controller;
        const std::string uuid = element_text(controller, "uuid");
        if (!current_guid.empty() && equal_guid(guid_from_cemu_uuid(uuid), current_guid)) {
            selected_controller = controller;
            break;
        }
    }
    if (!selected_controller) selected_controller = first_sdl_controller;
    if (!selected_controller) {
        if (error) *error = "No SDLController entry was found in this Cemu profile.";
        return false;
    }

    report.source_controller_name = element_text(selected_controller, "display_name");
    report.source_controller_uuid = element_text(selected_controller, "uuid");
    const std::string source_guid = guid_from_cemu_uuid(report.source_controller_uuid);
    if (!current_guid.empty() && !source_guid.empty() && !equal_guid(source_guid, current_guid)) {
        warning(report, "The profile's saved controller GUID differs from the selected controller. Review every binding before saving.");
    }

    Profile result = default_profile();
    result.player_slot = current_profile.player_slot;
    result.device_guid = current_profile.device_guid;
    result.name = report.profile_name.substr(0, 64);
    result.buttons.fill(-1);
    result.axes.fill(-1);
    result.axis_inverted.fill(false);
    result.dead_zones.fill(0.15f);
    result.dead_zones[static_cast<size_t>(AxisAction::kLeftTrigger)] = 0.0f;
    result.dead_zones[static_cast<size_t>(AxisAction::kRightTrigger)] = 0.0f;
    result.trigger_threshold = current_profile.trigger_threshold;

    const tinyxml2::XMLElement* mappings = selected_controller->FirstChildElement("mappings");
    if (!mappings) {
        if (error) *error = "The selected SDLController entry has no mappings.";
        return false;
    }

    struct AxisAssignment { bool set = false; int index = -1; bool inverted = false; };
    std::array<AxisAssignment, kAxisCount> axis_assignments{};
    std::array<bool, kButtonCount> button_assignments{};

    for (const tinyxml2::XMLElement* entry = mappings->FirstChildElement("entry");
         entry; entry = entry->NextSiblingElement("entry")) {
        uint64_t logical_id = 0, physical_id = 0;
        if (!parse_unsigned(entry->FirstChildElement("mapping"), logical_id) ||
            !parse_unsigned(entry->FirstChildElement("button"), physical_id)) {
            ++report.skipped_mappings;
            warning(report, "Skipped a mapping entry with a missing or invalid numeric value.");
            continue;
        }

        LogicalMapping logical;
        if (!logical_mapping(report.emulated_controller_type, logical_id, logical) ||
            logical.kind == LogicalKind::kUnsupported) {
            ++report.skipped_mappings;
            warning(report, "Skipped an unsupported Cemu logical mapping.");
            continue;
        }

        const PhysicalMapping physical = physical_mapping(physical_id);
        if (logical.kind == LogicalKind::kButton) {
            const size_t button_index = static_cast<size_t>(logical.button);
            if (physical.kind == PhysicalMapping::Kind::kButton) {
                if (button_assignments[button_index] && result.buttons[button_index] != physical.index) {
                    ++report.skipped_mappings;
                    warning(report, "Skipped a duplicate logical button with conflicting physical bindings.");
                    continue;
                }
                result.buttons[button_index] = static_cast<int16_t>(physical.index);
                button_assignments[button_index] = true;
                ++report.imported_button_bindings;
                continue;
            }

            const bool is_left_trigger = logical.button == ButtonAction::kZL;
            const bool is_right_trigger = logical.button == ButtonAction::kZR;
            if (physical.kind == PhysicalMapping::Kind::kAxis && physical.sign > 0 &&
                (is_left_trigger || is_right_trigger) &&
                (physical.index == SDL_GAMEPAD_AXIS_LEFT_TRIGGER || physical.index == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER)) {
                const size_t axis_index = static_cast<size_t>(is_left_trigger ? AxisAction::kLeftTrigger : AxisAction::kRightTrigger);
                AxisAssignment& existing = axis_assignments[axis_index];
                if (existing.set && existing.index != physical.index) {
                    ++report.skipped_mappings;
                    warning(report, "Skipped a trigger mapping because it conflicts with an earlier physical axis.");
                    continue;
                }
                if (!existing.set) ++report.imported_axis_bindings;
                result.axes[axis_index] = static_cast<int8_t>(physical.index);
                existing = {true, physical.index, false};
                continue;
            }
            ++report.skipped_mappings;
            warning(report, "Skipped a button mapping that cannot be represented by an SDL gamepad button.");
            continue;
        }

        if (logical.kind == LogicalKind::kAxis) {
            if (physical.kind != PhysicalMapping::Kind::kAxis ||
                physical.index == SDL_GAMEPAD_AXIS_LEFT_TRIGGER || physical.index == SDL_GAMEPAD_AXIS_RIGHT_TRIGGER) {
                ++report.skipped_mappings;
                warning(report, "Skipped a stick mapping that does not point to a stick axis.");
                continue;
            }
            const size_t axis_index = static_cast<size_t>(logical.axis);
            const bool inverted = physical.sign != logical.expected_sign;
            AxisAssignment& existing = axis_assignments[axis_index];
            if (existing.set && (existing.index != physical.index || existing.inverted != inverted)) {
                ++report.skipped_mappings;
                warning(report, "Skipped a stick mapping because its opposite direction conflicts with the first binding.");
                continue;
            }
            const bool first_binding = !existing.set;
            existing = {true, physical.index, inverted};
            result.axes[axis_index] = static_cast<int8_t>(physical.index);
            result.axis_inverted[axis_index] = inverted;
            if (first_binding) ++report.imported_axis_bindings;
        }
    }

    const auto apply_dead_zone = [&](const char* element_name, std::initializer_list<AxisAction> actions) {
        const tinyxml2::XMLElement* settings = selected_controller->FirstChildElement(element_name);
        float dead_zone = 0.0f;
        if (settings && parse_float(settings, "deadzone", dead_zone)) {
            if (dead_zone < 0.0f || dead_zone > 0.9f) {
                warning(report, std::string("Ignored an out-of-range ") + element_name + " dead zone.");
            } else {
                for (AxisAction action : actions) result.dead_zones[static_cast<size_t>(action)] = dead_zone;
            }
        }
        float range = 1.0f;
        if (settings && parse_float(settings, "range", range) && std::fabs(range - 1.0f) > 0.001f) {
            warning(report, std::string("The Cemu ") + element_name + " range value is not represented by the current profile format.");
        }
    };
    apply_dead_zone("axis", {AxisAction::kLeftX, AxisAction::kLeftY});
    apply_dead_zone("rotation", {AxisAction::kRightX, AxisAction::kRightY});
    apply_dead_zone("trigger", {AxisAction::kLeftTrigger, AxisAction::kRightTrigger});

    float rumble = 0.0f;
    if (parse_float(selected_controller, "rumble", rumble) && rumble > 0.0f) {
        warning(report, "Cemu rumble strength is not imported; configure vibration separately.");
    }
    const std::string motion = element_text(selected_controller, "motion");
    if (motion == "true" || motion == "1") {
        warning(report, "Cemu motion settings are not imported.");
    }

    if (report.imported_button_bindings == 0 && report.imported_axis_bindings == 0) {
        if (error) *error = "No supported SDLController mappings could be imported.";
        return false;
    }

    imported_profile = std::move(result);
    return true;
}

} // namespace cafe::host::controller_profiles
