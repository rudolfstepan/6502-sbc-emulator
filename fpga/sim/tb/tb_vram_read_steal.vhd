-- tb_vram_read_steal.vhd
--
-- Reproduction testbench for the "random A ($01) appears when the screen
-- scrolls" artefact. Scrolling is a burst of VRAM read-modify-write (read row
-- N+1, write row N). The suspected root cause is a single-port VRAM
-- read-after-steal hazard:
--
--   * The VRAM (sync_ram) has one cycle of read latency.
--   * During a VIC bus steal, vram_addr_mux is driven by vic_addr, so vram_dout
--     holds the VIC's fetched byte (e.g. a COLOUR value such as $01).
--   * cpu_rdy goes high the instant the steal ends, but vram_dout still reflects
--     the VIC address for one more cycle. If the CPU samples its VRAM read in
--     that cycle it latches the VIC's byte ($01) instead of the character ($20),
--     then the scroll writes that $01 upward -> stray 'A' on screen.
--
-- Whether the CPU's read-completion edge lands in that stale window depends on
-- the cpu_enable phase relative to the steal — which is why adding the sound
-- modules (which shifted place & route / phase) made a latent hazard visible.
--
-- The fix (generic READ_LATENCY_FIX) holds cpu_rdy low for one extra cycle after
-- a steal ends, so the RAM always presents the CPU's own address before the CPU
-- samples. With the fix, no stale read can ever occur regardless of phase.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sbc_pkg.all;

entity tb_vram_read_steal is
  generic (
    READ_LATENCY_FIX : boolean := false
  );
end entity;

architecture sim of tb_vram_read_steal is
  constant CLK_PERIOD : time := 37 ns;

  signal clk     : std_logic := '0';
  signal reset_n : std_logic := '0';

  signal cpu_enable : std_logic := '0';

  -- CPU bus
  signal cpu_addr : addr_t := x"8005";   -- reads the character cell at $8005
  signal cpu_dout : data_t := (others => '0');
  signal cpu_we   : std_logic := '0';
  signal cpu_rdy  : std_logic;

  -- VIC steal model
  signal vic_stealing   : std_logic := '0';
  signal vic_stealing_d : std_logic := '0';
  signal vic_addr       : addr_t := x"8010";  -- VIC fetches the colour cell $8010

  -- VRAM arbitration (read-relevant subset of the top level)
  signal vram_addr_mux : std_logic_vector(10 downto 0);
  signal vram_we_mux   : std_logic;
  signal vram_din_mux  : data_t;
  signal vram_dout     : data_t;

  -- what the CPU actually latches on its read cycles
  signal reads_done : integer := 0;
  signal stale_reads : integer := 0;

  type phase_t is (P_INIT, P_READ, P_DONE);
  signal phase : phase_t := P_INIT;
begin
  clk     <= not clk after CLK_PERIOD/2;
  reset_n <= '1' after 6*CLK_PERIOD;

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then cpu_enable <= '0';
      else cpu_enable <= not cpu_enable; end if;
    end if;
  end process;

  -- cpu_rdy, with and without the read-latency fix
  process(clk)
  begin
    if rising_edge(clk) then
      vic_stealing_d <= vic_stealing;
    end if;
  end process;

  cpu_rdy <= '0' when vic_stealing = '1' else
             '0' when (READ_LATENCY_FIX and vic_stealing_d = '1') else
             '1';

  -- real single-port VRAM
  vram : entity work.sync_ram
    generic map (ADDR_WIDTH => 11, ASYNC_READ => false)
    port map (clk => clk, we => vram_we_mux,
              addr => vram_addr_mux, din => vram_din_mux, dout => vram_dout);

  -- address mux exactly like the top: VIC owns the bus during a steal
  vram_addr_mux <= vic_addr(10 downto 0) when vic_stealing = '1'
                   else cpu_addr(10 downto 0);
  vram_din_mux  <= cpu_dout;
  vram_we_mux   <= cpu_we when vic_stealing = '0' else '0';

  -- VIC steal generator: 5 cycles on / 4 off (period 9, odd) so the steal-end
  -- edge rotates through both cpu_enable phases over time.
  vic_gen : process(clk)
    variable c : integer := 0;
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        c := 0; vic_stealing <= '0';
      elsif phase = P_READ then
        c := (c + 1) mod 9;
        if c < 5 then vic_stealing <= '1'; else vic_stealing <= '0'; end if;
      else
        vic_stealing <= '0';
      end if;
    end if;
  end process;

  -- CPU model
  cpu : process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '1' and cpu_enable = '1' then
        case phase is
          when P_INIT =>
            null;  -- init writes handled by the stimulus driving cpu_* directly
          when P_READ =>
            -- A read completes whenever the CPU is enabled and ready. Sample the
            -- byte the CPU would latch for its VRAM read.
            if cpu_rdy = '1' and cpu_we = '0' then
              reads_done <= reads_done + 1;
              if vram_dout = x"01" then
                stale_reads <= stale_reads + 1;
              end if;
            end if;
          when others =>
            null;
        end case;
      end if;
    end if;
  end process;

  stim : process
  begin
    wait until reset_n = '1';
    wait for 2*CLK_PERIOD;

    -- INIT: write $20 to char cell $8005 and $01 to colour cell $8010
    -- (no steals during init).
    phase <= P_INIT;
    cpu_addr <= x"8005"; cpu_dout <= x"20"; cpu_we <= '1';
    wait for 2*CLK_PERIOD;
    cpu_addr <= x"8010"; cpu_dout <= x"01"; cpu_we <= '1';
    wait for 2*CLK_PERIOD;
    cpu_we <= '0';
    cpu_addr <= x"8005";   -- CPU now continuously reads the char cell
    wait for 2*CLK_PERIOD;

    -- READ phase: steals collide with the continuous read of $8005.
    phase <= P_READ;
    wait for 6000*CLK_PERIOD;

    phase <= P_DONE;
    wait for 20*CLK_PERIOD;

    report "READ_LATENCY_FIX = " & boolean'image(READ_LATENCY_FIX) severity note;
    report "VRAM reads completed: " & integer'image(reads_done) severity note;
    report "STALE reads (latched $01 from VIC instead of $20): " &
           integer'image(stale_reads) severity note;

    if stale_reads = 0 then
      report "PASS: every VRAM read returned the correct character ($20)."
        severity note;
    else
      report "FAIL: read-after-steal hazard reproduced -> scroll copies $01 ('A')."
        severity note;
    end if;

    std.env.stop;
  end process;
end architecture;
