cmake_minimum_required(VERSION 3.20)
project(UUnlockedLauncherCompileCheck LANGUAGES CXX)

find_package(SDL3 REQUIRED CONFIG)

get_filename_component(ENGINE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

# Compile the complete launcher translation unit without linking or requiring
# user game data / generated recompiled game code. This catches UI, SDL3, stb,
# and controller-import integration errors in ordinary Windows CI.
add_library(u_unlocked_launcher_compile OBJECT
    "${ENGINE_ROOT}/launcher/smash/main.cpp"
    "${ENGINE_ROOT}/runtime/src/host/keymap.cpp"
    "${ENGINE_ROOT}/runtime/src/host/netplay.cpp"
    "${ENGINE_ROOT}/runtime/src/host/rooms.cpp"
)

target_include_directories(u_unlocked_launcher_compile PRIVATE
    "${ENGINE_ROOT}/runtime/src"
    "${ENGINE_ROOT}/runtime/include"
    "${ENGINE_ROOT}/third_party/tinyxml2"
    "${ENGINE_ROOT}/third_party/stb"
)

target_compile_features(u_unlocked_launcher_compile PRIVATE cxx_std_20)
target_link_libraries(u_unlocked_launcher_compile PRIVATE SDL3::SDL3)
target_compile_options(u_unlocked_launcher_compile PRIVATE
    /W4
    /permissive-
    /Zc:__cplusplus
)
