library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use std.env.all;

use work.sbc_pkg.all;

entity tb_sbc_t65_boot_shadow is
end entity;

architecture sim of tb_sbc_t65_boot_shadow is
  signal clk           : std_logic := '0';
  signal reset_n       : std_logic := '0';
  signal boot_done     : std_logic := '0';
  signal rom_load_we   : std_logic := '0';
  signal rom_load_addr : std_logic_vector(13 downto 0) := (others => '0');
  signal rom_load_data : data_t := (others => '0');
  signal vga_r         : std_logic_vector(4 downto 0);
  signal vga_g         : std_logic_vector(5 downto 0);
  signal vga_b         : std_logic_vector(4 downto 0);
  signal vga_hs        : std_logic;
  signal vga_vs        : std_logic;
  signal uart_tx_data  : data_t;
  signal uart_tx_valid : std_logic;
  signal via_portb     : data_t;
  signal dbg_cpu_addr  : addr_t;
  signal dbg_cpu_data  : data_t;
  signal dbg_cpu_din   : data_t;
  signal dbg_cpu_we    : std_logic;
  signal dbg_cpu_sync  : std_logic;

  procedure load_byte(
    signal addr : out std_logic_vector(13 downto 0);
    signal data : out data_t;
    signal we   : out std_logic;
    constant a  : in natural;
    constant d  : in std_logic_vector(7 downto 0)
  ) is
  begin
    addr <= std_logic_vector(to_unsigned(a, 14));
    data <= d;
    we <= '1';
    wait until rising_edge(clk);
    we <= '0';
    wait until rising_edge(clk);
  end procedure;
begin
  clk <= not clk after 5 ns;

  dut : entity work.sbc_t65_boot_top
    port map (
      clk           => clk,
      reset_n       => reset_n,
      boot_done     => boot_done,
      rom_load_we   => rom_load_we,
      rom_load_addr => rom_load_addr,
      rom_load_data => rom_load_data,
      vga_r         => vga_r,
      vga_g         => vga_g,
      vga_b         => vga_b,
      vga_hs        => vga_hs,
      vga_vs        => vga_vs,
      uart_rx       => '1',
      uart_tx_data  => uart_tx_data,
      uart_tx_valid => uart_tx_valid,
      uart_tx_busy  => '0',
      via_portb     => via_portb,
      dbg_cpu_addr  => dbg_cpu_addr,
      dbg_cpu_data  => dbg_cpu_data,
      dbg_cpu_din   => dbg_cpu_din,
      dbg_cpu_we    => dbg_cpu_we,
      dbg_cpu_sync  => dbg_cpu_sync
    );

  process
  begin
    wait for 30 ns;
    reset_n <= '1';

    -- $C000: LDA #$00 ; STA $8803 ; JMP $C005
    load_byte(rom_load_addr, rom_load_data, rom_load_we, 16#0000#, x"A9");
    load_byte(rom_load_addr, rom_load_data, rom_load_we, 16#0001#, x"00");
    load_byte(rom_load_addr, rom_load_data, rom_load_we, 16#0002#, x"8D");
    load_byte(rom_load_addr, rom_load_data, rom_load_we, 16#0003#, x"03");
    load_byte(rom_load_addr, rom_load_data, rom_load_we, 16#0004#, x"88");
    load_byte(rom_load_addr, rom_load_data, rom_load_we, 16#0005#, x"4C");
    load_byte(rom_load_addr, rom_load_data, rom_load_we, 16#0006#, x"05");
    load_byte(rom_load_addr, rom_load_data, rom_load_we, 16#0007#, x"C0");

    -- Reset vector at CPU $FFFC/$FFFD, ROM offsets $3FFC/$3FFD.
    load_byte(rom_load_addr, rom_load_data, rom_load_we, 16#3FFC#, x"00");
    load_byte(rom_load_addr, rom_load_data, rom_load_we, 16#3FFD#, x"C0");

    boot_done <= '1';

    for i in 0 to 2000 loop
      wait until rising_edge(clk);

      if dbg_cpu_we = '1' and dbg_cpu_addr = x"8803" then
        assert dbg_cpu_data = x"00"
          report "loaded boot ROM wrote unexpected VIA DDRA value"
          severity failure;
        report "tb_sbc_t65_boot_shadow passed";
        stop;
      end if;
    end loop;

    assert false
      report "loaded boot ROM did not execute expected VIA DDRA write"
      severity failure;
  end process;
end architecture;
