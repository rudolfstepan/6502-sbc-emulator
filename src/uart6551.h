#pragma once
#include <stdint.h>
#include <stdbool.h>

/*
 * MOS 6551 ACIA (Asynchronous Communications Interface Adapter)
 *
 * Register map (4 bytes):
 *  $0  Transmit Data Register (W) / Receive Data Register (R)
 *  $1  Status Register (R)        / Programmed Reset (W, any value)
 *  $2  Command Register (R/W)
 *  $3  Control Register (R/W)
 *
 * Status register bits:
 *  7 - Interrupt (active-low IRQ)
 *  6 - DSR (Data Set Ready, active low)
 *  5 - DCD (Data Carrier Detect, active low)
 *  4 - TDRE (Transmit Data Register Empty)
 *  3 - RDRF (Receive Data Register Full)
 *  2 - Overrun error
 *  1 - Framing error
 *  0 - Parity error
 */

#define ACIA_DATA    0x0
#define ACIA_STATUS  0x1
#define ACIA_CMD     0x2
#define ACIA_CTRL    0x3

#define ACIA_ST_IRQ   (1 << 7)
#define ACIA_ST_DSR   (1 << 6)
#define ACIA_ST_DCD   (1 << 5)
#define ACIA_ST_TDRE  (1 << 4)
#define ACIA_ST_RDRF  (1 << 3)
#define ACIA_ST_OVR   (1 << 2)
#define ACIA_ST_FE    (1 << 1)
#define ACIA_ST_PE    (1 << 0)

#define ACIA_RX_BUF   256

typedef enum {
    UART_MODE_STDIO,       /* stdin/stdout */
    UART_MODE_TCP,         /* TCP server on a port */
} UartMode;

typedef struct {
    uint8_t  rx_buf[ACIA_RX_BUF];
    int      rx_head, rx_tail;
    uint8_t  status;
    uint8_t  cmd;
    uint8_t  ctrl;
    bool     irq_active;
    UartMode mode;
    int      tcp_port;
    int      tcp_server_fd;
    int      tcp_client_fd;
    int      stdin_fd;
    bool     raw_mode_active;
} UART6551;

int     uart_init(UART6551 *uart, UartMode mode, int tcp_port);
void    uart_free(UART6551 *uart);
void    uart_stdio_suspend(UART6551 *uart);
void    uart_stdio_resume(UART6551 *uart);
uint8_t uart_read(void *dev, uint16_t offset);
void    uart_write(void *dev, uint16_t offset, uint8_t val);
void    uart_tick(void *dev, uint32_t cycles);
bool    uart_irq(const UART6551 *uart);
