#include <stdbool.h>
#include <stdint.h>

typedef uint32_t nul_error;

static uint8_t nul_narrowing_0(void);

/* narrowing */
static uint8_t nul_narrowing_0(void) {
    if (true) goto b1; else goto b2;
b1:;
    return (uint8_t)200;
b2:;
    return (uint8_t)10;
}

