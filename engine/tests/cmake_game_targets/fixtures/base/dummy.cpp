#include "cafe/generated.h"

extern "C" {
extern const cafe::GuestFunction cafe_guest_functions[] = {
    {0, nullptr},
};
extern const size_t cafe_guest_function_count = 0;

extern const cafe::GuestImport cafe_guest_imports[] = {
    {nullptr, nullptr, 0, 0, nullptr, false},
};
extern const size_t cafe_guest_import_count = 0;

extern const cafe::ProgramInfo cafe_program_info = {
    "0000000000000000000000000000000000000000000000000000000000000000",
    0,
    0,
    0,
    0,
    0,
    0,
    0,
};
}

extern "C" int u_unlocked_base_fixture() { return 0; }
