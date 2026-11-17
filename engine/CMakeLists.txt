cmake_minimum_required(VERSION 3.20)
project(UUnlocked LANGUAGES C CXX)

if(WIN32)
    # Libraries built and installed by U Unlocked's tools\build-deps.ps1. Vulkan links through an import library
    # made from the driver's vulkan-1.dll.
    set(CAFE_DEPS_PREFIX ${CMAKE_SOURCE_DIR}/build-deps/prefix)
    list(APPEND CMAKE_PREFIX_PATH ${CAFE_DEPS_PREFIX})
    set(ZLIB_USE_STATIC_LIBS ON)
    set(Vulkan_INCLUDE_DIR ${CAFE_DEPS_PREFIX}/include CACHE PATH "")
    set(Vulkan_LIBRARY ${CAFE_DEPS_PREFIX}/lib/libvulkan-1.a CACHE FILEPATH "")
elseif(NOT UNIX)
    message(FATAL_ERROR "The safe extraction utility currently requires a POSIX host.")
endif()

add_subdirectory(third_party/ZArchive EXCLUDE_FROM_ALL)

# AMD's surface address library (MIT), in its R600 variant for the Wii U GPU:
# GX2 surface layouts must match the console's exactly.
set(ADDRLIB_DIR ${CMAKE_SOURCE_DIR}/third_party/addrlib)
add_library(amd_addrlib STATIC EXCLUDE_FROM_ALL
    ${ADDRLIB_DIR}/src/addrinterface.cpp
    ${ADDRLIB_DIR}/src/core/addrelemlib.cpp
    ${ADDRLIB_DIR}/src/core/addrlib.cpp
    ${ADDRLIB_DIR}/src/core/addrobject.cpp
    ${ADDRLIB_DIR}/src/r600/r600addrlib.cpp)
target_include_directories(amd_addrlib SYSTEM PUBLIC ${ADDRLIB_DIR}/include)
target_include_directories(amd_addrlib PRIVATE ${ADDRLIB_DIR}/src)
target_compile_features(amd_addrlib PRIVATE cxx_std_17)
target_compile_options(amd_addrlib PRIVATE -w)

# Cemu's NEX client (MPL 2.0, third_party/cemu_nex/LICENSE.txt): PRUDP and the
# friends service, for Nintendo Network (Pretendo) play. Built from Cemu's
# files with cemu_compat.h standing in for the rest of Cemu.
set(CEMU_NEX_DIR ${CMAKE_SOURCE_DIR}/third_party/cemu_nex)
add_library(cemu_nex STATIC EXCLUDE_FROM_ALL
    ${CEMU_NEX_DIR}/Cemu/nex/nex.cpp
    ${CEMU_NEX_DIR}/Cemu/nex/nexFriends.cpp
    ${CEMU_NEX_DIR}/Cemu/nex/nexThread.cpp
    ${CEMU_NEX_DIR}/Cemu/nex/prudp.cpp
    ${CEMU_NEX_DIR}/util/crypto/md5.cpp)
target_include_directories(cemu_nex SYSTEM PUBLIC ${CEMU_NEX_DIR})
target_compile_features(cemu_nex PUBLIC cxx_std_20)
target_compile_options(cemu_nex PRIVATE -w -include ${CEMU_NEX_DIR}/cemu_compat.h)
if(WIN32)
    target_link_libraries(cemu_nex PUBLIC ws2_32)
endif()

if(WIN32)
    add_executable(wua_extract tools/wua_extract_windows.cpp)
    target_compile_features(wua_extract PRIVATE cxx_std_20)
    target_link_libraries(wua_extract PRIVATE ZArchive::zarchive shell32)
    set_target_properties(wua_extract PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    if(MSVC)
        target_compile_options(wua_extract PRIVATE /W4 /permissive-)
    else()
        target_compile_options(wua_extract PRIVATE -Wall -Wextra -Wpedantic)
    endif()
elseif(UNIX)
    add_executable(wua_extract tools/wua_extract.cpp)
    target_compile_features(wua_extract PRIVATE cxx_std_20)
    target_link_libraries(wua_extract PRIVATE ZArchive::zarchive)
    target_compile_options(wua_extract PRIVATE -Wall -Wextra -Wpedantic)
endif()

# Function-level PowerPC -> C++ recompiler for the standalone port.
add_subdirectory(recomp)
add_subdirectory(runtime)

if(WIN32)
    # Compile the game-host translation units in CI even when no copyrighted
    # generated game sources are available. Real game targets use these same
    # sources with the v2/v3 CPU-specific compile definitions.
    function(add_smash_host_compile_check target compatibility)
        add_library(${target} OBJECT EXCLUDE_FROM_ALL
            runtime/src/smash_main.cpp
            runtime/src/smash_logo.cpp
            runtime/src/smash_overlay.cpp)
        target_include_directories(${target} PRIVATE runtime/src third_party/tinyxml2)
        target_include_directories(${target} SYSTEM PRIVATE third_party/stb)
        target_compile_features(${target} PRIVATE cxx_std_20)
        target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic)
        target_link_libraries(${target} PRIVATE cafe_runtime)
        if(${compatibility})
            target_compile_definitions(${target} PRIVATE SMASH_COMPAT)
        endif()
    endfunction()
    add_smash_host_compile_check(smash_host_compile_check_v3 FALSE)
    add_smash_host_compile_check(smash_host_compile_check_v2 TRUE)
endif()
if(UNIX)
    enable_testing()
    add_subdirectory(tests)
endif()

# User-owned game code is generated locally and never enters CI or release assets.
set(SMASH_GENERATED_DIR "" CACHE PATH "cafe-recomp output directory for the updated game")
set(SMASH_BASE_GENERATED_DIR "" CACHE PATH "cafe-recomp output directory for the base game")
include(cmake/SmashTargets.cmake)

if(WIN32)
    enable_language(RC)
endif()
if(SMASH_GENERATED_DIR)
    add_smash_game_pair(smash_update "${SMASH_GENERATED_DIR}" smash smash-compat)
endif()
if(SMASH_BASE_GENERATED_DIR)
    add_smash_game_pair(smash_base "${SMASH_BASE_GENERATED_DIR}" smash-base smash-base-compat)
endif()

if(SMASH_GENERATED_DIR)
    # U Unlocked's launcher (launcher/smash/): the menu that runs the game targets.
    find_package(SDL3 REQUIRED CONFIG)
    add_executable(smash-launcher WIN32 launcher/smash/main.cpp runtime/src/host/display_settings.cpp
        runtime/src/host/keymap.cpp
        runtime/src/host/controller_profiles.cpp runtime/src/host/controller_profile_import.cpp
        third_party/tinyxml2/tinyxml2.cpp
        # Pretendo sign-in (the Online page)
        runtime/src/os/online_identity.cpp runtime/src/os/sect233.cpp runtime/src/os/act_server.cpp
        runtime/src/host/http.cpp
        # Netplay's room list (the Netplay page)
        runtime/src/host/rooms.cpp)
    set_target_properties(smash-launcher PROPERTIES OUTPUT_NAME "U Unlocked")
    # The historical RC file references an icon asset that is not present in the
    # source tree. Omit the optional executable icon resource so clean builds work.
    target_include_directories(smash-launcher PRIVATE runtime/src third_party/tinyxml2)
    target_include_directories(smash-launcher SYSTEM PRIVATE third_party/stb)
    target_compile_features(smash-launcher PRIVATE cxx_std_20)
    target_link_libraries(smash-launcher PRIVATE SDL3::SDL3 $<$<PLATFORM_ID:Windows>:winhttp bcrypt ws2_32>)
    target_compile_options(smash-launcher PRIVATE -Wall -Wextra -Wno-missing-field-initializers)
endif()
