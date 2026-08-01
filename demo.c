#include <stdbool.h>
#include <stdint.h>

typedef uint32_t nul_error;

static int64_t nul_count_up_0(int64_t t0);
static int64_t nul_main_1(void);

/* count_up */
static int64_t nul_count_up_0(int64_t t0) {
    int64_t* t2;
    int64_t t2_slot;
    int64_t t4;
    bool t5;
    int64_t t7;
    int64_t t8;
    int64_t t11;
    t2 = &t2_slot;
    *t2 = (int64_t)0;
b1:;
    t4 = *t2;
    t5 = t4 < t0;
    if (t5) goto b2; else goto b3;
b2:;
    t7 = *t2;
    t8 = (int64_t)((uint64_t)t7 + (uint64_t)(int64_t)1);
    *t2 = t8;
    goto b1;
b3:;
    t11 = *t2;
    return t11;
}

/* main */
static int64_t nul_main_1(void) {
    int64_t t1;
    t1 = nul_count_up_0((int64_t)100);
    return t1;
}

int main(void) { return (int)nul_main_1(); }
