/*
 * Generate a loadable MultiCalc worksheet file (data/disk/demo.mc) from the
 * host-side seed_demo().  The demo is intentionally NOT compiled into the PRG
 * (the FPGA has too little RAM); instead the user loads this file with the
 * spreadsheet's "/ L  DEMO" command.
 *
 * The file is exactly the raw sheet image (sheet_image_ptr()/_size()), which is
 * what the Load command reads straight back into the engine.
 */
#include "../examples/spreadsheet/spreadsheet.c"   /* host mode: seed_demo, image API */
#include <stdio.h>

int main(int argc, char **argv)
{
    const char *out = (argc > 1) ? argv[1] : "data/disk/demo.mc";
    FILE *f;

    seed_demo();
    sheet_image_prepare();

    f = fopen(out, "wb");
    if (!f) { perror(out); return 1; }
    if (fwrite(sheet_image_ptr(), 1, (size_t)sheet_image_size(), f) != (size_t)sheet_image_size()) {
        perror("write");
        fclose(f);
        return 1;
    }
    fclose(f);
    printf("wrote %s (%d bytes, %d cells)\n", out, sheet_image_size(), sheet_count());
    return 0;
}
