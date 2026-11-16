cmake_minimum_required(VERSION 3.20)
project(UUnlockedWuaExtractorCompile LANGUAGES C CXX)

if(NOT WIN32)
    message(FATAL_ERROR "This compile check is intended for Windows.")
endif()

set(BUILD_STATIC_TOOL OFF CACHE BOOL "Do not build ZArchive's standalone CLI" FORCE)
add_subdirectory("${CMAKE_CURRENT_LIST_DIR}/../../third_party/ZArchive"
                 "${CMAKE_CURRENT_BINARY_DIR}/zarchive")

add_executable(wua_extract_compile
    "${CMAKE_CURRENT_LIST_DIR}/../../tools/wua_extract_windows.cpp")
target_compile_features(wua_extract_compile PRIVATE cxx_std_20)
target_link_libraries(wua_extract_compile PRIVATE ZArchive::zarchive)
set_target_properties(wua_extract_compile PROPERTIES MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
target_compile_options(wua_extract_compile PRIVATE /W4 /permissive-)
