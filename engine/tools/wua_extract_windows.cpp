#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <zarchive/zarchivereader.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>
#include <vector>

#include <filesystem>

namespace fs = std::filesystem;

namespace {

constexpr size_t kMaximumEntries = 100000;
constexpr unsigned kMaximumDepth = 128;
constexpr uint64_t kMaximumExpandedBytes = 64ULL * 1024 * 1024 * 1024;
constexpr size_t kMaximumPathCharacters = 32760;

[[noreturn]] void win_error(const std::string& operation) {
    const DWORD error = GetLastError();
    throw std::runtime_error(operation + " (Windows error " + std::to_string(error) + ")");
}

std::wstring wide(std::string_view value) {
    if (value.empty()) return {};
    const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                                          static_cast<int>(value.size()), nullptr, 0);
    if (count <= 0) throw std::runtime_error("Archive contains a filename that is not valid UTF-8");
    std::wstring result(static_cast<size_t>(count), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), result.data(), count) != count)
        throw std::runtime_error("Cannot convert an archive filename to UTF-16");
    return result;
}

std::wstring folded(std::wstring_view value) {
    if (value.empty()) return {};
    const int count = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE,
                                    value.data(), static_cast<int>(value.size()),
                                    nullptr, 0, nullptr, nullptr, 0);
    if (count <= 0) win_error("Cannot normalise an archive path");
    std::wstring result(static_cast<size_t>(count), L'\0');
    if (LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE,
                      value.data(), static_cast<int>(value.size()),
                      result.data(), count, nullptr, nullptr, 0) != count)
        win_error("Cannot normalise an archive path");
    return result;
}

bool reserved_device_name(std::wstring_view component) {
    const size_t dot = component.find(L'.');
    std::wstring stem(component.substr(0, dot));
    std::transform(stem.begin(), stem.end(), stem.begin(),
                   [](wchar_t c) { return c >= L'a' && c <= L'z' ? c - (L'a' - L'A') : c; });
    if (stem == L"CON" || stem == L"PRN" || stem == L"AUX" || stem == L"NUL") return true;
    if (stem.size() == 4 && (stem.compare(0, 3, L"COM") == 0 || stem.compare(0, 3, L"LPT") == 0)
        && stem[3] >= L'1' && stem[3] <= L'9') return true;
    return false;
}

void validate_component(std::string_view component) {
    if (component.empty() || component == "." || component == "..")
        throw std::runtime_error("Archive contains an unsafe path component");
    const std::wstring name = wide(component);
    if (name.size() > 255 || name.back() == L'.' || name.back() == L' ' || reserved_device_name(name))
        throw std::runtime_error("Archive contains a Windows-reserved filename");
    for (wchar_t c : name) {
        if (c < 32 || c == L'<' || c == L'>' || c == L':' || c == L'"' ||
            c == L'/' || c == L'\\' || c == L'|' || c == L'?' || c == L'*')
            throw std::runtime_error("Archive contains an unsafe Windows filename");
    }
}

struct Entry {
    std::string path;
    ZArchiveNodeHandle node = ZARCHIVE_INVALID_NODE;
    uint64_t size = 0;
};

std::vector<Entry> inventory(ZArchiveReader& reader, bool analysis_only) {
    struct Directory { std::string path; ZArchiveNodeHandle node; unsigned depth; };
    const auto root = reader.LookUp("", false, true);
    if (root == ZARCHIVE_INVALID_NODE) throw std::runtime_error("Archive has no valid root directory");

    std::vector<Directory> pending{{"", root, 0}};
    std::unordered_set<ZArchiveNodeHandle> visited;
    std::unordered_set<std::wstring> paths;
    std::vector<Entry> files;
    uint64_t total = 0;
    size_t visited_entries = 0;

    while (!pending.empty()) {
        Directory directory = std::move(pending.back());
        pending.pop_back();
        if (directory.depth > kMaximumDepth || !visited.insert(directory.node).second)
            throw std::runtime_error("Archive has cyclic or excessively deep directories");

        const uint32_t count = reader.GetDirEntryCount(directory.node);
        for (uint32_t i = 0; i < count; ++i) {
            ZArchiveReader::DirEntry item{};
            if (++visited_entries > kMaximumEntries)
                throw std::runtime_error("Archive exceeds the 100,000-entry safety limit");
            if (!reader.GetDirEntry(directory.node, i, item) || item.isFile == item.isDirectory)
                throw std::runtime_error("Archive contains an invalid directory entry");
            validate_component(item.name);

            std::string path = directory.path.empty()
                ? std::string(item.name)
                : directory.path + "/" + std::string(item.name);
            const std::wstring key = folded(wide(path));
            if (!paths.insert(key).second)
                throw std::runtime_error("Archive contains duplicate or case-colliding paths: " + path);

            const auto node = reader.LookUp(path, item.isFile, item.isDirectory);
            if (node == ZARCHIVE_INVALID_NODE)
                throw std::runtime_error("Cannot resolve archive entry: " + path);

            if (item.isDirectory) {
                pending.push_back({std::move(path), node, directory.depth + 1});
                continue;
            }

            if (!analysis_only || [&] {
                    const size_t first = path.find('/');
                    if (first == std::string::npos) return false;
                    const size_t second = path.find('/', first + 1);
                    if (second == std::string::npos) return false;
                    const std::string section = path.substr(first + 1, second - first - 1);
                    return section == "code" || section == "meta";
                }()) {
                const uint64_t size = reader.GetFileSize(node);
                if (size > kMaximumExpandedBytes - total)
                    throw std::runtime_error("Archive exceeds the 64 GiB expanded-size safety limit");
                total += size;
                files.push_back({std::move(path), node, size});
                if (files.size() > kMaximumEntries)
                    throw std::runtime_error("Archive exceeds the 100,000-file safety limit");
            }
        }
    }
    std::sort(files.begin(), files.end(), [](const Entry& a, const Entry& b) { return a.path < b.path; });
    return files;
}

void reject_reparse(const fs::path& path, bool allow_missing) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        const DWORD error = GetLastError();
        if (allow_missing && (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND)) return;
        win_error("Cannot inspect path " + path.string());
    }
    if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
        throw std::runtime_error("Refusing to follow a Windows reparse point: " + path.string());
}

void ensure_safe_root(const fs::path& requested) {
    std::error_code ec;
    const fs::path absolute = fs::absolute(requested, ec).lexically_normal();
    if (ec || absolute.empty() || !absolute.is_absolute())
        throw std::runtime_error("Output directory is not a valid absolute path");

    fs::path current = absolute.root_path();
    for (const auto& component : absolute.relative_path()) {
        current /= component;
        reject_reparse(current, true);
    }
    fs::create_directories(absolute, ec);
    if (ec) throw std::runtime_error("Cannot create output directory: " + ec.message());
    reject_reparse(absolute, false);
    const DWORD attributes = GetFileAttributesW(absolute.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0)
        throw std::runtime_error("Output path is not a directory");
}

void ensure_directory(const fs::path& path) {
    std::error_code ec;
    if (!fs::create_directory(path, ec) && ec != std::errc::file_exists)
        throw std::runtime_error("Cannot create directory " + path.string() + ": " + ec.message());
    reject_reparse(path, false);
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0)
        throw std::runtime_error("Archive path is not a directory: " + path.string());
}

void extract_file(ZArchiveReader& reader, const Entry& entry, const fs::path& root) {
    const fs::path relative = fs::u8path(entry.path);
    fs::path parent = root;
    for (const auto& component : relative.parent_path()) {
        parent /= component;
        ensure_directory(parent);
    }

    const fs::path destination = root / relative;
    if (destination.native().size() > kMaximumPathCharacters)
        throw std::runtime_error("Archive path exceeds the Windows path-length limit: " + entry.path);

    HANDLE output = CreateFileW(destination.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (output == INVALID_HANDLE_VALUE)
        win_error("Cannot create output file without overwriting an existing file: " + entry.path);

    FILE_ATTRIBUTE_TAG_INFO tag{};
    if (!GetFileInformationByHandleEx(output, FileAttributeTagInfo, &tag, sizeof(tag)) ||
        (tag.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        CloseHandle(output);
        DeleteFileW(destination.c_str());
        throw std::runtime_error("Output file unexpectedly resolved to a reparse point: " + entry.path);
    }

    try {
        std::array<uint8_t, 1024 * 1024> buffer{};
        uint64_t offset = 0;
        while (offset < entry.size) {
            const uint64_t amount = std::min<uint64_t>(buffer.size(), entry.size - offset);
            if (reader.ReadFromFile(entry.node, offset, amount, buffer.data()) != amount)
                throw std::runtime_error("Short read from WUA archive: " + entry.path);
            uint64_t written = 0;
            while (written < amount) {
                const DWORD chunk = static_cast<DWORD>(std::min<uint64_t>(amount - written, 0x7ffff000ULL));
                DWORD count = 0;
                if (!WriteFile(output, buffer.data() + written, chunk, &count, nullptr) || count == 0)
                    win_error("Cannot write extracted file: " + entry.path);
                written += count;
            }
            offset += amount;
        }
        if (!FlushFileBuffers(output)) win_error("Cannot flush extracted file: " + entry.path);
        if (!CloseHandle(output)) {
            output = INVALID_HANDLE_VALUE;
            win_error("Cannot close extracted file: " + entry.path);
        }
        output = INVALID_HANDLE_VALUE;
    } catch (...) {
        if (output != INVALID_HANDLE_VALUE) CloseHandle(output);
        DeleteFileW(destination.c_str());
        throw;
    }
}

} // namespace

int main(int argc, char** argv) {
    const std::string command = argc > 1 ? argv[1] : "";
    const bool list = command == "list";
    const bool analysis = command == "extract-analysis";
    const bool all = command == "extract-all";
    if ((!list && !analysis && !all) || argc != (list ? 3 : 4)) {
        std::cerr << "Usage:\n  wua_extract list ARCHIVE\n"
                  << "  wua_extract extract-analysis ARCHIVE OUTPUT_DIR\n"
                  << "  wua_extract extract-all ARCHIVE OUTPUT_DIR\n";
        return 2;
    }

    try {
        std::unique_ptr<ZArchiveReader> reader(ZArchiveReader::OpenFromFile(fs::u8path(argv[2])));
        if (!reader) throw std::runtime_error("Cannot open WUA/ZArchive: " + std::string(argv[2]));
        const auto files = inventory(*reader, analysis);

        if (list) {
            std::cout << "path\tsize_bytes\n";
            for (const auto& entry : files)
                std::cout << entry.path << '\t' << entry.size << '\n';
        } else {
            const fs::path root = fs::u8path(argv[3]);
            ensure_safe_root(root);
            uint64_t bytes = 0;
            for (const auto& entry : files) {
                extract_file(*reader, entry, root);
                bytes += entry.size;
                std::cout << entry.path << '\n';
            }
            std::cerr << "Extracted " << files.size() << " files (" << bytes << " bytes)\n";
            if (analysis && files.empty())
                throw std::runtime_error("No TITLEID_VERSION/code or /meta files found");
        }
        if (!std::cout) throw std::runtime_error("Cannot write standard output");
    } catch (const std::exception& error) {
        std::cerr << "wua_extract: " << error.what() << '\n';
        return 1;
    }
    return 0;
}
