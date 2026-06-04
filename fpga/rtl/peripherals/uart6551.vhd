-- UART 6551: Serial Communications Interface with Baud Rate Generation
-- Enhanced version with configurable baud rates and serial parameters
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity uart6551 is
  port (
    clk          : in  std_logic;      -- System clock (100 MHz)
    reset_n      : in  std_logic;      -- Active-low synchronous reset
    cs           : in  std_logic;      -- Chip Select
    we           : in  std_logic;      -- Write Enable
    addr         : in  addr_t;         -- Register address (lower 2 bits)
    din          : in  data_t;         -- Data input for writes
    dout         : out data_t;         -- Data output for reads
    rx_data      : in  data_t;         -- External RX data (stub interface)
    rx_valid     : in  std_logic;      -- External RX valid signal
    tx_data      : out data_t;         -- TX data output
    tx_valid     : out std_logic;      -- TX request signal
    irq          : out std_logic       -- Interrupt Request
  );
end entity;

architecture rtl of uart6551 is
  -- Register address map
  constant REG_DATA   : std_logic_vector(1 downto 0) := "00";
  constant REG_STATUS : std_logic_vector(1 downto 0) := "01";
  constant REG_CMD    : std_logic_vector(1 downto 0) := "10";
  constant REG_CTRL   : std_logic_vector(1 downto 0) := "11";

  -- Status register bits
  constant ST_IRQ  : natural := 7;
  constant ST_DSR  : natural := 6;
  constant ST_DCD  : natural := 5;
  constant ST_TDRE : natural := 4;
  constant ST_RDRF : natural := 3;
  constant ST_OVR  : natural := 2;
  constant ST_FE   : natural := 1;
  constant ST_PE   : natural := 0;

  -- Baud rate dividers for 100 MHz clock with 16x oversampling
  -- Divider = 100_000_000 / (baud_rate * 16)
  constant BAUD_300     : natural := 20833;   -- 100M/(300*16)
  constant BAUD_600     : natural := 10417;   -- 100M/(600*16)
  constant BAUD_1200    : natural := 5208;    -- 100M/(1200*16)
  constant BAUD_2400    : natural := 2604;    -- 100M/(2400*16)
  constant BAUD_4800    : natural := 1302;    -- 100M/(4800*16)
  constant BAUD_9600    : natural := 651;     -- 100M/(9600*16)
  constant BAUD_19200   : natural := 325;     -- 100M/(19200*16)
  constant BAUD_38400   : natural := 162;     -- 100M/(38400*16) [approximate]
  constant BAUD_57600   : natural := 108;     -- 100M/(57600*16) [approximate]
  constant BAUD_115200  : natural := 54;      -- 100M/(115200*16) [approximate]

  -- Internal registers
  signal rx_reg       : data_t := (others => '0');
  signal tx_reg       : data_t := (others => '0');
  signal status_reg   : data_t := x"10";
  signal cmd_reg      : data_t := (others => '0');
  signal ctrl_reg     : data_t := (others => '0');
  signal dout_reg     : data_t := (others => '0');
  signal tx_valid_reg : std_logic := '0';

  -- Baud rate generator signals
  signal baud_div_count : natural range 0 to 65535 := 0;
  signal baud_clock : std_logic := '0';
  signal baud_divider : natural range 0 to 65535 := BAUD_9600;

  -- Data format configuration signals
  signal data_length : natural range 5 to 8 := 8;  -- Default 8 bits

  -- Helper function to get data length from CTRL register
  function get_data_length(ctrl : data_t) return natural is
  begin
    case ctrl(1 downto 0) is
      when "00" => return 5;  -- 5 bits
      when "01" => return 6;  -- 6 bits
      when "10" => return 7;  -- 7 bits
      when others => return 8;  -- 8 bits (default)
    end case;
  end function;

begin
  -- Output assignments
  dout <= dout_reg;
  tx_data <= tx_reg;
  tx_valid <= tx_valid_reg;
  irq <= status_reg(ST_IRQ);

  -- Baud rate generator process
  -- Generates baud clock at 16x the specified baud rate
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        baud_div_count <= 0;
        baud_clock <= '0';
        baud_divider <= BAUD_9600;  -- Default to 9600 baud
      else
        -- Update baud divider from control register (bits 3:0)
        case ctrl_reg(3 downto 0) is
          when x"0" => baud_divider <= BAUD_300;
          when x"1" => baud_divider <= BAUD_600;
          when x"2" => baud_divider <= BAUD_1200;
          when x"3" => baud_divider <= BAUD_2400;
          when x"4" => baud_divider <= BAUD_4800;
          when x"5" => baud_divider <= BAUD_9600;
          when x"6" => baud_divider <= BAUD_19200;
          when x"7" => baud_divider <= BAUD_38400;
          when x"8" => baud_divider <= BAUD_57600;
          when x"9" => baud_divider <= BAUD_115200;
          when others => baud_divider <= BAUD_9600;  -- Unknown codes default to 9600
        end case;

        -- Clock divider counter
        if baud_div_count = 0 then
          baud_clock <= not baud_clock;  -- Toggle baud clock output
          baud_div_count <= baud_divider - 1;
        else
          baud_div_count <= baud_div_count - 1;
        end if;
      end if;
    end if;
  end process;

  -- Main UART control process (simplified for basic operation)
  process(clk)
    variable next_status : data_t;
  begin
    if rising_edge(clk) then
      tx_valid_reg <= '0';

      if reset_n = '0' then
        rx_reg <= (others => '0');
        tx_reg <= (others => '0');
        status_reg <= x"10";
        cmd_reg <= (others => '0');
        ctrl_reg <= (others => '0');
        dout_reg <= (others => '0');
      else
        next_status := status_reg;
        next_status(ST_TDRE) := '1';  -- Always ready in simplified model

        -- Update data length based on current CTRL register
        data_length <= get_data_length(ctrl_reg);

        -- Handle incoming RX data
        if rx_valid = '1' then
          if status_reg(ST_RDRF) = '1' then
            next_status(ST_OVR) := '1';
          else
            rx_reg <= rx_data;
            next_status(ST_RDRF) := '1';
          end if;
        end if;

        -- Register access
        if cs = '1' then
          if we = '1' then
            case addr(1 downto 0) is
              when REG_DATA =>
                tx_reg <= din;
                tx_valid_reg <= '1';
              when REG_STATUS =>
                next_status := x"10";
                cmd_reg <= (others => '0');
                ctrl_reg <= (others => '0');
              when REG_CMD =>
                cmd_reg <= din;
              when REG_CTRL =>
                ctrl_reg <= din;
              when others =>
                null;
            end case;
          else
            case addr(1 downto 0) is
              when REG_DATA =>
                dout_reg <= rx_reg;
                next_status(ST_RDRF) := '0';
              when REG_STATUS =>
                dout_reg <= next_status;
              when REG_CMD =>
                dout_reg <= cmd_reg;
              when REG_CTRL =>
                dout_reg <= ctrl_reg;
              when others =>
                dout_reg <= x"FF";
            end case;
          end if;
        else
          dout_reg <= (others => '0');
        end if;

        -- Interrupt generation
        if next_status(ST_RDRF) = '1' and cmd_reg(0) = '1' then
          next_status(ST_IRQ) := '1';
        else
          next_status(ST_IRQ) := '0';
        end if;

        status_reg <= next_status;
      end if;
    end if;
  end process;

end architecture;
