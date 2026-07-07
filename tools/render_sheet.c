/*
 * Host-only harness that renders the MultiCalc UI into a text buffer and
 * prints it, so the 80x25 screen layout can be reviewed without the FPGA or
 * the emulator.  It textually includes spreadsheet.c (compiled in host mode,
 * so main() and the hardware paths are excluded) to reach its static drawing
 * routines and screen buffer.
 *
 *   gcc -Iexamples/spreadsheet tools/render_sheet.c examples/spreadsheet/sheet.c -o render_sheet
 *   ./render_sheet            # demo budget, cursor on E4
 *   ./render_sheet blank      # empty sheet
 */
#include "../examples/spreadsheet/spreadsheet.c"
#include <stdio.h>
#include <string.h>

static void dump(void)
{
    int x, y;
    printf("    +");
    for (x = 0; x < SCREEN_W; ++x) putchar('-');
    printf("+\n");
    for (y = 0; y < SCREEN_H; ++y) {
        printf("%2d  |", y);
        for (x = 0; x < SCREEN_W; ++x) {
            unsigned char ch = scr_buf[y * SCREEN_W + x];
            ch &= 0x7F;   /* bit 7 = VIC underline attribute; show the letter */
            putchar(ch < 32 || ch > 126 ? ' ' : ch);
        }
        printf("|\n");
    }
    printf("    +");
    for (x = 0; x < SCREEN_W; ++x) putchar('-');
    printf("+\n");
}

int main(int argc, char **argv)
{
    int blank = (argc > 1 && strcmp(argv[1], "blank") == 0);
    int show_menu = (argc > 1 && strcmp(argv[1], "menu") == 0);

    sel_col = 0; sel_row = 0;
    view_col0 = 0; view_row0 = 0;
    message[0] = 0;

    if (blank) {
        sheet_reset();
        set_message("READY - TYPE A VALUE OR PRESS / FOR THE MENU");
    } else {
        seed_demo();
        sel_col = 4; sel_row = 3;   /* E4 = Q1 sales total */
        set_message("DEMO SHEET - Q1 BUDGET WITH LIVE FORMULAS");
    }

    ensure_visible();
    draw_all();
    if (show_menu) draw_command_bar();
    dump();
    return 0;
}
