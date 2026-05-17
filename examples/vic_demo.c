/*
 * VIC Demo Program
 * 
 * This example demonstrates how to use the VIC (Video Interface Controller)
 * to display text on the screen.
 * 
 * The VIC provides:
 * - 2KB video RAM at $8000-$87FF (dual-port, CPU accessible)
 * - Built-in character ROM with 8x8 pixel font (256 ASCII characters)
 * - 40x25 text mode display
 * 
 * Usage from 6502 assembly:
 * 
 * ; Write character 'A' to position (0,0)
 * LDA #'A'
 * STA $8000
 * 
 * ; Write "HELLO" to positions 0-4
 * LDX #0
 * LDA #'H'
 * STA $8000,X
 * INX
 * LDA #'E'
 * STA $8000,X
 * INX
 * LDA #'L'
 * STA $8000,X
 * INX
 * LDA #'L'
 * STA $8000,X
 * INX
 * LDA #'O'
 * STA $8000,X
 * 
 * Screen Layout:
 * - 40 columns x 25 rows = 1000 bytes (1KB)
 * - Row 0: $8000-$8027 (40 bytes)
 * - Row 1: $8028-$804F (40 bytes)
 * - Row 2: $8050-$8077 (40 bytes)
 * - ...
 * - Row 24: $83D0-$83F7 (40 bytes)
 * 
 * Character Set:
 * - ASCII 0x20-0x7E: Printable characters
 * - ASCII 0x00-0x1F: Control characters (displayed as blank)
 * - ASCII 0x7F-0xFF: Extended characters (blank by default)
 */

#include <stdio.h>
#include "../src/vic.h"

int main(void) {
    printf("VIC Demo Program\n");
    printf("================\n\n");
    
    // Initialize VIC
    vic_init();
    
    // Clear screen
    vic_clear_screen();
    
    // Write welcome message
    vic_write_string("*** COMMODORE 64 BASIC V2 ***\n\n");
    vic_write_string(" 64K RAM SYSTEM  38911 BASIC BYTES FREE\n\n");
    vic_write_string("READY.\n");
    
    // Simulate cursor position
    vic_set_cursor(0, 7);
    vic_write_string("10 PRINT \"HELLO, WORLD!\"\n");
    vic_write_string("20 GOTO 10\n");
    vic_write_string("\nRUN\n");
    
    // Display multiple HELLO, WORLD! lines
    for (int i = 0; i < 5; i++) {
        vic_write_string("HELLO, WORLD!\n");
    }
    
    // Render the screen
    vic_render_screen();
    
    printf("\nDemo complete. Video RAM contains the displayed text.\n");
    printf("CPU can read/write video RAM at $8000-$87FF.\n");
    
    return 0;
}
