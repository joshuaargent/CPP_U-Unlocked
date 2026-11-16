#pragma once

#include "host/controller_profiles.h"

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace cafe::host::controller_profiles {

struct CemuImportReport {
    std::string profile_name;
    std::string emulated_controller_type;
    std::string source_controller_name;
    std::string source_controller_uuid;
    size_t imported_button_bindings = 0;
    size_t imported_axis_bindings = 0;
    size_t skipped_mappings = 0;
    std::vector<std::string> warnings;
};

// Imports only Cemu SDLController profiles. Cemu mapping identifiers are translated
// explicitly; they are never cast to SDL enums. The source XML is never modified.
bool import_cemu_profile_xml(std::string_view xml,
                             const Profile& current_profile,
                             Profile& imported_profile,
                             CemuImportReport& report,
                             std::string* error = nullptr);

} // namespace cafe::host::controller_profiles
