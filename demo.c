#include <stdbool.h>
#include <stdint.h>

typedef uint32_t nul_error;
#define nul_error_Nice ((nul_error)1)

typedef struct nul_tag_19 nul_err_19;

struct nul_tag_19 { nul_error err; int64_t value; };  /* !i64 */

static nul_err_19 nul_count_up_0(int64_t t0);
static int64_t nul_main_1(void);

/* count_up */
static nul_err_19 nul_count_up_0(int64_t t0) {
    nul_err_19 t2;
    t2 = (nul_err_19){ .err = nul_error_Nice };
    return t2;
}

/* main */
static int64_t nul_main_1(void) {
    nul_err_19 t1;
    bool t2;
    int64_t* t3;
    int64_t t3_slot;
    int64_t t4;
    int64_t t7;
    t1 = nul_count_up_0((int64_t)100);
    t2 = (t1).err != 0;
    t3 = &t3_slot;
    if (t2) goto b2; else goto b1;
b1:;
    t4 = (t1).value;
    *t3 = t4;
    goto b3;
b2:;
    *t3 = (int64_t)0;
b3:;
    t7 = *t3;
    return t7;
}

int main(void) { return (int)nul_main_1(); }
