// U Unlocked's launcher: a full-window menu over a scene from the game
// (Play, Settings, Mods, Quit) driven by a pad, the keyboard or the mouse.
// It finds the game and its update, writes display.ini (what the game reads
// when it starts) and runs smash.exe beside it.
//
// Files beside the executable: smash.exe, launcher.ini, display.ini, mods\,
// cache\, and fonts\launcher.ttf (optional, else Bahnschrift / Segoe UI / DejaVu Sans).

#include "host/cpu_level.h"
#include "host/controller_profiles.h"
#include "host/display_settings.h"
#include "host/rooms.h"
#include "host/http.h"
#include "os/act_server.h"
#include "os/online_identity.h"
#include "host/paint.h" // before the stb_truetype implementation below
#include "host/controller_profile_import.h"
#include "host/keymap.h"

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#endif

#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#include "stb_image.h"
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <charconv>
#include <exception>
#include <cctype>
#include <cstdlib>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <numbers>
#include <optional>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

namespace fs = std::filesystem;
namespace display = cafe::host::display;
namespace online = cafe::os::online;
namespace act_server = cafe::os::act_server;
namespace controller_profiles = cafe::host::controller_profiles;
namespace keymap = cafe::host::keymap;
using namespace cafe::host::paint;

namespace {

constexpr const char* kVersion = "0.3.2-dev";
constexpr const char* kUpdateId = "0005000E10144F00"; // v304
constexpr const char* kGameId = "0005000010144F00";   // USA


// ------------------------------------------------------------------ files

fs::path exe_dir() { return fs::path(SDL_GetBasePath()); }

std::string path_utf8(const fs::path& path) {
    const std::u8string encoded = path.u8string();
    return std::string(reinterpret_cast<const char*>(encoded.data()), encoded.size());
}

std::optional<std::string> read_text(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return std::nullopt;
    std::stringstream s;
    s << in.rdbuf();
    return s.str();
}

// launcher.ini: `name = value` lines.
std::map<std::string, std::string> read_ini(const fs::path& path) {
    std::map<std::string, std::string> values;
    std::istringstream in(read_text(path).value_or(""));
    for (std::string line; std::getline(in, line);) {
        const size_t eq = line.find('=');
        if (line.empty() || line[0] == '#' || eq == std::string::npos) continue;
        const auto trim = [](std::string s) {
            s.erase(0, s.find_first_not_of(" \t\r"));
            s.erase(s.find_last_not_of(" \t\r") + 1);
            return s;
        };
        values[trim(line.substr(0, eq))] = trim(line.substr(eq + 1));
    }
    return values;
}

fs::path cemu_profiles_directory() {
    if (const char* configured = std::getenv("CEMU_CONFIG_DIR"); configured && *configured) {
        const fs::path root(configured);
        return root.filename() == "controllerProfiles" ? root : root / "controllerProfiles";
    }
#ifdef _WIN32
    if (const char* app_data = std::getenv("APPDATA"); app_data && *app_data) {
        return fs::path(app_data) / "Cemu" / "controllerProfiles";
    }
    if (const char* user_profile = std::getenv("USERPROFILE"); user_profile && *user_profile) {
        return fs::path(user_profile) / "AppData" / "Roaming" / "Cemu" / "controllerProfiles";
    }
#elif defined(__APPLE__)
    if (const char* home = std::getenv("HOME"); home && *home) {
        return fs::path(home) / "Library" / "Application Support" / "Cemu" / "controllerProfiles";
    }
#else
    if (const char* config = std::getenv("XDG_CONFIG_HOME"); config && *config == '/') {
        return fs::path(config) / "Cemu" / "controllerProfiles";
    }
    if (const char* home = std::getenv("HOME"); home && *home) {
        return fs::path(home) / ".config" / "Cemu" / "controllerProfiles";
    }
#endif
    return {};
}

size_t count_cemu_profiles(const fs::path& directory) {
    std::error_code ec;
    if (directory.empty() || !fs::is_directory(directory, ec)) return 0;
    size_t count = 0;
    for (fs::directory_iterator it(directory, fs::directory_options::skip_permission_denied, ec), end;
         it != end && !ec; it.increment(ec)) {
        if (!it->is_regular_file(ec)) continue;
        std::string extension = it->path().extension().string();
        std::transform(extension.begin(), extension.end(), extension.begin(),
                       [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        if (extension == ".xml") ++count;
    }
    return count;
}

constexpr const char* kDlcId = "0005000C10144F00";

// A title folder's code/app.xml: its title id and version (both hex there).
struct TitleInfo {
    std::string id;
    int version = 0;
};
std::optional<TitleInfo> title_of(const fs::path& folder) {
    const auto xml = read_text(folder / "code" / "app.xml");
    if (!xml) return std::nullopt;
    const auto tag = [&](const char* name) -> std::string {
        const size_t open = xml->find(std::string("<") + name);
        const size_t start = open == std::string::npos ? open : xml->find('>', open);
        const size_t end = start == std::string::npos ? start : xml->find('<', start);
        return end == std::string::npos ? "" : xml->substr(start + 1, end - start - 1);
    };
    TitleInfo t{tag("title_id"), static_cast<int>(std::strtol(tag("title_version").c_str(), nullptr, 16))};
    std::transform(t.id.begin(), t.id.end(), t.id.begin(), [](unsigned char c) { return static_cast<char>(std::toupper(c)); });
    return t;
}

// The three folders the launcher needs (DLC optional), as chosen.
enum Slot { kGame, kUpdate, kDlc, kSlots };
constexpr const char* kSlotIds[kSlots] = {kGameId, kUpdateId, kDlcId};
constexpr const char* kSlotKeys[kSlots] = {"game", "update", "dlc"};

// Whether `folder` is that title.
bool is_title(const fs::path& folder, Slot slot) {
    const auto t = title_of(folder);
    std::error_code ec;
    return t && t->id == kSlotIds[slot] && (slot != kUpdate || fs::exists(folder / "code" / "cross_f.rpx", ec));
}

// The titles in `folder`, the folders in it and the folders beside it, for
// the slots not chosen yet.
void find_titles(const fs::path& folder, fs::path (&slots)[kSlots]) {
    std::error_code ec;
    std::vector<fs::path> candidates{folder};
    for (const fs::path& dir : {folder, folder.parent_path()}) {
        for (const auto& entry : fs::directory_iterator(dir, ec)) {
            if (entry.is_directory(ec)) candidates.push_back(entry.path());
        }
    }
    for (const fs::path& c : candidates) {
        for (int s = 0; s < kSlots; ++s) {
            if (slots[s].empty() && is_title(c, Slot(s))) slots[s] = c;
        }
    }
}

// DLC folders hold content/<number>/ folders; a dump without the content
// has only placeholder files there.
// The DLC items: content\<number>\ folders with a file in them. Smash's fighters and stages come with the
// update; each DLC item's folder only marks it owned (dummy_content.txt, "content data").
int dlc_items(const fs::path& folder) {
    std::error_code ec;
    int items = 0;
    for (const auto& item : fs::directory_iterator(folder / "content", ec)) {
        if (!item.is_directory(ec)) continue;
        for (const auto& entry : fs::recursive_directory_iterator(item.path(), ec)) {
            if (entry.is_regular_file(ec)) {
                ++items;
                break;
            }
        }
    }
    return items;
}

// A mod: a folder in mods\ with the game's content\ layout somewhere inside, as the common formats
// put it: content\ itself (Sm4shExplorer, big packs), a folder or two down (archives),
// sdcafiine\<title id>\<mod>\content\ (SDCafiine), or beside a Cemu graphic pack's rules.txt.
struct Mod {
    std::string name;
    fs::path root; // the folder with content\ in it
    bool on = true;
};

// The first folder holding content\, searching `depth` levels down.
fs::path find_content_root(const fs::path& folder, int depth) {
    std::error_code ec;
    if (fs::is_directory(folder / "content", ec)) return folder;
    if (depth == 0) return {};
    for (const auto& sub : fs::directory_iterator(folder, ec)) {
        if (!sub.is_directory(ec) || sub.path().filename() == "content") continue;
        if (fs::path root = find_content_root(sub.path(), depth - 1); !root.empty()) return root;
    }
    return {};
}

// A Cemu graphic pack's name from its rules.txt (`name = ...` in [Definition]).
std::string pack_name(const fs::path& root) {
    std::istringstream in(read_text(root / "rules.txt").value_or(""));
    for (std::string line; std::getline(in, line);) {
        if (line.rfind("name", 0) != 0 || line.find('=') == std::string::npos) continue;
        std::string name = line.substr(line.find('=') + 1);
        name.erase(0, name.find_first_not_of(" \t\""));
        name.erase(name.find_last_not_of(" \t\r\"") + 1);
        return name;
    }
    return {};
}

// Archive extraction is deliberately disabled until a bounded, link-safe extractor is
// integrated. The Windows tar utility is not an acceptable security boundary for
// archives supplied by users.

// What installing a mod (a folder) did: the mod's name, or why it failed.
struct Installed {
    bool ok = false;
    std::string message;
};

bool is_reparse_point(const fs::path& path) {
#ifdef _WIN32
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
#else
    std::error_code ec;
    const auto status = fs::symlink_status(path, ec);
    return ec || fs::is_symlink(status);
#endif
}

void copy_mod_folder_safely(const fs::path& source, const fs::path& destination) {
    constexpr size_t kMaximumEntries = 20000;
    constexpr uint64_t kMaximumExpandedBytes = 4ULL * 1024 * 1024 * 1024;
    std::error_code ec;
    const auto root_status = fs::symlink_status(source, ec);
    if (ec || !fs::is_directory(root_status) || fs::is_symlink(root_status) || is_reparse_point(source))
        throw std::runtime_error("The selected mod folder is not a normal directory.");
    fs::create_directories(destination, ec);
    if (ec) throw std::runtime_error("Cannot create the mod staging directory: " + ec.message());

    size_t entries = 0;
    uint64_t expanded_bytes = 0;
    for (fs::recursive_directory_iterator it(source, fs::directory_options::none, ec), end; it != end; it.increment(ec)) {
        if (ec) throw std::runtime_error("Cannot inspect the selected mod folder: " + ec.message());
        if (++entries > kMaximumEntries)
            throw std::runtime_error("The mod folder exceeds the 20,000-entry safety limit.");
        const fs::path input = it->path();
        const fs::path relative = input.lexically_relative(source);
        if (relative.empty() || relative.is_absolute())
            throw std::runtime_error("The mod folder contains an invalid relative path.");
        for (const auto& component : relative) {
            if (component == "." || component == "..")
                throw std::runtime_error("The mod folder contains an unsafe path.");
        }
        const auto status = it->symlink_status(ec);
        if (ec || fs::is_symlink(status) || is_reparse_point(input))
            throw std::runtime_error("The mod folder contains a symbolic link or reparse point: " + relative.string());
        const fs::path output = destination / relative;
        if (fs::is_directory(status)) {
            fs::create_directory(output, ec);
            if (ec) throw std::runtime_error("Cannot create mod directory: " + ec.message());
        } else if (fs::is_regular_file(status)) {
            const uint64_t size = fs::file_size(input, ec);
            if (ec || size > kMaximumExpandedBytes - expanded_bytes)
                throw std::runtime_error("The mod folder exceeds the 4 GiB expanded-size safety limit.");
            expanded_bytes += size;
            fs::copy_file(input, output, fs::copy_options::none, ec);
            if (ec) throw std::runtime_error("Cannot copy mod file " + relative.string() + ": " + ec.message());
        } else {
            throw std::runtime_error("The mod folder contains an unsupported filesystem entry: " + relative.string());
        }
    }
    if (ec) throw std::runtime_error("Cannot finish inspecting the mod folder: " + ec.message());
}

// Installs an extracted mod folder as mods/<its name>.
Installed install_mod(const fs::path& source, const fs::path& mods) {
    std::error_code ec;
    const auto source_status = fs::symlink_status(source, ec);
    if (ec || !fs::is_directory(source_status) || fs::is_symlink(source_status) || is_reparse_point(source))
        return {false, "Select an extracted mod folder. Archive installation is temporarily disabled until secure extraction is available."};
    fs::create_directories(mods, ec);
    if (ec) return {false, "Cannot create the mods directory: " + ec.message()};
    std::string name = source.filename().string();
    for (char& c : name) {
        if (std::string("<>:\"/\\|?*").find(c) != std::string::npos || static_cast<unsigned char>(c) < 32) c = '_';
    }
    if (name.empty() || name[0] == '.') name = "mod" + name;
    // Copy into a fresh staging directory, then atomically rename into the mods list.
    const fs::path staging = mods / (".installing-" + name);
    if (fs::exists(staging, ec))
        return {false, "A previous installation is still staged for this mod. Remove " + staging.filename().string() + " and retry."};
    fs::create_directory(staging, ec);
    if (ec) return {false, "Cannot create the mod staging directory: " + ec.message()};
    const auto fail = [&](std::string why) {
        std::error_code cleanup_error;
        fs::remove_all(staging, cleanup_error);
        return Installed{false, std::move(why)};
    };
    try {
        copy_mod_folder_safely(source, staging / source.filename());
    } catch (const std::exception& error) {
        return fail(std::string("Mod folder rejected: ") + error.what());
    }
    if (find_content_root(staging, 5).empty()) {
        return fail(source.filename().string() + " isn't a Smash mod: there's no content folder in it.");
    }
    // A single top-level folder becomes the installed mod's folder.
    fs::path top = staging;
    std::vector<fs::path> entries;
    for (const auto& e : fs::directory_iterator(staging, ec)) entries.push_back(e.path());
    if (entries.size() == 1 && fs::is_directory(entries[0], ec) && entries[0].filename() != "content") top = entries[0];
    fs::path target = mods / name;
    for (int n = 2; fs::exists(target, ec); ++n) target = mods / (name + " (" + std::to_string(n) + ")");
    fs::rename(top, target, ec);
    if (ec) return fail("Couldn't move the mod into the mods folder: " + ec.message());
    fs::remove_all(staging, ec);
    return Installed{true, target.filename().string()};
}

std::vector<Mod> find_mods(const fs::path& mods) {
    std::vector<Mod> found;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(mods, ec)) {
        if (!entry.is_directory(ec) || entry.path().filename().string().rfind(".installing-", 0) == 0) continue;
        const fs::path root = find_content_root(entry.path(), 4);
        if (root.empty()) continue;
        // The name: a graphic pack's own, SDCafiine's mod folder, else the folder in mods\.
        std::string name = pack_name(root);
        if (name.empty() && root.parent_path().parent_path().filename() == "sdcafiine") name = root.filename().string();
        found.push_back({name.empty() ? entry.path().filename().string() : name, root});
    }
    std::sort(found.begin(), found.end(), [](const Mod& a, const Mod& b) { return a.name < b.name; });
    return found;
}

// ------------------------------------------------------------------ drawing


Image load_image(SDL_Renderer* renderer, const fs::path& path) {
    int w = 0, h = 0, n = 0;
    stbi_uc* pixels = stbi_load(path.string().c_str(), &w, &h, &n, 4);
    if (!pixels) return {};
    SDL_Texture* t = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA32, SDL_TEXTUREACCESS_STATIC, w, h);
    if (t) {
        SDL_UpdateTexture(t, nullptr, pixels, w * 4);
        SDL_SetTextureBlendMode(t, SDL_BLENDMODE_BLEND);
        SDL_SetTextureScaleMode(t, SDL_SCALEMODE_LINEAR);
    }
    stbi_image_free(pixels);
    return {t, float(w), float(h)};
}


// Clear credential buffers before releasing their storage. Volatile writes
// prevent the compiler from treating the wipe as an unused optimisation.
void secure_erase(std::string& value) {
    volatile char* bytes = value.empty() ? nullptr : value.data();
    for (size_t i = 0; i < value.size(); ++i) bytes[i] = '\0';
    value.clear();
}

struct WuaImportResult {
    bool ok = false;
    std::string message;
    fs::path stage;
    fs::path extracted;
    fs::path slots[kSlots];
};

struct AppUpdateCheck {
    bool ok = false;
    bool available = false;
    std::string channel;
    std::string version;
    std::string release_url;
    std::string message;
};

std::string json_string_field(std::string_view json, std::string_view key) {
    const std::string needle = "\"" + std::string(key) + "\"";
    const size_t key_pos = json.find(needle);
    if (key_pos == std::string_view::npos) return {};
    const size_t colon = json.find(':', key_pos + needle.size());
    if (colon == std::string_view::npos) return {};
    size_t pos = colon + 1;
    while (pos < json.size() && std::isspace(static_cast<unsigned char>(json[pos]))) ++pos;
    if (pos >= json.size() || json[pos++] != '"') return {};
    std::string value;
    while (pos < json.size()) {
        const char c = json[pos++];
        if (c == '"') return value;
        if (c == '\\') {
            if (pos >= json.size()) return {};
            const char escaped = json[pos++];
            if (escaped == '"' || escaped == '\\' || escaped == '/') value.push_back(escaped);
            else if (escaped == 'n') value.push_back('\n');
            else if (escaped == 'r') value.push_back('\r');
            else if (escaped == 't') value.push_back('\t');
            else return {};
        } else if (static_cast<unsigned char>(c) >= 0x20) {
            value.push_back(c);
        } else {
            return {};
        }
    }
    return {};
}

std::array<int, 3> numeric_version(std::string version) {
    if (!version.empty() && (version.front() == 'v' || version.front() == 'V')) version.erase(version.begin());
    const size_t suffix = version.find_first_of("-+");
    if (suffix != std::string::npos) version.resize(suffix);
    std::array<int, 3> parts{};
    size_t start = 0;
    for (size_t i = 0; i < parts.size(); ++i) {
        const size_t end = i + 1 == parts.size() ? version.size() : version.find('.', start);
        if (end == std::string::npos || end <= start) return {};
        const auto parsed = std::from_chars(version.data() + start, version.data() + end, parts[i]);
        if (parsed.ec != std::errc{} || parsed.ptr != version.data() + end || parts[i] < 0) return {};
        start = end + 1;
    }
    return parts;
}

std::array<int, 2> release_stage(const std::string& version) {
    const size_t suffix_at = version.find_first_of("-+");
    if (suffix_at == std::string::npos) return {4, 0}; // stable
    std::string suffix = version.substr(suffix_at + 1);
    std::transform(suffix.begin(), suffix.end(), suffix.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    int stage = 0; // development / unknown prerelease
    if (suffix.starts_with("alpha")) stage = 1;
    else if (suffix.starts_with("beta")) stage = 2;
    else if (suffix.starts_with("rc")) stage = 3;
    int sequence = 0;
    const size_t dot = suffix.find_last_of('.');
    if (dot != std::string::npos) {
        const char* first = suffix.data() + dot + 1;
        const char* last = suffix.data() + suffix.size();
        const auto parsed = std::from_chars(first, last, sequence);
        if (parsed.ec != std::errc{} || parsed.ptr != last) sequence = 0;
    }
    return {stage, sequence};
}

bool is_newer_release(const std::string& latest, const std::string& current) {
    const auto a = numeric_version(latest);
    const auto b = numeric_version(current);
    if (a == std::array<int, 3>{} || b == std::array<int, 3>{}) return false;
    if (a != b) return a > b;
    return release_stage(latest) > release_stage(current);
}

// ------------------------------------------------------------------ the launcher

enum class Screen { kMain, kSettings, kMods, kOnline, kNetplay, kControls, kControlTest, kLibrary, kUpdates, kDiagnostics };

// A preset is deliberately derived from the saved settings: changing any
// individual option immediately changes the label to Custom.
int graphics_preset_index(const display::Settings& settings) {
    if (settings.resolution == display::Resolution::k720 && !settings.interpolation) return 0;
    if (settings.resolution == display::Resolution::k1080 && settings.interpolation && settings.frame_rate == 0) return 1;
    if (settings.resolution == display::Resolution::k1440 && settings.interpolation && settings.frame_rate == 0) return 2;
    if (settings.resolution == display::Resolution::kAuto && settings.interpolation && settings.frame_rate == 0) return 3;
    return -1;
}

std::string graphics_preset_name(const display::Settings& settings) {
    switch (graphics_preset_index(settings)) {
    case 0: return "Performance";
    case 1: return "Balanced";
    case 2: return "Quality";
    case 3: return "Automatic";
    default: return "Custom";
    }
}


struct Item {
    std::string label;
    std::string value; // settings: the current choice, shown with chevrons
    int badge = 0;
};

class Launcher {
public:
    Launcher(SDL_Window* window, SDL_Renderer* renderer) : window_(window), r_(renderer), paint_(renderer) {
        dir_ = exe_dir();
        logo_ = load_image(r_, dir_ / "title-logo.png");
        if (!logo_.texture) {
            std::fprintf(stderr, "launcher: project title logo is missing; using the text fallback\\n");
        }
        display::set_file(data_dir() / "display.ini", "U Unlocked");
        settings_ = display::load(display::file_path()).settings;
        const auto ini = read_ini(dir_ / "launcher.ini");
        for (int s = 0; s < kSlots; ++s) {
            if (auto it = ini.find(kSlotKeys[s]); it != ini.end()) paths_[s] = it->second;
        }
        if (auto it = ini.find("game_folder"); it != ini.end()) find_titles(it->second, paths_); // older file
        if (auto it = ini.find("netplay_host"); it != ini.end()) netplay_host_ = it->second == "yes";
        if (auto it = ini.find("netplay_name"); it != ini.end()) netplay_name_ = it->second;
        if (auto it = ini.find("netplay_address"); it != ini.end()) netplay_address_ = it->second;
        if (auto it = ini.find("update_channel"); it != ini.end() && it->second == "beta") update_channel_ = "beta";
        online::load(data_dir() / "online");
        refresh();
        font_.open({data_dir() / "fonts" / "launcher.ttf", "C:/Windows/Fonts/bahnschrift.ttf", "C:/Windows/Fonts/segoeui.ttf",
                    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf"});

        // Check in the background on startup; installation remains an explicit user action.
        check_launcher_updates();
    }

    bool running() const { return !quit_; }
    bool game_running() const { return process_ != nullptr; }
    bool installing() const { return installing_; }

    ~Launcher() {
        shutting_down_.store(true, std::memory_order_release);
        room_watch_enabled_.store(false, std::memory_order_release);
        if (rooms_thread_.joinable()) rooms_thread_.join();
        if (install_thread_.joinable()) install_thread_.join();
        if (sign_in_thread_.joinable()) sign_in_thread_.join();
        if (update_check_thread_.joinable()) update_check_thread_.join();
        if (wua_thread_.joinable()) wua_thread_.join();
        if (build_process_) {
            int code = 0;
            SDL_WaitProcess(build_process_, true, &code);
            SDL_DestroyProcess(build_process_);
            build_process_ = nullptr;
        }
        if (!wua_stage_path_.empty()) {
            std::error_code cleanup_error;
            fs::remove_all(wua_stage_path_, cleanup_error);
        }
        if (logo_.texture) {
            SDL_DestroyTexture(logo_.texture);
            logo_.texture = nullptr;
        }
        if (background_.texture) {
            SDL_DestroyTexture(background_.texture);
            background_.texture = nullptr;
        }
    }

    void event(SDL_Event& e) {
        SDL_ConvertEventToRenderCoordinates(r_, &e);
        if (capture_binding_) {
            if (e.type == SDL_EVENT_KEY_DOWN && e.key.key == SDLK_ESCAPE) {
                capture_binding_ = false;
                capture_keyboard_ = false;
                controls_status_ = "Binding cancelled.";
                return;
            }
            if (capture_keyboard_ && e.type == SDL_EVENT_KEY_DOWN && !e.key.repeat) {
                const uint16_t scancode = static_cast<uint16_t>(e.key.scancode);
                if (scancode < keymap::kFirstKey || scancode >= keymap::kKeyCount) return;
                if (keymap::reserved(scancode)) {
                    controls_status_ = "That key is reserved by U Unlocked. Press another key or Escape to cancel.";
                    return;
                }
                keyboard_keys_[control_keyboard_action_] = scancode;
                capture_binding_ = false;
                capture_keyboard_ = false;
                controls_status_ = "Keyboard key captured. Save keyboard bindings to keep it.";
                return;
            }
            if (e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN && e.gbutton.which == control_device_ && !capture_axis_ && !capture_keyboard_) {
                control_profile_.buttons[control_button_action_] = static_cast<int16_t>(e.gbutton.button);
                capture_binding_ = false;
                controls_status_ = "Button binding captured. Save the profile to keep it.";
                return;
            }
            if (e.type == SDL_EVENT_GAMEPAD_AXIS_MOTION && e.gaxis.which == control_device_ &&
                capture_axis_ && !capture_keyboard_ && std::abs(e.gaxis.value) > 16000) {
                control_profile_.axes[control_axis_action_] = static_cast<int8_t>(e.gaxis.axis);
                capture_binding_ = false;
                controls_status_ = "Axis binding captured. Save the profile to keep it.";
                return;
            }
            return;
        }
        if (editing_ >= 0 && text_event(e)) return;
        switch (e.type) {
        case SDL_EVENT_QUIT:
        case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
            std::fprintf(stderr, "launcher: quit (event 0x%x)\n", e.type);
            quit_ = true;
            break;
        case SDL_EVENT_KEY_DOWN:
            switch (e.key.key) {
            case SDLK_UP: case SDLK_W: move(-1); break;
            case SDLK_DOWN: case SDLK_S: move(1); break;
            case SDLK_LEFT: case SDLK_A:
                if (screen_ == Screen::kMain) move(-1); else change(-1);
                break;
            case SDLK_RIGHT: case SDLK_D:
                if (screen_ == Screen::kMain) move(1); else change(1);
                break;
            case SDLK_RETURN: case SDLK_SPACE: case SDLK_KP_ENTER: if (!e.key.repeat) activate(); break;
            case SDLK_ESCAPE: case SDLK_BACKSPACE: if (!e.key.repeat) back(); break;
            case SDLK_F11: SDL_SetWindowFullscreen(window_, !(SDL_GetWindowFlags(window_) & SDL_WINDOW_FULLSCREEN)); break;
            default: break;
            }
            break;
        case SDL_EVENT_GAMEPAD_ADDED: SDL_OpenGamepad(e.gdevice.which); break;
        case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
            switch (e.gbutton.button) {
            case SDL_GAMEPAD_BUTTON_DPAD_UP: move(-1); break;
            case SDL_GAMEPAD_BUTTON_DPAD_DOWN: move(1); break;
            case SDL_GAMEPAD_BUTTON_DPAD_LEFT:
                if (screen_ == Screen::kMain) move(-1); else change(-1);
                break;
            case SDL_GAMEPAD_BUTTON_DPAD_RIGHT:
                if (screen_ == Screen::kMain) move(1); else change(1);
                break;
            case SDL_GAMEPAD_BUTTON_SOUTH: case SDL_GAMEPAD_BUTTON_START: activate(); break;
            case SDL_GAMEPAD_BUTTON_EAST: case SDL_GAMEPAD_BUTTON_BACK: back(); break;
            default: break;
            }
            break;
        case SDL_EVENT_GAMEPAD_AXIS_MOTION:
            if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTY) stick_y_ = e.gaxis.value / 32767.0f;
            if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX) stick_x_ = e.gaxis.value / 32767.0f;
            break;
        case SDL_EVENT_MOUSE_MOTION:
            // (Not the motion a new window reports where the pointer already is.)
            if (time_ > 0.3f && (e.motion.xrel != 0 || e.motion.yrel != 0)) mouse_moved_ = true;
            if (int i = item_at(e.motion.x, e.motion.y); i >= 0 && mouse_moved_) select(i);
            break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            if (e.button.button != SDL_BUTTON_LEFT) break;
            if (int i = item_at(e.button.x, e.button.y); i >= 0) {
                select(i);
                const bool control_action = screen_ == Screen::kControls &&
                    (i == 3 || i == 5 || i == 9 || i == 10 || i == 11 || i == 12);
                const bool netplay_action = screen_ == Screen::kNetplay &&
                    (i == kHostSwitch || i == kNameField || i == kAddressField || i >= kFirstRoom);
                if (!control_action && !netplay_action && !items()[i].value.empty() && !folder_slot(i) && screen_ != Screen::kOnline) {
                    change(e.button.x < layout_.right_chevron - layout_.h * 0.06f ? -1 : 1);
                } else {
                    activate();
                }
            } else if (screen_ != Screen::kMain && e.button.x < layout_.w * 0.5f) {
                // (a click beside the menu does nothing; Back is an item)
            }
            break;
        case SDL_EVENT_DROP_FILE:
            if (e.drop.data) {
                go(Screen::kMods);
                start_install(e.drop.data);
            }
            break;
        case SDL_EVENT_MOUSE_BUTTON_UP:
            if (e.button.button == 4 /* X1: back */) back();
            break;
        default: break;
        }
    }

    void update(float dt) {
        time_ += dt;
        if (capture_binding_ && time_ - capture_started_ >= 10.0f) {
            capture_binding_ = false;
            capture_keyboard_ = false;
            controls_status_ = "Binding timed out. Select Bind again to retry.";
        }
        // The stick moves the selection, repeating while held.
        const auto repeat = [&](float value, float& held, auto&& action) {
            if (std::fabs(value) < 0.5f) {
                held = 0;
                return;
            }
            if (held == 0 || held > 0.4f) {
                action(value > 0 ? 1 : -1);
                if (held > 0.4f) held = 0.28f;
            }
            held += dt;
        };
        repeat(stick_y_, held_y_, [&](int d) { move(d); });
        repeat(stick_x_, held_x_, [&](int d) { change(d); });
        selection_y_ = ease(selection_y_, float(selected_), dt, 18);
        fade_ = std::min(1.0f, fade_ + dt * 5.5f);
        if (build_process_) {
            int code = 0;
            if (SDL_WaitProcess(build_process_, false, &code)) {
                SDL_DestroyProcess(build_process_);
                build_process_ = nullptr;
                building_runtime_ = false;
                refresh();
                std::error_code build_ec;
                const fs::path built_runtime = dir_ / "runtime";
                const auto output_exists = [&](const char* name) {
                    build_ec.clear();
                    return fs::is_regular_file(built_runtime / name, build_ec) && !build_ec;
                };
                const bool all_runtimes = output_exists("smash.exe") && output_exists("smash-compat.exe") &&
                    output_exists("smash-base.exe") && output_exists("smash-base-compat.exe");
                if (code == 0 && all_runtimes) {
                    reload_runtime_data_paths();
                    build_status_ = "Runtime built. Select Play.";
                    launch_error_.clear();
                } else {
                    build_status_ = "Build failed (exit " + std::to_string(code) + "). Open BuildLogs in Local AppData.";
                    launch_error_ = build_status_;
                }
            }
        }
        if (process_) {
            int code = 0;
            if (SDL_WaitProcess(process_, false, &code)) {
                SDL_DestroyProcess(process_);
                process_ = nullptr;
                exit_code_ = code;
                SDL_RestoreWindow(window_);
                SDL_RaiseWindow(window_);
                refresh();
            }
        }
        std::string chosen;
        bool done = false;
        {
            std::lock_guard lock(dialog_mutex_);
            chosen.swap(dialog_result_);
            std::swap(done, dialog_done_);
        }
        finish_sign_in();
        finish_install();
        finish_wua_import();
        finish_launcher_update_check();
        if (!done) return;
        SDL_SetWindowTitle(window_, "U Unlocked");
        if (wua_dialog_) {
            wua_dialog_ = false;
            if (!chosen.empty()) start_wua_import(fs::u8path(chosen));
            else wua_status_ = "WUA import cancelled.";
            return;
        }
        if (cemu_dialog_) {
            cemu_dialog_ = false;
            if (!chosen.empty()) import_cemu_profile_file(chosen);
            else controls_status_ = "Cemu profile import cancelled.";
            return;
        }
        if (mod_dialog_) {
            mod_dialog_ = false;
            if (!chosen.empty()) start_install(chosen);
            return;
        }
        if (online_dialog_) {
            online_dialog_ = false;
            if (!chosen.empty()) import_console_files(chosen);
            return;
        }
        if (!chosen.empty()) {
            // The chosen folder fills its slot; titles found beside it fill empty ones.
            paths_[dialog_slot_] = chosen;
            find_titles(chosen, paths_);
            save_launcher_ini();
            refresh();
        }
        // Play's questions go on until nothing is missing; cancelling the game stops them, the
        // update and DLC are skipped.
        if (prompting_) {
            const auto next = missing();
            if (next && (!chosen.empty() || dialog_slot_ != kGame)) {
                choose_folder(*next);
            } else {
                prompting_ = false;
                if (ready()) play();
            }
        }
    }

    // A mod given to the launcher (dropped on its icon, or on the command line).
    void install(const std::string& path) {
        go(Screen::kMods);
        start_install(path);
    }

    void open_screen(const std::string& name) {
        if (name == "settings") go(Screen::kSettings);
        if (name == "controls") { load_control_profile(); go(Screen::kControls); }
        if (name == "online") go(Screen::kOnline);
        if (name == "netplay") go(Screen::kNetplay);
        if (name == "mods") go(Screen::kMods);
        if (name == "library") go(Screen::kLibrary);
        if (name == "updates") go(Screen::kUpdates);
        if (name == "diagnostics") go(Screen::kDiagnostics);
        if (name == "play") play();
    }

    void draw(bool save = false) {
        int w = 0, h = 0;
        SDL_GetCurrentRenderOutputSize(r_, &w, &h);
        layout_ = Layout{float(w), float(h), items().size()};
        const float W = layout_.w, H = layout_.h;
        SDL_SetRenderDrawBlendMode(r_, SDL_BLENDMODE_BLEND);
        SDL_SetRenderDrawColor(r_, 6, 8, 14, 255);
        SDL_RenderClear(r_);
        if (screen_ == Screen::kMain) {
            draw_home();
            if (save) {
                if (SDL_Surface* shot = SDL_RenderReadPixels(r_, nullptr)) {
                    SDL_SaveBMP(shot, std::getenv("U_UNLOCKED_LAUNCHER_SHOT"));
                    SDL_DestroySurface(shot);
                }
            }
            SDL_RenderPresent(r_);
            return;
        }
        if (screen_ == Screen::kOnline) {
            // The Online page looks like the Wii U's own Nintendo Network ID Settings.
            draw_wiiu_online();
            if (save) {
                if (SDL_Surface* shot = SDL_RenderReadPixels(r_, nullptr)) {
                    SDL_SaveBMP(shot, std::getenv("U_UNLOCKED_LAUNCHER_SHOT"));
                    SDL_DestroySurface(shot);
                }
            }
            SDL_RenderPresent(r_);
            return;
        }
        draw_background();

        // The logo, top left.
        if (logo_.texture) {
            const float lh = H * 0.30f, lw = lh * logo_.width / logo_.height;
            paint_.image(logo_, {W * 0.055f, H * 0.075f, lw, lh});
        } else {
            font_.draw(r_, W * 0.08f, H * 0.25f, "U UNLOCKED", H * 0.09f, kWhite);
        }

        // The menu: the selected item between chevrons.
        const float alpha = fade_, slide = (1 - fade_) * H * 0.03f;
        const auto& list = items();
        const float px = H * layout_.px;
        const float sel_y = layout_.item_y(selection_y_) - px * 0.36f;
        const float pulse = 0.85f + 0.15f * std::sin(time_ * 4.0f);
        const Color chev{1, 1, 1, alpha * pulse};
        paint_.chevron(layout_.left_chevron - slide, sel_y, H * 0.034f, -1, H * 0.0042f, chev);
        paint_.chevron(layout_.right_chevron + slide, sel_y, H * 0.034f, 1, H * 0.0042f, chev);
        for (size_t i = 0; i < list.size(); ++i) {
            const bool on = static_cast<int>(i) == selected_;
            const Color c{1, 1, 1, alpha * (on ? 1.0f : 0.72f)};
            const float y = layout_.item_y(float(i));
            const float x = layout_.text_x + slide;
            const float tw = font_.draw(r_, x, y, list[i].label, px, c);
            if (list[i].badge > 0) {
                const float br = px * 0.3f, bx = x + tw + px * 0.42f, by = y - px * 0.36f;
                paint_.round_rect(bx - br, by - br, br * 2, br * 2, br, {kBadge.r, kBadge.g, kBadge.b, alpha});
                const std::string n = std::to_string(list[i].badge);
                font_.draw(r_, bx - font_.width(r_, n, px * 0.45f) / 2, by + px * 0.16f, n, px * 0.45f,
                           {0.12f, 0.08f, 0.02f, alpha}, false);
            }
            if (!list[i].value.empty()) {
                const float vpx = px * 0.74f;
                const std::string v = fit(list[i].value, vpx, W * 0.36f - (x - layout_.text_x) - tw);
                const float vx = layout_.right_chevron - H * 0.03f - font_.width(r_, v, vpx);
                const std::string& raw = list[i].value;
                Color vc = raw.rfind("Found", 0) == 0 || raw == "On" || (raw[0] == 'v' && raw.size() < 6) ? kGood
                           : raw == "Choose..."                                                ? kGold
                           : raw == "Wrong folder"                                             ? kBad
                                                                                               : kDim;
                vc.a = c.a;
                font_.draw(r_, vx, y - px * 0.04f, v, vpx, vc);
            }
        }

        draw_status();
        draw_toast();
        const std::string version = std::string("Version ") + kVersion;
        const float vpx = H * 0.032f;
        font_.draw(r_, W * 0.94f - font_.width(r_, version, vpx), H * 0.905f, version, vpx, kWhite);
        if (save) {
            if (SDL_Surface* s = SDL_RenderReadPixels(r_, nullptr)) {
                SDL_SaveBMP(s, std::getenv("U_UNLOCKED_LAUNCHER_SHOT"));
                SDL_DestroySurface(s);
            }
        }
        SDL_RenderPresent(r_);
    }

private:
    // The main menu: Play, the game / update / DLC folders, Settings, Mods, Quit.
    enum MainItem { kPlay, kBuildItem, kGameItem, kUpdateItem, kDlcItem, kOnlineItem, kNetplayItem, kControlsItem, kSettingsItem, kModsItem, kLibraryItem, kUpdatesItem, kDiagnosticsItem, kQuitItem };
    // The Netplay page (host/netplay.h: the host's game streamed to its guests): hosting, a name, joining.
    // Then the open rooms (or a line saying there are none), then Back.
    enum NetplayItem { kHostSwitch, kNameField, kAddressField, kFirstRoom };
    // The Online page: the console's files, the Pretendo ID and password, signing in and out.
    enum OnlineItem { kConsoleFiles, kUserField, kPasswordField, kSignIn, kSignOut, kOnlineBack };
    static constexpr int kSettingsBack = 4;
    static std::optional<Slot> folder_slot_of(Screen screen, int item) {
        if (screen != Screen::kMain || item < kGameItem || item > kDlcItem) return std::nullopt;
        return Slot(item - kGameItem);
    }
    std::optional<Slot> folder_slot(int item) const { return folder_slot_of(screen_, item); }

    struct Layout {
        float w = 1600, h = 900;
        float text_x = 0, left_chevron = 0, right_chevron = 0;
        float top = 0.505f, step = 0.083f, px = 0.048f; // fractions of the height
        Layout() = default;
        Layout(float w_, float h_, size_t items) : w(w_), h(h_) {
            text_x = std::max(w * 0.085f, h * 0.15f);
            left_chevron = text_x - h * 0.05f;
            right_chevron = text_x + std::min(w * 0.40f, h * 0.78f);
            if (items > 9) {
                top = 0.405f;
                step = 0.39f / float(items - 1);
                px = 0.031f;
            } else if (items > 4) { // the main menu: smaller, closer, above the status
                top = 0.445f;
                step = 0.33f / float(items - 1);
                px = 0.040f;
            }
        }
        float item_y(float i) const { return h * (top + i * step); }
    } layout_;

    // A folder's short state for the menu (the path shows below it when selected).
    std::string folder_value(Slot s) const {
        if (paths_[s].empty()) return s == kDlc ? "None" : "Choose...";
        if (!valid_[s]) return "Wrong folder";
        if (s == kUpdate) return "v" + std::to_string(update_version_);
        if (s == kDlc) return dlc_items_ > 0 ? "Found (" + std::to_string(dlc_items_) + " items)" : "No items";
        return "Found";
    }

    const std::vector<Item>& items() {
        list_.clear();
        switch (screen_) {
        case Screen::kMain:
            list_ = {{"PLAY"},
                     {"BUILD RUNTIME", building_runtime_ ? "Building locally..." : build_status_},
                     {"GAME", folder_value(kGame)},
                     {"UPDATE", folder_value(kUpdate)},
                     {"DLC", folder_value(kDlc)},
                     {"ONLINE", online_value()},
                     {"NETPLAY", netplay_host_ ? "Hosting" : ""},
                     {"CONTROLS"},
                     {"SETTINGS"},
                     {"MODS", "", static_cast<int>(std::count_if(mods_.begin(), mods_.end(), [](const Mod& m) { return m.on; }))},
                     {"LIBRARY"},
                     {"UPDATES", valid_[kUpdate] ? "Installed" : "Not installed"},
                     {"DIAGNOSTICS"},
                     {"QUIT"}};
            break;
        case Screen::kLibrary:
            list_ = {{"BASE GAME", folder_value(kGame)},
                     {"GAME UPDATE", folder_value(kUpdate)},
                     {"DLC CONTENT", folder_value(kDlc)},
                     {"IMPORT WUA ARCHIVE", wua_importing_ ? "Extracting and validating..." : wua_status_},
                     {"OPEN GAME DIRECTORY", paths_[kGame].empty() ? "Not configured" : paths_[kGame].string()},
                     {"OPEN UPDATE DIRECTORY", paths_[kUpdate].empty() ? "Not configured" : paths_[kUpdate].string()},
                     {"OPEN DLC DIRECTORY", paths_[kDlc].empty() ? "Not configured" : paths_[kDlc].string()},
                     {"BACK"}};
            break;
        case Screen::kUpdates:
            list_ = {{"APPLICATION VERSION", kVersion},
                     {"UPDATE CHANNEL", update_channel_ == "stable" ? "Stable" : "Beta"},
                     {"APPLICATION UPDATE STATUS", update_status_},
                     {"CHECK FOR APPLICATION UPDATES"},
                     {"INSTALL APPLICATION UPDATE"},
                     {"OPEN RELEASE PAGE"},
                     {"INSTALLED GAME UPDATE", valid_[kUpdate] ? "Version " + std::to_string(update_version_) : "Not installed"},
                     {"SELECT GAME UPDATE FOLDER"},
                     {"REMOVE GAME UPDATE"},
                     {"BACK"}};
            break;
        case Screen::kDiagnostics: {
            const char* platform = SDL_GetPlatform();
            const char* renderer = SDL_GetRendererName(r_);
            list_ = {{"PLATFORM", platform ? platform : "Unknown"},
                     {"LOGICAL CPU CORES", std::to_string(SDL_GetNumLogicalCPUCores())},
                     {"SYSTEM MEMORY", std::to_string(SDL_GetSystemRAM()) + " MB"},
                     {"CPU OPTIMISATION", cafe::host::cpu_has_x86_64_v3() ? "x86-64-v3 available" : "Compatibility path"},
                     {"LAUNCHER RENDERER", renderer ? renderer : "Unknown"},
                     {"BASE GAME", valid_[kGame] ? "Verified" : "Missing or invalid"},
                     {"GAME UPDATE", valid_[kUpdate] ? "Version " + std::to_string(update_version_) : "Not installed"},
                     {"ACTIVE MODS", std::to_string(std::count_if(mods_.begin(), mods_.end(), [](const Mod& m) { return m.on; }))},
                     {"SHADER CACHE", std::to_string(shaders_) + " files"},
                     {"LOG FILE", (dir_ / "smash.log").string()},
                     {"COPY DIAGNOSTIC REPORT", diagnostics_status_.empty() ? "Copy to clipboard" : diagnostics_status_},
                     {"BACK"}};
            break;
        }
        case Screen::kSettings: {
            const char* res = "Automatic";
            switch (settings_.resolution) {
            case display::Resolution::k720: res = "1280 x 720"; break;
            case display::Resolution::k1080: res = "1920 x 1080"; break;
            case display::Resolution::k1440: res = "2560 x 1440"; break;
            case display::Resolution::k2160: res = "3840 x 2160 (4K)"; break;
            case display::Resolution::k2880: res = "5120 x 2880 (5K)"; break;
            default: break;
            }
            const std::string fps = !settings_.interpolation                       ? "60"
                                    : settings_.frame_rate == 0                     ? "Automatic"
                                    : settings_.frame_rate == display::kUncapped   ? "Uncapped"
                                                                                   : std::to_string(settings_.frame_rate);
            list_ = {{"GRAPHICS PRESET", graphics_preset_name(settings_)},
                     {"RENDER RESOLUTION", res},
                     {"DISPLAY MODE", settings_.fullscreen ? "Fullscreen" : "Window"},
                     {"PRESENTATION RATE", fps},
                     {"BACK"}};
            break;
        }
        case Screen::kOnline: {
            const auto field = [&](int item, const std::string& text, bool secret) {
                std::string shown = secret ? std::string(utf8_length(text), '*') : text;
                if (editing_ == item) return shown + (std::fmod(time_, 1.0f) < 0.5f ? "|" : " ");
                return shown.empty() ? std::string("Type...") : shown;
            };
            list_ = {{"CONSOLE FILES", online::device().present ? "Found" : "Choose..."},
                     {"PRETENDO ID", field(kUserField, user_, false)},
                     {"PASSWORD", field(kPasswordField, password_, true)},
                     {"SIGN IN", signing_in_ ? "Signing in..." : ""},
                     {"SIGN OUT", online::account().present ? online::account().account_id : ""},
                     {"BACK"}};
            break;
        }
        case Screen::kNetplay: {
            const auto field = [&](int item, const std::string& text) {
                if (editing_ == item) return text + (std::fmod(time_, 1.0f) < 0.5f ? "|" : " ");
                return text.empty() ? std::string("Type...") : text;
            };
            list_ = {{"HOST MY GAMES", netplay_host_ ? "On" : "Off"},
                     {"MY NAME", field(kNameField, netplay_name_)},
                     {"JOIN ADDRESS", field(kAddressField, netplay_address_)}};
            std::lock_guard lock(rooms_mutex_);
            for (const auto& room : rooms_) {
                std::string label = room.name + "'S ROOM";
                for (char& ch : label) ch = static_cast<char>(std::toupper(static_cast<unsigned char>(ch)));
                list_.push_back({label, room.players >= room.max
                                                            ? "Full"
                                                            : std::to_string(room.players) + "/" + std::to_string(room.max)});
            }
            if (rooms_.empty()) {
                const bool directory_configured = !cafe::host::netplay::room_server().empty();
                list_.push_back({rooms_reached_ ? "NO OPEN ROOMS"
                                                : directory_configured ? "LOOKING FOR ROOMS..." : "ROOM DIRECTORY NOT CONFIGURED",
                                 directory_configured ? "" : "Enter a host IP or VPN address above to join directly."});
            }
            list_.push_back({"BACK"});
            break;
        }
        case Screen::kControls: {
            if (control_keyboard_) {
                static const std::array<const char*, keymap::kInputCount> names = {
                    "D-PAD UP", "D-PAD DOWN", "D-PAD LEFT", "D-PAD RIGHT",
                    "FACE TOP (X)", "FACE BOTTOM (B)", "FACE LEFT (Y)", "FACE RIGHT (A)",
                    "L", "R", "ZL", "ZR", "LEFT STICK UP", "LEFT STICK DOWN",
                    "LEFT STICK LEFT", "LEFT STICK RIGHT", "RIGHT STICK UP", "RIGHT STICK DOWN",
                    "RIGHT STICK LEFT", "RIGHT STICK RIGHT", "PLUS", "MINUS", "HOME"};
                const uint16_t scancode = keyboard_keys_[control_keyboard_action_];
                const char* key_name = SDL_GetScancodeName(static_cast<SDL_Scancode>(scancode));
                list_ = {{"INPUT DEVICE", "Keyboard (Player 1)"},
                         {"BUTTON", names[control_keyboard_action_]},
                         {"BIND KEY", capture_binding_ && capture_keyboard_ ? "Press a key..." : (key_name && *key_name ? key_name : "Unbound")},
                         {"SAVE KEYBOARD", "Save"},
                         {"RESET KEYBOARD", "Defaults"},
                         {"BACK"}};
            } else {
                const char* device = "No controller connected";
                if (SDL_Gamepad* pad = selected_control_gamepad()) {
                    if (const char* name = SDL_GetGamepadName(pad)) device = name;
                }
                const int button = control_profile_.buttons[control_button_action_];
                const int axis = control_profile_.axes[control_axis_action_];
                const char* button_name = button >= 0 ? SDL_GetGamepadStringForButton(static_cast<SDL_GamepadButton>(button)) : "Unbound";
                const char* axis_name = axis >= 0 ? SDL_GetGamepadStringForAxis(static_cast<SDL_GamepadAxis>(axis)) : "Unbound";
                const std::string player_slot = control_profile_.player_slot < 0
                    ? "Automatic" : "Player " + std::to_string(static_cast<int>(control_profile_.player_slot) + 1);
                char dead_zone[16]{}, threshold[16]{};
                std::snprintf(dead_zone, sizeof(dead_zone), "%.2f", control_profile_.dead_zones[control_axis_action_]);
                std::snprintf(threshold, sizeof(threshold), "%.2f", control_profile_.trigger_threshold);
                list_ = {{"INPUT DEVICE", device},
                         {"PLAYER SLOT", player_slot},
                         {"BUTTON", control_button_names()[control_button_action_]},
                         {"BIND BUTTON", capture_binding_ && !capture_axis_ ? "Waiting..." : (button_name ? button_name : "Unbound")},
                         {"STICK AXIS", control_axis_names()[control_axis_action_]},
                         {"BIND AXIS", capture_binding_ && capture_axis_ ? "Waiting..." : (axis_name ? axis_name : "Unbound")},
                         {"AXIS DEAD ZONE", dead_zone},
                         {"INVERT AXIS", control_axis_action_ >= static_cast<size_t>(controller_profiles::AxisAction::kLeftTrigger)
                             ? "N/A" : (control_profile_.axis_inverted[control_axis_action_] ? "On" : "Off")},
                         {"TRIGGER THRESHOLD", threshold},
                         {"IMPORT CEMU PROFILE", cemu_profile_count_ == 0
                             ? "Find Cemu XML..." : std::to_string(cemu_profile_count_) + " found"},
                         {"LIVE TEST", "Open"},
                         {"SAVE PROFILE", "Save"},
                         {"RESET PROFILE", "Defaults"},
                         {"BACK"}};
            }
            break;
        }
        case Screen::kControlTest: {
            SDL_Gamepad* pad = selected_control_gamepad();
            list_.clear();
            list_.push_back({"CONTROLLER", pad && SDL_GetGamepadName(pad) ? SDL_GetGamepadName(pad) : "No controller connected"});
            static constexpr std::array<controller_profiles::ButtonAction, controller_profiles::kButtonCount> actions = {
                controller_profiles::ButtonAction::kA, controller_profiles::ButtonAction::kB,
                controller_profiles::ButtonAction::kX, controller_profiles::ButtonAction::kY,
                controller_profiles::ButtonAction::kDpadUp, controller_profiles::ButtonAction::kDpadDown,
                controller_profiles::ButtonAction::kDpadLeft, controller_profiles::ButtonAction::kDpadRight,
                controller_profiles::ButtonAction::kL, controller_profiles::ButtonAction::kR,
                controller_profiles::ButtonAction::kZL, controller_profiles::ButtonAction::kZR,
                controller_profiles::ButtonAction::kPlus, controller_profiles::ButtonAction::kMinus,
                controller_profiles::ButtonAction::kHome, controller_profiles::ButtonAction::kLeftStick,
                controller_profiles::ButtonAction::kRightStick
            };
            static constexpr std::array<const char*, controller_profiles::kButtonCount> names = {
                "A", "B", "X", "Y", "UP", "DOWN", "LEFT", "RIGHT", "L", "R", "ZL", "ZR",
                "PLUS", "MINUS", "HOME", "L3", "R3"
            };
            std::string pressed;
            for (size_t i = 0; i < actions.size(); ++i) {
                if (!pad || !controller_profiles::button_pressed(pad, control_profile_, actions[i])) continue;
                if (!pressed.empty()) pressed += ", ";
                pressed += names[i];
            }
            if (pressed.empty()) pressed = "None";
            char left_stick[40]{}, right_stick[40]{}, triggers[40]{};
            const float lx = pad ? controller_profiles::axis_value(pad, control_profile_, controller_profiles::AxisAction::kLeftX) : 0.0f;
            const float ly = pad ? controller_profiles::axis_value(pad, control_profile_, controller_profiles::AxisAction::kLeftY) : 0.0f;
            const float rx = pad ? controller_profiles::axis_value(pad, control_profile_, controller_profiles::AxisAction::kRightX) : 0.0f;
            const float ry = pad ? controller_profiles::axis_value(pad, control_profile_, controller_profiles::AxisAction::kRightY) : 0.0f;
            const float lt = pad ? controller_profiles::axis_value(pad, control_profile_, controller_profiles::AxisAction::kLeftTrigger) : 0.0f;
            const float rt = pad ? controller_profiles::axis_value(pad, control_profile_, controller_profiles::AxisAction::kRightTrigger) : 0.0f;
            std::snprintf(left_stick, sizeof(left_stick), "X %+.2f   Y %+.2f", lx, ly);
            std::snprintf(right_stick, sizeof(right_stick), "X %+.2f   Y %+.2f", rx, ry);
            std::snprintf(triggers, sizeof(triggers), "L %.2f   R %.2f", lt, rt);
            list_ = {{"CONTROLLER", pad && SDL_GetGamepadName(pad) ? SDL_GetGamepadName(pad) : "No controller connected"},
                     {"PRESSED BUTTONS", pressed},
                     {"LEFT STICK", left_stick},
                     {"RIGHT STICK", right_stick},
                     {"TRIGGERS", triggers},
                     {"BACK"}};
            break;
        }
        case Screen::kMods:
            // Each mod with its switch, then the folder and Back.
            for (const Mod& m : mods_) list_.push_back({m.name, m.on ? "On" : "Off"});
            list_.push_back({"ADD MOD FOLDER...", installing_ ? "Installing..." : ""});
            list_.push_back({"OPEN MODS FOLDER"});
            list_.push_back({"BACK"});
            break;
        }
        return list_;
    }

    static const std::array<const char*, controller_profiles::kButtonCount>& control_button_names() {
        static const std::array<const char*, controller_profiles::kButtonCount> names = {
            "A", "B", "X", "Y", "D-PAD UP", "D-PAD DOWN", "D-PAD LEFT", "D-PAD RIGHT",
            "L", "R", "ZL", "ZR", "PLUS", "MINUS", "HOME", "LEFT STICK CLICK", "RIGHT STICK CLICK"};
        return names;
    }
    static const std::array<const char*, controller_profiles::kAxisCount>& control_axis_names() {
        static const std::array<const char*, controller_profiles::kAxisCount> names = {
            "LEFT STICK X", "LEFT STICK Y", "RIGHT STICK X", "RIGHT STICK Y", "LEFT TRIGGER", "RIGHT TRIGGER"};
        return names;
    }
    SDL_Gamepad* selected_control_gamepad() {
        if (control_device_ == 0) return nullptr;
        SDL_Gamepad* pad = SDL_GetGamepadFromID(control_device_);
        return pad ? pad : SDL_OpenGamepad(control_device_);
    }
    void load_control_profile() {
        const keymap::Loaded keyboard = keymap::load(keymap::file_path(), [](const std::string& name) {
            return static_cast<uint16_t>(SDL_GetScancodeFromName(name.c_str()));
        });
        keyboard_keys_ = keyboard.keys;
        for (const std::string& line : keyboard.log) std::fprintf(stderr, "launcher: %s\n", line.c_str());

        int count = 0;
        SDL_JoystickID* ids = SDL_GetGamepads(&count);
        control_device_ = count > 0 ? ids[0] : 0;
        for (int i = 0; i < count; ++i) {
            if (!SDL_GetGamepadFromID(ids[i])) SDL_OpenGamepad(ids[i]);
        }
        SDL_free(ids);
        control_keyboard_ = true;
        controls_status_ = "Editing keyboard controls for Player 1. Physical controllers are Players 2-8.";
        if (SDL_Gamepad* pad = selected_control_gamepad()) control_profile_ = controller_profiles::for_device(pad);
        else control_profile_ = controller_profiles::default_profile();
    }
    void select_control_device(int direction) {
        int count = 0;
        SDL_JoystickID* ids = SDL_GetGamepads(&count);
        int current = 0; // Keyboard is always the first entry (Player 1).
        if (!control_keyboard_) {
            for (int i = 0; i < count; ++i) if (ids[i] == control_device_) current = i + 1;
        }
        const int option_count = count + 1;
        const int next = (current + direction + option_count) % option_count;
        if (next == 0) {
            control_keyboard_ = true;
            controls_status_ = "Editing keyboard controls for Player 1.";
        } else {
            control_keyboard_ = false;
            control_device_ = ids[next - 1];
            if (!SDL_GetGamepadFromID(control_device_)) SDL_OpenGamepad(control_device_);
            if (SDL_Gamepad* pad = selected_control_gamepad()) {
                control_profile_ = controller_profiles::for_device(pad);
                const char* name = SDL_GetGamepadName(pad);
                controls_status_ = "Editing the profile for " + std::string(name ? name : "Controller");
            }
        }
        SDL_free(ids);
    }
    bool save_keyboard_profile() {
        const fs::path destination = keymap::file_path();
        std::error_code ec;
        fs::create_directories(destination.parent_path(), ec);
        if (ec) {
            controls_status_ = "Could not create keyboard settings folder: " + ec.message();
            return false;
        }
        fs::path temporary = destination;
        temporary += ".tmp";
        {
            std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
            if (!out) {
                controls_status_ = "Could not create the temporary keyboard settings file.";
                return false;
            }
            out << "# U Unlocked keyboard bindings for Player 1\n";
            for (size_t i = 0; i < keymap::kInputCount; ++i) {
                const uint16_t scancode = keyboard_keys_[i];
                if (scancode < keymap::kFirstKey || scancode >= keymap::kKeyCount || keymap::reserved(scancode)) {
                    controls_status_ = "A keyboard binding is invalid or reserved.";
                    out.close();
                    fs::remove(temporary, ec);
                    return false;
                }
                // Store numeric SDL scancodes so locale-specific key names and
                // names containing comment characters cannot corrupt the file.
                out << keymap::kInputs[i].id << " = " << scancode << "\n";
            }
            out.flush();
            if (!out) {
                controls_status_ = "Could not write the keyboard settings file.";
                out.close();
                fs::remove(temporary, ec);
                return false;
            }
        }
#ifdef _WIN32
        if (!MoveFileExW(temporary.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            const DWORD error = GetLastError();
            fs::remove(temporary, ec);
            controls_status_ = "Could not save keyboard settings (Windows error " + std::to_string(error) + ").";
            return false;
        }
#else
        fs::rename(temporary, destination, ec);
        if (ec) {
            const std::string message = ec.message();
            fs::remove(temporary, ec);
            controls_status_ = "Could not save keyboard settings: " + message;
            return false;
        }
#endif
        controls_status_ = "Player 1 keyboard bindings saved. They will apply when the game starts.";
        return true;
    }

    void select(int i) {
        if (i == selected_) return;
        selected_ = i;
    }
    void move(int d) {
        const int n = static_cast<int>(items().size());
        selected_ = (selected_ + d + n) % n;
    }
    void go(Screen s) {
        room_watch_enabled_.store(s == Screen::kNetplay, std::memory_order_release);
        if (s == Screen::kNetplay) watch_rooms();
        screen_ = s;
        selected_ = 0;
        selection_y_ = 0;
        fade_ = 0;
    }
    void back() {
        if (editing_ >= 0) stop_editing();
        if (screen_ == Screen::kControlTest) {
            go(Screen::kControls);
            return;
        }
        if (screen_ != Screen::kMain) go(Screen::kMain);
    }

    // Left / right on a setting.
    void change(int d) {
        // Left on the update or DLC: play without it.
        if (const auto slot = folder_slot(selected_); slot && *slot != kGame && d < 0 && !paths_[*slot].empty()) {
            paths_[*slot].clear();
            asked_[*slot] = true;
            save_launcher_ini();
            refresh();
            return;
        }
        if (screen_ == Screen::kControls) {
            if (selected_ == 0) {
                select_control_device(d);
            } else if (control_keyboard_) {
                if (selected_ == 1) {
                    control_keyboard_action_ = (control_keyboard_action_ + d + keymap::kInputCount) % keymap::kInputCount;
                }
            } else if (selected_ == 1) {
                const int current = control_profile_.player_slot < 0 ? 0 : control_profile_.player_slot;
                const int next = (current + d + 8) % 8;
                control_profile_.player_slot = static_cast<int8_t>(next == 0 ? -1 : next);
            } else if (selected_ == 2) {
                control_button_action_ = (control_button_action_ + d + controller_profiles::kButtonCount) % controller_profiles::kButtonCount;
            } else if (selected_ == 4) {
                control_axis_action_ = (control_axis_action_ + d + controller_profiles::kAxisCount) % controller_profiles::kAxisCount;
            } else if (selected_ == 6) {
                const size_t axis = control_axis_action_;
                control_profile_.dead_zones[axis] = std::clamp(control_profile_.dead_zones[axis] + d * 0.025f, 0.0f, 0.9f);
            } else if (selected_ == 7) {
                if (control_axis_action_ >= static_cast<size_t>(controller_profiles::AxisAction::kLeftTrigger)) {
                    controls_status_ = "Trigger axes do not use stick inversion. Adjust the trigger threshold instead.";
                } else {
                    control_profile_.axis_inverted[control_axis_action_] = !control_profile_.axis_inverted[control_axis_action_];
                }
            } else if (selected_ == 8) {
                control_profile_.trigger_threshold = std::clamp(control_profile_.trigger_threshold + d * 0.05f, 0.05f, 0.95f);
            }
            return;
        }
        if (screen_ == Screen::kNetplay && selected_ == kHostSwitch) {
            netplay_host_ = !netplay_host_;
            save_launcher_ini();
            return;
        }
        if (screen_ == Screen::kUpdates && selected_ == 1) {
            update_channel_ = update_channel_ == "stable" ? "beta" : "stable";
            update_status_ = "Not checked";
            update_available_ = false;
            update_release_version_.clear();
            update_release_url_.clear();
            save_launcher_ini();
            return;
        }
        if (screen_ == Screen::kMods && selected_ < static_cast<int>(mods_.size())) { // a mod's switch
            mods_[selected_].on = !mods_[selected_].on;
            save_mods();
            return;
        }
        if (screen_ != Screen::kSettings) return;
        if (selected_ == 0) {
            // These are starting profiles, not hardware benchmarks. They only
            // change the render scale and presentation interpolation settings.
            static constexpr int kPresetCount = 4;
            const int current = graphics_preset_index(settings_);
            const int next = current < 0 ? (d > 0 ? 0 : kPresetCount - 1)
                                         : (current + d + kPresetCount) % kPresetCount;
            switch (next) {
            case 0: // Performance: native 720p render target, no extra presentation frames.
                settings_.resolution = display::Resolution::k720;
                settings_.interpolation = false;
                settings_.frame_rate = 0;
                break;
            case 1: // Balanced: 1080p render target, automatic presentation pacing.
                settings_.resolution = display::Resolution::k1080;
                settings_.interpolation = true;
                settings_.frame_rate = 0;
                break;
            case 2: // Quality: 1440p render target, automatic presentation pacing.
                settings_.resolution = display::Resolution::k1440;
                settings_.interpolation = true;
                settings_.frame_rate = 0;
                break;
            default: // Automatic retains the renderer's display-based scale selection.
                settings_.resolution = display::Resolution::kAuto;
                settings_.interpolation = true;
                settings_.frame_rate = 0;
                break;
            }
        } else if (selected_ == 1) {
            static constexpr display::Resolution order[] = {display::Resolution::kAuto, display::Resolution::k1080,
                                                            display::Resolution::k1440, display::Resolution::k2160,
                                                            display::Resolution::k2880, display::Resolution::k720};
            int i = 0;
            while (i < 6 && order[i] != settings_.resolution) ++i;
            if (i == 6) i = 0;
            settings_.resolution = order[(i + d + 6) % 6];
        } else if (selected_ == 2) {
            settings_.fullscreen = !settings_.fullscreen;
        } else if (selected_ == 3) {
            // This controls extra presentation frames, not the game's simulation tick.
            static constexpr uint32_t kRates[] = {0, 60, 120, 180, 240, display::kUncapped};
            int current = 0;
            if (!settings_.interpolation) current = 1;
            else if (settings_.frame_rate == 120) current = 2;
            else if (settings_.frame_rate == 180) current = 3;
            else if (settings_.frame_rate == 240) current = 4;
            else if (settings_.frame_rate == display::kUncapped) current = 5;
            const int next = (current + d + 6) % 6;
            settings_.interpolation = next != 1;
            settings_.frame_rate = next == 1 ? 0 : kRates[next];
        } else {
            return;
        }
        save_display();
    }

    void activate() {
        switch (screen_) {
        case Screen::kMain:
            if (selected_ == kPlay) play();
            if (selected_ == kBuildItem) build_runtime();
            if (const auto slot = folder_slot(selected_)) choose_folder(*slot);
            if (selected_ == kOnlineItem) go(Screen::kOnline);
            if (selected_ == kNetplayItem) go(Screen::kNetplay);
            if (selected_ == kControlsItem) { load_control_profile(); go(Screen::kControls); }
            if (selected_ == kSettingsItem) go(Screen::kSettings);
            if (selected_ == kModsItem) go(Screen::kMods);
            if (selected_ == kLibraryItem) go(Screen::kLibrary);
            if (selected_ == kUpdatesItem) go(Screen::kUpdates);
            if (selected_ == kDiagnosticsItem) go(Screen::kDiagnostics);
            if (selected_ == kQuitItem) quit_ = true;
            break;
        case Screen::kLibrary:
            if (selected_ == 0) choose_folder(kGame);
            else if (selected_ == 1) choose_folder(kUpdate);
            else if (selected_ == 2) choose_folder(kDlc);
            else if (selected_ == 3) choose_wua_archive();
            else if (selected_ >= 4 && selected_ <= 6) {
                const Slot slot = static_cast<Slot>(selected_ - 4);
                if (paths_[slot].empty()) wua_status_ = "Choose this folder first.";
                else SDL_OpenURL((std::string("file:///") + paths_[slot].generic_string()).c_str());
            } else back();
            break;
        case Screen::kUpdates:
            if (selected_ == 1) change(1);
            else if (selected_ == 3) check_launcher_updates();
            else if (selected_ == 4) install_launcher_update();
            else if (selected_ == 5) {
                if (!update_release_url_.empty() && update_release_url_.starts_with("https://")) SDL_OpenURL(update_release_url_.c_str());
            } else if (selected_ == 7) choose_folder(kUpdate);
            else if (selected_ == 8) {
                paths_[kUpdate].clear();
                asked_[kUpdate] = true;
                save_launcher_ini();
                refresh();
            } else if (selected_ == 9) back();
            break;
        case Screen::kDiagnostics:
            if (selected_ == 10) {
                const char* platform = SDL_GetPlatform();
                const char* renderer = SDL_GetRendererName(r_);
                std::ostringstream report;
                report << "U Unlocked diagnostics\n"
                       << "Platform: " << (platform ? platform : "Unknown") << "\n"
                       << "Logical CPU cores: " << SDL_GetNumLogicalCPUCores() << "\n"
                       << "System memory: " << SDL_GetSystemRAM() << " MB\n"
                       << "CPU optimisation: " << (cafe::host::cpu_has_x86_64_v3() ? "x86-64-v3" : "compatibility") << "\n"
                       << "Launcher renderer: " << (renderer ? renderer : "Unknown") << "\n"
                       << "Base game: " << (valid_[kGame] ? "verified" : "missing/invalid") << "\n"
                       << "Update: " << (valid_[kUpdate] ? std::to_string(update_version_) : "not installed") << "\n"
                       << "Active mods: " << std::count_if(mods_.begin(), mods_.end(), [](const Mod& m) { return m.on; }) << "\n"
                       << "Shader cache files: " << shaders_ << "\n"
                       << "Game log: smash.log (stored beside the launcher)";
                if (SDL_SetClipboardText(report.str().c_str())) diagnostics_status_ = "Copied to clipboard";
                else diagnostics_status_ = std::string("Copy failed: ") + SDL_GetError();
            } else back();
            break;
        case Screen::kSettings:
            if (selected_ == kSettingsBack) back();
            else change(1);
            break;
        case Screen::kControls:
            if (control_keyboard_) {
                switch (selected_) {
                case 2:
                    capture_axis_ = false;
                    capture_keyboard_ = true;
                    capture_binding_ = true;
                    capture_started_ = time_;
                    controls_status_ = "Press the new keyboard key for Player 1 within 10 seconds. Escape cancels.";
                    break;
                case 3: save_keyboard_profile(); break;
                case 4:
                    keyboard_keys_ = keymap::default_keys();
                    controls_status_ = "Default Player 1 keyboard bindings restored. Save to keep them.";
                    break;
                case 5: back(); break;
                default: change(1); break;
                }
            } else {
                switch (selected_) {
                case 3:
                    if (selected_control_gamepad()) {
                        capture_keyboard_ = false;
                        capture_axis_ = false;
                        capture_binding_ = true;
                        capture_started_ = time_;
                        controls_status_ = "Press the physical button on the selected controller within 10 seconds. Escape cancels.";
                    } else controls_status_ = "Connect a controller before binding inputs.";
                    break;
                case 5:
                    if (selected_control_gamepad()) {
                        capture_keyboard_ = false;
                        capture_axis_ = true;
                        capture_binding_ = true;
                        capture_started_ = time_;
                        controls_status_ = "Move the desired stick or trigger axis within 10 seconds. Escape cancels.";
                    } else controls_status_ = "Connect a controller before binding inputs.";
                    break;
                case 9: choose_cemu_profile(); break;
                case 10:
                    go(Screen::kControlTest);
                    controls_status_ = "Move the sticks and press buttons to verify the selected mapping.";
                    break;
                case 11: {
                    std::string error;
                    if (SDL_Gamepad* pad = selected_control_gamepad()) {
                        if (controller_profiles::save_for_device(pad, control_profile_, &error)) controls_status_ = "Controller profile saved.";
                        else controls_status_ = "Could not save profile: " + error;
                    } else controls_status_ = "Connect a controller before saving its profile.";
                    break;
                }
                case 12:
                    control_profile_ = controller_profiles::default_profile();
                    if (SDL_Gamepad* pad = selected_control_gamepad()) control_profile_.device_guid = controller_profiles::device_info(pad).guid;
                    controls_status_ = "Default bindings restored. Save to keep them.";
                    break;
                case 13: back(); break;
                default: change(1); break;
                }
            }
            break;
        case Screen::kControlTest:
            if (selected_ + 1 == static_cast<int>(items().size())) back();
            break;
        case Screen::kNetplay:
            switch (selected_) {
            case kHostSwitch: change(1); break;
            case kNameField:
            case kAddressField: start_editing(selected_); break;
            default:
                if (selected_ + 1 == static_cast<int>(items().size())) back();
                else join(selected_ - kFirstRoom);
                break;
            }
            break;
        case Screen::kOnline:
            switch (selected_) {
            case kConsoleFiles: choose_console_files(); break;
            case kUserField:
            case kPasswordField: start_editing(selected_); break;
            case kSignIn: sign_in(); break;
            case kSignOut: sign_out(); break;
            default: back(); break;
            }
            break;
        case Screen::kMods: {
            const int n = static_cast<int>(mods_.size());
            if (selected_ < n) {
                change(1);
            } else if (selected_ == n) {
                choose_mod_folder();
            } else if (selected_ == n + 1) {
                std::error_code ec;
                fs::create_directories(dir_ / "mods", ec);
                SDL_OpenURL(("file:///" + (dir_ / "mods").generic_string()).c_str());
            } else {
                back();
            }
            break;
        }
        }
    }

    // mods.ini: the mods switched off, one `off = name` line each (new mods start on).
    void load_mods() {
        mods_ = find_mods(dir_ / "mods");
        std::istringstream in(read_text(dir_ / "mods.ini").value_or(""));
        for (std::string line; std::getline(in, line);) {
            if (line.rfind("off = ", 0) != 0) continue;
            std::string name = line.substr(6);
            name.erase(name.find_last_not_of(" \r") + 1);
            for (Mod& m : mods_) m.on = m.on && m.name != name;
        }
    }
    void save_mods() {
        std::ofstream out(dir_ / "mods.ini", std::ios::binary);
        out << "# U Unlocked's mods (folders in mods\\ holding content\\): the ones switched off.\n";
        for (const Mod& m : mods_) {
            if (!m.on) out << "off = " << m.name << "\n";
        }
    }

    bool ready() const { return valid_[kGame]; } // the update and DLC are optional

    // ------------------------------------------------------------ the mod installer
    void choose_mod_folder() {
        if (installing_) return;
        static const auto callback = [](void* self, const char* const* files, int) {
            auto* l = static_cast<Launcher*>(self);
            std::lock_guard lock(l->dialog_mutex_);
            if (files && files[0]) l->dialog_result_ = files[0];
            l->dialog_done_ = true;
        };
        mod_dialog_ = true;
        SDL_SetWindowTitle(window_, "Choose an extracted mod folder");
        SDL_ShowOpenFolderDialog(callback, this, window_, nullptr, false);
    }

    // Copies and validates the selected folder off the launcher's thread.
    void start_install(const std::string& source) {
        if (installing_) return;
        installing_ = true;
        mod_ok_ = true;
        mod_status_ = "Installing " + fs::u8path(source).filename().string() + "...";
        try {
            install_thread_ = std::thread([this, source, mods = dir_ / "mods"] {
                Installed result;
                try {
                    result = install_mod(fs::u8path(source), mods);
                } catch (const std::exception& error) {
                    result = {false, std::string("Mod installation failed: ") + error.what()};
                } catch (...) {
                    result = {false, "Mod installation failed because of an unknown error."};
                }
                std::lock_guard lock(install_mutex_);
                install_result_ = std::move(result);
                install_done_ = true;
            });
        } catch (const std::exception& error) {
            installing_ = false;
            mod_ok_ = false;
            mod_status_ = std::string("Could not start mod installation: ") + error.what();
        }
    }

    void finish_install() {
        {
            std::lock_guard lock(install_mutex_);
            if (!install_done_) return;
        }
        if (install_thread_.joinable()) install_thread_.join();
        Installed r;
        {
            std::lock_guard lock(install_mutex_);
            install_done_ = false;
            r = std::move(install_result_);
        }
        installing_ = false;
        mod_ok_ = r.ok;
        if (!r.ok) {
            mod_status_ = r.message;
            return;
        }
        load_mods();
        // The new mod, switched on and selected; mods.ini lists only the ones off, so it starts on.
        for (size_t i = 0; i < mods_.size(); ++i) {
            if (mods_[i].root.lexically_relative(dir_ / "mods").begin()->string() == r.message) selected_ = static_cast<int>(i);
        }
        mod_status_ = "Installed " + r.message + (valid_[kUpdate] ? ". It's on." : ". Mods need the update to load.");
    }

    // The next folder Play asks for: the game, then the update and the DLC once each (both may be skipped).
    std::optional<Slot> missing() const {
        if (!valid_[kGame]) return kGame;
        if (!valid_[kUpdate] && !asked_[kUpdate]) return kUpdate;
        if (!valid_[kDlc] && !asked_[kDlc]) return kDlc;
        return std::nullopt;
    }

    // The local game runtime is isolated from the launcher so its MinGW DLLs
    // cannot replace the launcher's own SDL runtime. Keep game data beside it.
    fs::path data_dir() const {
        const fs::path runtime_dir = dir_ / "runtime";
        std::error_code ec;
        for (const char* name : {"smash.exe", "smash-compat.exe", "smash-base.exe", "smash-base-compat.exe"}) {
            ec.clear();
            if (fs::is_regular_file(runtime_dir / name, ec) && !ec) return runtime_dir;
        }
        return dir_;
    }

    void reload_runtime_data_paths() {
        const fs::path data = data_dir();
        display::set_file(data / "display.ini", "U Unlocked");
        settings_ = display::load(display::file_path()).settings;
        online::load(data / "online");
        font_.open({data / "fonts" / "launcher.ttf", "C:/Windows/Fonts/bahnschrift.ttf",
                    "C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf"});
    }

    // The game's program: smash.exe is the update's (v304), smash-base.exe the game's own (v1.0);
    // smash-compat.exe is the update's for processors without AVX2/FMA.
    fs::path game_exe() const {
        const fs::path runtime_dir = data_dir();
        if (!valid_[kUpdate]) {
            return runtime_dir / (cafe::host::cpu_has_x86_64_v3() ? "smash-base.exe" : "smash-base-compat.exe");
        }
        return runtime_dir / (cafe::host::cpu_has_x86_64_v3() ? "smash.exe" : "smash-compat.exe");
    }

    void build_runtime() {
        if (process_ || build_process_) return;
        if (!valid_[kGame]) {
            build_status_ = "Select a valid base-game folder first.";
            choose_folder(kGame);
            return;
        }
        if (!valid_[kUpdate]) {
            build_status_ = "Select the game update folder to build the updated runtime.";
            choose_folder(kUpdate);
            return;
        }

        fs::path script = dir_ / "build-kit" / "tools" / "windows" / "build-from-library.ps1";
        if (!fs::is_regular_file(script)) {
            script = dir_.parent_path() / "tools" / "windows" / "build-from-library.ps1";
        }
        std::error_code ec;
        if (!fs::is_regular_file(script, ec) || ec) {
            build_status_ = "Build kit missing. Reinstall the complete release package.";
            launch_error_ = "The local build kit is missing beside the launcher. Download the complete U Unlocked release package again.";
            return;
        }

        const std::vector<std::string> words = {
            "powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", script.string(),
            "-GameDirectory", paths_[kGame].string(),
            "-UpdateDirectory", paths_[kUpdate].string(),
            "-LauncherDirectory", dir_.string()
        };
        std::vector<const char*> args;
        args.reserve(words.size() + 1);
        for (const std::string& word : words) args.push_back(word.c_str());
        args.push_back(nullptr);

        build_status_ = "Preparing local Vulkan runtime...";
        launch_error_.clear();
        build_process_ = SDL_CreateProcess(args.data(), false);
        if (build_process_) {
            building_runtime_ = true;
        } else {
            build_status_ = std::string("Build could not start: ") + SDL_GetError();
            launch_error_ = build_status_;
        }
    }

    void play() {
        if (process_ || building_runtime_) return;
        if (!valid_[kGame] || (!asked_[kUpdate] && !valid_[kUpdate]) || (!asked_[kDlc] && !valid_[kDlc])) {
            // Ask for what is missing, one folder after another (once per run for the optional ones).
            prompting_ = true;
            if (const auto slot = missing()) {
                choose_folder(*slot);
                return;
            }
            prompting_ = false;
        }
        if (!ready()) return;
        std::error_code ec;
        if (ec || !fs::is_regular_file(game_exe(), ec) || ec) {
            build_runtime();
            return;
        }
        launch_error_.clear();
        // smash.exe [--host PORT] [--mod FOLDER]... UPDATE GAME; smash-base.exe GAME (mods are made for the update).
        std::vector<std::string> words{game_exe().string()};
        if (netplay_host_) words.insert(words.end(), {"--host", netplay_name_.empty() ? "Player" : netplay_name_});
        if (valid_[kUpdate]) {
            for (const Mod& m : mods_) {
                if (m.on) words.insert(words.end(), {"--mod", m.root.string()});
            }
            // The DLC's items unlock what the update carries, so only with it.
            if (valid_[kDlc]) words.insert(words.end(), {"--dlc", paths_[kDlc].string()});
            words.push_back(paths_[kUpdate].string());
        }
        words.push_back(paths_[kGame].string());
        std::vector<const char*> args;
        for (const std::string& w : words) args.push_back(w.c_str());
        args.push_back(nullptr);
        // The game's messages, for when it closes with an error.
        SDL_SetEnvironmentVariable(SDL_GetEnvironment(), "SMASH_LOG", (dir_ / "smash.log").string().c_str(), true);
        process_ = SDL_CreateProcess(args.data(), false);
        if (process_) {
            exit_code_ = 0;
            SDL_MinimizeWindow(window_);
        } else {
            launch_error_ = SDL_GetError();
        }
    }

    // The room list, asked for every three seconds while the Netplay page shows.
    void watch_rooms() {
        if (rooms_thread_.joinable()) return;
        try {
            rooms_thread_ = std::thread([this] {
                while (!shutting_down_.load(std::memory_order_acquire)) {
                    if (room_watch_enabled_.load(std::memory_order_acquire)) {
                        std::vector<cafe::host::netplay::Room> rooms;
                        bool reached = false;
                        try {
                            reached = cafe::host::netplay::list_rooms(rooms);
                        } catch (...) {
                            reached = false;
                        }
                        std::lock_guard lock(rooms_mutex_);
                        rooms_reached_ = reached;
                        if (reached) rooms_ = std::move(rooms);
                    }
                    for (int i = 0; i < 30 && !shutting_down_.load(std::memory_order_acquire); ++i) {
                        std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    }
                }
            });
        } catch (const std::exception&) {
            std::lock_guard lock(rooms_mutex_);
            rooms_reached_ = false;
        }
    }

    void launch_guest(const std::string& target) {
        if (process_ || building_runtime_) return;
        if (target.empty()) {
            launch_error_ = "Enter a host IP address or select an open room.";
            return;
        }
        if (!valid_[kGame]) {
            choose_folder(kGame);
            return;
        }
        if (!valid_[kUpdate]) {
            choose_folder(kUpdate);
            return;
        }
        std::error_code runtime_ec;
        const fs::path executable = game_exe();
        if (!fs::is_regular_file(executable, runtime_ec) || runtime_ec) {
            build_runtime();
            return;
        }
        save_launcher_ini();
        const std::string exe = executable.string();
        const std::string name = netplay_name_.empty() ? "Player" : netplay_name_;
        const char* args[] = {exe.c_str(), "--join", target.c_str(), name.c_str(), nullptr};
        SDL_SetEnvironmentVariable(SDL_GetEnvironment(), "SMASH_LOG", (dir_ / "smash.log").string().c_str(), true);
        process_ = SDL_CreateProcess(args, false);
        if (process_) {
            exit_code_ = 0;
            launch_error_.clear();
            SDL_MinimizeWindow(window_);
        } else {
            launch_error_ = SDL_GetError();
        }
    }

    void join_address() {
        std::string target = netplay_address_;
        const size_t first = target.find_first_not_of(" \t");
        if (first == std::string::npos) {
            launch_error_ = "Enter a host IP address, hostname, or VPN address.";
            return;
        }
        const size_t last = target.find_last_not_of(" \t");
        target = target.substr(first, last - first + 1);
        launch_guest(target);
    }

    // Joins a room from the optional U Unlocked room directory.
    void join(int index) {
        std::string target;
        {
            std::lock_guard lock(rooms_mutex_);
            if (index < 0 || index >= static_cast<int>(rooms_.size())) return;
            const auto& room = rooms_[index];
            if (room.players >= room.max) {
                launch_error_ = room.name + "'s room is full";
                return;
            }
            char id[16];
            std::snprintf(id, sizeof id, "room:%06x", room.id);
            target = id;
        }
        launch_guest(target);
    }

    void choose_wua_archive() {
#ifdef _WIN32
        if (wua_importing_) {
            wua_status_ = "A WUA import is already running.";
            return;
        }
        static constexpr SDL_DialogFileFilter filters[] = {
            {"Wii U archive", "wua"}
        };
        {
            std::lock_guard lock(dialog_mutex_);
            dialog_result_.clear();
            dialog_done_ = false;
        }
        wua_dialog_ = true;
        SDL_SetWindowTitle(window_, "Select a Wii U WUA archive");
        SDL_ShowOpenFileDialog([](void* self, const char* const* files, int) {
            auto* launcher = static_cast<Launcher*>(self);
            std::lock_guard lock(launcher->dialog_mutex_);
            if (files && files[0]) launcher->dialog_result_ = files[0];
            launcher->dialog_done_ = true;
        }, this, window_, filters, 1, nullptr, false);
#else
        wua_status_ = "WUA import is currently supported on Windows only.";
#endif
    }

    // Extract into a private staging directory. The original WUA is read-only
    // and is never moved, overwritten, or deleted.
    void start_wua_import(const fs::path& archive) {
#ifdef _WIN32
        if (wua_importing_) return;
        const fs::path extractor = dir_ / "wua_extract.exe";
        std::error_code ec;
        if (!fs::is_regular_file(extractor, ec) || ec) {
            wua_status_ = "WUA extractor is missing. Reinstall the launcher package.";
            return;
        }
        if (!fs::is_regular_file(archive, ec) || ec || is_reparse_point(archive)) {
            wua_status_ = "Select a normal, accessible WUA file (not a link or reparse point).";
            return;
        }
        const uint64_t archive_size = fs::file_size(archive, ec);
        if (ec || archive_size == 0) {
            wua_status_ = "The selected WUA archive is empty or cannot be read.";
            return;
        }
        if (archive_size > 64ULL * 1024 * 1024 * 1024) {
            wua_status_ = "The selected WUA archive exceeds the 64 GiB safety limit.";
            return;
        }
        const fs::path imports = dir_ / "imports";
        fs::create_directories(imports, ec);
        if (ec) {
            wua_status_ = "Cannot create the private import staging directory: " + ec.message();
            return;
        }
        static std::atomic<uint64_t> sequence{0};
        const std::string token = std::to_string(SDL_GetTicksNS()) + "-" +
                                  std::to_string(sequence.fetch_add(1, std::memory_order_relaxed));
        const fs::path stage = imports / (".wua-stage-" + token);
        fs::create_directory(stage, ec);
        if (ec) {
            wua_status_ = "Cannot create the WUA staging directory: " + ec.message();
            return;
        }
        const fs::path extracted = stage / "extracted";
        const std::string executable_arg = path_utf8(extractor);
        const std::string archive_arg = path_utf8(archive);
        const std::string output_arg = path_utf8(extracted);
        wua_stage_path_ = stage;
        wua_importing_ = true;
        wua_status_ = "Extracting archive and validating Smash title folders...";
        try {
            wua_thread_ = std::thread([this, stage, extracted, executable_arg, archive_arg, output_arg] {
                WuaImportResult result;
                result.stage = stage;
                result.extracted = extracted;
                try {
                    const char* arguments[] = {
                        executable_arg.c_str(), "extract-all", archive_arg.c_str(), output_arg.c_str(), nullptr
                    };
                    SDL_Process* process = SDL_CreateProcess(arguments, false);
                    if (!process) {
                        throw std::runtime_error(std::string("Could not start the WUA extractor: ") + SDL_GetError());
                    }
                    int exit_code = -1;
                    const bool waited = SDL_WaitProcess(process, true, &exit_code);
                    SDL_DestroyProcess(process);
                    if (!waited) throw std::runtime_error(std::string("Could not wait for the WUA extractor: ") + SDL_GetError());
                    if (exit_code != 0) {
                        throw std::runtime_error("WUA extraction failed (exit code " + std::to_string(exit_code) +
                                                 "). The archive may be damaged or unsupported.");
                    }
                    find_titles(extracted, result.slots);
                    if (result.slots[kGame].empty()) {
                        throw std::runtime_error("The archive did not contain a valid Super Smash Bros. for Wii U base-game folder.");
                    }
                    result.ok = true;
                    result.message = "Archive extracted; game folder verified";
                    if (!result.slots[kUpdate].empty()) result.message += ", update found";
                    if (!result.slots[kDlc].empty()) result.message += ", DLC found";
                } catch (const std::exception& error) {
                    result.message = error.what();
                    std::error_code cleanup_error;
                    fs::remove_all(stage, cleanup_error);
                } catch (...) {
                    result.message = "WUA import failed because of an unknown error.";
                    std::error_code cleanup_error;
                    fs::remove_all(stage, cleanup_error);
                }
                std::lock_guard lock(wua_mutex_);
                wua_result_ = std::move(result);
                wua_done_ = true;
            });
        } catch (const std::exception& error) {
            wua_importing_ = false;
            wua_stage_path_.clear();
            fs::remove_all(stage, ec);
            wua_status_ = std::string("Could not start WUA import: ") + error.what();
        }
#else
        (void)archive;
        wua_status_ = "WUA import is currently supported on Windows only.";
#endif
    }

    void finish_wua_import() {
        {
            std::lock_guard lock(wua_mutex_);
            if (!wua_done_) return;
        }
        if (wua_thread_.joinable()) wua_thread_.join();
        WuaImportResult result;
        {
            std::lock_guard lock(wua_mutex_);
            wua_done_ = false;
            result = std::move(wua_result_);
        }
        wua_importing_ = false;
        if (!result.ok) {
            wua_status_ = result.message.empty() ? "WUA import failed." : result.message;
            wua_stage_path_.clear();
            return;
        }

        std::error_code ec;
        const fs::path library = dir_ / "library";
        const bool library_exists = fs::exists(library, ec);
        if (ec || (library_exists && (is_reparse_point(library) || !fs::is_directory(library, ec)))) {
            const std::string reason = ec ? ec.message() : "the library path is not a normal directory";
            std::error_code cleanup_error;
            fs::remove_all(result.stage, cleanup_error);
            wua_stage_path_.clear();
            wua_status_ = "Cannot use the game library directory: " + reason;
            return;
        }
        if (!library_exists) fs::create_directory(library, ec);
        if (ec) {
            const std::string reason = ec.message();
            std::error_code cleanup_error;
            fs::remove_all(result.stage, cleanup_error);
            wua_stage_path_.clear();
            wua_status_ = "Cannot create the game library directory: " + reason;
            return;
        }
        const std::string stage_name = result.stage.filename().string();
        constexpr std::string_view kStagePrefix = ".wua-stage-";
        if (!stage_name.starts_with(kStagePrefix)) {
            std::error_code cleanup_error;
            fs::remove_all(result.stage, cleanup_error);
            wua_stage_path_.clear();
            wua_status_ = "The WUA staging directory has an invalid name.";
            return;
        }
        const fs::path destination = library / ("wua-" + stage_name.substr(kStagePrefix.size()));
        const bool destination_exists = fs::exists(destination, ec);
        if (ec || destination_exists) {
            const std::string reason = ec ? ec.message() : "destination already exists";
            std::error_code cleanup_error;
            fs::remove_all(result.stage, cleanup_error);
            wua_stage_path_.clear();
            wua_status_ = "Cannot activate this import: " + reason;
            return;
        }
        fs::rename(result.stage, destination, ec);
        if (ec) {
            const std::string reason = ec.message();
            std::error_code cleanup_error;
            fs::remove_all(result.stage, cleanup_error);
            wua_stage_path_.clear();
            wua_status_ = "Could not activate the extracted game library: " + reason;
            return;
        }

        const fs::path final_extracted = destination / "extracted";
        for (int slot = 0; slot < kSlots; ++slot) {
            if (result.slots[slot].empty()) continue;
            const fs::path relative = result.slots[slot].lexically_relative(result.extracted);
            if (relative.is_absolute()) continue;
            if (relative.empty() || relative == ".") {
                paths_[slot] = final_extracted;
                continue;
            }
            bool unsafe = false;
            for (const auto& component : relative) {
                if (component == "." || component == "..") unsafe = true;
            }
            if (!unsafe) paths_[slot] = final_extracted / relative;
        }
        wua_stage_path_.clear();
        save_launcher_ini();
        refresh();
        wua_status_ = "Imported successfully. Original WUA preserved.";
    }

    void choose_folder(Slot slot) {
        // (The callback can come on another thread.)
        static const auto callback = [](void* self, const char* const* files, int) {
            auto* l = static_cast<Launcher*>(self);
            std::lock_guard lock(l->dialog_mutex_);
            if (files && files[0]) l->dialog_result_ = files[0];
            l->dialog_done_ = true; // chosen, cancelled or failed
        };
        asked_[slot] = true;
        dialog_slot_ = slot;
        // The dialog's title says which folder it wants.
        static const char* titles[kSlots] = {"Choose the game folder (0005000010144F00)",
                                             "Choose the update folder (0005000E10144F00)",
                                             "Choose the DLC folder (0005000C10144F00) - optional"};
        SDL_SetWindowTitle(window_, titles[slot]);
        fs::path start = paths_[slot];
        for (int s = 0; s < kSlots && start.empty(); ++s) start = paths_[s].parent_path();
        const std::string s = start.string();
        SDL_ShowOpenFolderDialog(callback, this, window_, s.empty() ? nullptr : s.c_str(), false);
    }

    void refresh() {
        for (int s = 0; s < kSlots; ++s) valid_[s] = !paths_[s].empty() && is_title(paths_[s], Slot(s));
        update_version_ = valid_[kUpdate] ? title_of(paths_[kUpdate])->version : 0;
        dlc_items_ = valid_[kDlc] ? dlc_items(paths_[kDlc]) : 0;
        load_mods();
        std::error_code ec;
        shaders_ = 0;
        for (const auto& entry : fs::directory_iterator(data_dir() / "cache" / "spirv", ec)) shaders_ += entry.is_regular_file(ec);
    }
    void save_display() {
        std::ofstream(display::file_path(), std::ios::binary) << display::format(settings_);
    }
    void save_launcher_ini() {
        std::ofstream out(dir_ / "launcher.ini", std::ios::binary);
        out << "# U Unlocked's launcher: the game (0005000010144F00), its update (0005000E10144F00) and DLC\n"
               "# (0005000C10144F00) folders, as chosen in the menu. Only the game is needed.\n";
        for (int s = 0; s < kSlots; ++s) out << kSlotKeys[s] << " = " << paths_[s].string() << "\n";
        out << "netplay_host = " << (netplay_host_ ? "yes" : "no") << "\nnetplay_name = " << netplay_name_
            << "\nnetplay_address = " << netplay_address_ << "\nupdate_channel = " << update_channel_ << "\n";
    }

    void check_launcher_updates() {
        if (update_checking_) return;
        if (update_check_thread_.joinable()) update_check_thread_.join();
        update_checking_ = true;
        update_status_ = "Checking GitHub releases...";
        update_available_ = false;
        update_release_version_.clear();
        update_release_url_.clear();
        try {
            const std::string channel = update_channel_;
            update_check_thread_ = std::thread([this, channel] {
                AppUpdateCheck result;
                result.channel = channel;
                try {
                    const std::string endpoint = channel == "beta"
                        ? "https://api.github.com/repos/joshuaargent/CPP_U-Unlocked/releases?per_page=1"
                        : "https://api.github.com/repos/joshuaargent/CPP_U-Unlocked/releases/latest";
                    const auto response = cafe::host::http_request(
                        "GET", endpoint,
                        {"Accept: application/vnd.github+json", "User-Agent: U-Unlocked-Updater",
                         "X-GitHub-Api-Version: 2022-11-28"},
                        {}, 5000);
                    if (response.status != 200) {
                        result.message = response.error.empty()
                            ? "GitHub returned HTTP " + std::to_string(response.status)
                            : response.error;
                    } else {
                        result.version = json_string_field(response.body, "tag_name");
                        result.release_url = json_string_field(response.body, "html_url");
                        if (result.version.empty() || result.release_url.empty() ||
                            !result.release_url.starts_with("https://github.com/")) {
                            result.message = "GitHub returned an invalid release record.";
                        } else {
                            result.ok = true;
                            result.available = is_newer_release(result.version, kVersion);
                            result.message = result.available
                                ? "Version " + result.version + " is available"
                                : "You're up to date";
                        }
                    }
                } catch (const std::exception& error) {
                    result.message = std::string("Update check failed: ") + error.what();
                } catch (...) {
                    result.message = "Update check failed because of an unknown error.";
                }
                std::lock_guard lock(update_check_mutex_);
                update_check_result_ = std::move(result);
                update_check_done_ = true;
            });
        } catch (const std::exception& error) {
            update_checking_ = false;
            update_status_ = std::string("Could not start update check: ") + error.what();
        }
    }

    void finish_launcher_update_check() {
        {
            std::lock_guard lock(update_check_mutex_);
            if (!update_check_done_) return;
        }
        if (update_check_thread_.joinable()) update_check_thread_.join();
        AppUpdateCheck result;
        {
            std::lock_guard lock(update_check_mutex_);
            update_check_done_ = false;
            result = std::move(update_check_result_);
        }
        update_checking_ = false;
        if (!result.channel.empty() && result.channel != update_channel_) {
            check_launcher_updates();
            return;
        }
        update_available_ = result.ok && result.available;
        update_status_ = result.message.empty() ? "Update check unavailable" : result.message;
        if (result.ok) {
            update_release_version_ = std::move(result.version);
            update_release_url_ = std::move(result.release_url);
        }
    }

    void install_launcher_update() {
        if (!update_available_) {
            update_status_ = "Check for updates first";
            return;
        }
#ifdef _WIN32
        const fs::path updater = dir_ / "update-launcher.ps1";
        std::error_code ec;
        if (!fs::is_regular_file(updater, ec)) {
            update_status_ = "Updater missing. Reinstall the launcher package.";
            return;
        }
        const std::string updater_path = updater.string();
        const std::string install_path = dir_.string();
        const std::string version = kVersion;
        const std::string channel = update_channel_;
        const std::string process_id = std::to_string(GetCurrentProcessId());
        const char* args[] = {
            "powershell.exe", "-NoProfile", "-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass",
            "-File", updater_path.c_str(), "-InstallDirectory", install_path.c_str(),
            "-CurrentVersion", version.c_str(), "-Channel", channel.c_str(),
            "-ParentProcessId", process_id.c_str(), nullptr
        };
        SDL_Process* process = SDL_CreateProcess(args, false);
        if (!process) {
            update_status_ = std::string("Could not start updater: ") + SDL_GetError();
            return;
        }
        SDL_DestroyProcess(process);
        quit_ = true;
#else
        update_status_ = "Automatic updates are currently supported on Windows only.";
#endif
    }

    // Shortened with "..." in the middle to fit `width`.
    std::string fit(std::string text, float px, float width) {
        if (font_.width(r_, text, px) <= width) return text;
        while (text.size() > 8 && font_.width(r_, text, px) > width) text.erase(text.size() / 2 - 2, 1);
        const size_t mid = text.size() / 2;
        return text.substr(0, mid - 2) + "..." + text.substr(mid + 1);
    }

    int item_at(float x, float y) const {
        if (screen_ == Screen::kMain) {
            for (size_t i = 0; i < main_rects_.size(); ++i) {
                const SDL_FRect& b = main_rects_[i];
                if (b.w > 0 && x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h) {
                    return static_cast<int>(i);
                }
            }
            return -1;
        }
        if (screen_ == Screen::kOnline) {
            for (size_t i = 0; i < online_rects_.size(); ++i) {
                const SDL_FRect& b = online_rects_[i];
                if (x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h) return static_cast<int>(i);
            }
            return -1;
        }
        const float H = layout_.h;
        if (x < layout_.left_chevron - H * 0.03f || x > layout_.right_chevron + H * 0.03f) return -1;
        for (size_t i = 0; i < list_.size(); ++i) {
            const float iy = layout_.item_y(float(i));
            if (y > iy - H * 0.06f && y < iy + H * 0.022f) return static_cast<int>(i);
        }
        return -1;
    }

    void draw_background() {
        const float W = layout_.w, H = layout_.h;
        if (background_.texture) {
            // Covering the window, drifting slowly.
            const float zoom = 1.08f + 0.02f * std::sin(time_ * 0.07f);
            const float scale = std::max(W / background_.width, H / background_.height) * zoom;
            const float bw = background_.width * scale, bh = background_.height * scale;
            const float dx = (W - bw) / 2 + std::sin(time_ * 0.05f) * W * 0.012f, dy = (H - bh) / 2;
            SDL_SetTextureColorModFloat(background_.texture, 0.82f, 0.82f, 0.86f);
            paint_.image(background_, {dx, dy, bw, bh});
        } else {
            paint_.rect(0, 0, W, H, {0.055f, 0.065f, 0.09f}, {0.035f, 0.045f, 0.07f}, {0.012f, 0.018f, 0.028f}, {0.02f, 0.03f, 0.045f});
        }
        // Dark from the left and the bottom, where the menu is.
        const Color black{0, 0, 0, 0.88f}, clear{0, 0, 0, 0};
        paint_.rect(0, 0, W * 0.30f, H, black, {0, 0, 0, 0.62f}, {0, 0, 0, 0.62f}, black);
        paint_.rect(W * 0.30f, 0, W * 0.38f, H, {0, 0, 0, 0.62f}, clear, clear, {0, 0, 0, 0.62f});
        paint_.rect(0, H * 0.62f, W, H * 0.38f, clear, clear, {0, 0, 0, 0.70f}, {0, 0, 0, 0.70f});
        paint_.rect(0, 0, W, H * 0.18f, {0, 0, 0, 0.35f}, {0, 0, 0, 0.35f}, clear, clear);
    }

    void draw_home() {
        const float W = layout_.w, H = layout_.h;
        const float a = fade_;
        const Color panel{0.025f, 0.035f, 0.055f, 0.94f};
        const Color panel_alt{0.055f, 0.075f, 0.105f, 0.96f};
        const Color border{0.22f, 0.29f, 0.38f, 0.72f};
        const Color accent{0.10f, 0.72f, 0.96f, 1.0f};
        const Color muted{0.62f, 0.69f, 0.78f, 1.0f};
        const Color white{0.96f, 0.98f, 1.0f, 1.0f};
        const auto mix_alpha = [&](Color c, float opacity) {
            c.a *= a * opacity;
            return c;
        };
        main_rects_.fill(SDL_FRect{});

        // The home screen uses a static composition: no per-frame texture creation,
        // no expensive blur, and only a restrained highlight animation on the active tile.
        draw_background();

        const float margin = W * 0.052f;
        const float header_y = H * 0.055f;
        float brand_width = H * 0.26f;
        if (logo_.texture) {
            const float logo_h = H * 0.105f;
            const float logo_w = logo_h * logo_.width / logo_.height;
            paint_.image(logo_, {margin, header_y - logo_h * 0.78f, logo_w, logo_h});
            brand_width = logo_w;
        } else {
            font_.draw(r_, margin, header_y, "U UNLOCKED", H * 0.052f, mix_alpha(white, 1.0f));
        }
        font_.draw(r_, margin + brand_width + H * 0.035f, header_y - H * 0.004f,
                   "SUPER SMASH BROS. FOR WII U  /  PC", H * 0.018f, mix_alpha(muted, 0.95f));
        const std::string version = std::string("BUILD ") + kVersion;
        font_.draw(r_, W - margin - font_.width(r_, version, H * 0.018f),
                   header_y - H * 0.004f, version, H * 0.018f, mix_alpha(muted, 0.9f));
        paint_.rect(margin, H * 0.112f, W - margin * 2, H * 0.0018f, mix_alpha(border, 0.8f));

        // Featured launch panel.
        const float hero_x = margin, hero_y = H * 0.145f, hero_w = W * 0.575f, hero_h = H * 0.355f;
        main_rects_[kPlay] = {hero_x, hero_y, hero_w, hero_h};
        const bool play_selected = selected_ == kPlay;
        paint_.round_rect(hero_x, hero_y, hero_w, hero_h, H * 0.018f, mix_alpha(play_selected ? panel_alt : panel, 1.0f));
        paint_.round_rect(hero_x, hero_y, hero_w, H * 0.006f, H * 0.003f, mix_alpha(accent, play_selected ? 1.0f : 0.55f));
        if (play_selected) {
            const float pulse = 0.72f + 0.18f * std::sin(time_ * 3.2f);
            paint_.round_rect(hero_x - H * 0.003f, hero_y - H * 0.003f, hero_w + H * 0.006f,
                              hero_h + H * 0.006f, H * 0.02f, mix_alpha(accent, pulse * 0.14f));
        }
        font_.draw(r_, hero_x + H * 0.035f, hero_y + H * 0.065f,
                   "READY TO PLAY", H * 0.019f, mix_alpha(accent, 1.0f));
        font_.draw(r_, hero_x + H * 0.035f, hero_y + H * 0.145f,
                   "SUPER SMASH BROS. FOR WII U", H * 0.035f, mix_alpha(white, 1.0f));
        const bool game_ready = ready();
        std::error_code runtime_ec;
        const bool runtime_ready = game_ready && fs::is_regular_file(game_exe(), runtime_ec) && !runtime_ec;
        const std::string game_state = process_ ? "GAME RUNNING"
                                      : !game_ready ? "SET UP YOUR GAME FILES"
                                      : runtime_ready ? "RUNTIME READY"
                                                      : "RUNTIME BUILD REQUIRED";
        const Color state_color = process_ ? kGold : runtime_ready ? kGood : game_ready ? kGold : kBad;
        font_.draw(r_, hero_x + H * 0.035f, hero_y + H * 0.195f,
                   game_state, H * 0.019f, mix_alpha(state_color, 1.0f));
        std::string detail = !game_ready
            ? "Select your legally obtained game folder to get started."
            : !runtime_ready
                ? "Game files found. Build the local Vulkan runtime before launching."
                : (valid_[kUpdate] ? "Update v" + std::to_string(update_version_) : "Base game only");
        font_.draw(r_, hero_x + H * 0.035f, hero_y + H * 0.245f,
                   fit(detail, H * 0.019f, hero_w * 0.72f), H * 0.019f, mix_alpha(muted, 1.0f));

        const float button_w = H * 0.205f, button_h = H * 0.064f;
        const float button_x = hero_x + H * 0.035f, button_y = hero_y + hero_h - button_h - H * 0.035f;
        paint_.round_rect(button_x, button_y, button_w, button_h, H * 0.009f,
                          mix_alpha(game_ready ? accent : Color{0.20f, 0.26f, 0.34f, 1.0f}, 1.0f));
        font_.draw(r_, button_x + H * 0.028f, button_y + button_h * 0.66f,
                   process_ ? "RUNNING..." : "LAUNCH GAME", H * 0.020f,
                   mix_alpha(game_ready ? Color{0.015f, 0.035f, 0.055f, 1.0f} : muted, 1.0f));
        font_.draw(r_, button_x + button_w + H * 0.025f, button_y + button_h * 0.66f,
                   "ENTER  /  A TO SELECT", H * 0.015f, mix_alpha(muted, 0.9f));

        // Installation panel: each row remains independently selectable and editable.
        const float setup_x = hero_x + hero_w + W * 0.022f;
        const float setup_y = hero_y, setup_w = W - margin - setup_x, setup_h = hero_h;
        paint_.round_rect(setup_x, setup_y, setup_w, setup_h, H * 0.018f, mix_alpha(panel, 1.0f));
        font_.draw(r_, setup_x + H * 0.025f, setup_y + H * 0.055f,
                   "GAME INSTALLATION", H * 0.020f, mix_alpha(white, 1.0f));
        const float row_x = setup_x + H * 0.018f, row_w = setup_w - H * 0.036f;
        const float row_h = H * 0.071f, row_gap = H * 0.012f;
        const int setup_items[] = {kGameItem, kUpdateItem, kDlcItem};
        const char* setup_labels[] = {"BASE GAME", "GAME UPDATE", "DLC"};
        for (size_t n = 0; n < 3; ++n) {
            const int item = setup_items[n];
            const float y = setup_y + H * 0.085f + n * (row_h + row_gap);
            main_rects_[item] = {row_x, y, row_w, row_h};
            const bool selected = selected_ == item;
            paint_.round_rect(row_x, y, row_w, row_h, H * 0.007f,
                              mix_alpha(selected ? panel_alt : Color{0.035f, 0.048f, 0.068f, 1.0f}, 1.0f));
            if (selected) paint_.round_rect(row_x, y, H * 0.004f, row_h, H * 0.002f, mix_alpha(accent, 1.0f));
            font_.draw(r_, row_x + H * 0.014f, y + row_h * 0.63f,
                       setup_labels[n], H * 0.016f, mix_alpha(selected ? white : muted, 1.0f));
            const std::string value = folder_value(static_cast<Slot>(n));
            const float value_size = H * 0.014f;
            const float value_width = font_.width(r_, value, value_size);
            font_.draw(r_, row_x + row_w - H * 0.014f - value_width,
                       y + row_h * 0.63f, value, value_size,
                       mix_alpha(valid_[n] ? kGood : (n == kDlc ? muted : kGold), 1.0f));
        }
        font_.draw(r_, setup_x + H * 0.025f, setup_y + setup_h - H * 0.025f,
                   "Select a row to locate or change its folder.", H * 0.013f, mix_alpha(muted, 0.85f));

        // Six feature cards. The same hit boxes drive mouse, touchpad and controller selection.
        const int feature_items[] = {kOnlineItem, kNetplayItem, kControlsItem, kSettingsItem, kModsItem,
                                      kLibraryItem, kUpdatesItem, kDiagnosticsItem, kQuitItem};
        const char* feature_titles[] = {"ONLINE", "NETPLAY", "CONTROLS", "GRAPHICS", "MODS",
                                        "BUILD", "GAME UPDATE", "DIAGNOSTICS", "QUIT"};
        const char* feature_descriptions[] = {
            "Pretendo Network services", "Private play with friends", "Configure every controller",
            "Resolution and frame pacing", "Install and manage content", "Configure and verify game files",
            "Manage the installed game update", "System and runtime health", "Close U Unlocked"
        };
        const float grid_y = H * 0.535f, grid_gap_x = W * 0.014f, grid_gap_y = H * 0.012f;
        const float grid_w = (W - margin * 2 - grid_gap_x * 2) / 3.0f;
        const float grid_h = H * 0.105f;
        for (size_t i = 0; i < 9; ++i) {
            const int item = feature_items[i];
            const int column = static_cast<int>(i % 3), row = static_cast<int>(i / 3);
            const float x = margin + column * (grid_w + grid_gap_x);
            const float y = grid_y + row * (grid_h + grid_gap_y);
            main_rects_[item] = {x, y, grid_w, grid_h};
            const bool selected = selected_ == item;
            paint_.round_rect(x, y, grid_w, grid_h, H * 0.012f,
                              mix_alpha(selected ? panel_alt : panel, 1.0f));
            paint_.round_rect(x, y, grid_w, H * 0.003f,
                              H * 0.0015f, mix_alpha(selected ? accent : border, 1.0f));
            if (selected) {
                paint_.round_rect(x - H * 0.002f, y - H * 0.002f, grid_w + H * 0.004f,
                                  grid_h + H * 0.004f, H * 0.014f, mix_alpha(accent, 0.13f));
            }
            font_.draw(r_, x + H * 0.022f, y + H * 0.060f, feature_titles[i],
                       H * 0.021f, mix_alpha(selected ? white : white, 1.0f));
            font_.draw(r_, x + H * 0.022f, y + H * 0.100f,
                       feature_descriptions[i], H * 0.014f, mix_alpha(muted, 0.95f));
            if (item == kModsItem) {
                const std::string count = std::to_string(std::count_if(mods_.begin(), mods_.end(),
                    [](const Mod& mod) { return mod.on; })) + " ACTIVE";
                font_.draw(r_, x + grid_w - H * 0.022f - font_.width(r_, count, H * 0.013f),
                           y + H * 0.060f, count, H * 0.013f, mix_alpha(kGood, 1.0f));
            } else if (item == kOnlineItem) {
                const std::string status = online::account().present ? "SIGNED IN" : "NOT SIGNED IN";
                font_.draw(r_, x + grid_w - H * 0.022f - font_.width(r_, status, H * 0.013f),
                           y + H * 0.060f, status, H * 0.013f,
                           mix_alpha(online::account().present ? kGood : kGold, 1.0f));
            }
        }

        const std::string footer = "ARROWS / D-PAD NAVIGATE     ENTER / A SELECT     ESC / B BACK";
        font_.draw(r_, margin, H * 0.965f, footer, H * 0.013f, mix_alpha(muted, 0.78f));
        font_.draw(r_, W - margin - font_.width(r_, "BUILT FOR COMPETITIVE PLAY", H * 0.012f),
                   H * 0.965f, "BUILT FOR COMPETITIVE PLAY", H * 0.012f, mix_alpha(muted, 0.55f));
    }

    void draw_status() {
        if (screen_ == Screen::kOnline) {
            draw_online_status();
            return;
        }
        if (screen_ == Screen::kControls || screen_ == Screen::kControlTest) {
            const float H = layout_.h, x = layout_.text_x, y = H * 0.86f, px = H * 0.032f;
            const std::string line = screen_ == Screen::kControlTest
                ? "Live input monitor: press each button and move each stick; Back returns to Controls."
                : (controls_status_.empty()
                    ? (control_keyboard_ ? "Player 1 uses the keyboard. Select a button, bind a key, then save."
                                         : "Select a control, bind a physical input, then save the profile.")
                    : controls_status_);
            font_.draw(r_, x, y, fit(line, px * 0.85f, layout_.w * 0.65f), px * 0.85f,
                       capture_binding_ ? kGold : kDim);
            font_.draw(r_, x, y + H * 0.045f,
                       control_keyboard_ ? "Keyboard bindings are stored in the U Unlocked configuration folder."
                                         : "Controller profiles are stored per device in the U Unlocked configuration folder.",
                       px * 0.75f, kDim);
            return;
        }
        if (screen_ != Screen::kMain && screen_ != Screen::kMods && screen_ != Screen::kNetplay) return;
        const float H = layout_.h, x = layout_.text_x, y = H * 0.86f, px = H * 0.033f;
        if (screen_ == Screen::kNetplay) {
            std::string line, detail;
            Color c = kDim;
            if (!launch_error_.empty()) {
                line = "Could not start: " + launch_error_;
                c = kBad;
            } else if (selected_ >= kFirstRoom && selected_ + 1 < static_cast<int>(items().size())) {
                bool none;
                {
                    std::lock_guard lock(rooms_mutex_);
                    none = rooms_.empty();
                }
                line = none ? "Rooms appear here while their host plays with HOST MY GAMES on."
                                      : "Join: you play on the host's game as the next free player (up to 8).";
                detail = "You need no game files to join. Your pads and keyboard play as one of their Pro Controllers.";
            } else if (netplay_host_) {
                line = "Hosting: your running game accepts direct IP and VPN connections.";
                detail = "Use a trusted private VPN for now. Do not expose UDP 52700 publicly until authentication and encryption are implemented.";
                c = kGood;
            } else {
                line = "Host: your game is streamed to up to 7 friends, who play as players 2-8.";
                detail = "The host streams video/audio and receives controller inputs. Use a trusted LAN/VPN only: the current protocol has no app-level authentication or encryption.";
            }
            font_.draw(r_, x, y, fit(line, px * 0.85f, layout_.w * 0.62f), px * 0.85f, c);
            if (!detail.empty()) font_.draw(r_, x, y + H * 0.045f, fit(detail, px * 0.8f, layout_.w * 0.62f), px * 0.8f, kDim);
            return;
        }
        const float icon = px * 0.75f, ix = x - icon * 1.55f;
        if (screen_ == Screen::kMods && !mod_status_.empty()) {
            font_.draw(r_, x, y, fit(mod_status_, px * 0.85f, layout_.w * 0.6f), px * 0.85f, mod_ok_ ? kGood : kBad);
            font_.draw(r_, x, y + H * 0.045f, "Select an extracted mod folder to install it. Archive support is temporarily disabled for security.", px * 0.8f, kDim);
            return;
        }
        if (screen_ == Screen::kMods) {
            const char* note = !valid_[kUpdate] ? "Mods need the update: they are made for v304."
                               : mods_.empty()  ? "Put each mod's folder (with content\\ inside) in:"
                                                : "Mods load over the game; the first in the list wins.";
            font_.draw(r_, x, y, note, px * 0.85f, valid_[kUpdate] ? kDim : kBad);
            font_.draw(r_, x, y + H * 0.045f, fit((dir_ / "mods").string(), px * 0.8f, layout_.w * 0.5f), px * 0.8f, kDim);
            return;
        }
        std::string line, detail;
        Color c = kGood;
        if (process_) {
            paint_.spinner(ix + icon / 2, y - px * 0.33f, icon * 0.5f, H * 0.0035f, time_, kGood);
            line = "U Unlocked is running...";
        } else if (!launch_error_.empty()) {
            c = kBad;
            paint_.cross(ix, y - px * 0.7f, icon * 0.8f, H * 0.0035f, c);
            line = "The game did not start: " + launch_error_;
        } else if (exit_code_ != 0) {
            c = kBad;
            paint_.cross(ix, y - px * 0.7f, icon * 0.8f, H * 0.0035f, c);
            line = "The game closed with an error (" + std::to_string(exit_code_) + "). Details: smash.log";
        } else if (ready()) {
            std::error_code runtime_ec;
            if (fs::is_regular_file(game_exe(), runtime_ec) && !runtime_ec) {
                paint_.check(ix, y - px * 0.78f, icon, H * 0.0035f, c);
                line = "Game runtime ready.";
            } else {
                c = kGold;
                paint_.cross(ix, y - px * 0.7f, icon * 0.8f, H * 0.0035f, c);
                line = "Game files verified; local Vulkan runtime build required.";
            }
        } else {
            c = kBad;
            paint_.cross(ix, y - px * 0.7f, icon * 0.8f, H * 0.0035f, c);
            line = paths_[kGame].empty() ? "Choose the game folder." : "That game folder is not Smash for Wii U.";
        }
        font_.draw(r_, x, y, fit(line, px, layout_.w * 0.55f), px, c);
        if (const auto slot = folder_slot(selected_); slot && !paths_[*slot].empty()) {
            detail = paths_[*slot].string(); // the selected folder in full
        } else if (ready()) {
            detail = std::string("Wii U \x7f USA \x7f ") +
                     (valid_[kUpdate] ? "Update v" + std::to_string(update_version_) : std::string("No update (v1.0)")) +
                     " \x7f " + (!valid_[kDlc]      ? std::string("No DLC")
                         : dlc_items_ > 0 ? "DLC found: " + std::to_string(dlc_items_) + " items"
                                          : std::string("DLC folder has no items"));
        } else {
            detail = "Needs the game, 0005000010144F00 (the update and DLC are optional)";
        }
        detail = fit(detail, px * 0.8f, layout_.w * 0.6f);
        // (0x7f: a bullet, drawn below)
        float dx = x;
        const float dpx = px * 0.8f;
        size_t start = 0;
        for (size_t i = 0; i <= detail.size(); ++i) {
            if (i == detail.size() || detail[i] == '\x7f') {
                dx += font_.draw(r_, dx, y + H * 0.05f, detail.substr(start, i - start), dpx, kDim);
                if (i < detail.size()) {
                    const float r = dpx * 0.09f;
                    paint_.round_rect(dx + dpx * 0.1f - r, y + H * 0.05f - dpx * 0.3f - r, r * 2, r * 2, r, kDim);
                    dx += dpx * 0.2f;
                }
                start = i + 1;
            }
        }
    }

    // ------------------------------------------------------------ the Online page
    std::string online_value() const {
        if (online::account().present) return "Signed in: " + online::account().account_id;
        return online::device().present ? "Not signed in" : "Not set up";
    }

    static size_t utf8_length(const std::string& s) {
        return static_cast<size_t>(std::count_if(s.begin(), s.end(), [](char c) { return (c & 0xC0) != 0x80; }));
    }

    void start_editing(int item) {
        editing_ = item;
        SDL_StartTextInput(window_);
    }
    void stop_editing() {
        if (screen_ == Screen::kNetplay && editing_ >= 0) save_launcher_ini();
        editing_ = -1;
        SDL_StopTextInput(window_);
    }

    // Typing in the ID or password field; true if the event was the field's.
    bool text_event(const SDL_Event& e) {
        const bool netplay = screen_ == Screen::kNetplay;
        std::string& text = netplay
            ? (editing_ == kAddressField ? netplay_address_ : netplay_name_)
            : editing_ == kUserField ? user_ : password_;
        // A PNID and netplay name are short; a direct host address may be an IP, VPN IP, or hostname.
        const size_t limit = netplay && editing_ == kAddressField ? 255
                           : editing_ == kUserField || (netplay && editing_ == kNameField) ? 16 : 64;
        switch (e.type) {
        case SDL_EVENT_TEXT_INPUT:
            for (const char* c = e.text.text; *c && utf8_length(text) < limit; ++c) text += *c;
            return true;
        case SDL_EVENT_KEY_DOWN:
            if (e.key.key == SDLK_BACKSPACE) {
                while (!text.empty() && (text.back() & 0xC0) == 0x80) text.pop_back();
                if (!text.empty()) text.pop_back();
            } else if (e.key.key == SDLK_V && (e.key.mod & SDL_KMOD_CTRL)) {
                if (char* clip = SDL_GetClipboardText()) {
                    for (const char* c = clip; *c && *c != '\n' && *c != '\r' && utf8_length(text) < limit; ++c) text += *c;
                    SDL_free(clip);
                }
            } else if (e.key.key == SDLK_RETURN || e.key.key == SDLK_KP_ENTER || e.key.key == SDLK_TAB) {
                // On from the ID to the password; from the password, sign in.
                const int was = editing_;
                stop_editing();
                if (netplay && was == kAddressField) {
                    join_address();
                } else if (netplay) {
                } else if (was == kUserField) {
                    selected_ = kPasswordField;
                    start_editing(kPasswordField);
                } else if (e.key.key != SDLK_TAB) {
                    selected_ = kSignIn;
                    sign_in();
                }
            } else if (e.key.key == SDLK_ESCAPE) {
                stop_editing();
            }
            return true; // (letters arrive as text; the menu keys stay with the field)
        case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
            if (e.gbutton.button == SDL_GAMEPAD_BUTTON_EAST || e.gbutton.button == SDL_GAMEPAD_BUTTON_SOUTH) {
                stop_editing();
                return true;
            }
            return false;
        case SDL_EVENT_MOUSE_BUTTON_DOWN: stop_editing(); return false;
        default: return false;
        }
    }

    void choose_cemu_profile() {
        if (!selected_control_gamepad()) {
            controls_status_ = "Connect and select a controller before importing a profile.";
            return;
        }
        static constexpr SDL_DialogFileFilter filters[] = {
            {"Cemu controller profile", "xml"}
        };
        {
            std::lock_guard lock(dialog_mutex_);
            dialog_result_.clear();
            dialog_done_ = false;
        }
        cemu_dialog_ = true;
        SDL_SetWindowTitle(window_, "Select a Cemu controller profile XML file");
        std::error_code directory_error;
        cemu_dialog_directory_ = fs::is_directory(cemu_profiles_dir_, directory_error)
            ? cemu_profiles_dir_.string() : std::string{};
        SDL_ShowOpenFileDialog([](void* self, const char* const* files, int) {
            auto* launcher = static_cast<Launcher*>(self);
            std::lock_guard lock(launcher->dialog_mutex_);
            if (files && files[0]) launcher->dialog_result_ = files[0];
            launcher->dialog_done_ = true;
        }, this, window_, filters, 1,
           cemu_dialog_directory_.empty() ? nullptr : cemu_dialog_directory_.c_str(), false);
    }

    void import_cemu_profile_file(const fs::path& path) {
        std::error_code ec;
        const auto size = fs::file_size(path, ec);
        if (ec || size == 0 || size > 1024 * 1024) {
            controls_status_ = "The selected XML file is empty, unavailable, or larger than 1 MiB.";
            return;
        }
        std::ifstream input(path, std::ios::binary);
        if (!input) {
            controls_status_ = "Unable to read the selected Cemu profile.";
            return;
        }
        const std::string xml{std::istreambuf_iterator<char>(input), {}};
        controller_profiles::Profile imported;
        controller_profiles::CemuImportReport report;
        std::string error;
        if (!controller_profiles::import_cemu_profile_xml(xml, control_profile_, imported, report, &error)) {
            controls_status_ = "Cemu import failed: " + error;
            return;
        }
        control_profile_ = std::move(imported);
        controls_status_ = "Imported " + std::to_string(report.imported_button_bindings) +
            " button and " + std::to_string(report.imported_axis_bindings) +
            " axis bindings. Review the settings, then Save Profile.";
        if (!report.warnings.empty()) controls_status_ += " " + report.warnings.front();
    }

    // Dumpling's online files: otp.bin, seeprom.bin and (if the console's account was dumped) its account.dat.
    void choose_console_files() {
        static const auto callback = [](void* self, const char* const* files, int) {
            auto* l = static_cast<Launcher*>(self);
            std::lock_guard lock(l->dialog_mutex_);
            if (files && files[0]) l->dialog_result_ = files[0];
            l->dialog_done_ = true;
        };
        online_dialog_ = true;
        SDL_SetWindowTitle(window_, "Choose the folder with your Wii U's otp.bin and seeprom.bin (Dumpling's Online Files)");
        SDL_ShowOpenFolderDialog(callback, this, window_, nullptr, false);
    }

    void import_console_files(const fs::path& folder) {
        std::error_code ec;
        fs::path otp, seeprom, account;
        // (Searching a few folders down: Dumpling puts account.dat under mlc01\usr\save\system\act\80000001.)
        for (auto it = fs::recursive_directory_iterator(folder, fs::directory_options::skip_permission_denied, ec);
             it != fs::recursive_directory_iterator(); it.increment(ec)) {
            if (ec || it.depth() > 7) {
                if (it.depth() > 7) it.disable_recursion_pending();
                continue;
            }
            const std::string name = it->path().filename().string();
            if (name == "otp.bin" && otp.empty()) otp = it->path();
            if (name == "seeprom.bin" && seeprom.empty()) seeprom = it->path();
            if (name == "account.dat" && account.empty() && it->path().parent_path().filename() == "80000001") account = it->path();
        }
        if (otp.empty() || seeprom.empty() || fs::file_size(otp, ec) != 1024 || fs::file_size(seeprom, ec) != 512) {
            online_status_ = "No otp.bin and seeprom.bin from a Wii U in that folder.";
            online_ok_ = false;
            return;
        }
        const fs::path dir = data_dir() / "online";
        fs::create_directories(dir, ec);
        fs::copy_file(otp, dir / "otp.bin", fs::copy_options::overwrite_existing, ec);
        fs::copy_file(seeprom, dir / "seeprom.bin", fs::copy_options::overwrite_existing, ec);
        if (!account.empty()) fs::copy_file(account, dir / "account.dat", fs::copy_options::overwrite_existing, ec);
        online::load(dir);
        online_ok_ = online::device().present;
        online_status_ = !online_ok_                   ? "Those console files could not be read."
                         : online::account().present ? "Console files and account found: signed in as " + online::account().account_id + "."
                                                       : "Console files found. Now sign in with your Pretendo ID.";
    }

    void sign_in() {
        if (signing_in_) return;
        if (!online::device().present) {
            online_status_ = "Choose your console files first.";
            online_ok_ = false;
            return;
        }
        if (user_.empty() || password_.empty()) {
            online_status_ = "Type your Pretendo ID and password.";
            online_ok_ = false;
            return;
        }
        signing_in_ = true;
        online_status_ = "Signing in to Pretendo...";
        online_ok_ = true;
        const std::string user = user_;
        std::string password = std::move(password_);
        password_.clear();
        try {
            sign_in_thread_ = std::thread([this, user, password = std::move(password)]() mutable {
                act_server::SignIn result;
                try {
                    result = act_server::sign_in(user, password);
                } catch (const std::exception& error) {
                    result.message = std::string("Sign-in failed: ") + error.what();
                } catch (...) {
                    result.message = "Sign-in failed because of an unknown error.";
                }
                secure_erase(password);
                std::lock_guard lock(sign_in_mutex_);
                sign_in_result_ = std::move(result);
                sign_in_done_ = true;
            });
        } catch (const std::exception& error) {
            secure_erase(password);
            std::lock_guard lock(sign_in_mutex_);
            sign_in_result_.message = std::string("Could not start sign-in: ") + error.what();
            sign_in_done_ = true;
        }
    }

    // The sign-in's result, on the launcher's thread: account.dat, or why not.
    void finish_sign_in() {
        {
            std::lock_guard lock(sign_in_mutex_);
            if (!sign_in_done_) return;
        }
        if (sign_in_thread_.joinable()) sign_in_thread_.join();
        act_server::SignIn r;
        {
            std::lock_guard lock(sign_in_mutex_);
            sign_in_done_ = false;
            r = std::move(sign_in_result_);
        }
        signing_in_ = false;
        if (!r.ok) {
            online_ok_ = false;
            online_status_ = "Sign-in failed: " + (r.message.empty() ? "error " + std::to_string(r.error_code) : r.message);
            return;
        }
        online::NewAccount a;
        a.user_id = r.user_id;
        a.pid = r.pid;
        a.password_hash = r.password_hash;
        a.mii = r.mii;
        a.mii_name = r.mii_name;
        a.us = r.country.empty() || r.country == "US";
        online_ok_ = online::save_account(data_dir() / "online", a);
        online_status_ = online_ok_ ? "Signed in as " + r.user_id + ". Smash's online modes use this account."
                                    : "Signed in, but the account could not be saved.";
    }

    void sign_out() {
        std::error_code ec;
        fs::remove(data_dir() / "online" / "account.dat", ec);
        online::load(data_dir() / "online");
        online_ok_ = true;
        online_status_ = "Signed out. The console files stay; sign in again any time.";
    }

    void draw_online_status() {
        const float H = layout_.h, x = layout_.text_x, y = H * 0.86f, px = H * 0.03f;
        const std::string line = !online_status_.empty() ? online_status_
                                 : online::account().present
                                     ? "Signed in as " + online::account().account_id + " on Pretendo Network."
                                     : "Online play uses Pretendo Network: your Wii U's files and your Pretendo ID.";
        font_.draw(r_, x, y, fit(line, px, layout_.w * 0.6f), px, online_status_.empty() || online_ok_ ? kGood : kBad);
        const std::string hint = selected_ == kConsoleFiles
                                     ? "Dumpling (on your Wii U): Dump Online Files. Choose the folder it made."
                                     : "Your password is not saved: only the console's hash of it, as on a Wii U.";
        font_.draw(r_, x, y + H * 0.045f, fit(hint, px * 0.8f, layout_.w * 0.6f), px * 0.8f, kDim);
    }

    // ------------------------------------------------------------ the Online page, Wii U style
    // Light gray with faint diagonal stripes, a white title bar, white rounded rows with a cyan
    // outline on the selected one, inset text boxes, the blue pill button and a footer of round
    // button hints: the look of the Wii U's System Settings.
    void draw_wiiu_online() {
        const float W = layout_.w, H = layout_.h;
        const Color ink{0.24f, 0.24f, 0.26f}, soft{0.52f, 0.53f, 0.56f}, cyan{0.0f, 0.68f, 0.90f};
        const Color white{1, 1, 1}, shade{0, 0, 0, 0.10f};
        const float a = fade_;
        const auto fa = [&](Color c, float k = 1) { return Color{c.r, c.g, c.b, c.a * a * k}; };
        // Background: the Wii U's pale gray with Smash 4's light rays and its emblem, faint.
        paint_.rect(0, 0, W, H, {0.93f, 0.96f, 0.99f}, {0.93f, 0.96f, 0.99f}, {0.84f, 0.87f, 0.92f},
                    {0.84f, 0.87f, 0.92f});
        {
            const float ox = W * 0.5f, oy = -H * 0.35f, reach = W + H;
            const float turn = time_ * 0.02f;
            for (int i = 0; i < 24; i += 2) {
                const float a0 = std::numbers::pi_v<float> * (0.08f + i / 24.0f * 0.84f) + turn, a1 = a0 + std::numbers::pi_v<float> * 0.84f / 24;
                SDL_FPoint p[4] = {{ox, oy}, {ox + std::cos(a0) * reach, oy + std::sin(a0) * reach},
                                   {ox + std::cos(a1) * reach, oy + std::sin(a1) * reach}, {ox, oy}};
                const Color c[4] = {{1, 1, 1, 0.0f}, {1, 1, 1, 0.22f}, {1, 1, 1, 0.22f}, {1, 1, 1, 0.0f}};
                paint_.quad(p, c);
            }
            // The Smash emblem: a ring split by a vertical and a horizontal bar.
            const float er = H * 0.42f, ecx = W - H * 0.28f, ecy = H * 0.62f, t = H * 0.055f;
            const Color mark{0.0f, 0.45f, 0.75f, 0.06f};
            const float r0 = er - t / 2, r1 = er + t / 2;
            for (int k = 0; k < 120; ++k) { // the ring, segment by segment, edge to edge
                const float b0 = k / 120.0f * 2 * std::numbers::pi_v<float>, b1 = (k + 1) / 120.0f * 2 * std::numbers::pi_v<float>;
                SDL_FPoint q[4] = {{ecx + std::cos(b0) * r1, ecy + std::sin(b0) * r1},
                                   {ecx + std::cos(b1) * r1, ecy + std::sin(b1) * r1},
                                   {ecx + std::cos(b1) * r0, ecy + std::sin(b1) * r0},
                                   {ecx + std::cos(b0) * r0, ecy + std::sin(b0) * r0}};
                const Color mc[4] = {mark, mark, mark, mark};
                paint_.quad(q, mc);
            }
            paint_.rect(ecx + er * 0.12f, ecy - er, t * 1.2f, er * 2, mark);
            paint_.rect(ecx - er, ecy + er * 0.3f, er * 2, t * 1.1f, mark);
        }
        // Title bar: Smash 4's slanted ONLINE banner, then the Wii U settings title; the sign-in state on the right.
        const float bar = H * 0.115f;
        paint_.rect(0, 0, W, bar, white);
        paint_.rect(0, bar, W, H * 0.008f, {0, 0, 0, 0.10f}, {0, 0, 0, 0.10f}, {0, 0, 0, 0}, {0, 0, 0, 0});
        const float bw0 = H * 0.42f, slant = bar * 0.45f;
        {
            SDL_FPoint p[4] = {{0, 0}, {bw0 + slant, 0}, {bw0, bar}, {0, bar}};
            const Color c[4] = {{0.0f, 0.70f, 0.95f}, {0.10f, 0.45f, 0.90f}, {0.10f, 0.40f, 0.85f}, {0.0f, 0.62f, 0.90f}};
            paint_.quad(p, c);
            SDL_FPoint s2[4] = {{bw0 + slant + H * 0.012f, 0}, {bw0 + slant + H * 0.03f, 0}, {bw0 + H * 0.03f, bar},
                                {bw0 + H * 0.012f, bar}};
            const Color c2[4] = {cyan, cyan, cyan, cyan};
            paint_.quad(s2, c2);
        }
        // (Bold: drawn twice, a pixel apart.)
        const float tpx = H * 0.058f;
        font_.draw(r_, H * 0.05f, bar * 0.72f, "ONLINE", tpx, {0, 0, 0, 0.25f}, false);
        font_.draw(r_, H * 0.047f, bar * 0.70f, "ONLINE", tpx, white, false);
        font_.draw(r_, H * 0.047f + 1.5f, bar * 0.70f, "ONLINE", tpx, white, false);
        font_.draw(r_, bw0 + slant + H * 0.06f, bar * 0.64f, "Pretendo Network ID", H * 0.04f, ink, false);
        const bool signed_in = online::account().present;
        const std::string state = signed_in ? online::account().account_id : "Not signed in";
        const float sw = font_.width(r_, state, H * 0.028f) + H * 0.07f;
        const float sx = W - H * 0.05f - sw, sy = bar * 0.27f, sh = bar * 0.46f;
        paint_.round_rect(sx, sy, sw, sh, sh / 2, signed_in ? Color{0.90f, 0.97f, 1.0f} : Color{0.94f, 0.94f, 0.95f});
        paint_.round_rect(sx + sh * 0.32f, sy + sh * 0.36f, sh * 0.28f, sh * 0.28f, sh * 0.14f,
                          signed_in ? Color{0.25f, 0.75f, 0.35f} : soft);
        font_.draw(r_, sx + sh * 0.8f, sy + sh * 0.68f, state, H * 0.028f, ink, false);

        // The rows: Console files, ID, password, then the two buttons.
        const auto& list = items();
        online_rects_.assign(list.size(), SDL_FRect{});
        const float cw = std::min(W * 0.62f, H * 1.15f), cx = (W - cw) / 2;
        const float rh = H * 0.088f, gap = H * 0.02f;
        float y = bar + H * 0.06f;
        const float px = H * 0.032f, slide = (1 - a) * H * 0.02f;
        for (int i = kConsoleFiles; i <= kPasswordField; ++i) {
            const bool sel = selected_ == i;
            const SDL_FRect b{cx, y + slide, cw, rh};
            online_rects_[i] = b;
            if (sel) {
                // A pulsing glow around the Wii U's cyan outline.
                const float pulse = 0.5f + 0.5f * std::sin(time_ * 5.0f), g = H * (0.014f + 0.006f * pulse);
                paint_.round_rect(b.x - g, b.y - g, b.w + 2 * g, b.h + 2 * g, H * 0.018f + g, fa(cyan, 0.18f + 0.12f * pulse));
                paint_.round_rect(b.x - H * 0.007f, b.y - H * 0.007f, b.w + H * 0.014f, b.h + H * 0.014f, H * 0.025f,
                                  fa(cyan, 0.95f));
            }
            paint_.round_rect(b.x + 2, b.y + 4, b.w, b.h, H * 0.018f, fa(shade));
            paint_.round_rect(b.x, b.y, b.w, b.h, H * 0.018f, fa(white));
            // Smash 4's colour strip down the left of each item.
            paint_.round_rect(b.x + H * 0.008f, b.y + rh * 0.18f, H * 0.008f, rh * 0.64f, H * 0.004f,
                              fa(sel ? cyan : Color{0.70f, 0.78f, 0.86f}));
            static const char* kNames[] = {"Console files", "Pretendo ID", "Password"};
            font_.draw(r_, b.x + H * 0.035f, b.y + rh * 0.62f, kNames[i], px, fa(ink), false);
            const float vx = b.x + b.w * 0.42f, vw = b.w * 0.58f - H * 0.03f;
            if (i == kConsoleFiles) {
                const bool found = online::device().present;
                const std::string v = found ? "Found" : "Choose...";
                const float tw = font_.width(r_, v, px * 0.9f);
                if (found) paint_.check(b.x + b.w - H * 0.035f - tw - H * 0.045f, b.y + rh * 0.34f, px * 0.75f, H * 0.004f,
                                        fa({0.25f, 0.70f, 0.32f}));
                font_.draw(r_, b.x + b.w - H * 0.035f - tw, b.y + rh * 0.62f, v, px * 0.9f, fa(found ? ink : cyan), false);
            } else {
                // An inset text box.
                const float bh = rh * 0.62f, by = b.y + (rh - bh) / 2;
                paint_.round_rect(vx, by, vw, bh, H * 0.012f, fa({0.86f, 0.87f, 0.89f}));
                paint_.round_rect(vx + 1.5f, by + 2.5f, vw - 3, bh - 4, H * 0.011f, fa({0.975f, 0.978f, 0.985f}));
                const std::string& text = i == kUserField ? user_ : password_;
                std::string shown = i == kPasswordField ? std::string(utf8_length(text), '*') : text;
                const bool typing = editing_ == i;
                if (shown.empty() && !typing) {
                    font_.draw(r_, vx + H * 0.02f, by + bh * 0.7f, i == kUserField ? "Tap to type" : "Tap to type",
                               px * 0.85f, fa(soft, 0.8f), false);
                } else {
                    const float tw = font_.draw(r_, vx + H * 0.02f, by + bh * 0.7f, shown, px * 0.9f, fa(ink), false);
                    if (typing && std::fmod(time_, 1.0f) < 0.55f) {
                        paint_.rect(vx + H * 0.022f + tw, by + bh * 0.2f, H * 0.003f, bh * 0.6f, fa(cyan));
                    }
                }
                if (typing) paint_.round_rect(vx - 1, by - 1, vw + 2, H * 0.004f, H * 0.002f, fa(cyan, 0.0f));
            }
            y += rh + gap;
        }

        // Sign In: the blue pill; Sign Out: a white one (when signed in).
        y += gap;
        const float bw = cw * 0.42f, bh2 = rh * 0.86f;
        const auto pill = [&](int item, float x, const std::string& label, bool primary, bool enabled) {
            const bool sel = selected_ == item;
            const SDL_FRect b{x, y + slide, bw, bh2};
            online_rects_[item] = b;
            if (sel) paint_.round_rect(b.x - H * 0.008f, b.y - H * 0.008f, b.w + H * 0.016f, b.h + H * 0.016f,
                                       (bh2 + H * 0.016f) / 2, fa(cyan, 0.9f));
            paint_.round_rect(b.x + 2, b.y + 4, b.w, b.h, bh2 / 2, fa(shade));
            if (primary && enabled) {
                paint_.round_rect(b.x, b.y, b.w, b.h, bh2 / 2, fa({0.0f, 0.58f, 0.85f}));
                paint_.round_rect(b.x + 3, b.y + 2, b.w - 6, b.h * 0.5f, bh2 / 2, fa({1, 1, 1}, 0.18f));
            } else {
                paint_.round_rect(b.x, b.y, b.w, b.h, bh2 / 2, fa(white));
            }
            const float tw = font_.width(r_, label, px);
            const Color tc = primary && enabled ? white : enabled ? ink : soft;
            font_.draw(r_, b.x + (b.w - tw) / 2, b.y + bh2 * 0.64f, label, px, fa(tc), false);
        };
        const bool can_sign_in = online::device().present && !signing_in_;
        pill(kSignIn, cx + cw / 2 - bw - H * 0.02f, signing_in_ ? "Signing in..." : "Sign In", true, can_sign_in);
        pill(kSignOut, cx + cw / 2 + H * 0.02f, "Sign Out", false, signed_in);
        if (signing_in_) {
            const SDL_FRect& b = online_rects_[kSignIn];
            paint_.spinner(b.x + bh2 * 0.5f, b.y + bh2 / 2, bh2 * 0.22f, H * 0.004f, time_, white);
        }
        y += bh2 + gap * 1.8f;

        // What happened, or what to do.
        const std::string line = !online_status_.empty() ? online_status_
                                 : signed_in ? "Signed in. Smash's online modes use this account on Pretendo Network."
                                             : "Sign in with your Pretendo Network ID to play online.";
        const Color lc = online_status_.empty() || online_ok_ ? ink : Color{0.85f, 0.25f, 0.22f};
        const float lw = font_.width(r_, line, px * 0.8f);
        font_.draw(r_, (W - std::min(lw, W * 0.9f)) / 2, y + slide, fit(line, px * 0.8f, W * 0.9f), px * 0.8f, fa(lc), false);
        const std::string hint = selected_ == kConsoleFiles
                                     ? "On your Wii U, Dumpling > Dump Online Files. Then choose the folder it made."
                                     : "Your password is not saved, only the console's hash of it, as on a Wii U.";
        const float hw = font_.width(r_, hint, px * 0.7f);
        font_.draw(r_, (W - std::min(hw, W * 0.9f)) / 2, y + H * 0.045f + slide, fit(hint, px * 0.7f, W * 0.9f), px * 0.7f,
                   fa(soft), false);

        // Footer: the round button hints, Back on the left (clickable) and OK on the right.
        const float fh = H * 0.1f, fy = H - fh;
        paint_.rect(0, fy, W, fh, {0.84f, 0.85f, 0.87f});
        paint_.rect(0, fy, W, H * 0.004f, {0.78f, 0.79f, 0.81f});
        const auto hint_button = [&](float x, const char* letter, const char* text, bool selected) {
            const float d = fh * 0.46f, by = fy + (fh - d) / 2;
            const float tw = font_.width(r_, text, H * 0.03f);
            const SDL_FRect b{x - fh * 0.12f, fy + fh * 0.14f, d + tw + fh * 0.5f, fh * 0.72f};
            if (selected) paint_.round_rect(b.x - 3, b.y - 3, b.w + 6, b.h + 6, (b.h + 6) / 2, fa(cyan, 0.9f));
            paint_.round_rect(b.x, b.y, b.w, b.h, b.h / 2, {1, 1, 1, 0.9f});
            paint_.round_rect(x, by, d, d, d / 2, {0.33f, 0.34f, 0.37f});
            const float lw2 = font_.width(r_, letter, H * 0.026f);
            font_.draw(r_, x + (d - lw2) / 2, by + d * 0.7f, letter, H * 0.026f, white, false);
            font_.draw(r_, x + d + fh * 0.18f, by + d * 0.72f, text, H * 0.03f, ink, false);
            return b;
        };
        online_rects_[kOnlineBack] = hint_button(H * 0.05f, "B", "Back", selected_ == kOnlineBack);
        hint_button(W - H * 0.05f - fh * 0.46f - font_.width(r_, "OK", H * 0.03f) - fh * 0.3f, "A", "OK", false);
    }

    void draw_toast() {
        const float H = layout_.h;
        const float px = H * 0.027f;
        const std::string text = shaders_ > 0 ? std::to_string(shaders_) + " shaders ready"
                                              : "Shaders compile the first time you play";
        const float tw = font_.width(r_, text, px);
        const float bx = H * 0.018f, bh = H * 0.068f, by = H - bh - H * 0.02f, bw = tw + H * 0.11f;
        paint_.round_rect(bx, by, bw, bh, H * 0.008f, {kGold.r, kGold.g, kGold.b, 0.75f});
        paint_.round_rect(bx + 1.5f, by + 1.5f, bw - 3, bh - 3, H * 0.007f, {0.04f, 0.035f, 0.03f, 0.88f});
        const float icon = px * 0.8f, ix = bx + H * 0.03f, cy = by + bh / 2;
        if (shaders_ > 0) {
            paint_.check(ix, cy - icon / 2, icon, H * 0.0032f, kGood);
        } else {
            paint_.spinner(ix + icon / 2, cy, icon / 2, H * 0.003f, time_, kWhite);
        }
        font_.draw(r_, ix + H * 0.045f, cy + px * 0.36f, text, px, kWhite, false);
    }

    SDL_Window* window_;
    SDL_Renderer* r_;
    std::array<SDL_FRect, 14> main_rects_{};
    fs::path cemu_profiles_dir_ = cemu_profiles_directory();
    size_t cemu_profile_count_ = count_cemu_profiles(cemu_profiles_dir_);
    std::string cemu_dialog_directory_;
    Painter paint_;
    Font font_;
    Image logo_, background_;
    fs::path dir_;
    fs::path paths_[kSlots];
    bool valid_[kSlots] = {};
    int dlc_items_ = 0; // DLC items present (owned)
    int update_version_ = 0;
    Slot dialog_slot_ = kGame;
    bool dialog_done_ = false, prompting_ = false;
    bool asked_[kSlots] = {};
    bool mouse_moved_ = false;
    std::vector<Mod> mods_;
    display::Settings settings_;
    int shaders_ = 0;
    Screen screen_ = Screen::kMain;
    controller_profiles::Profile control_profile_ = controller_profiles::default_profile();
    SDL_JoystickID control_device_ = 0;
    keymap::Keys keyboard_keys_ = keymap::default_keys();
    size_t control_button_action_ = 0, control_axis_action_ = 0, control_keyboard_action_ = 0;
    bool control_keyboard_ = true;
    bool capture_binding_ = false, capture_axis_ = false, capture_keyboard_ = false;
    float capture_started_ = 0.0f;
    std::string controls_status_;
    std::string diagnostics_status_;
    std::vector<Item> list_;
    int selected_ = 0;
    float selection_y_ = 0, fade_ = 0, time_ = 0;
    float stick_x_ = 0, stick_y_ = 0, held_x_ = 0, held_y_ = 0;
    SDL_Process* process_ = nullptr;
    SDL_Process* build_process_ = nullptr;
    bool building_runtime_ = false;
    std::string build_status_ = "Not built";
    int exit_code_ = 0;
    std::string launch_error_;
    std::mutex dialog_mutex_;
    std::string dialog_result_;
    bool quit_ = false;
    // The Online page.
    bool online_dialog_ = false, cemu_dialog_ = false, signing_in_ = false, online_ok_ = true;
    // The mod installer.
    bool mod_dialog_ = false, installing_ = false, mod_ok_ = true, install_done_ = false;
    std::string mod_status_;
    std::mutex install_mutex_;
    std::thread install_thread_;
    Installed install_result_;
    int editing_ = -1; // the field being typed in
    // Netplay.
    bool netplay_host_ = false;
    std::string netplay_name_, netplay_address_;
    std::thread rooms_thread_;
    std::atomic<bool> shutting_down_{false};
    std::atomic<bool> room_watch_enabled_{false};
    std::mutex rooms_mutex_;
    std::vector<cafe::host::netplay::Room> rooms_;
    bool rooms_reached_ = false;
    std::vector<SDL_FRect> online_rects_; // each Online row's box, for the mouse
    std::string user_, password_, online_status_;
    std::mutex sign_in_mutex_;
    std::thread sign_in_thread_;
    bool sign_in_done_ = false;
    act_server::SignIn sign_in_result_;
    std::thread update_check_thread_;
    std::mutex wua_mutex_;
    std::thread wua_thread_;
    WuaImportResult wua_result_;
    bool wua_dialog_ = false, wua_importing_ = false, wua_done_ = false;
    fs::path wua_stage_path_;
    std::string wua_status_ = "Select a .wua archive";
    std::mutex update_check_mutex_;
    bool update_check_done_ = false;
    bool update_checking_ = false;
    bool update_available_ = false;
    std::string update_channel_ = "stable";
    std::string update_status_ = "Not checked";
    std::string update_release_version_;
    std::string update_release_url_;
    AppUpdateCheck update_check_result_;
};

} // namespace

int main(int argc, char** argv) {
    SDL_SetHint(SDL_HINT_WINDOWS_INTRESOURCE_ICON, "1");
    SDL_SetHint(SDL_HINT_WINDOWS_INTRESOURCE_ICON_SMALL, "1");
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD)) {
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "U Unlocked", SDL_GetError(), nullptr);
        return 1;
    }
    SDL_Window* window = SDL_CreateWindow("U Unlocked", 1600, 900, SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    SDL_Renderer* renderer = window ? SDL_CreateRenderer(window, nullptr) : nullptr;
    if (!renderer) {
        SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, "U Unlocked", SDL_GetError(), nullptr);
        return 1;
    }
    SDL_SetRenderVSync(renderer, 1);
    SDL_SetWindowMinimumSize(window, 960, 540);
    {
        Launcher launcher(window, renderer);
        // U_UNLOCKED_LAUNCHER_SHOT=<file.bmp>: saves the frame shown after 1.5 s and quits
        // (SMASH_LAUNCHER_SCREEN=settings, mods or online: that screen).
        const char* shot = std::getenv("U_UNLOCKED_LAUNCHER_SHOT");
        if (const char* s = std::getenv("SMASH_LAUNCHER_SCREEN")) launcher.open_screen(s);
        if (argc > 1) launcher.install(argv[1]); // a mod folder dropped on the launcher's icon
        const uint64_t started = SDL_GetTicksNS();
        uint64_t last = started;
        while (launcher.running()) {
            SDL_Event e;
            // While the game runs the launcher only waits for it.
            if (launcher.game_running() ? SDL_WaitEventTimeout(&e, 250) : SDL_PollEvent(&e)) {
                do launcher.event(e);
                while (SDL_PollEvent(&e));
            }
            const uint64_t now = SDL_GetTicksNS();
            launcher.update(std::min(0.1f, (now - last) / 1e9f));
            last = now;
            const bool save = shot && now - started > 1500000000ull && !launcher.installing();
            if (!launcher.game_running()) launcher.draw(save);
            if (save) break;
        }
        if (shot) std::fprintf(stderr, "launcher: stopped after %.2f s\n", (SDL_GetTicksNS() - started) / 1e9);
    }
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();
    return 0;
}
