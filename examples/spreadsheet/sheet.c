/*
 * sheet.c - portable spreadsheet engine.  No hardware access; see sheet.h.
 */
#include "sheet.h"

/* ------------------------------------------------------------------ state */

/* The persistent worksheet is one contiguous struct so it can be written to
 * and read from the disk device directly (see sheet_image_*). */
typedef struct {
    uint8_t magic0;                                /* 'M' */
    uint8_t magic1;                                /* 'C' */
    uint8_t version;
    uint8_t count;                                 /* non-empty cell count   */
    uint8_t colw[SHEET_COLS];
    Cell    pool[MAX_CELLS];
} SheetImage;

static SheetImage g_img;

#define g_pool  (g_img.pool)
#define g_colw  (g_img.colw)
#define g_count (g_img.count)

#define IMG_VERSION  1
#define DEFAULT_COLW 9
#define FMT_ERR      0x80          /* cell's formula last evaluated to error */

uint8_t sheet_last_error;

/* ------------------------------------------------------------ tiny helpers */

static uint8_t up(uint8_t c)      { return (c >= 'a' && c <= 'z') ? (uint8_t)(c - 32) : c; }
static int     is_dig(uint8_t c)  { return c >= '0' && c <= '9'; }
static int     is_alpha(uint8_t c){ c = up(c); return c >= 'A' && c <= 'Z'; }

static void s_copy(char *dst, const char *src, uint8_t max)
{
    uint8_t i = 0;
    while (i + 1 < max && src[i] != 0) { dst[i] = src[i]; ++i; }
    dst[i] = 0;
}

/* ------------------------------------------------------------- cell lookup */
/* The pool is scanned linearly.  MAX_CELLS is small (RAM-limited target), so a
 * scan is cheap and avoids a 1.5 KB index array we cannot afford in the FPGA's
 * ~24 KB of usable RAM. */

Cell *sheet_find(uint8_t col, uint8_t row)
{
    uint8_t i;
    if (col >= SHEET_COLS || row >= SHEET_ROWS) return 0;
    for (i = 0; i < MAX_CELLS; ++i) {
        Cell *c = &g_pool[i];
        if (c->kind != CK_EMPTY && c->col == col && c->row == row) return c;
    }
    return 0;
}

static Cell *alloc_cell(uint8_t col, uint8_t row)
{
    uint8_t i;
    Cell *c = sheet_find(col, row);
    if (c) return c;
    for (i = 0; i < MAX_CELLS; ++i) {
        c = &g_pool[i];
        if (c->kind == CK_EMPTY) {
            c->col = col;
            c->row = row;
            c->fmt = FMT_DEFAULT;
            c->value = 0;
            c->text[0] = 0;
            c->kind = CK_LABEL;   /* placeholder non-empty; caller sets real kind */
            ++g_count;
            return c;
        }
    }
    return 0;                     /* pool full */
}

void sheet_blank(uint8_t col, uint8_t row)
{
    Cell *c = sheet_find(col, row);
    if (!c) return;
    c->kind = CK_EMPTY;
    c->text[0] = 0;
    --g_count;
}

uint8_t sheet_count(void) { return g_count; }

/* --------------------------------------------------------------- lifecycle */

void sheet_reset(void)
{
    uint8_t k;
    for (k = 0; k < MAX_CELLS; ++k) {
        g_pool[k].kind = CK_EMPTY;      /* keep unused slots out of the image */
        g_pool[k].text[0] = 0;
    }
    g_count = 0;
    g_img.magic0 = 'M';
    g_img.magic1 = 'C';
    g_img.version = IMG_VERSION;
    for (k = 0; k < SHEET_COLS; ++k) g_colw[k] = DEFAULT_COLW;
    sheet_last_error = EV_OK;
}

uint8_t sheet_colw(uint8_t col)
{
    return (col < SHEET_COLS) ? g_colw[col] : DEFAULT_COLW;
}

void sheet_set_colw(uint8_t col, uint8_t w)
{
    if (col >= SHEET_COLS) return;
    if (w < 3) w = 3;
    if (w > 30) w = 30;
    g_colw[col] = w;
}

void sheet_set_fmt(uint8_t col, uint8_t row, uint8_t fmt)
{
    Cell *c = sheet_find(col, row);
    if (c) c->fmt = (uint8_t)((c->fmt & FMT_ERR) | (fmt & ~FMT_ERR));
}

/* --------------------------------------------------------------- numbers */

int sheet_is_number(const char *s)
{
    uint8_t i = 0;
    uint8_t digits = 0;
    uint8_t dot = 0;
    if (s[0] == '-' || s[0] == '+') i = 1;
    if (s[i] == 0) return 0;
    while (s[i]) {
        if (is_dig((uint8_t)s[i])) {
            digits = 1;
        } else if ((s[i] == '.' || s[i] == ',') && !dot) {
            dot = 1;
        } else {
            return 0;
        }
        ++i;
    }
    return digits;
}

sval sheet_parse_number(const char *s)
{
    sval n = 0, frac = 0;
    uint8_t i = 0, neg = 0, fd = 0;
    if (s[0] == '-' || s[0] == '+') { neg = (s[0] == '-'); i = 1; }
    while (is_dig((uint8_t)s[i])) { n = n * 10 + (s[i] - '0'); ++i; }
    if (s[i] == '.' || s[i] == ',') {
        ++i;
        while (is_dig((uint8_t)s[i]) && fd < 2) { frac = frac * 10 + (s[i] - '0'); ++fd; ++i; }
    }
    if (fd == 1) frac *= 10;
    n = n * 100 + frac;
    return neg ? -n : n;
}

/* Format v with exactly nd decimals (rounded), optional '$'. */
static void fmt_fixed(sval v, int nd, uint8_t currency, char *out, uint8_t maxlen)
{
    char tmp[16];
    uint8_t p = 0, o = 0;
    uint8_t neg = 0;
    sval whole, frac, scaled;

    if (v < 0) { neg = 1; v = -v; }
    if (nd == 0)      scaled = ((v + 50) / 100) * 100;
    else if (nd == 1) scaled = ((v + 5) / 10) * 10;
    else              scaled = v;
    whole = scaled / 100;
    frac  = scaled % 100;

    do { tmp[p++] = (char)('0' + (whole % 10)); whole /= 10; }
    while (whole && p < sizeof(tmp));

    if (neg && o + 1 < maxlen) out[o++] = '-';
    if (currency && o + 1 < maxlen) out[o++] = '$';
    while (p && o + 1 < maxlen) out[o++] = tmp[--p];
    if (nd >= 1 && o + 1 < maxlen) {
        out[o++] = '.';
        if (o + 1 < maxlen) out[o++] = (char)('0' + (frac / 10));
        if (nd == 2 && o + 1 < maxlen) out[o++] = (char)('0' + (frac % 10));
    }
    out[o] = 0;
}

void sheet_format_value(sval v, uint8_t fmt, char *out, uint8_t maxlen)
{
    uint8_t dm = fmt & FMT_DEC_MASK;
    uint8_t cur = (fmt & FMT_CURRENCY) ? 1 : 0;
    int nd;

    if (cur) {
        nd = 2;                              /* currency always 2 places */
    } else if (dm == FMT_GENERAL) {
        sval a = v < 0 ? -v : v;
        sval f = a % 100;
        if (f == 0)         nd = 0;
        else if (f % 10 == 0) nd = 1;
        else                nd = 2;
    } else {
        nd = dm;                             /* 0,1,2 */
    }
    fmt_fixed(v, nd, cur, out, maxlen);
}

/* --------------------------------------------------------------- references */

int sheet_parse_ref(const char *s, uint8_t *col, uint8_t *row, const char **end)
{
    uint8_t c;
    unsigned r = 0;
    uint8_t nd = 0;
    if (!is_alpha((uint8_t)s[0])) return 0;
    if (!is_dig((uint8_t)s[1]))   return 0;
    c = (uint8_t)(up((uint8_t)s[0]) - 'A');
    if (c >= SHEET_COLS) return 0;
    ++s;
    while (is_dig((uint8_t)*s) && nd < 3) { r = r * 10 + (*s - '0'); ++s; ++nd; }
    if (r < 1 || r > SHEET_ROWS) return 0;
    *col = c;
    *row = (uint8_t)(r - 1);
    if (end) *end = s;
    return 1;
}

void sheet_ref_name(uint8_t col, uint8_t row, char *out)
{
    uint8_t o = 0;
    unsigned r = (unsigned)row + 1;
    out[o++] = (char)('A' + col);
    if (r >= 10) out[o++] = (char)('0' + (r / 10));
    out[o++] = (char)('0' + (r % 10));
    out[o] = 0;
}

/* --------------------------------------------------------------- evaluator */

enum { FN_SUM, FN_AVG, FN_MIN, FN_MAX, FN_COUNT, FN_NONE };

#define LBIG 2000000000L

static const char *ep;
static uint8_t     eerr;

static sval e_expr(void);

static void eskip(void) { while (*ep == ' ') ++ep; }

static sval fpmul(sval a, sval b)
{
    uint8_t neg = 0;
    sval hi, lo;
    if (a < 0) { a = -a; neg ^= 1; }
    if (b < 0) { b = -b; neg ^= 1; }
    hi = (a / 100) * b;
    lo = ((a % 100) * b) / 100;
    return neg ? -(hi + lo) : (hi + lo);
}

static sval fpdiv(sval a, sval b)
{
    uint8_t neg = 0;
    sval q, rem;
    if (a < 0) { a = -a; neg ^= 1; }
    if (b < 0) { b = -b; neg ^= 1; }
    q   = (a / b) * 100;
    rem = ((a % b) * 100) / b;
    return neg ? -(q + rem) : (q + rem);
}

static sval e_number(void)
{
    sval n = 0, frac = 0;
    uint8_t fd = 0, any = 0;
    while (is_dig((uint8_t)*ep)) { n = n * 10 + (*ep - '0'); ++ep; any = 1; }
    if (*ep == '.' || *ep == ',') {
        ++ep;
        while (is_dig((uint8_t)*ep) && fd < 2) { frac = frac * 10 + (*ep - '0'); ++fd; ++ep; }
        while (is_dig((uint8_t)*ep)) ++ep;
        any = 1;
    }
    if (!any) { eerr = EV_ERR; return 0; }
    if (fd == 1) frac *= 10;
    return n * 100 + frac;
}

static sval apply_fn(int fn, sval acc, sval v)
{
    switch (fn) {
        case FN_SUM:
        case FN_AVG:   return acc + v;
        case FN_MIN:   return v < acc ? v : acc;
        case FN_MAX:   return v > acc ? v : acc;
        default:       return acc;
    }
}

static sval e_function(int fn)
{
    sval acc;
    long cnt = 0;

    if (fn == FN_NONE) { eerr = EV_ERR; return 0; }
    if (*ep != '(') { eerr = EV_ERR; return 0; }
    ++ep;
    acc = (fn == FN_MIN) ? LBIG : (fn == FN_MAX) ? -LBIG : 0;

    for (;;) {
        uint8_t c1, r1, c2, r2;
        const char *save, *end, *after;
        int handled = 0;

        eskip();
        save = ep;
        if (sheet_parse_ref(ep, &c1, &r1, &end)) {
            after = end;
            while (*after == ' ') ++after;
            if (*after == ':') {
                ++after;
                while (*after == ' ') ++after;
                if (sheet_parse_ref(after, &c2, &r2, &end)) {
                    uint8_t lo_c = c1 < c2 ? c1 : c2, hi_c = c1 < c2 ? c2 : c1;
                    uint8_t lo_r = r1 < r2 ? r1 : r2, hi_r = r1 < r2 ? r2 : r1;
                    uint8_t cc, rr;
                    ep = end;
                    for (rr = lo_r; rr <= hi_r; ++rr) {
                        for (cc = lo_c; cc <= hi_c; ++cc) {
                            uint8_t k = sheet_kind(cc, rr);
                            if (k == CK_EMPTY || k == CK_LABEL) continue;
                            acc = apply_fn(fn, acc, sheet_value(cc, rr));
                            ++cnt;
                        }
                    }
                    handled = 1;
                } else {
                    eerr = EV_ERR;
                    return 0;
                }
            }
            if (!handled) ep = save;   /* single ref: parse as expression below */
        }
        if (!handled) {
            acc = apply_fn(fn, acc, e_expr());
            ++cnt;
        }

        eskip();
        if (*ep == ',') { ++ep; continue; }
        if (*ep == ')') { ++ep; break; }
        eerr = EV_ERR;
        break;
    }

    if (fn == FN_COUNT) return cnt * 100;
    if (fn == FN_AVG)   return cnt ? acc / cnt : 0;
    if ((fn == FN_MIN || fn == FN_MAX) && cnt == 0) return 0;
    return acc;
}

static int match_fn(void)
{
    /* ep points at first letter; read the identifier and classify. */
    char name[10];
    uint8_t n = 0;
    while (is_alpha((uint8_t)*ep) && n < sizeof(name) - 1) name[n++] = (char)up((uint8_t)*ep++);
    name[n] = 0;
    if (n == 3 && name[0] == 'S' && name[1] == 'U' && name[2] == 'M') return FN_SUM;
    if (n == 3 && name[0] == 'A' && name[1] == 'V' && name[2] == 'G') return FN_AVG;
    if (n == 7 && name[0] == 'A' && name[1] == 'V' && name[2] == 'E') return FN_AVG;
    if (n == 3 && name[0] == 'M' && name[1] == 'I' && name[2] == 'N') return FN_MIN;
    if (n == 3 && name[0] == 'M' && name[1] == 'A' && name[2] == 'X') return FN_MAX;
    if (n == 5 && name[0] == 'C' && name[1] == 'O' && name[2] == 'U') return FN_COUNT;
    return FN_NONE;
}

static sval e_primary(void)
{
    uint8_t c;
    eskip();
    c = (uint8_t)*ep;
    if (c == '(') {
        sval v;
        ++ep;
        v = e_expr();
        eskip();
        if (*ep == ')') ++ep; else eerr = EV_ERR;
        return v;
    }
    if (c == '-') { ++ep; return -e_primary(); }
    if (c == '+') { ++ep; return e_primary(); }
    if (c == '@') { ++ep; return e_function(match_fn()); }
    if (is_alpha(c)) {
        /* single letter + digit => cell reference; otherwise function name */
        if (is_dig((uint8_t)ep[1])) {
            uint8_t col, row;
            const char *end;
            if (sheet_parse_ref(ep, &col, &row, &end)) { ep = end; return sheet_value(col, row); }
            eerr = EV_ERR;
            return 0;
        }
        return e_function(match_fn());
    }
    return e_number();
}

static sval e_term(void)
{
    sval a = e_primary();
    for (;;) {
        eskip();
        if (*ep == '*') { ++ep; a = fpmul(a, e_primary()); }
        else if (*ep == '/') {
            sval b;
            ++ep;
            b = e_primary();
            if (b == 0) { eerr = EV_DIV0; return 0; }
            a = fpdiv(a, b);
        } else break;
    }
    return a;
}

static sval e_expr(void)
{
    sval a = e_term();
    for (;;) {
        eskip();
        if (*ep == '+') { ++ep; a += e_term(); }
        else if (*ep == '-') { ++ep; a -= e_term(); }
        else break;
    }
    return a;
}

static sval eval_formula(const char *f, uint8_t *err)
{
    sval v;
    ep = f;
    eerr = EV_OK;
    v = e_expr();
    eskip();
    if (*ep != 0) eerr = EV_ERR;
    *err = eerr;
    return (eerr == EV_OK) ? v : 0;
}

/* --------------------------------------------------------------- set / get */

int sheet_set(uint8_t col, uint8_t row, const char *entry)
{
    Cell *c;
    uint8_t existed;

    if (col >= SHEET_COLS || row >= SHEET_ROWS) return -1;
    if (entry == 0 || entry[0] == 0) { sheet_blank(col, row); return 0; }

    existed = sheet_find(col, row) != 0;
    c = alloc_cell(col, row);
    if (!c) return -1;
    if (!existed) c->fmt = FMT_DEFAULT;
    c->fmt &= (uint8_t)~FMT_ERR;

    if (entry[0] == '=') {
        uint8_t i = 0;
        c->kind = CK_FORMULA;
        while (entry[i] && i + 1 < ENTRY_LEN) {
            char ch = entry[i];
            if (ch >= 'a' && ch <= 'z') ch = (char)(ch - 32);
            c->text[i] = ch;
            ++i;
        }
        c->text[i] = 0;
        c->value = eval_formula(c->text + 1, &sheet_last_error);
        if (sheet_last_error != EV_OK) c->fmt |= FMT_ERR;
    } else if (entry[0] == '"' || entry[0] == '\'') {
        c->kind = CK_LABEL;
        s_copy(c->text, entry + 1, ENTRY_LEN);
    } else if (sheet_is_number(entry)) {
        c->kind = CK_NUMBER;
        s_copy(c->text, entry, ENTRY_LEN);
        c->value = sheet_parse_number(entry);
    } else {
        c->kind = CK_LABEL;
        s_copy(c->text, entry, ENTRY_LEN);
    }
    return 0;
}

uint8_t sheet_kind(uint8_t col, uint8_t row)
{
    Cell *c = sheet_find(col, row);
    return c ? c->kind : CK_EMPTY;
}

sval sheet_value(uint8_t col, uint8_t row)
{
    Cell *c = sheet_find(col, row);
    if (!c || c->kind == CK_LABEL || c->kind == CK_EMPTY) return 0;
    return c->value;
}

/* --------------------------------------------------------------- recalc */

void sheet_recalc(void)
{
    uint8_t pass, i;
    for (pass = 0; pass < 12; ++pass) {
        uint8_t changed = 0;
        for (i = 0; i < MAX_CELLS; ++i) {
            Cell *c = &g_pool[i];
            if (c->kind == CK_FORMULA) {
                uint8_t err;
                sval v = eval_formula(c->text + 1, &err);
                if (err != EV_OK) c->fmt |= FMT_ERR; else c->fmt &= (uint8_t)~FMT_ERR;
                if (v != c->value) { c->value = v; changed = 1; }
            } else if (c->kind == CK_NUMBER) {
                c->value = sheet_parse_number(c->text);
            }
        }
        if (!changed) break;
    }
}

/* --------------------------------------------------------------- display */

void sheet_format_cell(const Cell *c, char *out, uint8_t maxlen)
{
    if (!c || c->kind == CK_EMPTY) { out[0] = 0; return; }
    if (c->kind == CK_LABEL) { s_copy(out, c->text, maxlen); return; }
    if (c->kind == CK_FORMULA && (c->fmt & FMT_ERR)) { s_copy(out, "ERR", maxlen); return; }
    sheet_format_value(c->value, c->fmt, out, maxlen);
}

void sheet_cell_display(uint8_t col, uint8_t row, char *out, uint8_t maxlen)
{
    sheet_format_cell(sheet_find(col, row), out, maxlen);
}

Cell *sheet_slot(uint8_t i)
{
    return (i < MAX_CELLS) ? &g_pool[i] : 0;
}

/* --------------------------------------------------------------- copy */

static void adjust_formula(const char *src, char *dst, int dc, int dr)
{
    uint8_t o = 0;
    const char *p = src;
    char prev = 0;
    while (*p && o + 1 < ENTRY_LEN) {
        if (is_alpha((uint8_t)*p) && is_dig((uint8_t)p[1]) && !is_alpha((uint8_t)prev)) {
            uint8_t col, row;
            const char *end;
            if (sheet_parse_ref(p, &col, &row, &end)) {
                int nc = (int)col + dc;
                int nr = (int)row + dr;
                char name[6];
                uint8_t j = 0;
                if (nc < 0) nc = 0;
                if (nc >= SHEET_COLS) nc = SHEET_COLS - 1;
                if (nr < 0) nr = 0;
                if (nr >= SHEET_ROWS) nr = SHEET_ROWS - 1;
                sheet_ref_name((uint8_t)nc, (uint8_t)nr, name);
                while (name[j] && o + 1 < ENTRY_LEN) { dst[o++] = name[j]; ++j; }
                prev = p[0];
                p = end;
                continue;
            }
        }
        prev = *p;
        dst[o++] = *p++;
    }
    dst[o] = 0;
}

int sheet_copy(uint8_t scol, uint8_t srow, uint8_t dcol, uint8_t drow)
{
    Cell *s = sheet_find(scol, srow);
    uint8_t fmt;
    if (scol >= SHEET_COLS || srow >= SHEET_ROWS ||
        dcol >= SHEET_COLS || drow >= SHEET_ROWS) return -1;
    if (!s) { sheet_blank(dcol, drow); return 0; }
    fmt = s->fmt & (uint8_t)~FMT_ERR;
    if (s->kind == CK_FORMULA) {
        char buf[ENTRY_LEN];
        adjust_formula(s->text, buf, (int)dcol - (int)scol, (int)drow - (int)srow);
        if (sheet_set(dcol, drow, buf) != 0) return -1;
    } else {
        char buf[ENTRY_LEN];
        if (s->kind == CK_LABEL) {
            buf[0] = '\'';
            s_copy(buf + 1, s->text, ENTRY_LEN - 1);
        } else {
            s_copy(buf, s->text, ENTRY_LEN);
        }
        if (sheet_set(dcol, drow, buf) != 0) return -1;
    }
    sheet_set_fmt(dcol, drow, fmt);
    return 0;
}

/* --------------------------------------------------------------- persistence */

uint8_t *sheet_image_ptr(void) { return (uint8_t *)&g_img; }
int      sheet_image_size(void) { return (int)sizeof(g_img); }

/* Stamp the header before saving.  colw and pool are already live in g_img. */
void sheet_image_prepare(void)
{
    g_img.magic0 = 'M';
    g_img.magic1 = 'C';
    g_img.version = IMG_VERSION;
    /* g_count is maintained on every add/blank. */
}

/* Validate a freshly loaded image, recompute the cell count, then recalc. */
int sheet_image_reload(int len)
{
    uint8_t slot, used;

    if (len < (int)(sizeof(g_img) - sizeof(g_img.pool))) return -1;
    if (g_img.magic0 != 'M' || g_img.magic1 != 'C' || g_img.version != IMG_VERSION)
        return -1;

    used = 0;
    for (slot = 0; slot < MAX_CELLS; ++slot) {
        Cell *c = &g_pool[slot];
        if (c->kind != CK_EMPTY && c->kind <= CK_FORMULA &&
            c->col < SHEET_COLS && c->row < SHEET_ROWS) {
            c->text[ENTRY_LEN - 1] = 0;            /* guard against bad data */
            ++used;
        } else {
            c->kind = CK_EMPTY;
            c->text[0] = 0;
        }
    }
    g_count = used;
    sheet_recalc();
    return 0;
}
