#pragma once
// Whether this processor and operating system can run x86-64-v3 code. The v3 level includes AVX2, FMA, F16C,
// BMI1/2, LZCNT and MOVBE in addition to the x86-64-v2 baseline. Check OSXSAVE/XCR0 as well as CPU feature bits.

#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
#include <intrin.h>
#elif defined(__GNUC__) && (defined(__x86_64__) || defined(__i386__))
#endif

#include <cstdint>

namespace cafe::host {

inline bool cpu_has_x86_64_v3() {
#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
    int registers[4]{};
    __cpuid(registers, 0);
    if (registers[0] < 7) return false;

    __cpuidex(registers, 1, 0);
    const uint32_t ecx = static_cast<uint32_t>(registers[2]);
    const uint32_t edx = static_cast<uint32_t>(registers[3]);
    constexpr uint32_t required_ecx =
        (1u << 0)  | // SSE3
        (1u << 9)  | // SSSE3
        (1u << 12) | // FMA
        (1u << 13) | // CMPXCHG16B
        (1u << 19) | // SSE4.1
        (1u << 20) | // SSE4.2
        (1u << 22) | // MOVBE
        (1u << 23) | // POPCNT
        (1u << 27) | // OSXSAVE
        (1u << 28) | // AVX
        (1u << 29);  // F16C
    if ((ecx & required_ecx) != required_ecx || (edx & (1u << 26)) == 0) return false; // SSE2

    __cpuidex(registers, 7, 0);
    const uint32_t ebx = static_cast<uint32_t>(registers[1]);
    constexpr uint32_t required_ebx = (1u << 3) | (1u << 5) | (1u << 8); // BMI1, AVX2, BMI2
    if ((ebx & required_ebx) != required_ebx) return false;

    __cpuid(registers, static_cast<int>(0x80000000u));
    if (static_cast<uint32_t>(registers[0]) < 0x80000001u) return false;
    __cpuid(registers, static_cast<int>(0x80000001u));
    const uint32_t extended_ecx = static_cast<uint32_t>(registers[2]);
    constexpr uint32_t required_extended_ecx = (1u << 0) | (1u << 5); // LAHF/SAHF, LZCNT
    if ((extended_ecx & required_extended_ecx) != required_extended_ecx) return false;

    // AVX state must be enabled by the OS (XMM and YMM state components).
    return (_xgetbv(0) & 0x6u) == 0x6u;
#elif defined(__GNUC__) && (defined(__x86_64__) || defined(__i386__))
    __builtin_cpu_init();
    return __builtin_cpu_supports("x86-64-v3");
#else
    return false;
#endif
}

} // namespace cafe::host
