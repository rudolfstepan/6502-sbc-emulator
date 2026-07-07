/*
 * sheet.h - portable spreadsheet engine for MultiCalc / the 6502 SBC.
 *
 * This translation unit contains NO hardware access.  It is compiled both by
 * cc65 (into the PRG) and by the host C compiler (into tests/test_sheet.c),
 * so the formula engine, cell store, number formatting and file format can be
 * verified on a PC before running on the FPGA.
 */
#ifndef SHEET_H
#define SHEET_H

#include <stdint.h>

/* Logical worksheet: columns A..Z, rows 1..SHEET_ROWS. */
#define SHEET_COLS   26
#define SHEET_ROWS   60

/* Sparse storage: at most MAX_CELLS non-empty cells may exist at once.  Kept
 * small because the real FPGA has only ~24 KB of usable RAM ($0000-$5FFF);
 * see examples/spreadsheet/spreadsheet.cfg. */
#define MAX_CELLS    80

/* Longest cell entry the user can type (formula/label), including the NUL. */
#define ENTRY_LEN    28

/* Fixed-point scale.  Every value is stored as hundredths (2 decimals). */
#define VAL_SCALE    100L

typedef long sval;                 /* fixed-point value, scaled by VAL_SCALE */

/* Cell kinds. */
enum {
    CK_EMPTY   = 0,
    CK_NUMBER  = 1,                /* numeric literal (text is the typed form) */
    CK_LABEL   = 2,                /* text label */
    CK_FORMULA = 3                 /* formula, text[0] == '=' */
};

/* Format byte layout:
 *   bits 0-1  decimal places field: 0,1,2 = fixed; 3 = general (auto)
 *   bit  2    currency ($ prefix)
 */
#define FMT_DEC_MASK  0x03
#define FMT_GENERAL   0x03
#define FMT_CURRENCY  0x04
#define FMT_DEFAULT   FMT_GENERAL  /* new numeric cells are "general" */

typedef struct {
    uint8_t col;                   /* 0..SHEET_COLS-1 */
    uint8_t row;                   /* 0..SHEET_ROWS-1 */
    uint8_t kind;                  /* CK_* */
    uint8_t fmt;                   /* format flags */
    sval    value;                 /* computed value (number/formula) */
    char    text[ENTRY_LEN];       /* source: label / number / "=formula" */
} Cell;

/* Result codes for evaluation, exposed for display of error cells. */
enum {
    EV_OK    = 0,
    EV_ERR   = 1,                  /* syntax / bad reference */
    EV_DIV0  = 2                   /* division by zero */
};

/* ---- lifecycle ------------------------------------------------------- */
void    sheet_reset(void);                    /* clear everything, default widths */

/* ---- cell access ----------------------------------------------------- */
Cell   *sheet_find(uint8_t col, uint8_t row); /* NULL if empty */
int     sheet_set(uint8_t col, uint8_t row, const char *entry); /* 0 ok, -1 full */
void    sheet_blank(uint8_t col, uint8_t row);
uint8_t sheet_kind(uint8_t col, uint8_t row);
sval    sheet_value(uint8_t col, uint8_t row);
uint8_t sheet_count(void);                    /* number of non-empty cells */

/* ---- columns / formats ---------------------------------------------- */
uint8_t sheet_colw(uint8_t col);
void    sheet_set_colw(uint8_t col, uint8_t w);
void    sheet_set_fmt(uint8_t col, uint8_t row, uint8_t fmt);

/* ---- recalculation --------------------------------------------------- */
void    sheet_recalc(void);

/* ---- references ------------------------------------------------------ */
/* Parse "A1".."Z60" at s.  On success stores col/row (0-based), sets *end to
 * the first char after the reference, returns 1.  Returns 0 if not a ref. */
int     sheet_parse_ref(const char *s, uint8_t *col, uint8_t *row,
                        const char **end);
void    sheet_ref_name(uint8_t col, uint8_t row, char *out); /* -> "A1", 4 bytes */

/* ---- numbers --------------------------------------------------------- */
sval    sheet_parse_number(const char *s);
int     sheet_is_number(const char *s);
/* Format v into out (<=maxlen incl NUL) honouring fmt's decimals/currency. */
void    sheet_format_value(sval v, uint8_t fmt, char *out, uint8_t maxlen);

/* Rendered contents of a cell (what appears in the grid), NUL-terminated. */
void    sheet_cell_display(uint8_t col, uint8_t row, char *out, uint8_t maxlen);

/* Fast redraw helpers: iterate the pool directly instead of looking every grid
 * position up.  sheet_slot(i) returns storage slot i (may be empty; check
 * kind); sheet_format_cell renders a cell you already hold a pointer to. */
Cell   *sheet_slot(uint8_t i);
void    sheet_format_cell(const Cell *c, char *out, uint8_t maxlen);

/* ---- copy with relative reference adjustment ------------------------- */
int     sheet_copy(uint8_t scol, uint8_t srow, uint8_t dcol, uint8_t drow);

/* ---- persistence ----------------------------------------------------- */
/* The whole worksheet is stored in one contiguous, directly-saveable image.
 * To save: call sheet_image_prepare(), then write sheet_image_size() bytes
 * from sheet_image_ptr() to disk.  To load: read the bytes back into
 * sheet_image_ptr(), then call sheet_image_reload(len). */
uint8_t *sheet_image_ptr(void);
int      sheet_image_size(void);
void     sheet_image_prepare(void);
int      sheet_image_reload(int len);   /* 0 ok, -1 bad/short image */

/* Last evaluation status (EV_*), useful for the status line. */
extern uint8_t sheet_last_error;

#endif /* SHEET_H */
