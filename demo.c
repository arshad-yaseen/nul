#include <stdbool.h>
#include <stdint.h>

typedef uint32_t nul_error;

typedef struct nul_tag_19 nul_type_19;
typedef struct nul_tag_31 nul_opt_31;
typedef struct nul_tag_32 nul_err_32;

struct nul_tag_19 {
    int64_t value;
};  /* Cell */
struct nul_tag_31 { bool has; int64_t value; };  /* ?i64 */
struct nul_tag_32 { nul_error err; int64_t value; };  /* !i64 */

static int64_t nul_expression_body_1(int64_t t0, int64_t t1);
static int64_t nul_tail_of_a_block_2(bool t0);
static int64_t nul_one_arm_leaves_3(bool t0);
static int64_t nul_both_arms_leave_4(bool t0);
static int64_t nul_through_a_capture_5(nul_opt_31 t0);
static int64_t nul_guard_6(nul_opt_31 t0);
static int64_t nul_rescue_7(nul_err_32 t0);
static int64_t nul_fallback_with_a_tail_8(nul_err_32 t0);
static void nul_statement_position_9(bool t0, nul_type_19* t1);
static void nul_dropped_10(nul_err_32 t0);
static int64_t nul_leaves_a_loop_11(int64_t t0, nul_opt_31 t1);
static int64_t nul_take_13(int64_t t0);
static int64_t nul_as_an_argument_12(bool t0);
static nul_opt_31 nul_annotated_null_14(bool t0);
static int64_t nul_every_arm_leaves_15(bool t0, bool t1);
static int64_t nul_leaving_from_an_operand_16(int64_t t0, nul_opt_31 t1);
static int64_t nul_operand_that_never_arrives_17(int64_t t0, bool t1);

/* expression_body */
static int64_t nul_expression_body_1(int64_t t0, int64_t t1) {
    int64_t t3;
    bool t4;
    int64_t t11;
    t4 = t0 > t1;
    if (t4) goto b1; else goto b2;
b1:;
    t3 = t0;
    goto b3;
b2:;
    t3 = t1;
b3:;
    t11 = t3;
    return t11;
}

/* tail_of_a_block */
static int64_t nul_tail_of_a_block_2(bool t0) {
    int64_t t2;
    int64_t t9;
    if (t0) goto b1; else goto b2;
b1:;
    t2 = (int64_t)8080;
    goto b3;
b2:;
    t2 = (int64_t)0;
b3:;
    t9 = t2;
    return t9;
}

/* one_arm_leaves */
static int64_t nul_one_arm_leaves_3(bool t0) {
    int64_t t2;
    int64_t t9;
    if (t0) goto b1; else goto b2;
b1:;
    t2 = (int64_t)1;
    goto b3;
b2:;
    return (int64_t)0;
b3:;
    t9 = t2;
    return t9;
}

/* both_arms_leave */
static int64_t nul_both_arms_leave_4(bool t0) {
    if (t0) goto b1; else goto b2;
b1:;
    return (int64_t)1;
b2:;
    return (int64_t)2;
}

/* through_a_capture */
static int64_t nul_through_a_capture_5(nul_opt_31 t0) {
    int64_t t2;
    bool t3;
    int64_t t4;
    int64_t t6;
    int64_t t12;
    t3 = (t0).has;
    if (t3) goto b1; else goto b2;
b1:;
    t4 = (t0).value;
    t6 = (int64_t)((uint64_t)t4 * (uint64_t)(int64_t)2);
    t2 = t6;
    goto b3;
b2:;
    t2 = (int64_t)0;
b3:;
    t12 = t2;
    return t12;
}

/* guard */
static int64_t nul_guard_6(nul_opt_31 t0) {
    int64_t t2;
    bool t3;
    int64_t t4;
    int64_t t7;
    t3 = (t0).has;
    if (t3) goto b1; else goto b2;
b1:;
    t4 = (t0).value;
    t2 = t4;
    goto b3;
b2:;
    return (int64_t)0;
b3:;
    t7 = t2;
    return t7;
}

/* rescue */
static int64_t nul_rescue_7(nul_err_32 t0) {
    int64_t t2;
    bool t3;
    int64_t t4;
    int64_t t7;
    t3 = (t0).err != 0;
    if (t3) goto b2; else goto b1;
b1:;
    t4 = (t0).value;
    t2 = t4;
    goto b3;
b2:;
    return (int64_t)-1;
b3:;
    t7 = t2;
    return t7;
}

/* fallback_with_a_tail */
static int64_t nul_fallback_with_a_tail_8(nul_err_32 t0) {
    int64_t t2;
    bool t3;
    int64_t t4;
    nul_error t6;
    int64_t t10;
    t3 = (t0).err != 0;
    if (t3) goto b2; else goto b1;
b1:;
    t4 = (t0).value;
    t2 = t4;
    goto b3;
b2:;
    t6 = (t0).err;
    t2 = (int64_t)8080;
b3:;
    t10 = t2;
    return t10;
}

/* statement_position */
static void nul_statement_position_9(bool t0, nul_type_19* t1) {
    int64_t* t4;
    int64_t* t8;
    if (t0) goto b1; else goto b2;
b1:;
    t4 = &(*t1).value;
    *t4 = (int64_t)1;
    goto b3;
b2:;
    t8 = &(*t1).value;
    *t8 = (int64_t)2;
b3:;
    return;
}

/* dropped */
static void nul_dropped_10(nul_err_32 t0) {
    int64_t t2;
    bool t3;
    int64_t t4;
    int64_t t7;
    t3 = (t0).err != 0;
    if (t3) goto b2; else goto b1;
b1:;
    t4 = (t0).value;
    t2 = t4;
    goto b3;
b2:;
    t2 = (int64_t)0;
b3:;
    t7 = t2;
    return;
}

/* leaves_a_loop */
static int64_t nul_leaves_a_loop_11(int64_t t0, nul_opt_31 t1) {
    int64_t t3;
    int64_t t5;
    int64_t t7;
    bool t8;
    int64_t t10;
    int64_t t11;
    int64_t t13;
    bool t14;
    int64_t t30;
    int64_t t15;
    int64_t t18;
    int64_t t19;
    bool t20;
    int64_t t24;
    int64_t t25;
    int64_t t26;
    int64_t t27;
    t3 = (int64_t)0;
    t5 = (int64_t)0;
b1:;
    t7 = t5;
    t8 = t7 < t0;
    if (t8) goto b2; else goto b3;
b2:;
    t10 = t5;
    t11 = (int64_t)((uint64_t)t10 + (uint64_t)(int64_t)1);
    t5 = t11;
    t14 = (t1).has;
    if (t14) goto b4; else goto b5;
b3:;
    t30 = t3;
    return t30;
b4:;
    t15 = (t1).value;
    t13 = t15;
    goto b6;
b5:;
    goto b3;
b6:;
    t18 = t13;
    t19 = t5;
    t20 = t19 == (int64_t)3;
    if (t20) goto b7; else goto b8;
b7:;
    goto b1;
b8:;
    t24 = t3;
    t25 = t5;
    t26 = (int64_t)((uint64_t)t18 * (uint64_t)t25);
    t27 = (int64_t)((uint64_t)t24 + (uint64_t)t26);
    t3 = t27;
    goto b1;
}

/* take */
static int64_t nul_take_13(int64_t t0) {
    return t0;
}

/* as_an_argument */
static int64_t nul_as_an_argument_12(bool t0) {
    int64_t t2;
    int64_t t9;
    int64_t t10;
    if (t0) goto b1; else goto b2;
b1:;
    t2 = (int64_t)1;
    goto b3;
b2:;
    t2 = (int64_t)2;
b3:;
    t9 = t2;
    t10 = nul_take_13(t9);
    return t10;
}

/* annotated_null */
static nul_opt_31 nul_annotated_null_14(bool t0) {
    nul_opt_31 t2;
    nul_opt_31 t8;
    nul_opt_31 t10;
    if (t0) goto b1; else goto b2;
b1:;
    t2 = (nul_opt_31){ .has = false };
    goto b3;
b2:;
    t8 = (nul_opt_31){ .has = true, .value = (int64_t)5 };
    t2 = t8;
b3:;
    t10 = t2;
    return t10;
}

/* every_arm_leaves */
static int64_t nul_every_arm_leaves_15(bool t0, bool t1) {
    int64_t t3;
    int64_t t5;
    int64_t t18;
    if (t0) goto b1; else goto b2;
b1:;
    if (t1) goto b4; else goto b5;
b2:;
    t3 = (int64_t)3;
    t18 = t3;
    return t18;
b4:;
    return (int64_t)1;
b5:;
    return (int64_t)2;
}

/* leaving_from_an_operand */
static int64_t nul_leaving_from_an_operand_16(int64_t t0, nul_opt_31 t1) {
    int64_t t3;
    bool t4;
    int64_t t5;
    int64_t t8;
    int64_t t9;
    int64_t t10;
    t4 = (t1).has;
    if (t4) goto b1; else goto b2;
b1:;
    t5 = (t1).value;
    t3 = t5;
    goto b3;
b2:;
    return (int64_t)0;
b3:;
    t8 = t3;
    t9 = (int64_t)((uint64_t)t8 + (uint64_t)(int64_t)1);
    t10 = (int64_t)((uint64_t)t9 + (uint64_t)t0);
    return t10;
}

/* operand_that_never_arrives */
static int64_t nul_operand_that_never_arrives_17(int64_t t0, bool t1) {
    bool t3;
    if (t1) goto b1; else goto b2;
b1:;
    return (int64_t)1;
b2:;
    return (int64_t)2;
}

