-- Deep diagnostic testbench for T65 indirect addressing
-- Captures detailed bus and control signals during STA ($F2),Y execution
-- Focus: Understand exactly where/why instruction is skipped

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity tb_t65_indirect_deep_analysis is
end entity;

architecture diag of tb_t65_indirect_deep_analysis is
  -- System signals
  signal clk          : std_logic := '0';
  signal reset_n      : std_logic := '0';
  signal uart_rx      : std_logic := '1';
  signal uart_tx      : std_logic;
  signal irq_out      : std_logic;

  -- CPU bus signals
  signal dbg_cpu_addr : addr_t;
  signal dbg_cpu_data : data_t;
  signal dbg_cpu_din  : data_t;
  signal dbg_cpu_we   : std_logic;
  signal dbg_cpu_sync : std_logic;

  -- Track state
  signal cycle_count  : integer := 0;
  signal in_indirect_zone : boolean := false;
  signal last_addr    : addr_t := (others => '0');
  signal addr_changed : boolean := false;
  signal data_written : std_logic_vector(7 downto 0) := (others => '0');

  -- Detect when we reach C00C (the problem instruction)
  signal at_c00c      : boolean := false;
  signal at_c00e      : boolean := false;
  signal jumped_early : boolean := false;

  -- Memory snapshot for debugging
  signal mem_f2_last  : data_t := x"00";
  signal mem_f3_last  : data_t := x"00";
  signal mem_8000_last : data_t := x"00";

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

  monitor : process
    variable cycle : integer := 0;
    variable op : character;
    variable write_to_8000 : boolean := false;
    variable clock_cycle : integer;
  begin
    reset_n <= '0';
    wait for 35 ns;
    reset_n <= '1';

    report "================================================================" severity note;
    report "  T65 Indirect Addressing - Deep Signal Analysis" severity note;
    report "  Focus: C00C (STA $F2,Y) execution path" severity note;
    report "================================================================" severity note;
    report "" severity note;

    for i in 0 to 25000 loop
      wait for 5 ns;
      cycle := cycle + 1;

      -- Track when we're near the problem zone
      if dbg_cpu_addr = x"C00A" or dbg_cpu_addr = x"C00B" or
         dbg_cpu_addr = x"C00C" or dbg_cpu_addr = x"C00D" then
        in_indirect_zone <= true;
      end if;

      -- Detect address changes
      if dbg_cpu_addr /= last_addr then
        addr_changed <= true;
        last_addr <= dbg_cpu_addr;
      else
        addr_changed <= false;
      end if;

      -- Track writes to memory
      if dbg_cpu_we = '1' then
        data_written <= dbg_cpu_data;
        if dbg_cpu_addr = x"8000" then
          write_to_8000 := true;
        end if;
      end if;

      -- Every clock cycle (cycle mod 2 = 0)
      if cycle mod 2 = 0 then
        clock_cycle := cycle / 2;

        -- === INSTRUCTION FETCH DETECTION ===
        if dbg_cpu_sync = '1' then
          if dbg_cpu_addr = x"C00A" then
            report "" severity note;
            report "Cycle " & integer'image(clock_cycle) &
                    " [T3] *** ENTERING CRITICAL ZONE ***" severity note;
            report "       Fetching LDA #$20 at $C00A" severity note;

          elsif dbg_cpu_addr = x"C00C" then
            at_c00c <= true;
            report "" severity note;
            report "Cycle " & integer'image(clock_cycle) &
                    " [T5] *** CRITICAL INSTRUCTION ***" severity note;
            report "       Fetching STA ($F2),Y at $C00C" severity note;
            report "       Opcode should be: 0x91 (indirect-Y store)" severity note;

          elsif dbg_cpu_addr = x"C00E" and at_c00c then
            at_c00e <= true;
            jumped_early <= true;
            report "" severity note;
            report "Cycle " & integer'image(clock_cycle) &
                    " [T7] *** JUMP DETECTED ***" severity note;
            report "       CPU jumped to $C00E WITHOUT executing $C00C!" severity note;
            report "       This means the indirect-Y write was SKIPPED" severity note;
          end if;
        end if;

        -- === MEMORY ACCESS TRACKING ===
        if dbg_cpu_we = '1' then
          if dbg_cpu_addr = x"00F2" then
            report "Cycle " & integer'image(clock_cycle) &
                    " [WR] Zero page F2 = 0x" & to_hstring(dbg_cpu_data) severity note;
            mem_f2_last <= dbg_cpu_data;

          elsif dbg_cpu_addr = x"00F3" then
            report "Cycle " & integer'image(clock_cycle) &
                    " [WR] Zero page F3 = 0x" & to_hstring(dbg_cpu_data) severity note;
            mem_f3_last <= dbg_cpu_data;

          elsif dbg_cpu_addr = x"8000" then
            report "Cycle " & integer'image(clock_cycle) &
                    " [WR] *** VIC TEXT RAM 8000 = 0x" & to_hstring(dbg_cpu_data) & " ***" severity note;
            mem_8000_last <= dbg_cpu_data;

          elsif in_indirect_zone then
            report "Cycle " & integer'image(clock_cycle) &
                    " [WR] Address 0x" & to_hstring(dbg_cpu_addr) &
                    " = 0x" & to_hstring(dbg_cpu_data) &
                    " (in indirect zone)" severity note;
          end if;
        end if;

        -- === ADDRESS BUS CHANGES ===
        if addr_changed and in_indirect_zone then
          report "Cycle " & integer'image(clock_cycle) &
                  " [RD] Address bus: $" & to_hstring(dbg_cpu_addr) &
                  " (data_in: $" & to_hstring(dbg_cpu_din) & ")" severity note;
        end if;
      end if;

    end loop;

    report "" severity note;
    report "================================================================" severity note;
    report "  ANALYSIS SUMMARY" severity note;
    report "================================================================" severity note;
    report "Instruction at $C00C reached: " & boolean'image(at_c00c) severity note;
    report "Instruction at $C00E reached: " & boolean'image(at_c00e) severity note;
    report "Early jump detected: " & boolean'image(jumped_early) severity note;
    report "Write to $8000 occurred: " & boolean'image(write_to_8000) severity note;
    report "Last $F2 value: $" & to_hstring(mem_f2_last) severity note;
    report "Last $F3 value: $" & to_hstring(mem_f3_last) severity note;
    report "Last $8000 value: $" & to_hstring(mem_8000_last) severity note;
    report "" severity note;

    if jumped_early and not write_to_8000 then
      report "DIAGNOSIS: CPU skipped the indirect-Y instruction" severity error;
      report "NEXT STEPS:" severity note;
      report "  1. Check if T65 is in correct 6502 mode" severity note;
      report "  2. Verify zero-page reads ($F2,$F3) work during indirect addressing" severity note;
      report "  3. Check if illegal/undefined opcode is being treated as NOP" severity note;
    end if;

    report "================================================================" severity note;

    wait;
  end process;

end architecture;
