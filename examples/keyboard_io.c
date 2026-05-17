/*
 * Keyboard & VIC I/O Library for 6502 SBC
 * 
 * This library provides basic I/O functions for reading from
 * the keyboard (via VIA6522) and writing to the VIC screen.
 * 
 * Compile with cc65:
 *   cl65 -t none -O keyboard_io_example.c -o keyboard_io.bin
 */

#include <stdint.h>
#include <stdbool.h>

/* Hardware addresses */
#define VIA_BASE   0x8800
#define VIC_RAM    0x8000

/* VIA Registers */
#define VIA_ORB    (*(volatile uint8_t *)(VIA_BASE + 0x00))
#define VIA_ORA    (*(volatile uint8_t *)(VIA_BASE + 0x01))
#define VIA_DDRB   (*(volatile uint8_t *)(VIA_BASE + 0x02))
#define VIA_DDRA   (*(volatile uint8_t *)(VIA_BASE + 0x03))
#define VIA_IFR    (*(volatile uint8_t *)(VIA_BASE + 0x0D))
#define VIA_IER    (*(volatile uint8_t *)(VIA_BASE + 0x0E))

/* Screen dimensions */
#define SCREEN_WIDTH  40
#define SCREEN_HEIGHT 25

/* Global cursor position */
static uint8_t cursor_x = 0;
static uint8_t cursor_y = 0;

/* Initialize keyboard and screen */
void init_io(void) {
    /* Configure VIA Port A as input for keyboard */
    VIA_DDRA = 0x00;  /* All bits input */
    
    /* Enable CA1 interrupt for keyboard */
    VIA_IER = 0x82;   /* Set bit 7 (enable) + bit 1 (CA1) */
    
    /* Clear screen */
    clear_screen();
    
    /* Reset cursor */
    cursor_x = 0;
    cursor_y = 0;
}

/* Clear the VIC screen */
void clear_screen(void) {
    uint16_t i;
    volatile uint8_t *screen = (volatile uint8_t *)VIC_RAM;
    
    for (i = 0; i < SCREEN_WIDTH * SCREEN_HEIGHT; i++) {
        screen[i] = ' ';
    }
}

/* Read a character from the keyboard (non-blocking) */
/* Returns 0 if no character available */
uint8_t getchar_nb(void) {
    /* Check if CA1 interrupt flag is set */
    if (VIA_IFR & 0x02) {
        return VIA_ORA;  /* Read character from Port A */
    }
    return 0;  /* No character available */
}

/* Read a character from the keyboard (blocking) */
uint8_t getchar(void) {
    uint8_t ch;
    while ((ch = getchar_nb()) == 0) {
        /* Wait for character */
    }
    return ch;
}

/* Check if a character is available */
bool kbhit(void) {
    return (VIA_IFR & 0x02) != 0;
}

/* Scroll screen up by one line */
void scroll_up(void) {
    uint16_t i;
    volatile uint8_t *screen = (volatile uint8_t *)VIC_RAM;
    
    /* Move all lines up */
    for (i = 0; i < SCREEN_WIDTH * (SCREEN_HEIGHT - 1); i++) {
        screen[i] = screen[i + SCREEN_WIDTH];
    }
    
    /* Clear last line */
    for (i = SCREEN_WIDTH * (SCREEN_HEIGHT - 1); 
         i < SCREEN_WIDTH * SCREEN_HEIGHT; i++) {
        screen[i] = ' ';
    }
}

/* Write a character to the VIC screen */
void putchar(uint8_t ch) {
    volatile uint8_t *screen = (volatile uint8_t *)VIC_RAM;
    uint16_t pos;
    
    /* Handle special characters */
    if (ch == '\n' || ch == '\r') {
        /* Newline */
        cursor_x = 0;
        cursor_y++;
    } else if (ch == '\b') {
        /* Backspace */
        if (cursor_x > 0) {
            cursor_x--;
            pos = cursor_y * SCREEN_WIDTH + cursor_x;
            screen[pos] = ' ';
        }
        return;
    } else {
        /* Normal character */
        pos = cursor_y * SCREEN_WIDTH + cursor_x;
        screen[pos] = ch;
        cursor_x++;
        
        /* Wrap to next line if needed */
        if (cursor_x >= SCREEN_WIDTH) {
            cursor_x = 0;
            cursor_y++;
        }
    }
    
    /* Scroll if needed */
    if (cursor_y >= SCREEN_HEIGHT) {
        scroll_up();
        cursor_y = SCREEN_HEIGHT - 1;
    }
}

/* Print a null-terminated string */
void print(const char *str) {
    while (*str) {
        putchar(*str++);
    }
}

/* Print a string with newline */
void println(const char *str) {
    print(str);
    putchar('\n');
}

/* Set cursor position */
void gotoxy(uint8_t x, uint8_t y) {
    if (x < SCREEN_WIDTH && y < SCREEN_HEIGHT) {
        cursor_x = x;
        cursor_y = y;
    }
}

/* ========================================
 * Example: Simple keyboard echo program
 * ======================================== */
void keyboard_echo(void) {
    uint8_t ch;
    
    init_io();
    
    println("6502 Keyboard Echo Test");
    println("Type text to see it echo...");
    println("Press ESC to quit.");
    println("");
    
    while (1) {
        ch = getchar();  /* Wait for keypress */
        
        if (ch == 0x1B) {  /* ESC key */
            break;
        }
        
        putchar(ch);  /* Echo to screen */
    }
    
    println("");
    println("Exiting...");
}

/* ========================================
 * Example: Simple line editor
 * ======================================== */
#define MAX_LINE_LEN 80

void line_editor(void) {
    char buffer[MAX_LINE_LEN];
    uint8_t pos = 0;
    uint8_t ch;
    
    init_io();
    
    println("Simple Line Editor");
    println("Type and press ENTER to submit.");
    println("");
    
    while (1) {
        print("> ");
        pos = 0;
        
        /* Read a line */
        while (1) {
            ch = getchar();
            
            if (ch == '\r' || ch == '\n') {
                /* End of line */
                buffer[pos] = '\0';
                putchar('\n');
                break;
            } else if (ch == '\b') {
                /* Backspace */
                if (pos > 0) {
                    pos--;
                    putchar('\b');
                }
            } else if (pos < MAX_LINE_LEN - 1) {
                /* Normal character */
                buffer[pos++] = ch;
                putchar(ch);
            }
        }
        
        /* Process the line */
        if (buffer[0] == 'q' && buffer[1] == '\0') {
            break;  /* Quit on 'q' */
        }
        
        /* Echo what was typed */
        print("You typed: ");
        println(buffer);
    }
    
    println("Goodbye!");
}

/* ========================================
 * Main entry point
 * ======================================== */
void main(void) {
    /* Choose which example to run */
    
    /* Option 1: Simple echo */
    // keyboard_echo();
    
    /* Option 2: Line editor */
    line_editor();
    
    /* Infinite loop after program ends */
    while (1) {
        /* halt */
    }
}
