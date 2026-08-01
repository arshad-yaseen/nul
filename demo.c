#include <stdbool.h>
#include <stdint.h>

typedef uint32_t nul_error;




static int64_t nul_main_0(void);

/* main */
static int64_t nul_main_0(void) {
    if (true) goto b1; else goto b2;
b1:;
    return (int64_t)60ULL;
b2:;
    goto b3;
b3:;
    return (int64_t)42ULL;
}

int main(void) { return (int)nul_main_0(); }
