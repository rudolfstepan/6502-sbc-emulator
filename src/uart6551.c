#define _POSIX_C_SOURCE 200809L
#include "uart6551.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <termios.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <stdlib.h>

static struct termios g_orig_termios;
static bool           g_termios_saved = false;
static int            g_orig_stdin_flags = -1;

static void restore_terminal(void);

static void apply_stdio_mode(bool raw_nonblock)
{
    if (!isatty(STDIN_FILENO)) return;

    if (!g_termios_saved) {
        if (tcgetattr(STDIN_FILENO, &g_orig_termios) != 0) return;
        g_termios_saved = true;
        atexit(restore_terminal);
    }

    if (g_orig_stdin_flags < 0) {
        g_orig_stdin_flags = fcntl(STDIN_FILENO, F_GETFL, 0);
    }

    if (raw_nonblock) {
        struct termios raw = g_orig_termios;
        raw.c_lflag &= ~(ICANON | ECHO);  /* keep ISIG for CTRL+C */
        raw.c_iflag &= ~(IXON | ICRNL);
        raw.c_cc[VMIN]  = 0;
        raw.c_cc[VTIME] = 0;
        tcsetattr(STDIN_FILENO, TCSANOW, &raw);
        if (g_orig_stdin_flags >= 0)
            fcntl(STDIN_FILENO, F_SETFL, g_orig_stdin_flags | O_NONBLOCK);
        return;
    }

    tcsetattr(STDIN_FILENO, TCSANOW, &g_orig_termios);
    if (g_orig_stdin_flags >= 0)
        fcntl(STDIN_FILENO, F_SETFL, g_orig_stdin_flags);
}

static void restore_terminal(void)
{
    apply_stdio_mode(false);
}

static int setup_tcp_server(int port)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }

    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port        = htons((uint16_t)port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); close(fd); return -1;
    }
    if (listen(fd, 1) < 0) {
        perror("listen"); close(fd); return -1;
    }
    /* non-blocking so accept() doesn't stall the emulator */
    fcntl(fd, F_SETFL, O_NONBLOCK);
    printf("UART: TCP server listening on 127.0.0.1:%d\n", port);
    return fd;
}

int uart_init(UART6551 *uart, UartMode mode, int tcp_port)
{
    memset(uart, 0, sizeof(*uart));
    uart->status         = ACIA_ST_TDRE; /* TX always ready */
    uart->mode           = mode;
    uart->tcp_port       = tcp_port;
    uart->tcp_server_fd  = -1;
    uart->tcp_client_fd  = -1;
    uart->stdin_fd       = STDIN_FILENO;

    if (mode == UART_MODE_STDIO) {
        apply_stdio_mode(true);
        uart->raw_mode_active = g_termios_saved;
    } else {
        uart->tcp_server_fd = setup_tcp_server(tcp_port);
        if (uart->tcp_server_fd < 0) return -1;
    }
    return 0;
}

void uart_free(UART6551 *uart)
{
    if (uart->tcp_client_fd >= 0) { close(uart->tcp_client_fd); }
    if (uart->tcp_server_fd >= 0) { close(uart->tcp_server_fd); }
    if (uart->mode == UART_MODE_STDIO)
        restore_terminal();
}

void uart_stdio_suspend(UART6551 *uart)
{
    if (uart->mode == UART_MODE_STDIO && uart->raw_mode_active)
        apply_stdio_mode(false);
}

void uart_stdio_resume(UART6551 *uart)
{
    if (uart->mode == UART_MODE_STDIO && uart->raw_mode_active)
        apply_stdio_mode(true);
}

static void rx_push(UART6551 *uart, uint8_t b)
{
    int next = (uart->rx_tail + 1) % ACIA_RX_BUF;
    if (next == uart->rx_head) {
        uart->status |= ACIA_ST_OVR;
        return;
    }
    uart->rx_buf[uart->rx_tail] = b;
    uart->rx_tail = next;
    uart->status |= ACIA_ST_RDRF;
}

static uint8_t rx_pop(UART6551 *uart)
{
    if (uart->rx_head == uart->rx_tail) return 0;
    uint8_t b = uart->rx_buf[uart->rx_head];
    uart->rx_head = (uart->rx_head + 1) % ACIA_RX_BUF;
    if (uart->rx_head == uart->rx_tail)
        uart->status &= ~ACIA_ST_RDRF;
    return b;
}

/* Poll for incoming bytes (called from uart_tick) */
static void uart_poll_rx(UART6551 *uart)
{
    uint8_t buf[64];
    ssize_t n = 0;

    if (uart->mode == UART_MODE_STDIO) {
        n = read(STDIN_FILENO, buf, sizeof(buf));
    } else {
        /* Accept pending connection */
        if (uart->tcp_client_fd < 0 && uart->tcp_server_fd >= 0) {
            struct sockaddr_in ca;
            socklen_t cal = sizeof(ca);
            int cfd = accept(uart->tcp_server_fd,
                             (struct sockaddr *)&ca, &cal);
            if (cfd >= 0) {
                int opt = 1;
                setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY,
                           &opt, sizeof(opt));
                fcntl(cfd, F_SETFL, O_NONBLOCK);
                uart->tcp_client_fd = cfd;
                printf("UART: TCP client connected from %s\n",
                       inet_ntoa(ca.sin_addr));
            }
        }
        if (uart->tcp_client_fd >= 0)
            n = read(uart->tcp_client_fd, buf, sizeof(buf));
    }

    if (n > 0) {
        for (ssize_t i = 0; i < n; i++)
            rx_push(uart, buf[i]);
    } else if (n == 0 && uart->mode == UART_MODE_TCP
               && uart->tcp_client_fd >= 0) {
        /* client disconnected */
        close(uart->tcp_client_fd);
        uart->tcp_client_fd = -1;
    }
}

uint8_t uart_read(void *dev, uint16_t offset)
{
    UART6551 *uart = (UART6551 *)dev;
    switch (offset & 0x03) {
    case ACIA_DATA:
        return rx_pop(uart);
    case ACIA_STATUS:
        return uart->status;
    case ACIA_CMD:
        return uart->cmd;
    case ACIA_CTRL:
        return uart->ctrl;
    }
    return 0xFF;
}

void uart_write(void *dev, uint16_t offset, uint8_t val)
{
    UART6551 *uart = (UART6551 *)dev;
    switch (offset & 0x03) {
    case ACIA_DATA: {
        /* Transmit byte */
        if (uart->mode == UART_MODE_STDIO) {
            (void)!write(STDOUT_FILENO, &val, 1);
        } else if (uart->tcp_client_fd >= 0) {
            (void)!write(uart->tcp_client_fd, &val, 1);
        }
        uart->status |= ACIA_ST_TDRE;
        break;
    }
    case ACIA_STATUS: /* Programmed reset */
        uart->status = ACIA_ST_TDRE;
        uart->cmd    = 0;
        uart->ctrl   = 0;
        uart->rx_head = uart->rx_tail = 0;
        break;
    case ACIA_CMD:
        uart->cmd = val;
        break;
    case ACIA_CTRL:
        uart->ctrl = val;
        break;
    }
}

/* Accumulate partial cycles; poll RX roughly every ~100 CPU cycles */
void uart_tick(void *dev, uint32_t cycles)
{
    static uint32_t accum = 0;
    accum += cycles;
    if (accum >= 100) {
        accum = 0;
        uart_poll_rx((UART6551 *)dev);
    }
}

bool uart_irq(const UART6551 *uart)
{
    return uart->irq_active;
}
