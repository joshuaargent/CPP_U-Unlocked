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
    target_link_libraries(wua_extract PRIVATE ZArchive::zarchive)
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
if(UNIX)
    enable_testing()
    add_subdirectory(tests)
endif()

# How the generated game code is compiled. The faster build requires AVX2 and FMA.
option(SMASH_COMPAT "Build for x86-64-v2 processors (smash-compat.exe)" OFF)
if(SMASH_COMPAT)
    set(SMASH_GENERATED_OPTIONS -O2 -march=x86-64-v2 -fno-exceptions -Wno-unused-label)
else()
    set(SMASH_GENERATED_OPTIONS -O2 -march=x86-64-v3 -fno-exceptions -Wno-unused-label)
endif()

# Super Smash Bros. for Wii U: the same runtime without unrelated title-specific extensions.
# Point SMASH_GENERATED_DIR at cafe-recomp's output for cross_f.rpx.
set(SMASH_GENERATED_DIR "" CACHE PATH "cafe-recomp output directory for Smash")
if(SMASH_GENERATED_DIR)
    include(${SMASH_GENERATED_DIR}/sources.cmake)
    add_library(smash_generated OBJECT ${CAFE_GENERATED_SOURCES})
    target_include_directories(smash_generated PRIVATE runtime/include)
    target_compile_features(smash_generated PRIVATE cxx_std_20)
    target_compile_options(smash_generated PRIVATE ${SMASH_GENERATED_OPTIONS})

    add_executable(smash runtime/src/smash_main.cpp runtime/src/smash_logo.cpp runtime/src/smash_overlay.cpp)
    target_include_directories(smash SYSTEM PRIVATE third_party/stb)
    if(WIN32)
        enable_language(RC)
        target_sources(smash PRIVATE runtime/res/smash.rc) # the icon
    endif()
    target_link_libraries(smash PRIVATE cafe_runtime smash_generated $<$<PLATFORM_ID:Windows>:winmm>)
    target_compile_options(smash PRIVATE -Wall -Wextra -Wpedantic)
    if(SMASH_COMPAT)
        target_compile_definitions(smash PRIVATE SMASH_COMPAT)
        set_target_properties(smash PROPERTIES OUTPUT_NAME smash-compat)
    endif()

    # U Unlocked's launcher (launcher/smash/): the menu that runs smash.exe.
    find_package(SDL3 REQUIRED CONFIG)
    add_executable(smash-launcher WIN32 launcher/smash/main.cpp runtime/src/host/display_settings.cpp
        runtime/src/host/controller_profiles.cpp runtime/src/host/controller_profile_import.cpp
        third_party/tinyxml2/tinyxml2.cpp
        # Pretendo sign-in (the Online page)
        runtime/src/os/online_identity.cpp runtime/src/os/sect233.cpp runtime/src/os/act_server.cpp
        runtime/src/host/http.cpp
        # Netplay's room list (the Netplay page)
        runtime/src/host/rooms.cpp)
    set_target_properties(smash-launcher PROPERTIES OUTPUT_NAME "U Unlocked")
    if(WIN32)
        target_sources(smash-launcher PRIVATE runtime/res/smash.rc)
    endif()
    target_include_directories(smash-launcher PRIVATE runtime/src third_party/tinyxml2)
    target_include_directories(smash-launcher SYSTEM PRIVATE third_party/stb)
    target_compile_features(smash-launcher PRIVATE cxx_std_20)
    target_link_libraries(smash-launcher PRIVATE SDL3::SDL3 $<$<PLATFORM_ID:Windows>:winhttp bcrypt ws2_32>)
    target_compile_options(smash-launcher PRIVATE -Wall -Wextra -Wno-missing-field-initializers)
endif()

