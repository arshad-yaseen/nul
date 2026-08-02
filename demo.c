#include <stdbool.h>
#include <stdint.h>

typedef uint32_t nul_error;

static int64_t nul_main_0(void);

/* main */
static int64_t nul_main_0(void) {
    int64_t t1;
    int64_t t8;
    if (true) goto b1; else goto b2;
b1:;
    t1 = (int64_t)5;
    goto b3;
b2:;
    t1 = (int64_t)10;
b3:;
    t8 = t1;
    return t8;
}

int main(void) { return (int)nul_main_0(); }
