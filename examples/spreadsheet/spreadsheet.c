/*
 * MultiCalc - an 80-column spreadsheet for the 6502 SBC (FPGA build).
 *
 * A Multiplan / Lotus 1-2-3 class worksheet: scrolling A1..Z60 grid, a real
 * formula engine (see sheet.c) with SUM/AVG/MIN/MAX/COUNT and ranges, cell
 * formats, adjustable column widths, relative-reference copy, and load/save to
 * disk.  The program is a cc65 PRG linked at $1000; it draws straight into the
 * VIC 80-column text RAM and reads raw keys from the VIA keyboard port.
 *
 * The pure spreadsheet logic lives in sheet.c and is unit-tested on the host.
 * This file is the UI + hardware glue.  Everything under __CC65__ is target
 * only; the drawing routines also compile on the host so the layout can be
 * rendered and reviewed without the FPGA (see tools/render_sheet.c).
 */
#include "sheet.h"

#define SCREEN_W 80
#define SCREEN_H 25

#define GUTTER   4            /* row-number gutter; data columns start here   */
#define STATUS_Y 0
#define HEAD_Y   1
#define GRID_Y   2
#define VIS_ROWS 20           /* data rows 2..21                              */
#define MSG_Y    22
#define MENU_Y   23
#define ENTRY_Y  24

/* ------------------------------------------------------------- hardware glue */

#ifdef __CC65__

#define SCR      ((unsigned char*)0x8000)
#define VIC_MODE (*(unsigned char*)0x9000)
#define VIC_CX   (*(unsigned char*)0x9001)
#define VIC_CY   (*(unsigned char*)0x9002)
#define VIC_FG   (*(unsigned char*)0x9003)
#define VIC_BG   (*(unsigned char*)0x9004)
#define VIC_ATTR (*(unsigned char*)0x9005)
#define VIC_SX   (*(unsigned char*)0x900D)
#define VIC_SY   (*(unsigned char*)0x900E)
#define VIA_DDRA (*(unsigned char*)0x8803)

#define COLOR_GREEN       5
#define COLOR_LIGHT_GREEN 13

/* Disk register block.  On the FPGA config (fpga.ini) the disk / SD-card
 * loader lives at $8824-$882F; the same device also answers the "disk MVP"
 * SAVE/LOAD command set used here (see src/diskdev.c). */
#define DISK      ((volatile unsigned char*)0x8824)
#define D_CMD     0
#define D_STATUS  1
#define D_ADDR_LO 2
#define D_ADDR_HI 3
#define D_LEN_LO  4
#define D_LEN_HI  5
#define D_ACT_LO  6
#define D_ACT_HI  7
#define D_FN_IDX  9
#define D_FN_CHR  10
#define DCMD_SAVE 1
#define DCMD_LOAD 2
#define DST_OK    2

unsigned char sbc_getch(void);

static void vic_cursor(unsigned char x, unsigned char y) { VIC_CX = x; VIC_CY = y; }

#else  /* host build: render into a plain buffer, no real I/O */

static unsigned char scr_buf[SCREEN_W * SCREEN_H];
#define SCR scr_buf
static unsigned char host_cx, host_cy;
static void vic_cursor(unsigned char x, unsigned char y) { host_cx = x; host_cy = y; }

#endif

/* ------------------------------------------------------------------- state */

static unsigned char sel_col;      /* cursor cell */
static unsigned char sel_row;
static unsigned char view_col0;    /* first visible column / row (scroll)     */
static unsigned char view_row0;
static char          message[42];
static char          entrybuf[ENTRY_LEN];

/* --------------------------------------------------------------- screen util */

static unsigned char str_len(const char *s)
{
    unsigned char n = 0;
    while (s[n]) ++n;
    return n;
}

static void put_at(unsigned char x, unsigned char y, unsigned char ch)
{
    /* The 80-column character ROM only has glyphs for upper-case letters;
     * lower-case codes render as graphics symbols.  Fold to upper case at the
     * single point where anything reaches the screen. */
    if (ch >= 'a' && ch <= 'z') ch = (unsigned char)(ch - 32);
    if (x < SCREEN_W && y < SCREEN_H) SCR[y * SCREEN_W + x] = ch;
}

static void print_at(unsigned char x, unsigned char y, const char *s)
{
    while (*s && x < SCREEN_W) { put_at(x, y, (unsigned char)*s); ++x; ++s; }
}

static void clear_line(unsigned char y)
{
    unsigned char x;
    for (x = 0; x < SCREEN_W; ++x) put_at(x, y, ' ');
}

static void clear_screen(void)
{
    unsigned int i;
    for (i = 0; i < SCREEN_W * SCREEN_H; ++i) SCR[i] = ' ';
}

/* Draw s into a field [x, x+w) with optional right alignment.  Numbers that
 * do not fit are shown as a run of '#', the way real spreadsheets do. */
static void field(unsigned char x, unsigned char y, unsigned char w,
                  const char *s, unsigned char right, unsigned char numeric)
{
    unsigned char n = str_len(s);
    unsigned char i;
    if (numeric && n > w) {
        for (i = 0; i < w; ++i) put_at(x + i, y, '#');
        return;
    }
    for (i = 0; i < w; ++i) put_at(x + i, y, ' ');
    if (n > w) n = w;
    if (right) {
        for (i = 0; i < n; ++i) put_at(x + (w - n) + i, y, (unsigned char)s[i]);
    } else {
        for (i = 0; i < n; ++i) put_at(x + i, y, (unsigned char)s[i]);
    }
}

/* ------------------------------------------------------------- column layout */

/* Return the on-screen x of a column, and how many columns are visible from
 * view_col0.  We recompute the layout each redraw; the grid is small. */
static unsigned char col_x(unsigned char col)
{
    unsigned char x = GUTTER;
    unsigned char c;
    for (c = view_col0; c < col; ++c) x += sheet_colw(c);
    return x;
}

static unsigned char last_visible_col(void)
{
    unsigned char x = GUTTER;
    unsigned char c = view_col0;
    while (c < SHEET_COLS) {
        unsigned char w = sheet_colw(c);
        if (x + w > SCREEN_W) break;
        x += w;
        ++c;
    }
    return (c > view_col0) ? (unsigned char)(c - 1) : view_col0;
}

static void ensure_visible(void)
{
    if (sel_row < view_row0) view_row0 = sel_row;
    else if (sel_row >= view_row0 + VIS_ROWS) view_row0 = (unsigned char)(sel_row - VIS_ROWS + 1);

    if (sel_col < view_col0) view_col0 = sel_col;
    else {
        while (sel_col > last_visible_col()) ++view_col0;
    }
}

/* ------------------------------------------------------------- drawing parts */

static void draw_status(void)
{
    char ref[6];
    Cell *c;
    unsigned char x;
    char info[24];
    unsigned char n, i;

    clear_line(STATUS_Y);
    sheet_ref_name(sel_col, sel_row, ref);
    print_at(0, STATUS_Y, ref);
    put_at(str_len(ref), STATUS_Y, ':');

    c = sheet_find(sel_col, sel_row);
    if (c) {
        if (c->kind == CK_LABEL) {
            put_at(str_len(ref) + 2, STATUS_Y, '"');
            print_at((unsigned char)(str_len(ref) + 3), STATUS_Y, c->text);
        } else {
            print_at((unsigned char)(str_len(ref) + 2), STATUS_Y, c->text);
        }
    }

    /* right side: name + memory gauge (used / MAX_CELLS) */
    info[0] = 0;
    {
        unsigned char cnt = sheet_count();
        char *p = info;
        const char *lbl = "MULTICALC  CELLS ";
        while (*lbl) *p++ = *lbl++;
        if (cnt >= 10) *p++ = (char)('0' + (cnt / 10) % 10);
        *p++ = (char)('0' + cnt % 10);
        *p++ = '/';
        *p++ = (char)('0' + (MAX_CELLS / 10) % 10);
        *p++ = (char)('0' + MAX_CELLS % 10);
        *p = 0;
    }
    n = str_len(info);
    x = (n < SCREEN_W) ? (unsigned char)(SCREEN_W - n) : 0;
    for (i = 0; i < n; ++i) put_at(x + i, STATUS_Y, (unsigned char)info[i]);
}

static void draw_headers(void)
{
    unsigned char c, lastc, x, w, mid;
    clear_line(HEAD_Y);
    lastc = last_visible_col();
    for (c = view_col0; c <= lastc; ++c) {
        x = col_x(c);
        w = sheet_colw(c);
        mid = (unsigned char)(x + w / 2);
        if (c == sel_col) {
            put_at((unsigned char)(mid - 1), HEAD_Y, '[');
            put_at(mid, HEAD_Y, (unsigned char)('A' + c));
            put_at((unsigned char)(mid + 1), HEAD_Y, ']');
        } else {
            put_at(mid, HEAD_Y, (unsigned char)('A' + c));
        }
    }
}

static void draw_cell(unsigned char col, unsigned char row, unsigned char y,
                      unsigned char selected)
{
    char out[ENTRY_LEN];
    unsigned char x = col_x(col);
    unsigned char w = sheet_colw(col);
    unsigned char kind = sheet_kind(col, row);
    unsigned char numeric = (kind == CK_NUMBER || kind == CK_FORMULA);

    sheet_cell_display(col, row, out, sizeof(out));
    if (selected) {
        put_at(x, y, '[');
        field((unsigned char)(x + 1), y, (unsigned char)(w - 2), out, numeric, numeric);
        put_at((unsigned char)(x + w - 1), y, ']');
    } else {
        field(x, y, w, out, numeric, numeric);
    }
}

static void draw_grid(void)
{
    unsigned char vr, r, lastc, y, i;

    lastc = last_visible_col();

    /* 1) clear the grid area and paint the row-number gutter */
    for (vr = 0; vr < VIS_ROWS; ++vr) {
        r = (unsigned char)(view_row0 + vr);
        y = (unsigned char)(GRID_Y + vr);
        clear_line(y);
        if (r >= SHEET_ROWS) continue;
        if (r == sel_row) put_at(0, y, '>');
        if (r + 1 >= 10) put_at(1, y, (unsigned char)('0' + ((r + 1) / 10)));
        put_at(2, y, (unsigned char)('0' + ((r + 1) % 10)));
    }

    /* 2) place the non-empty cells in a single pass over the pool.  This is
     *    O(cells), not O(visible positions * cells), so paging stays fast even
     *    though cell lookup is a linear scan. */
    for (i = 0; i < MAX_CELLS; ++i) {
        Cell *c = sheet_slot(i);
        char out[ENTRY_LEN];
        unsigned char x, w, numeric;
        if (c->kind == CK_EMPTY) continue;
        if (c->col < view_col0 || c->col > lastc) continue;
        if (c->row < view_row0 || c->row >= (unsigned char)(view_row0 + VIS_ROWS)) continue;
        if (c->col == sel_col && c->row == sel_row) continue;   /* drawn below */
        x = col_x(c->col);
        w = sheet_colw(c->col);
        y = (unsigned char)(GRID_Y + (c->row - view_row0));
        numeric = (unsigned char)(c->kind == CK_NUMBER || c->kind == CK_FORMULA);
        sheet_format_cell(c, out, sizeof(out));
        field(x, y, w, out, numeric, numeric);
    }

    /* 3) draw the cursor cell last, with its highlight brackets */
    if (sel_row >= view_row0 && sel_row < (unsigned char)(view_row0 + VIS_ROWS) &&
        sel_col >= view_col0 && sel_col <= lastc) {
        draw_cell(sel_col, sel_row, (unsigned char)(GRID_Y + (sel_row - view_row0)), 1);
    }
}

static void draw_menu(void)
{
    clear_line(MENU_Y);
    print_at(0, MENU_Y,
             "/ MENU   ARROWS MOVE   RET EDIT   TYPE NUMBER/LABEL/=FORMULA");
    put_at(0, MENU_Y, (unsigned char)('/' | 0x80));   /* underline the menu key */
}

static const char *const g_cmd_names[] = {
    "GOTO", "BLANK", "COPY", "WIDTH", "FORMAT", "RECALC",
    "SAVE", "LOAD", "NEW", "HELP", "QUIT"
};
#define CMD_COUNT 11

/* Write a single character underlined, using the VIC underline attribute
 * (bit 7 of the character code, enabled via VIC_ATTR bit 2). */
static void put_ul(unsigned char x, unsigned char y, unsigned char ch)
{
    if (ch >= 'a' && ch <= 'z') ch = (unsigned char)(ch - 32);
    put_at(x, y, (unsigned char)(ch | 0x80));
}

/* The "/" command bar: the command list on MENU_Y with each hot-key (the
 * first letter) underlined by the VIC's underline text attribute, the way
 * Multiplan marked its command keys. */
static void draw_command_bar(void)
{
    unsigned char i, x;
    clear_line(MSG_Y);
    clear_line(MENU_Y);
    clear_line(ENTRY_Y);
    print_at(0, MSG_Y, "SELECT A COMMAND BY ITS UNDERLINED LETTER   (ESC CANCELS)");
    print_at(0, MENU_Y, "CMD:");
    x = 5;
    for (i = 0; i < CMD_COUNT; ++i) {
        print_at(x, MENU_Y, g_cmd_names[i]);
        put_ul(x, MENU_Y, (unsigned char)g_cmd_names[i][0]);  /* underline hot key */
        x = (unsigned char)(x + str_len(g_cmd_names[i]) + 1);
    }
}

static void draw_message(void)
{
    clear_line(MSG_Y);
    print_at(0, MSG_Y, message);
}

static void draw_all(void)
{
    draw_status();
    draw_headers();
    draw_grid();
    draw_message();
    draw_menu();
    clear_line(ENTRY_Y);
    vic_cursor(col_x(sel_col), (unsigned char)(GRID_Y + (sel_row - view_row0)));
}

static void set_message(const char *m)
{
    unsigned char i = 0;
    while (m[i] && i < sizeof(message) - 1) { message[i] = m[i]; ++i; }
    message[i] = 0;
}

/* =====================================================================
 *  Everything below is target-only: keyboard editing, commands, disk I/O
 *  and main().  The host render harness calls the drawing code directly.
 * ===================================================================== */
#ifdef __CC65__

static unsigned char upcase(unsigned char ch)
{
    return (ch >= 'a' && ch <= 'z') ? (unsigned char)(ch - 32) : ch;
}

/* Line editor on the entry row.  Returns 1 on RETURN, 0 on ESC/cancel.
 * buf is prefilled with *initial and edited in place (max ENTRY_LEN). */
static unsigned char read_entry(const char *prompt, char *buf,
                                unsigned char maxlen, const char *initial,
                                unsigned char force_upper)
{
    unsigned char plen = str_len(prompt);
    unsigned char pos = 0;
    unsigned char ch;
    unsigned char x0 = plen;

    (void)force_upper;   /* the display is upper-case only; always fold input */
    clear_line(ENTRY_Y);
    print_at(0, ENTRY_Y, prompt);
    while (initial && initial[pos] && pos + 1 < maxlen) {
        buf[pos] = initial[pos];
        put_at((unsigned char)(x0 + pos), ENTRY_Y, (unsigned char)initial[pos]);
        ++pos;
    }
    buf[pos] = 0;
    put_at((unsigned char)(x0 + pos), ENTRY_Y, '_');
    vic_cursor((unsigned char)(x0 + pos), ENTRY_Y);

    for (;;) {
        ch = sbc_getch();
        if (ch == 13 || ch == 10) { put_at((unsigned char)(x0 + pos), ENTRY_Y, ' '); buf[pos] = 0; return 1; }
        if (ch == 27) { buf[0] = 0; return 0; }
        if (ch == 8 || ch == 20 || ch == 127) {
            if (pos) {
                put_at((unsigned char)(x0 + pos), ENTRY_Y, ' ');
                --pos;
                put_at((unsigned char)(x0 + pos), ENTRY_Y, '_');
                vic_cursor((unsigned char)(x0 + pos), ENTRY_Y);
            }
        } else if (ch >= 32 && ch < 127 && pos + 1 < maxlen) {
            ch = upcase(ch);
            buf[pos] = (char)ch;
            put_at((unsigned char)(x0 + pos), ENTRY_Y, ch);
            ++pos;
            put_at((unsigned char)(x0 + pos), ENTRY_Y, '_');
            vic_cursor((unsigned char)(x0 + pos), ENTRY_Y);
        }
    }
}

/* Prefill an edit of the current cell so its type is preserved. */
static void current_cell_initial(char *out)
{
    Cell *c = sheet_find(sel_col, sel_row);
    unsigned char i;
    if (!c) { out[0] = 0; return; }
    if (c->kind == CK_LABEL) {
        out[0] = '\'';
        for (i = 0; c->text[i] && i + 2 < ENTRY_LEN; ++i) out[i + 1] = c->text[i];
        out[i + 1] = 0;
    } else {
        for (i = 0; c->text[i] && i + 1 < ENTRY_LEN; ++i) out[i] = c->text[i];
        out[i] = 0;
    }
}

static void commit_entry(const char *first)
{
    char init[ENTRY_LEN];
    char pr[8];
    unsigned char upper;
    char ref[6];

    sheet_ref_name(sel_col, sel_row, ref);
    pr[0] = ref[0]; pr[1] = ref[1];
    if (ref[2]) { pr[2] = ref[2]; pr[3] = ':'; pr[4] = ' '; pr[5] = 0; }
    else        { pr[2] = ':'; pr[3] = ' '; pr[4] = 0; }

    /* Formulas and cell refs read best upper-cased; labels keep their case. */
    upper = (first[0] == '=' || first[0] == '@');
    init[0] = 0;
    if (first[0]) { init[0] = first[0]; init[1] = 0; }
    if (read_entry(pr, entrybuf, ENTRY_LEN, init, upper)) {
        if (sheet_set(sel_col, sel_row, entrybuf) != 0) {
            set_message("SHEET FULL - CELL NOT ADDED");
        } else {
            sheet_recalc();
        }
    }
}

static void edit_current(void)
{
    char init[ENTRY_LEN];
    char pr[8];
    char ref[6];

    current_cell_initial(init);
    sheet_ref_name(sel_col, sel_row, ref);
    pr[0] = ref[0]; pr[1] = ref[1];
    if (ref[2]) { pr[2] = ref[2]; pr[3] = ':'; pr[4] = ' '; pr[5] = 0; }
    else        { pr[2] = ':'; pr[3] = ' '; pr[4] = 0; }

    if (read_entry(pr, entrybuf, ENTRY_LEN, init, 0)) {
        if (sheet_set(sel_col, sel_row, entrybuf) != 0) set_message("SHEET FULL");
        else sheet_recalc();
    }
}

/* ------------------------------------------------------------ disk transfer */

static void disk_set_filename(const char *name)
{
    unsigned char i;
    for (i = 0; name[i]; ++i) {
        DISK[D_FN_IDX] = i;
        DISK[D_FN_CHR] = (unsigned char)name[i];
    }
}

/* Append ".mc" if the user gave no extension. */
static void make_fname(const char *in, char *out)
{
    unsigned char i = 0, dot = 0;
    while (in[i] && i < 20) { out[i] = in[i]; if (in[i] == '.') dot = 1; ++i; }
    if (!dot) { out[i++] = '.'; out[i++] = 'm'; out[i++] = 'c'; }
    out[i] = 0;
}

static void cmd_save(void)
{
    char raw[24];
    char name[28];
    unsigned int addr;
    int len;

    if (!read_entry("SAVE AS: ", raw, sizeof(raw), "", 0)) { set_message("SAVE CANCELLED"); return; }
    if (!raw[0]) { set_message("SAVE CANCELLED"); return; }
    make_fname(raw, name);

    sheet_image_prepare();
    addr = (unsigned int)(void*)sheet_image_ptr();
    len  = sheet_image_size();

    disk_set_filename(name);
    DISK[D_ADDR_LO] = (unsigned char)(addr & 0xFF);
    DISK[D_ADDR_HI] = (unsigned char)(addr >> 8);
    DISK[D_LEN_LO]  = (unsigned char)(len & 0xFF);
    DISK[D_LEN_HI]  = (unsigned char)((unsigned int)len >> 8);
    DISK[D_CMD]     = DCMD_SAVE;

    if (DISK[D_STATUS] & DST_OK) set_message("SAVED");
    else set_message("SAVE FAILED - DISK ERROR");
}

static void cmd_load(void)
{
    char raw[24];
    char name[28];
    unsigned int addr;
    unsigned int actual;
    int len;

    if (!read_entry("LOAD FILE: ", raw, sizeof(raw), "", 0)) { set_message("LOAD CANCELLED"); return; }
    if (!raw[0]) { set_message("LOAD CANCELLED"); return; }
    make_fname(raw, name);

    addr = (unsigned int)(void*)sheet_image_ptr();
    len  = sheet_image_size();
    disk_set_filename(name);
    DISK[D_ADDR_LO] = (unsigned char)(addr & 0xFF);
    DISK[D_ADDR_HI] = (unsigned char)(addr >> 8);
    DISK[D_LEN_LO]  = (unsigned char)(len & 0xFF);
    DISK[D_LEN_HI]  = (unsigned char)((unsigned int)len >> 8);
    DISK[D_CMD]     = DCMD_LOAD;

    if (!(DISK[D_STATUS] & DST_OK)) { set_message("LOAD FAILED - NOT FOUND"); return; }
    actual = (unsigned int)DISK[D_ACT_LO] | ((unsigned int)DISK[D_ACT_HI] << 8);
    if (sheet_image_reload((int)actual) != 0) { set_message("LOAD FAILED - BAD FILE"); return; }
    sel_col = 0; sel_row = 0; view_col0 = 0; view_row0 = 0;
    set_message("LOADED");
}

/* ---------------------------------------------------------------- commands */

static signed char read_ref(const char *prompt, unsigned char *col, unsigned char *row)
{
    char buf[8];
    const char *end;
    if (!read_entry(prompt, buf, sizeof(buf), "", 1)) return 0;
    if (!sheet_parse_ref(buf, col, row, &end)) return -1;
    return 1;
}

static void cmd_goto(void)
{
    unsigned char col, row;
    signed char r = read_ref("GOTO CELL: ", &col, &row);
    if (r == 1) { sel_col = col; sel_row = row; set_message("GOTO"); }
    else if (r < 0) set_message("BAD CELL REFERENCE");
}

static void cmd_width(void)
{
    char buf[6];
    unsigned char w = 0, i = 0;
    char ref[6];
    char pr[24];
    const char *tail = ": WIDTH (3-30): ";
    unsigned char k;
    sheet_ref_name(sel_col, sel_row, ref);
    pr[0] = 'C'; pr[1] = 'O'; pr[2] = 'L'; pr[3] = ' ';
    pr[4] = (char)('A' + sel_col); pr[5] = 0;
    for (k = 0; tail[k]; ++k) pr[5 + k] = tail[k];
    pr[5 + k] = 0;
    if (!read_entry(pr, buf, sizeof(buf), "", 0)) return;
    while (buf[i] >= '0' && buf[i] <= '9') { w = (unsigned char)(w * 10 + (buf[i] - '0')); ++i; }
    if (w) { sheet_set_colw(sel_col, w); set_message("WIDTH SET"); }
}

static void cmd_format(void)
{
    char buf[4];
    unsigned char fmt;
    if (!read_entry("FORMAT (G/0/1/2/$): ", buf, sizeof(buf), "", 1)) return;
    switch (buf[0]) {
        case 'G': fmt = FMT_GENERAL; break;
        case '0': fmt = 0; break;
        case '1': fmt = 1; break;
        case '2': fmt = 2; break;
        case '$': fmt = FMT_CURRENCY; break;
        default: set_message("BAD FORMAT"); return;
    }
    sheet_set_fmt(sel_col, sel_row, fmt);
    sheet_recalc();
    set_message("FORMAT SET");
}

static void cmd_copy(void)
{
    char buf[10];
    const char *p, *end;
    unsigned char c1, r1, c2, r2, cc, rr;
    if (!read_entry("COPY TO (cell or A1:A9): ", buf, sizeof(buf), "", 1)) return;
    p = buf;
    if (!sheet_parse_ref(p, &c1, &r1, &end)) { set_message("BAD RANGE"); return; }
    p = end;
    if (*p == ':') {
        ++p;
        if (!sheet_parse_ref(p, &c2, &r2, &end)) { set_message("BAD RANGE"); return; }
    } else { c2 = c1; r2 = r1; }
    {
        unsigned char lo_c = c1 < c2 ? c1 : c2, hi_c = c1 < c2 ? c2 : c1;
        unsigned char lo_r = r1 < r2 ? r1 : r2, hi_r = r1 < r2 ? r2 : r1;
        for (rr = lo_r; rr <= hi_r; ++rr)
            for (cc = lo_c; cc <= hi_c; ++cc)
                sheet_copy(sel_col, sel_row, cc, rr);
    }
    sheet_recalc();
    set_message("COPIED");
}

static void wait_key(void)
{
    clear_line(ENTRY_Y);
    print_at(0, ENTRY_Y, "PRESS ANY KEY");
    (void)sbc_getch();
}

static void cmd_help(void)
{
    clear_screen();
    print_at(2, 1,  "MULTICALC - QUICK REFERENCE");
    print_at(2, 3,  "MOVE      arrow keys; the sheet scrolls to follow the cursor");
    print_at(2, 4,  "ENTER     just type: 123 or 12.5 = number, letters = label,");
    print_at(2, 5,  "          =A1+B1 = formula.  RETURN re-edits, ESC cancels.");
    print_at(2, 7,  "FORMULAS  + - * / and parentheses, e.g. =(A1+A2)*B1");
    print_at(2, 8,  "FUNCTIONS =SUM(A1:A9)  AVG  MIN  MAX  COUNT  over a range");
    print_at(2, 10, "MENU  press / then the underlined letter:");
    print_at(2, 11, "   Goto  jump to a cell         Copy   copy to a cell/range");
    print_at(2, 12, "   Blank erase the cell         Width  set column width");
    print_at(2, 13, "   Format G/0/1/2/$             Recalc recalculate");
    print_at(2, 14, "   Save  write to disk          Load   read from disk");
    print_at(2, 15, "   New   empty sheet            Quit   leave MultiCalc");
    print_at(2, 17, "Cells A1..Z60, up to 80 filled, 2-decimal fixed point.");
    print_at(2, 18, "Load a sample worksheet with:  / L  then  DEMO");
    wait_key();
}

static void menu(void)
{
    unsigned char ch;

    draw_command_bar();
    vic_cursor(0, MSG_Y);
    ch = upcase(sbc_getch());
    switch (ch) {
        case 'G': cmd_goto(); break;
        case 'B': sheet_blank(sel_col, sel_row); sheet_recalc(); set_message("BLANKED"); break;
        case 'C': cmd_copy(); break;
        case 'W': cmd_width(); break;
        case 'F': cmd_format(); break;
        case 'R': sheet_recalc(); set_message("RECALCULATED"); break;
        case 'S': cmd_save(); break;
        case 'L': cmd_load(); break;
        case 'N': sheet_reset(); sel_col = 0; sel_row = 0; view_col0 = 0; view_row0 = 0;
                  set_message("NEW SHEET"); break;
        case 'H': cmd_help(); break;
        case 'Q': set_message("QUIT? PRESS Q AGAIN, ANY OTHER KEY CANCELS");
                  draw_message();
                  if (upcase(sbc_getch()) == 'Q') {
                      clear_screen();
                      print_at(2, 2, "MULTICALC ENDED.  THANK YOU.");
                      vic_cursor(0, 4);
                      for (;;) { }
                  }
                  set_message("");
                  break;
        default: set_message(""); break;
    }
}

/* ---------------------------------------------------------------- movement */

#define KEY_DOWN  0x11
#define KEY_RIGHT 0x1D
#define KEY_UP    0x91
#define KEY_LEFT  0x9D

static void welcome(void)
{
    clear_screen();
    print_at(20, 3,  "########################################");
    print_at(20, 5,  "            M U L T I C A L C           ");
    print_at(20, 7,  "     THE 80-COLUMN SPREADSHEET FOR      ");
    print_at(20, 8,  "          THE 6502 SBC SYSTEM          ");
    print_at(20, 11, "   A1..Z60   FORMULAS   SUM AVG MIN MAX ");
    print_at(20, 12, "   FORMATS   COLUMN WIDTHS   COPY       ");
    print_at(20, 13, "   LOAD AND SAVE TO DISK               ");
    print_at(20, 16, "        WRITTEN BY STEPAN.SCIENCE       ");
    print_at(20, 18, "            VERSION 1.0  -  2026         ");
    print_at(20, 21, "     PRESS ANY KEY TO BEGIN  ( ? = HELP )");
    print_at(20, 23, "########################################");
    vic_cursor(0, 24);
}

void main(void)
{
    unsigned char ch;

    VIA_DDRA = 0;
    VIC_MODE = 0;
    VIC_ATTR = 0x06;              /* 80-column text mode + underline attribute */
    VIC_FG = COLOR_LIGHT_GREEN;
    VIC_BG = COLOR_GREEN;
    VIC_SX = 0;
    VIC_SY = 0;

    sheet_reset();
    sel_col = 0; sel_row = 0; view_col0 = 0; view_row0 = 0;
    message[0] = 0;

    welcome();
    ch = sbc_getch();
    if (ch == '?') cmd_help();
    set_message("READY - TYPE A VALUE OR PRESS / FOR THE MENU");

    ensure_visible();
    draw_all();

    for (;;) {
        ch = sbc_getch();
        if (ch == KEY_LEFT) {
            if (sel_col) --sel_col;
        } else if (ch == KEY_RIGHT) {
            if (sel_col + 1 < SHEET_COLS) ++sel_col;
        } else if (ch == KEY_UP) {
            if (sel_row) --sel_row;
        } else if (ch == KEY_DOWN) {
            if (sel_row + 1 < SHEET_ROWS) ++sel_row;
        } else if (ch == 27) {
            /* terminal arrow keys arrive as ESC [ A/B/C/D (or ESC O ...) */
            unsigned char c2 = sbc_getch();
            if (c2 == '[' || c2 == 'O') {
                unsigned char c3 = sbc_getch();
                if (c3 == 'A') { if (sel_row) --sel_row; }
                else if (c3 == 'B') { if (sel_row + 1 < SHEET_ROWS) ++sel_row; }
                else if (c3 == 'C') { if (sel_col + 1 < SHEET_COLS) ++sel_col; }
                else if (c3 == 'D') { if (sel_col) --sel_col; }
            }
        } else if (ch == 13 || ch == 10) {
            edit_current();
        } else if (ch == '/') {
            menu();
        } else if (ch == '?') {
            cmd_help();
        } else if (ch >= 32 && ch < 127) {
            char first[2];
            first[0] = (char)upcase(ch); first[1] = 0;
            commit_entry(first);
        }
        ensure_visible();
        draw_all();
    }
}

#endif /* __CC65__ */

/* ---------------------------------------------------------- demo worksheet */
/* Host-only: the demo is NOT built into the PRG (to save the FPGA's scarce
 * RAM).  Instead tools/make_demo_sheet.c calls seed_demo() and writes a
 * loadable data/disk/demo.mc; the user opens it with "/ L  DEMO".  It is also
 * used by the host renderer tools/render_sheet.c. */
#ifndef __CC65__

void seed_demo(void)
{
    sheet_reset();
    sheet_set_colw(0, 14);

    sheet_set(0, 0, "'MULTICALC DEMO - Q1 BUDGET");

    sheet_set(0, 2, "'ITEM");
    sheet_set(1, 2, "'JAN");
    sheet_set(2, 2, "'FEB");
    sheet_set(3, 2, "'MAR");
    sheet_set(4, 2, "'TOTAL");

    sheet_set(0, 3, "'Sales");
    sheet_set(1, 3, "12500");  sheet_set(2, 3, "13850");  sheet_set(3, 3, "15200");
    sheet_set(4, 3, "=SUM(B4:D4)");

    sheet_set(0, 4, "'Services");
    sheet_set(1, 4, "4300");   sheet_set(2, 4, "5120");   sheet_set(3, 4, "6040");
    sheet_set(4, 4, "=SUM(B5:D5)");

    sheet_set(0, 5, "'Rent");
    sheet_set(1, 5, "-2200");  sheet_set(2, 5, "-2200");  sheet_set(3, 5, "-2200");
    sheet_set(4, 5, "=SUM(B6:D6)");

    sheet_set(0, 6, "'Payroll");
    sheet_set(1, 6, "-8400");  sheet_set(2, 6, "-8400");  sheet_set(3, 6, "-9100");
    sheet_set(4, 6, "=SUM(B7:D7)");

    sheet_set(0, 8, "'NET");
    sheet_set(1, 8, "=SUM(B4:B7)");
    sheet_set(2, 8, "=SUM(C4:C7)");
    sheet_set(3, 8, "=SUM(D4:D7)");
    sheet_set(4, 8, "=SUM(B9:D9)");

    sheet_set(0, 10, "'Avg/Month");
    sheet_set(1, 10, "=E9/3");

    sheet_set(0, 12, "'Margin %");
    sheet_set(1, 12, "=E9*100/E4");

    sheet_recalc();
}

#endif /* !__CC65__ */
