# Helpers for the four local game executables. The generated game code is compiled
# for x86-64-v3 and x86-64-v2 while the native runtime is shared.
get_filename_component(SMASH_ENGINE_ROOT "\${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)

function(add_smash_generated_variant target_name generated_sources architecture)
    add_library(\${target_name} OBJECT \${generated_sources})
    target_include_directories(\${target_name} PRIVATE "\${SMASH_ENGINE_ROOT}/runtime/include")
    target_compile_features(\${target_name} PRIVATE cxx_std_20)
    target_compile_options(\${target_name} PRIVATE
        -O2 -march=\${architecture} -fno-exceptions -Wno-unused-label)
endfunction()

function(add_smash_executable target_name output_name generated_target compatibility)
    add_executable(\${target_name}
        "\${SMASH_ENGINE_ROOT}/runtime/src/smash_main.cpp"
        "\${SMASH_ENGINE_ROOT}/runtime/src/smash_logo.cpp"
        "\${SMASH_ENGINE_ROOT}/runtime/src/smash_overlay.cpp")
    target_include_directories(\${target_name} SYSTEM PRIVATE "\${SMASH_ENGINE_ROOT}/third_party/stb")
    if(WIN32)
        target_sources(\${target_name} PRIVATE "\${SMASH_ENGINE_ROOT}/runtime/res/smash.rc")
    endif()
    target_link_libraries(\${target_name} PRIVATE cafe_runtime \${generated_target}
        $<$<PLATFORM_ID:Windows>:winmm>)
    target_compile_options(\${target_name} PRIVATE -Wall -Wextra -Wpedantic)
    if(compatibility)
        target_compile_definitions(\${target_name} PRIVATE SMASH_COMPAT)
    endif()
    set_target_properties(\${target_name} PROPERTIES OUTPUT_NAME "\${output_name}")
endfunction()

function(add_smash_game_pair prefix generated_dir output_v3 output_v2)
    if(NOT EXISTS "\${generated_dir}/sources.cmake")
        message(FATAL_ERROR "Missing cafe-recomp output: \${generated_dir}/sources.cmake")
    endif()
    include("\${generated_dir}/sources.cmake")
    set(generated_sources \${CAFE_GENERATED_SOURCES})

    add_smash_generated_variant(\${prefix}_generated_v3 "\${generated_sources}" x86-64-v3)
    add_smash_generated_variant(\${prefix}_generated_v2 "\${generated_sources}" x86-64-v2)
    add_smash_executable(\${prefix}_v3 "\${output_v3}" \${prefix}_generated_v3 FALSE)
    add_smash_executable(\${prefix}_v2 "\${output_v2}" \${prefix}_generated_v2 TRUE)
endfunction()
