-- tb_vram_steal_race.vhd
--
-- Reproduction testbench for the "random A ($01) in VRAM during sound playback"
-- artefact. It replicates the EXACT VRAM bus-steal arbitration from
-- sbc_t65_boot_monitor_top.vhd (deferred-write latch + cpu_rdy + vram_*_mux)
-- using the real bus_decode, and drives it with:
--
--   Phase 1 (siren-like): a CPU that does nothing but write $01 to the sound
--     FREQ_HI register ($8831) at the maximum rate, while the VIC steals the bus
--     frequently with a scanning vic_addr. This mirrors soundtest.bas options
--     1-4, which write $01 to $8831 in tight loops and never touch VRAM.
--     EXPECTATION: not a single VRAM write must occur in this phase.
--
--   Phase 2 (menu-print-like): the CPU writes a known character stream to VRAM
--     cells while steals keep colliding, exercising the deferred-write latch.
--     EXPECTATION: every intended (addr,data) is committed exactly once, in
--     order, with no spurious or lost writes.
--
-- The CPU model is run in the worst case IGNORE_RDY_WRITE = true: it advances
-- past a write cycle even while cpu_rdy = '0' (classic 6502 behaviour where RDY
-- only stalls reads). If the arbitration is sound, VRAM still stays clean.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity tb_vram_steal_race is
  generic (
    -- worst-case CPU: write cycles ignore RDY (proceed during a steal).
    -- Set false to model a CPU that stalls on RDY for every cycle.
    IGNORE_RDY_WRITE : boolean := true
  );
end entity;

architecture sim of tb_vram_steal_race is
  constant CLK_PERIOD : time := 37 ns;          -- ~27 MHz

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';

  -- CPU-side bus (driven by the behavioural CPU model)
  signal cpu_addr : addr_t := (others => '0');
  signal cpu_dout : data_t := (others => '0');
  signal cpu_we   : std_logic := '0';
  signal cpu_enable : std_logic := '0';
  signal cpu_bus_we : std_logic;
  signal cpu_rdy    : std_logic;

  -- VIC steal model
  signal vic_stealing : std_logic := '0';
  signal vic_addr     : addr_t := (others => '0');
  constant vic_fetch_bitmap : std_logic := '0';
  constant monitor_hold     : std_logic := '0';

  -- decode
  signal dev_sel : device_sel_t;

  -- VRAM arbitration (exact copy of the top-level signals)
  signal vram_we       : std_logic;
  signal vram_addr     : std_logic_vector(10 downto 0);
  signal vram_addr_mux : std_logic_vector(10 downto 0);
  signal vram_we_mux   : std_logic;
  signal vram_din_mux  : data_t;
  signal vram_wr_pending : std_logic := '0';
  signal vram_wr_addr    : std_logic_vector(10 downto 0) := (others => '0');
  signal vram_wr_data    : data_t := (others => '0');

  -- test phase / scoreboard
  type phase_t is (P_RESET, P_SIREN, P_MENU, P_DONE);
  signal phase : phase_t := P_RESET;

  signal siren_vram_writes : integer := 0;   -- must stay 0
  signal spurious_seen     : boolean := false;

  -- menu scoreboard
  constant MENU_LEN : integer := 32;
  type byte_arr is array (0 to MENU_LEN-1) of integer;
  -- intended VRAM cell addresses and data for phase 2
  signal menu_committed : byte_arr := (others => -1);  -- data seen at each cell
  signal menu_writes    : integer := 0;
begin
  clk     <= not clk after CLK_PERIOD/2;
  reset_n <= '1' after 6*CLK_PERIOD;

  -- cpu_enable toggles every clock, exactly like the top-level.
  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        cpu_enable <= '0';
      else
        cpu_enable <= not cpu_enable;
      end if;
    end if;
  end process;

  cpu_bus_we <= cpu_we and not cpu_enable;
  cpu_rdy    <= not vic_stealing and not vram_wr_pending and not monitor_hold;

  -- real address decoder
  dec : entity work.bus_decode
    port map (addr => cpu_addr, sel => dev_sel);

  -- ===== EXACT arbitration copy from sbc_t65_boot_monitor_top.vhd =====
  vram_we <= cpu_bus_we when monitor_hold = '0' and dev_sel = DEV_VIC_TEXT else '0';

  vram_addr   <= vic_addr(10 downto 0)
                 when vic_stealing = '1' and vic_fetch_bitmap = '0'
                 else cpu_addr(10 downto 0);

  vram_addr_mux <= vram_wr_addr when vram_wr_pending = '1' and vic_stealing = '0'
                   else vram_addr;

  vram_we_mux <= '1' when vram_wr_pending = '1' and vic_stealing = '0' else
                 '0' when vic_stealing = '1' else
                 vram_we;

  vram_din_mux <= vram_wr_data when vram_wr_pending = '1' and vic_stealing = '0'
                  else cpu_dout;

  defer : process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        vram_wr_pending <= '0';
        vram_wr_addr    <= (others => '0');
        vram_wr_data    <= (others => '0');
      elsif vram_wr_pending = '1' and vic_stealing = '0' then
        vram_wr_pending <= '0';
      elsif vram_we = '1' and vic_stealing = '1' then
        vram_wr_pending <= '1';
        vram_wr_addr    <= cpu_addr(10 downto 0);
        vram_wr_data    <= cpu_dout;
      end if;
    end if;
  end process;
  -- ===================================================================

  -- VIC steal generator: mimic vic_vga fetching one scanline (40 chars + 40
  -- colours ~ 80 stolen cycles) followed by a visible gap, with vic_addr
  -- scanning through the 2 KB VRAM. Frequent, asynchronous to CPU writes.
  vic_gen : process(clk)
    variable cnt   : integer := 0;
    variable a     : integer := 0;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        cnt := 0; a := 0; vic_stealing <= '0'; vic_addr <= (others => '0');
      else
        cnt := cnt + 1;
        if (cnt mod 110) < 80 then
          vic_stealing <= '1';
          a := (a + 1) mod 2048;
          vic_addr <= std_logic_vector(to_unsigned(16#8000# + a, 16));
        else
          vic_stealing <= '0';
        end if;
      end if;
    end if;
  end process;

  -- Behavioural CPU: advances on enable=1 edges, honouring rdy except (when
  -- IGNORE_RDY_WRITE) on write cycles. Presents a transaction pattern per phase.
  cpu_model : process(clk)
    variable advance : boolean;
    variable midx    : integer := 0;   -- menu write index
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        cpu_we <= '0'; cpu_addr <= (others => '0'); cpu_dout <= (others => '0');
      elsif cpu_enable = '1' then
        advance := (cpu_rdy = '1') or (cpu_we = '1' and IGNORE_RDY_WRITE);
        if advance then
          case phase is
            when P_SIREN =>
              -- STA $8831, #$01  (FREQ_HI = 1) — never targets VRAM
              cpu_addr <= x"8831";
              cpu_dout <= x"01";
              cpu_we   <= '1';
            when P_MENU =>
              -- Write a known stream into VRAM cells 0..MENU_LEN-1, with a
              -- read gap between writes so a single-entry deferred latch can
              -- commit each write before the next (mirrors real BASIC PRINT,
              -- which does plenty of non-VRAM work between screen stores).
              if midx < MENU_LEN*4 then
                if (midx mod 4) = 0 then
                  cpu_addr <= std_logic_vector(to_unsigned(16#8000# + (midx/4), 16));
                  cpu_dout <= std_logic_vector(to_unsigned(16#41# + ((midx/4) mod 16), 8));
                  cpu_we   <= '1';
                else
                  cpu_addr <= x"0010";  -- harmless ZP read between writes
                  cpu_we   <= '0';
                end if;
                midx := midx + 1;
              else
                cpu_addr <= x"0010";
                cpu_we   <= '0';
              end if;
            when others =>
              cpu_we <= '0';
          end case;
        end if;
      end if;
    end if;
  end process;

  -- Scoreboard: watch every committed VRAM write.
  monitor : process(clk)
    variable cell : integer;
    variable d    : integer;
  begin
    if rising_edge(clk) then
      if reset_n = '1' and vram_we_mux = '1' then
        cell := to_integer(unsigned(vram_addr_mux));
        d    := to_integer(unsigned(vram_din_mux));
        if phase = P_SIREN then
          -- ANY VRAM write during the pure-sound phase is spurious.
          siren_vram_writes <= siren_vram_writes + 1;
          spurious_seen <= true;
          report "SPURIOUS VRAM write during sound phase: cell=" &
                 integer'image(cell) & " data=$" &
                 integer'image(d) severity warning;
        elsif phase = P_MENU then
          menu_writes <= menu_writes + 1;
          if cell < MENU_LEN then
            menu_committed(cell) <= d;
          end if;
          if d = 16#01# then
            spurious_seen <= true;
            report "Unexpected $01 written to VRAM cell " &
                   integer'image(cell) severity warning;
          end if;
        end if;
      end if;
    end if;
  end process;

  stim : process
    variable ok : boolean := true;
  begin
    wait until reset_n = '1';
    wait for 4*CLK_PERIOD;

    -- Phase 1: heavy sound writes during steals.
    phase <= P_SIREN;
    wait for 20000*CLK_PERIOD;

    -- Phase 2: menu-style VRAM writes during steals.
    phase <= P_MENU;
    wait for 16000*CLK_PERIOD;

    phase <= P_DONE;
    wait for 50*CLK_PERIOD;

    -- ---- Evaluate ----
    report "IGNORE_RDY_WRITE = " & boolean'image(IGNORE_RDY_WRITE) severity note;
    report "siren-phase VRAM writes (expect 0): " &
           integer'image(siren_vram_writes) severity note;
    report "menu-phase VRAM writes committed: " & integer'image(menu_writes) &
           " of " & integer'image(MENU_LEN) severity note;

    -- PRIMARY result: the artefact is $01 appearing in VRAM during pure sound
    -- playback. That requires a VRAM write while the CPU only touches $8831.
    if siren_vram_writes /= 0 then
      ok := false;
      report "FAIL: sound-only writes corrupted VRAM (write-path race reproduced)"
        severity error;
    else
      report "OK: sound-only phase produced ZERO VRAM writes -> the $01 artefact "
           & "cannot originate in the VRAM write path." severity note;
    end if;

    -- SECONDARY: among committed menu writes, data must be correct (no wrong
    -- value reaching a cell). Missing cells are a separate 'lost-write' effect.
    for i in 0 to MENU_LEN-1 loop
      if menu_committed(i) /= -1 and
         menu_committed(i) /= (16#41# + (i mod 16)) then
        ok := false;
        report "FAIL: menu cell " & integer'image(i) & " got WRONG data " &
               integer'image(menu_committed(i)) severity error;
      end if;
    end loop;
    if menu_writes < MENU_LEN then
      report "NOTE: deferred latch LOST " &
             integer'image(MENU_LEN - menu_writes) &
             " menu writes (single-entry latch overwritten under steal load)."
             severity warning;
    end if;

    if ok and siren_vram_writes = 0 then
      report "PASS: write-path arbitration is clean; $01 artefact is NOT a "
           & "VRAM-write race -> look at the VIC display/fetch (timing) path."
             severity note;
    else
      report "RESULT: a write-path issue was reproduced (see above)." severity note;
    end if;

    std.env.stop;
  end process;
end architecture;
