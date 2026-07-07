/*
 * Host-side unit tests for the portable MultiCalc spreadsheet engine
 * (examples/spreadsheet/sheet.c).  Exercises references, number parse/format,
 * formula precedence/parentheses/functions/ranges, recalc dependency
 * propagation, relative copy, and the save/load round trip.
 */
#include "sheet.h"
#include <stdio.h>
#include <string.h>

static int g_fail = 0;
static int g_pass = 0;

static void check(int cond, const char *msg)
{
    if (cond) { ++g_pass; }
    else { ++g_fail; printf("FAIL: %s\n", msg); }
}

static void check_str(const char *got, const char *want, const char *msg)
{
    if (strcmp(got, want) == 0) { ++g_pass; }
    else { ++g_fail; printf("FAIL: %s (got \"%s\" want \"%s\")\n", msg, got, want); }
}

/* helper: set cell by "A1" style name */
static void put(const char *ref, const char *entry)
{
    uint8_t c, r;
    const char *end;
    sheet_parse_ref(ref, &c, &r, &end);
    sheet_set(c, r, entry);
}

static long val(const char *ref)
{
    uint8_t c, r;
    const char *end;
    sheet_parse_ref(ref, &c, &r, &end);
    return sheet_value(c, r);
}

static void disp(const char *ref, char *out)
{
    uint8_t c, r;
    const char *end;
    sheet_parse_ref(ref, &c, &r, &end);
    sheet_cell_display(c, r, out, 32);
}

static void test_refs(void)
{
    uint8_t c, r;
    const char *end;
    char name[8];

    check(sheet_parse_ref("A1", &c, &r, &end) && c == 0 && r == 0, "parse A1");
    check(sheet_parse_ref("Z60", &c, &r, &end) && c == 25 && r == 59, "parse Z60");
    check(sheet_parse_ref("b12", &c, &r, &end) && c == 1 && r == 11, "parse lowercase b12");
    check(*end == 0, "parse end after b12");
    check(!sheet_parse_ref("A0", &c, &r, &end), "reject A0");
    check(!sheet_parse_ref("A99", &c, &r, &end), "reject A99 (>60)");
    check(!sheet_parse_ref("1A", &c, &r, &end), "reject 1A");

    sheet_ref_name(0, 0, name);   check_str(name, "A1", "name A1");
    sheet_ref_name(25, 59, name); check_str(name, "Z60", "name Z60");
    sheet_ref_name(2, 11, name);  check_str(name, "C12", "name C12");
}

static void test_numbers(void)
{
    char out[32];
    check(sheet_is_number("12"), "is_number 12");
    check(sheet_is_number("-3.5"), "is_number -3.5");
    check(sheet_is_number("1,25"), "is_number 1,25 (comma)");
    check(!sheet_is_number("12a"), "not number 12a");
    check(!sheet_is_number(""), "not number empty");
    check(!sheet_is_number("A1"), "not number A1");

    check(sheet_parse_number("12") == 1200, "parse 12 -> 1200");
    check(sheet_parse_number("12.5") == 1250, "parse 12.5 -> 1250");
    check(sheet_parse_number("12,05") == 1205, "parse 12,05 -> 1205");
    check(sheet_parse_number("-0.99") == -99, "parse -0.99 -> -99");

    sheet_format_value(1200, FMT_GENERAL, out, sizeof(out));  check_str(out, "12", "fmt general 12");
    sheet_format_value(1250, FMT_GENERAL, out, sizeof(out));  check_str(out, "12.5", "fmt general 12.5");
    sheet_format_value(1205, FMT_GENERAL, out, sizeof(out));  check_str(out, "12.05", "fmt general 12.05");
    sheet_format_value(1205, 2, out, sizeof(out));            check_str(out, "12.05", "fmt 2dp 12.05");
    sheet_format_value(1205, 0, out, sizeof(out));            check_str(out, "12", "fmt 0dp rounds 12");
    sheet_format_value(1255, 0, out, sizeof(out));            check_str(out, "13", "fmt 0dp rounds up 13");
    sheet_format_value(1250, 1, out, sizeof(out));            check_str(out, "12.5", "fmt 1dp 12.5");
    sheet_format_value(-99, 2, out, sizeof(out));             check_str(out, "-0.99", "fmt -0.99");
    sheet_format_value(150000, FMT_CURRENCY, out, sizeof(out)); check_str(out, "$1500.00", "fmt currency");
}

static void test_formulas(void)
{
    char out[32];
    sheet_reset();
    put("A1", "10");
    put("A2", "20");
    put("A3", "=A1+A2");
    put("A4", "=A1*A2");
    put("A5", "=A2/A1");
    put("A6", "=A1+A2*2");        /* precedence: 10 + 40 = 50 */
    put("A7", "=(A1+A2)*2");      /* parens: 60 */
    put("A8", "=-A1");
    sheet_recalc();

    check(val("A3") == 3000, "A1+A2 = 30");
    check(val("A4") == 20000, "A1*A2 = 200");
    check(val("A5") == 200, "A2/A1 = 2");
    check(val("A6") == 5000, "precedence 10+20*2 = 50");
    check(val("A7") == 6000, "parens (10+20)*2 = 60");
    check(val("A8") == -1000, "unary minus -10");

    put("B1", "3.5");
    put("B2", "2");
    put("B3", "=B1*B2");          /* 7.00 */
    sheet_recalc();
    check(val("B3") == 700, "3.5*2 = 7");

    put("C1", "=5/0");
    sheet_recalc();
    disp("C1", out);
    check_str(out, "ERR", "division by zero shows ERR");

    put("D1", "=BOGUS(");
    sheet_recalc();
    disp("D1", out);
    check_str(out, "ERR", "bad function shows ERR");
}

static void test_functions(void)
{
    sheet_reset();
    put("A1", "10"); put("A2", "20"); put("A3", "30"); put("A4", "40");
    put("A5", "=SUM(A1:A4)");
    put("A6", "=AVG(A1:A4)");
    put("A7", "=MIN(A1:A4)");
    put("A8", "=MAX(A1:A4)");
    put("A9", "=COUNT(A1:A4)");
    put("A10", "=SUM(A1:A4)/COUNT(A1:A4)");
    put("A11", "=@SUM(A1:A2)+100");
    sheet_recalc();

    check(val("A5") == 10000, "SUM(A1:A4) = 100");
    check(val("A6") == 2500, "AVG(A1:A4) = 25");
    check(val("A7") == 1000, "MIN = 10");
    check(val("A8") == 4000, "MAX = 40");
    check(val("A9") == 400, "COUNT = 4");
    check(val("A10") == 2500, "SUM/COUNT = 25");
    check(val("A11") == 13000, "@SUM(A1:A2)+100 = 130");

    /* label inside range is skipped */
    put("B1", "5"); put("B2", "hi"); put("B3", "15");
    put("B4", "=SUM(B1:B3)");
    put("B5", "=COUNT(B1:B3)");
    sheet_recalc();
    check(val("B4") == 2000, "SUM skips label = 20");
    check(val("B5") == 200, "COUNT skips label = 2");
}

static void test_recalc_chain(void)
{
    /* Out-of-order dependency chain must converge. */
    sheet_reset();
    put("A5", "=A4+1");
    put("A4", "=A3+1");
    put("A3", "=A2+1");
    put("A2", "=A1+1");
    put("A1", "1");
    sheet_recalc();
    check(val("A2") == 200, "chain A2 = 2");
    check(val("A5") == 500, "chain A5 = 5");

    /* editing a leaf propagates on next recalc */
    put("A1", "10");
    sheet_recalc();
    check(val("A5") == 1400, "chain after edit A5 = 14");
}

static void test_copy(void)
{
    char out[32];
    sheet_reset();
    put("A1", "1"); put("B1", "2");
    put("C1", "=A1+B1");
    /* copy C1 down to C2..C3 should adjust to A2+B2 etc. */
    put("A2", "10"); put("B2", "20");
    put("A3", "100"); put("B3", "200");
    sheet_copy(2, 0, 2, 1);   /* C1 -> C2 */
    sheet_copy(2, 0, 2, 2);   /* C1 -> C3 */
    sheet_recalc();

    check(val("C1") == 300, "C1 = 3");
    check(val("C2") == 3000, "copied C2 = A2+B2 = 30");
    check(val("C3") == 30000, "copied C3 = A3+B3 = 300");

    /* the copied formula text is adjusted */
    {
        uint8_t c, r; const char *end;
        Cell *cell;
        sheet_parse_ref("C3", &c, &r, &end);
        cell = sheet_find(c, r);
        check_str(cell->text, "=A3+B3", "copied formula text adjusted");
    }

    /* copy label carries text */
    put("D1", "Total");
    sheet_copy(3, 0, 3, 4);   /* D1 -> D5 */
    disp("D5", out);
    check_str(out, "Total", "copied label");
}

static void test_persistence(void)
{
    static uint8_t snapshot[8192];
    int n;
    char out[32];

    sheet_reset();
    put("A1", "100"); put("A2", "200");
    put("A3", "=SUM(A1:A2)");
    put("B1", "Sales");
    sheet_set_colw(0, 12);
    sheet_set_fmt(0, 0, FMT_CURRENCY);
    sheet_recalc();

    /* Emulate a disk save: stamp header, copy the raw image out. */
    sheet_image_prepare();
    n = sheet_image_size();
    check(n > 0 && n <= (int)sizeof(snapshot), "image size sane");
    memcpy(snapshot, sheet_image_ptr(), (size_t)n);

    /* wipe, then emulate a disk load: copy the raw image back and reload. */
    sheet_reset();
    check(val("A3") == 0, "sheet cleared before load");
    memcpy(sheet_image_ptr(), snapshot, (size_t)n);
    check(sheet_image_reload(n) == 0, "image reload ok");

    check(val("A1") == 10000, "restored A1 = 100");
    check(val("A3") == 30000, "restored formula A3 = 300");
    check(sheet_colw(0) == 12, "restored column width");
    check(sheet_count() == 4, "restored cell count");
    disp("B1", out);
    check_str(out, "Sales", "restored label");
    disp("A1", out);
    check_str(out, "$100.00", "restored currency format");

    /* a bad magic must be rejected */
    snapshot[0] = 'X';
    memcpy(sheet_image_ptr(), snapshot, (size_t)n);
    check(sheet_image_reload(n) == -1, "bad image rejected");
}

static void test_capacity(void)
{
    int i, rc = 0;
    sheet_reset();
    /* Fill the pool; the (MAX_CELLS+1)-th distinct cell must fail cleanly. */
    for (i = 0; i < MAX_CELLS + 5; ++i) {
        uint8_t col = (uint8_t)(i % SHEET_COLS);
        uint8_t row = (uint8_t)(i / SHEET_COLS);
        if (row >= SHEET_ROWS) break;
        if (sheet_set(col, row, "1") != 0) { rc = 1; break; }
    }
    check(rc == 1, "pool full is reported, no overflow");
    check(sheet_count() == MAX_CELLS, "count capped at MAX_CELLS");
}

int main(void)
{
    test_refs();
    test_numbers();
    test_formulas();
    test_functions();
    test_recalc_chain();
    test_copy();
    test_persistence();
    test_capacity();

    printf("\n%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
