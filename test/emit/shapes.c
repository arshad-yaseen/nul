#include <stdbool.h>
#include <stdint.h>

typedef uint32_t nul_error;
#define nul_error_Negative ((nul_error)1)

typedef struct nul_tag_19 nul_type_19;
typedef struct nul_tag_20 nul_opt_20;
typedef struct nul_tag_24 nul_err_24;

struct nul_tag_19 {
    int64_t a;
    bool b;
};  /* Pair */
struct nul_tag_20 { bool has; int64_t value; };  /* ?i64 */
struct nul_tag_24 { nul_error err; int64_t value; };  /* !i64 */

static nul_opt_20 nul_maybe_1(int64_t t0);
static nul_err_24 nul_risky_2(int64_t t0);
static int64_t nul_main_3(void);

/* maybe */
static nul_opt_20 nul_maybe_1(int64_t t0) {
    bool t2;
    nul_opt_20 t4;
    t2 = t0 > (int64_t)0;
    if (t2) goto b1; else goto b2;
b1:;
    t4 = (nul_opt_20){ .has = true, .value = t0 };
    return t4;
b2:;
    return (nul_opt_20){ .has = false };
}

/* risky */
static nul_err_24 nul_risky_2(int64_t t0) {
    bool t2;
    nul_err_24 t4;
    nul_err_24 t7;
    t2 = t0 < (int64_t)0;
    if (t2) goto b1; else goto b2;
b1:;
    t4 = (nul_err_24){ .err = nul_error_Negative };
    return t4;
b2:;
    t7 = (nul_err_24){ .err = 0, .value = t0 };
    return t7;
}

/* main */
static int64_t nul_main_3(void) {
    nul_type_19 t1;
    nul_opt_20 t2;
    bool t3;
    int64_t* t4;
    int64_t t4_slot;
    int64_t t5;
    int64_t t8;
    nul_err_24 t9;
    bool t10;
    int64_t* t11;
    int64_t t11_slot;
    int64_t t12;
    int64_t t15;
    int64_t t16;
    int64_t t17;
    int64_t t18;
    t1 = (nul_type_19){ .a = (int64_t)20, .b = true };
    t2 = nul_maybe_1((int64_t)5);
    t3 = (t2).has;
    t4 = &t4_slot;
    if (t3) goto b1; else goto b2;
b1:;
    t5 = (t2).value;
    *t4 = t5;
    goto b3;
b2:;
    *t4 = (int64_t)0;
b3:;
    t8 = *t4;
    t9 = nul_risky_2((int64_t)3);
    t10 = (t9).err != 0;
    t11 = &t11_slot;
    if (t10) goto b5; else goto b4;
b4:;
    t12 = (t9).value;
    *t11 = t12;
    goto b6;
b5:;
    *t11 = (int64_t)0;
b6:;
    t15 = *t11;
    t16 = (t1).a;
    t17 = (int64_t)((uint64_t)t16 + (uint64_t)t8);
    t18 = (int64_t)((uint64_t)t17 + (uint64_t)t15);
    return t18;
}

int main(void) { return (int)nul_main_3(); }
