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

/* Raw SD2 sector controller at $88C0-$88CF.  The FPGA side buffers one 512-byte
 * sector; software streams bytes through DATA and then starts a read/write CMD. */
#define SDRAW      ((volatile unsigned char*)0x88C0)
#define SD_CMD     0
#define SD_STATUS  1
#define SD_LBA0    2
#define SD_LBA1    3
#define SD_LBA2    4
#define SD_LBA3    5
#define SD_DATA    6
#define SD_DPTR_L  7
#define SD_DPTR_H  8
#define SDC_READ   1
#define SDC_WRITE  2
#define SDS_BUSY   1
#define SDS_ERROR  2
#define SDS_READY  4
#define SDS_INIT   0x80

#define SHEET_SLOT_LBA 225U

unsigned char sbc_getch(void);
void sbc_basic(void);

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
#ifdef __CC65__
static char          entrybuf[ENTRY_LEN];
static unsigned char quit_requested;
#endif

/* --------------------------------------------------------------- screen util */

static unsigned char str_len(const char *s)
{
    unsigned char n = 0;
    while (s[n]) ++n;
    return n;
}

static void put_at(unsigned char x, unsigned char y, unsigned char ch)
{
    unsigned int i;

    /* The 80-column character ROM only has glyphs for upper-case letters;
     * lower-case codes render as graphics symbols.  Fold to upper case at the
     * single point where anything reaches the screen. */
    if (ch >= 'a' && ch <= 'z') ch = (unsigned char)(ch - 32);
    if (x < SCREEN_W && y < SCREEN_H) {
        i = (unsigned int)y * SCREEN_W + x;
        if (SCR[i] != ch) SCR[i] = ch;
    }
}

static void line_clear(char *line)
{
    unsigned char x;
    for (x = 0; x < SCREEN_W; ++x) line[x] = ' ';
}

static void line_put(char *line, unsigned char x, unsigned char ch)
{
    if (x < SCREEN_W) line[x] = (char)ch;
}

static void line_print(char *line, unsigned char x, const char *s)
{
    while (*s && x < SCREEN_W) {
        line_put(line, x, (unsigned char)*s);
        ++x;
        ++s;
    }
}

static void line_field(char *line, unsigned char x, unsigned char w,
                       const char *s, unsigned char right,
                       unsigned char numeric)
{
    unsigned char n = str_len(s);
    unsigned char i, start;

    if (numeric && n > w) {
        for (i = 0; i < w; ++i) line_put(line, (unsigned char)(x + i), '#');
        return;
    }

    if (n > w) n = w;
    start = right ? (unsigned char)(w - n) : 0;
    for (i = 0; i < w; ++i) {
        unsigned char ch = ' ';
        if (i >= start && i < (unsigned char)(start + n)) {
            ch = (unsigned char)s[i - start];
        }
        line_put(line, (unsigned char)(x + i), ch);
    }
}

static void flush_line(unsigned char y, const char *line)
{
    unsigned char x;
    for (x = 0; x < SCREEN_W; ++x) put_at(x, y, (unsigned char)line[x]);
}

static void draw_text_line(unsigned char y, const char *s)
{
    char line[SCREEN_W];
    line_clear(line);
    line_print(line, 0, s);
    flush_line(y, line);
}

static void clear_line(unsigned char y)
{
    unsigned char x;
    for (x = 0; x < SCREEN_W; ++x) put_at(x, y, ' ');
}

#ifdef __CC65__
static void print_at(unsigned char x, unsigned char y, const char *s)
{
    while (*s && x < SCREEN_W) { put_at(x, y, (unsigned char)*s); ++x; ++s; }
}

static void clear_screen(void)
{
    unsigned int i;
    for (i = 0; i < SCREEN_W * SCREEN_H; ++i) SCR[i] = ' ';
}
#endif

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
    char line[SCREEN_W];
    char ref[6];
    Cell *c;
    unsigned char x;
    char info[24];
    unsigned char n, i;

    line_clear(line);
    sheet_ref_name(sel_col, sel_row, ref);
    line_print(line, 0, ref);
    line_put(line, str_len(ref), ':');

    c = sheet_find(sel_col, sel_row);
    if (c) {
        if (c->kind == CK_LABEL) {
            line_put(line, (unsigned char)(str_len(ref) + 2), '"');
            line_print(line, (unsigned char)(str_len(ref) + 3), c->text);
        } else {
            line_print(line, (unsigned char)(str_len(ref) + 2), c->text);
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
    for (i = 0; i < n; ++i) line_put(line, (unsigned char)(x + i), (unsigned char)info[i]);
    flush_line(STATUS_Y, line);
}

static void draw_headers(void)
{
    char line[SCREEN_W];
    unsigned char c, lastc, x, w, mid;

    line_clear(line);
    lastc = last_visible_col();
    for (c = view_col0; c <= lastc; ++c) {
        x = col_x(c);
        w = sheet_colw(c);
        mid = (unsigned char)(x + w / 2);
        if (c == sel_col) {
            line_put(line, (unsigned char)(mid - 1), '[');
            line_put(line, mid, (unsigned char)('A' + c));
            line_put(line, (unsigned char)(mid + 1), ']');
        } else {
            line_put(line, mid, (unsigned char)('A' + c));
        }
    }
    flush_line(HEAD_Y, line);
}

static void draw_grid_row(unsigned char row)
{
    char line[SCREEN_W];
    char out[ENTRY_LEN];
    unsigned char lastc, y, i, x, w, numeric;
    Cell *cell, *selected_cell = 0;

    if (row < view_row0 || row >= (unsigned char)(view_row0 + VIS_ROWS)) return;
    y = (unsigned char)(GRID_Y + (row - view_row0));
    line_clear(line);
    if (row >= SHEET_ROWS) {
        flush_line(y, line);
        return;
    }

    if (row == sel_row) line_put(line, 0, '>');
    if (row + 1 >= 10) line_put(line, 1, (unsigned char)('0' + ((row + 1) / 10)));
    line_put(line, 2, (unsigned char)('0' + ((row + 1) % 10)));

    lastc = last_visible_col();
    for (i = 0; i < MAX_CELLS; ++i) {
        cell = sheet_slot(i);
        if (cell->kind == CK_EMPTY) continue;
        if (cell->row != row) continue;
        if (cell->col < view_col0 || cell->col > lastc) continue;
        if (cell->col == sel_col && cell->row == sel_row) {
            selected_cell = cell;
            continue;
        }

        x = col_x(cell->col);
        w = sheet_colw(cell->col);
        numeric = (unsigned char)(cell->kind == CK_NUMBER || cell->kind == CK_FORMULA);
        sheet_format_cell(cell, out, sizeof(out));
        line_field(line, x, w, out, numeric, numeric);
    }

    if (row == sel_row && sel_col >= view_col0 && sel_col <= lastc) {
        x = col_x(sel_col);
        w = sheet_colw(sel_col);
        if (selected_cell) {
            numeric = (unsigned char)(selected_cell->kind == CK_NUMBER ||
                                      selected_cell->kind == CK_FORMULA);
            sheet_format_cell(selected_cell, out, sizeof(out));
        } else {
            numeric = 0;
            out[0] = 0;
        }
        line_put(line, x, '[');
        line_field(line, (unsigned char)(x + 1), (unsigned char)(w - 2),
                   out, numeric, numeric);
        line_put(line, (unsigned char)(x + w - 1), ']');
    }
    flush_line(y, line);
}

static void draw_grid(void)
{
    unsigned char vr;
    for (vr = 0; vr < VIS_ROWS; ++vr)
        draw_grid_row((unsigned char)(view_row0 + vr));
}

static void draw_menu(void)
{
    draw_text_line(MENU_Y,
                   "/ MENU   ARROWS MOVE   RET EDIT   TYPE NUMBER/LABEL/=FORMULA");
    put_at(0, MENU_Y, (unsigned char)('/' | 0x80));   /* underline the menu key */
}

static const char *const g_cmd_names[] = {
    "GOTO", "BLANK", "COPY", "WIDTH", "FORMAT", "RECALC",
    "SAVE", "LOAD", "NEW", "HELP", "QUIT"
};
#define CMD_COUNT 11

/* The "/" command bar: the command list on MENU_Y with each hot-key (the
 * first letter) underlined by the VIC's underline text attribute, the way
 * Multiplan marked its command keys. */
static void draw_command_bar(void)
{
    char line[SCREEN_W];
    unsigned char i, x;

    draw_text_line(MSG_Y, "SELECT A COMMAND BY ITS UNDERLINED LETTER   (ESC CANCELS)");
    line_clear(line);
    line_print(line, 0, "CMD:");
    x = 5;
    for (i = 0; i < CMD_COUNT; ++i) {
        line_print(line, x, g_cmd_names[i]);
        line_put(line, x, (unsigned char)(g_cmd_names[i][0] | 0x80));
        x = (unsigned char)(x + str_len(g_cmd_names[i]) + 1);
    }
    flush_line(MENU_Y, line);
    clear_line(ENTRY_Y);
}

static void draw_message(void)
{
    draw_text_line(MSG_Y, message);
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

static void draw_movement(unsigned char old_row)
{
    draw_status();
    draw_headers();
    draw_grid_row(old_row);
    if (old_row != sel_row) draw_grid_row(sel_row);
    vic_cursor(col_x(sel_col), (unsigned char)(GRID_Y + (sel_row - view_row0)));
}

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

static unsigned char sd_wait(void)
{
    unsigned int guard = 30000;
    unsigned char st;
    do {
        st = SDRAW[SD_STATUS];
        if (st == 0xFF || !(st & SDS_INIT)) return 0;
        if (!(st & SDS_BUSY)) return (st & SDS_ERROR) ? 0 : 1;
    } while (--guard);
    return 0;
}

static void sd_lba(unsigned int lba)
{
    SDRAW[SD_LBA0] = (unsigned char)(lba & 0xFF);
    SDRAW[SD_LBA1] = (unsigned char)(lba >> 8);
    SDRAW[SD_LBA2] = 0;
    SDRAW[SD_LBA3] = 0;
}

static unsigned char sd_read_sector(unsigned int lba)
{
    sd_lba(lba);
    SDRAW[SD_CMD] = SDC_READ;
    if (!sd_wait()) return 0;
    SDRAW[SD_DPTR_L] = 0;
    SDRAW[SD_DPTR_H] = 0;
    return (SDRAW[SD_STATUS] & SDS_READY) ? 1 : 0;
}

static unsigned char sd_write_sector(unsigned int lba)
{
    sd_lba(lba);
    SDRAW[SD_CMD] = SDC_WRITE;
    return sd_wait();
}

static unsigned char sd_has_sbcfs(void)
{
    if (!sd_read_sector(0)) return 0;
    return SDRAW[SD_DATA] == 'S' &&
           SDRAW[SD_DATA] == 'B' &&
           SDRAW[SD_DATA] == 'C' &&
           SDRAW[SD_DATA] == 'F' &&
           SDRAW[SD_DATA] == 'S' &&
           SDRAW[SD_DATA] == '1';
}

static unsigned char sheet_save_slot(const unsigned char *src, unsigned int len)
{
    unsigned int lba = SHEET_SLOT_LBA;
    unsigned int rem = len;
    unsigned int chunk, i;
    const unsigned char *p = src;
    if (!sd_has_sbcfs()) return 0;
    do {
        chunk = rem > 512U ? 512U : rem;
        SDRAW[SD_DPTR_L] = 0;
        SDRAW[SD_DPTR_H] = 0;
        for (i = 0; i < 512U; ++i) {
            SDRAW[SD_DATA] = (i < chunk) ? *p++ : 0;
        }
        if (!sd_write_sector(lba++)) return 0;
        rem -= chunk;
    } while (rem);
    return 1;
}

static unsigned char sheet_load_slot(unsigned char *dst, unsigned int len)
{
    unsigned int lba = SHEET_SLOT_LBA;
    unsigned int rem = len;
    unsigned int chunk, i;
    unsigned char *p = dst;
    if (!sd_has_sbcfs()) return 0;
    while (rem) {
        chunk = rem > 512U ? 512U : rem;
        if (!sd_read_sector(lba++)) return 0;
        for (i = 0; i < chunk; ++i) *p++ = SDRAW[SD_DATA];
        for (; i < 512U; ++i) (void)SDRAW[SD_DATA];
        rem -= chunk;
    }
    return 1;
}

static void cmd_save(void)
{
    char raw[24];
    int len;

    if (!read_entry("SAVE AS: ", raw, sizeof(raw), "", 0)) { set_message("SAVE CANCELLED"); return; }
    if (!raw[0]) { set_message("SAVE CANCELLED"); return; }

    sheet_image_prepare();
    len  = sheet_image_size();

    if (sheet_save_slot(sheet_image_ptr(), (unsigned int)len)) set_message("SAVED");
    else set_message("SAVE DISK ERROR");
}

static void cmd_load(void)
{
    char raw[24];
    int actual;

    if (!read_entry("LOAD FILE: ", raw, sizeof(raw), "", 0)) { set_message("LOAD CANCELLED"); return; }
    if (!raw[0]) { set_message("LOAD CANCELLED"); return; }

    actual = sheet_image_size();
    if (!sheet_load_slot(sheet_image_ptr(), (unsigned int)actual)) { set_message("LOAD DISK ERROR"); return; }
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

static void restore_basic_screen(void)
{
    VIC_MODE = 0;
    VIC_ATTR = 0x02;              /* 80-column text, underline attribute off */
    VIC_FG = 0x0E;                /* EhBASIC default: light blue on black */
    VIC_BG = 0x00;
    VIC_SX = 0;
    VIC_SY = 0;
    clear_screen();
    vic_cursor(0, 0);
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
                      quit_requested = 1;
                      return;
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
    quit_requested = 0;

    set_message("READY - TYPE A VALUE OR PRESS / FOR THE MENU");

    ensure_visible();
    draw_all();

    for (;;) {
        unsigned char old_sel_col = sel_col;
        unsigned char old_sel_row = sel_row;
        unsigned char old_view_col0 = view_col0;
        unsigned char old_view_row0 = view_row0;
        unsigned char full_redraw = 0;

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
            full_redraw = 1;
        } else if (ch == '/') {
            menu();
            if (quit_requested) break;
            full_redraw = 1;
        } else if (ch == '?') {
            cmd_help();
            full_redraw = 1;
        } else if (ch >= 32 && ch < 127) {
            char first[2];
            first[0] = (char)upcase(ch); first[1] = 0;
            commit_entry(first);
            full_redraw = 1;
        }
        ensure_visible();
        if (full_redraw || old_view_col0 != view_col0 || old_view_row0 != view_row0) {
            draw_all();
        } else if (old_sel_col != sel_col || old_sel_row != sel_row) {
            draw_movement(old_sel_row);
        }
    }

    restore_basic_screen();
    sbc_basic();
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
