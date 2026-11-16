cmake_minimum_required(VERSION 3.20)
project(UUnlockedLauncherRelease LANGUAGES C CXX RC)

if(NOT WIN32)
    message(FATAL_ERROR "The redistributable launcher is built for Windows.")
endif()

find_package(SDL3 REQUIRED CONFIG)
get_filename_component(ENGINE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)

add_executable(u_unlocked_launcher WIN32
    "${ENGINE_ROOT}/launcher/smash/main.cpp"
    "${ENGINE_ROOT}/runtime/src/host/display_settings.cpp"
    "${ENGINE_ROOT}/runtime/src/host/controller_profiles.cpp"
    "${ENGINE_ROOT}/runtime/src/host/controller_profile_import.cpp"
    "${ENGINE_ROOT}/runtime/src/host/rooms.cpp"
    "${ENGINE_ROOT}/runtime/src/os/online_identity.cpp"
    "${ENGINE_ROOT}/runtime/src/os/sect233.cpp"
    "${ENGINE_ROOT}/runtime/src/os/act_server.cpp"
    "${ENGINE_ROOT}/runtime/src/host/http.cpp"
    "${ENGINE_ROOT}/third_party/tinyxml2/tinyxml2.cpp"
    "${ENGINE_ROOT}/runtime/res/smash.rc"
)

set_target_properties(u_unlocked_launcher PROPERTIES
    OUTPUT_NAME "U Unlocked"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/out"
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${CMAKE_BINARY_DIR}/out"
)
target_include_directories(u_unlocked_launcher PRIVATE
    "${ENGINE_ROOT}/runtime/src"
    "${ENGINE_ROOT}/third_party/tinyxml2"
)
target_include_directories(u_unlocked_launcher SYSTEM PRIVATE "${ENGINE_ROOT}/third_party/stb")
target_compile_features(u_unlocked_launcher PRIVATE cxx_std_20)
target_compile_options(u_unlocked_launcher PRIVATE /W4 /permissive- /Zc:__cplusplus /utf-8)
target_link_libraries(u_unlocked_launcher PRIVATE SDL3::SDL3 winhttp bcrypt ws2_32)
