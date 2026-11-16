cmake_minimum_required(VERSION 3.20)
project(UUnlockedControllerProfileTests LANGUAGES CXX)

include(CTest)
find_package(SDL3 REQUIRED CONFIG)

set(U_UNLOCKED_ENGINE_ROOT "${CMAKE_CURRENT_LIST_DIR}/../..")

add_executable(controller_profiles_test
    "${U_UNLOCKED_ENGINE_ROOT}/tests/controller_profiles_test.cpp"
    "${U_UNLOCKED_ENGINE_ROOT}/runtime/src/host/controller_profiles.cpp"
    "${U_UNLOCKED_ENGINE_ROOT}/runtime/src/host/controller_profile_import.cpp"
    "${U_UNLOCKED_ENGINE_ROOT}/third_party/tinyxml2/tinyxml2.cpp")

target_include_directories(controller_profiles_test PRIVATE
    "${U_UNLOCKED_ENGINE_ROOT}/runtime/src"
    "${U_UNLOCKED_ENGINE_ROOT}/third_party/tinyxml2")

target_compile_features(controller_profiles_test PRIVATE cxx_std_20)
target_link_libraries(controller_profiles_test PRIVATE SDL3::SDL3)

if(MSVC)
    target_compile_options(controller_profiles_test PRIVATE /W4 /permissive-)
else()
    target_compile_options(controller_profiles_test PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_test(NAME controller_profiles_test COMMAND controller_profiles_test)
