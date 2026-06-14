-- Diagnostic testbench for T65 indirect addressing issue
-- Captures detailed signal states during the failing instruction

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity tb_t65_indirect_diagnosis is
end entity;

architecture diag of tb_t65_indirect_diagnosis is
  signal clk          : std_logic := '0';
  signal reset_n      : std_logic := '0';
  signal uart_rx      : std_logic := '1';
  signal uart_tx      : std_logic;
  signal irq_out      : std_logic;
  signal dbg_cpu_addr : addr_t;
  signal dbg_cpu_data : data_t;
  signal dbg_cpu_din  : data_t;
  signal dbg_cpu_we   : std_logic;
  signal dbg_cpu_sync : std_logic;

  -- Track instruction sequence
  signal instruction_count : integer := 0;
  signal saw_sram_write : boolean := false;
  signal saw_vic_write  : boolean := false;
  signal zp_f2_value : data_t := x"00";
  signal zp_f3_value : data_t := x"00";

begin
  clk <= not clk after 5 ns;

  dut : entity work.sbc_t65_top
    generic map (
      ROM_INIT_FILE => "sim/hex/rom_t65_indirect_vic.hex"
    )
    port map (
      clk          => clk,
      reset_n      => reset_n,
      uart_rx      => uart_rx,
      uart_tx      => uart_tx,
      irq_out      => irq_out,
      dbg_cpu_addr => dbg_cpu_addr,
      dbg_cpu_data => dbg_cpu_data,
      dbg_cpu_din  => dbg_cpu_din,
      dbg_cpu_we   => dbg_cpu_we,
      dbg_cpu_sync => dbg_cpu_sync,
      dbg_uart_tx_data  => open,
      dbg_uart_tx_valid => open,
      dbg_via_portb_out => open
    );

  monitor_process : process
    variable cycle_count : integer := 0;
  begin
    -- Reset phase
    reset_n <= '0';
    wait for 35 ns;
    reset_n <= '1';

    report "=== T65 Indirect Addressing Diagnosis ===" severity note;
    report "Test: STA ($F2),Y to address $8000" severity note;
    report "" severity note;

    -- Monitor for 100us
    for i in 0 to 20000 loop
      wait for 5 ns;  -- Half clock
      cycle_count := cycle_count + 1;

      -- Count complete clock cycles
      if cycle_count mod 2 = 0 then

        -- Track instruction fetches (SYNC signal)
        if dbg_cpu_sync = '1' then
          instruction_count <= instruction_count + 1;
          report "Cycle " & integer'image(cycle_count/2) &
                  ": Instruction fetch at address $" &
                  to_hstring(dbg_cpu_addr) &
                  " (" & integer'image(instruction_count) & ")"
            severity note;
        end if;

        -- Track SRAM writes (address $0000-$7FFF)
        if dbg_cpu_we = '1' and dbg_cpu_addr(15) = '0' then
          if dbg_cpu_addr = x"00F2" or dbg_cpu_addr = x"00F3" then
            report "Cycle " & integer'image(cycle_count/2) &
                    ": Zero page write at $" &
                    to_hstring(dbg_cpu_addr) &
                    " = $" & to_hstring(dbg_cpu_data)
              severity note;
            if dbg_cpu_addr = x"00F2" then
              zp_f2_value <= dbg_cpu_data;
            else
              zp_f3_value <= dbg_cpu_data;
            end if;
          else
            saw_sram_write <= true;
            report "Cycle " & integer'image(cycle_count/2) &
                    ": SRAM write at $" &
                    to_hstring(dbg_cpu_addr) &
                    " = $" & to_hstring(dbg_cpu_data)
              severity note;
          end if;
        end if;

        -- Track VIC writes (address $8000-$87FF)
        if dbg_cpu_we = '1' and dbg_cpu_addr(15 downto 11) = "10000" then
          saw_vic_write <= true;
          report "Cycle " & integer'image(cycle_count/2) &
                  ": *** VIC write at $" &
                  to_hstring(dbg_cpu_addr) &
                  " = $" & to_hstring(dbg_cpu_data) &
                  " *** SUCCESS ***"
            severity note;
          wait;  -- Stop here
        end if;

      end if;
    end loop;

    report "" severity note;
    report "=== Diagnosis Results ===" severity note;
    report "Instructions executed: " & integer'image(instruction_count) severity note;
    report "SRAM writes seen: " & boolean'image(saw_sram_write) severity note;
    report "VIC writes seen: " & boolean'image(saw_vic_write) severity note;
    report "Zero page $F2: $" & to_hstring(zp_f2_value) severity note;
    report "Zero page $F3: $" & to_hstring(zp_f3_value) severity note;
    report "" severity note;

    if not saw_vic_write then
      report "FAILURE: VIC write never occurred" severity error;
    else
      report "SUCCESS: VIC write detected!" severity note;
    end if;

    wait;
  end process;

end architecture;
