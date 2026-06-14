-- SDRAM Controller for HY57V2562GTR (256Mbit, 16-bit)
-- Ported from sdram_core.v (ALINX/meisq) to VHDL.
-- Default parameters target 50 MHz (REFRESH_CYC=375 for 7.5 us refresh).
-- Burst-based interface: present burst_req for one clock to start a transfer.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sdram_ctrl is
  generic (
    T_RP        : natural := 4;      -- precharge to active (clocks)
    T_RC        : natural := 6;      -- row cycle time (clocks)
    T_MRD       : natural := 6;      -- mode-register delay (clocks)
    T_RCD       : natural := 2;      -- RAS-to-CAS delay (clocks)
    T_WR        : natural := 3;      -- write recovery (clocks)
    CAS_LAT     : natural := 3;      -- CAS latency (clocks)
    REFRESH_CYC : natural := 375;    -- refresh period  (375 = 7.5 us @ 50 MHz)
    INIT_CYC    : natural := 15000   -- power-on wait   (300 us @ 50 MHz)
  );
  port (
    clk               : in    std_logic;
    rst               : in    std_logic;   -- synchronous, active-high
    -- ---- write burst ----
    wr_burst_req      : in    std_logic;
    wr_burst_data     : in    std_logic_vector(15 downto 0);
    wr_burst_len      : in    std_logic_vector(9 downto 0);
    wr_burst_addr     : in    std_logic_vector(23 downto 0);
    wr_dqm            : in    std_logic_vector(1 downto 0);  -- byte mask during write
    wr_burst_data_req : out   std_logic;
    wr_burst_finish   : out   std_logic;
    -- ---- read burst ----
    rd_burst_req      : in    std_logic;
    rd_burst_len      : in    std_logic_vector(9 downto 0);
    rd_burst_addr     : in    std_logic_vector(23 downto 0);
    rd_burst_data     : out   std_logic_vector(15 downto 0);
    rd_burst_data_valid : out std_logic;
    rd_burst_finish   : out   std_logic;
    -- ---- SDRAM pins ----
    sdram_cke         : out   std_logic;
    sdram_cs_n        : out   std_logic;
    sdram_ras_n       : out   std_logic;
    sdram_cas_n       : out   std_logic;
    sdram_we_n        : out   std_logic;
    sdram_ba          : out   std_logic_vector(1 downto 0);
    sdram_addr        : out   std_logic_vector(12 downto 0);
    sdram_dqm         : out   std_logic_vector(1 downto 0);
    sdram_dq          : inout std_logic_vector(15 downto 0);
    -- '1' when controller is in S_IDLE and ready for a new request
    ctrl_idle         : out   std_logic
  );
end entity;

architecture rtl of sdram_ctrl is

  type state_t is (
    S_INIT_NOP, S_INIT_PRE, S_INIT_TRP,
    S_INIT_AR1, S_INIT_TRF1, S_INIT_AR2, S_INIT_TRF2,
    S_INIT_MRS, S_INIT_TMRD, S_INIT_DONE,
    S_IDLE,
    S_ACTIVE, S_TRCD,
    S_READ,  S_CL,  S_RD,
    S_WRITE, S_WD,  S_TWR,
    S_PRE,   S_TRP,
    S_AR,    S_TRFC
  );

  signal state        : state_t;
  signal read_flag    : std_logic;
  signal ref_req      : std_logic;
  signal cnt_init     : unsigned(14 downto 0);
  signal cnt_ref      : unsigned(10 downto 0);
  signal cnt_clk      : unsigned(9 downto 0);
  signal cnt_en       : std_logic;
  signal dq_out       : std_logic_vector(15 downto 0);
  signal dq_in        : std_logic_vector(15 downto 0);
  signal dq_oe        : std_logic;
  signal ras_r        : std_logic;
  signal cas_r        : std_logic;
  signal we_r         : std_logic;
  signal ba_r         : std_logic_vector(1 downto 0);
  signal addr_r       : std_logic_vector(12 downto 0);
  signal sys_addr     : std_logic_vector(23 downto 0);
  -- delay regs for finish-pulse generation
  signal wr_req_d0    : std_logic;
  signal wr_req_d1    : std_logic;
  signal rd_vld_d0    : std_logic;
  signal rd_vld_d1    : std_logic;
  signal wr_req_s     : std_logic;
  signal rd_vld_s     : std_logic;

  -- Timing end-conditions (combinational)
  signal end_trp   : boolean;
  signal end_trfc  : boolean;
  signal end_tmrd  : boolean;
  signal end_trcd  : boolean;
  signal end_tcl   : boolean;
  signal end_tread : boolean;
  signal end_twrite: boolean;
  signal end_twr   : boolean;

begin

  -- -----------------------------------------------------------------------
  -- Combinational timing conditions
  -- -----------------------------------------------------------------------
  end_trp   <= cnt_clk = T_RP;
  end_trfc  <= cnt_clk = T_RC;
  end_tmrd  <= cnt_clk = T_MRD;
  end_trcd  <= cnt_clk = T_RCD - 1;
  end_tcl   <= cnt_clk = CAS_LAT - 1;
  end_tread <= cnt_clk = unsigned(rd_burst_len) + 2;
  end_twrite<= cnt_clk = unsigned(wr_burst_len) - 1;
  end_twr   <= cnt_clk = T_WR;

  sys_addr <= rd_burst_addr when read_flag = '1' else wr_burst_addr;

  -- -----------------------------------------------------------------------
  -- Power-on init counter (counts to INIT_CYC, ~300 us @ 50 MHz)
  -- -----------------------------------------------------------------------
  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cnt_init <= (others => '0');
      elsif cnt_init < INIT_CYC then
        cnt_init <= cnt_init + 1;
      end if;
    end if;
  end process;

  -- -----------------------------------------------------------------------
  -- Refresh request counter (every REFRESH_CYC clocks = 7.5 us @ 50 MHz)
  -- -----------------------------------------------------------------------
  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cnt_ref <= (others => '0');
        ref_req <= '0';
      elsif cnt_ref < REFRESH_CYC then
        cnt_ref <= cnt_ref + 1;
      else
        cnt_ref <= (others => '0');
        ref_req <= '1';
      end if;
      if ref_req = '1' and state = S_AR then
        ref_req <= '0';
      end if;
    end if;
  end process;

  -- -----------------------------------------------------------------------
  -- Clock counter (resets when cnt_en='0', increments when cnt_en='1')
  -- cnt_en is derived combinatorially from state and timing conditions.
  -- -----------------------------------------------------------------------
  cnt_en <= '0' when
    state = S_INIT_NOP  or
    state = S_IDLE      or
    (state = S_INIT_TRP  and end_trp)   or
    (state = S_INIT_TRF1 and end_trfc)  or
    (state = S_INIT_TRF2 and end_trfc)  or
    (state = S_INIT_TMRD and end_tmrd)  or
    (state = S_INIT_DONE) or
    (state = S_TRCD      and end_trcd)  or
    (state = S_CL        and end_tcl)   or
    (state = S_RD        and end_tread) or
    (state = S_WD        and end_twrite) or
    (state = S_TWR       and end_twr)   or
    (state = S_TRP       and end_trp)   or
    (state = S_TRFC      and end_trfc)  or
    state = S_READ  or
    state = S_WRITE or
    state = S_PRE   or
    state = S_AR
  else '1';

  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or cnt_en = '0' then
        cnt_clk <= (others => '0');
      else
        cnt_clk <= cnt_clk + 1;
      end if;
    end if;
  end process;

  -- -----------------------------------------------------------------------
  -- Main state machine
  -- -----------------------------------------------------------------------
  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        state     <= S_INIT_NOP;
        read_flag <= '1';
        ras_r <= '1'; cas_r <= '1'; we_r <= '1';
        ba_r  <= (others => '1');
        addr_r<= (others => '1');
      else
        case state is
          -- ---- Initialisation sequence ----------------------------------
          when S_INIT_NOP =>
            if cnt_init = INIT_CYC then state <= S_INIT_PRE; end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';
            ba_r  <= (others => '1'); addr_r <= (others => '1');

          when S_INIT_PRE =>
            state <= S_INIT_TRP;
            ras_r <= '0'; cas_r <= '1'; we_r <= '0';   -- PRECHARGE ALL
            ba_r  <= (others => '1'); addr_r <= (others => '1');

          when S_INIT_TRP =>
            if end_trp  then state <= S_INIT_AR1; end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          when S_INIT_AR1 =>
            state <= S_INIT_TRF1;
            ras_r <= '0'; cas_r <= '0'; we_r <= '1';   -- AUTO REFRESH

          when S_INIT_TRF1 =>
            if end_trfc then state <= S_INIT_AR2; end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          when S_INIT_AR2 =>
            state <= S_INIT_TRF2;
            ras_r <= '0'; cas_r <= '0'; we_r <= '1';

          when S_INIT_TRF2 =>
            if end_trfc then state <= S_INIT_MRS; end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          when S_INIT_MRS =>
            state <= S_INIT_TMRD;
            -- Mode: CAS=3, burst-length=1, sequential
            ras_r <= '0'; cas_r <= '0'; we_r <= '0';
            ba_r  <= (others => '0');
            addr_r<= "0000000110000";  -- CAS=3, BL=1

          when S_INIT_TMRD =>
            if end_tmrd then state <= S_INIT_DONE; end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          when S_INIT_DONE =>
            state <= S_IDLE;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          -- ---- Idle / arbitration ---------------------------------------
          when S_IDLE =>
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';
            ba_r  <= (others => '1'); addr_r <= (others => '1');
            if ref_req = '1' then
              state <= S_AR; read_flag <= '1';
            elsif wr_burst_req = '1' then
              state <= S_ACTIVE; read_flag <= '0';
            elsif rd_burst_req = '1' then
              state <= S_ACTIVE; read_flag <= '1';
            end if;

          -- ---- Row activate ---------------------------------------------
          when S_ACTIVE =>
            state <= S_TRCD;
            ras_r <= '0'; cas_r <= '1'; we_r <= '1';  -- ACTIVE
            ba_r   <= sys_addr(23 downto 22);
            addr_r <= sys_addr(21 downto 9);           -- row address

          when S_TRCD =>
            if end_trcd then
              if read_flag = '1' then state <= S_READ; else state <= S_WRITE; end if;
            end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          -- ---- Read path ------------------------------------------------
          when S_READ =>
            state <= S_CL;
            ras_r <= '1'; cas_r <= '0'; we_r <= '1';  -- READ
            ba_r   <= sys_addr(23 downto 22);
            addr_r <= "0000" & sys_addr(8 downto 0);  -- col, A10=0

          when S_CL =>
            if end_tcl then state <= S_RD; end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          when S_RD =>
            if end_tread then state <= S_PRE; end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          -- ---- Write path -----------------------------------------------
          when S_WRITE =>
            state <= S_WD;
            ras_r <= '1'; cas_r <= '0'; we_r <= '0';  -- WRITE
            ba_r   <= sys_addr(23 downto 22);
            addr_r <= "0000" & sys_addr(8 downto 0);  -- col, A10=0

          when S_WD =>
            if end_twrite then state <= S_TWR; end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          when S_TWR =>
            if end_twr then state <= S_PRE; end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          -- ---- Precharge ------------------------------------------------
          when S_PRE =>
            state <= S_TRP;
            ras_r <= '0'; cas_r <= '1'; we_r <= '0';  -- PRECHARGE ALL
            ba_r  <= (others => '1'); addr_r <= (others => '1');

          when S_TRP =>
            if end_trp then state <= S_IDLE; end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          -- ---- Auto refresh ---------------------------------------------
          when S_AR =>
            state <= S_TRFC;
            ras_r <= '0'; cas_r <= '0'; we_r <= '1';  -- AUTO REFRESH

          when S_TRFC =>
            if end_trfc then state <= S_IDLE; end if;
            ras_r <= '1'; cas_r <= '1'; we_r <= '1';

          when others =>
            state <= S_INIT_NOP;
        end case;
      end if;
    end if;
  end process;

  -- -----------------------------------------------------------------------
  -- DQ tri-state: driven during WRITE/WD states
  -- -----------------------------------------------------------------------
  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        dq_oe  <= '0';
        dq_out <= (others => '0');
      elsif state = S_WRITE or state = S_WD then
        dq_oe  <= '1';
        dq_out <= wr_burst_data;
      else
        dq_oe  <= '0';
      end if;
    end if;
  end process;

  -- Capture read data from SDRAM
  process(clk)
  begin
    if rising_edge(clk) then
      if state = S_RD then
        dq_in <= sdram_dq;
      end if;
    end if;
  end process;

  -- -----------------------------------------------------------------------
  -- Burst-interface signals
  -- -----------------------------------------------------------------------
  wr_req_s <= '1' when (state = S_TRCD and read_flag = '0')
                     or  state = S_WRITE
                     or (state = S_WD and cnt_clk < unsigned(wr_burst_len) - 2)
              else '0';

  rd_vld_s <= '1' when state = S_RD
                   and cnt_clk >= 1
                   and cnt_clk < unsigned(rd_burst_len) + 1
              else '0';

  -- Falling-edge detectors for finish pulses
  process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        wr_req_d0 <= '0'; wr_req_d1 <= '0';
        rd_vld_d0 <= '0'; rd_vld_d1 <= '0';
      else
        wr_req_d0 <= wr_req_s;  wr_req_d1 <= wr_req_d0;
        rd_vld_d0 <= rd_vld_s;  rd_vld_d1 <= rd_vld_d0;
      end if;
    end if;
  end process;

  wr_burst_data_req   <= wr_req_s;
  rd_burst_data_valid <= rd_vld_s;
  wr_burst_finish     <= '1' when wr_req_d0 = '0' and wr_req_d1 = '1' else '0';
  rd_burst_finish     <= '1' when rd_vld_d0 = '0' and rd_vld_d1 = '1' else '0';
  rd_burst_data       <= dq_in;

  -- -----------------------------------------------------------------------
  -- SDRAM pin drives
  -- -----------------------------------------------------------------------
  sdram_cke   <= '1';
  sdram_cs_n  <= '0';
  sdram_ras_n <= ras_r;
  sdram_cas_n <= cas_r;
  sdram_we_n  <= we_r;
  sdram_ba    <= ba_r;
  sdram_addr  <= addr_r;
  sdram_dqm   <= wr_dqm when dq_oe = '1' else (others => '0');
  sdram_dq    <= dq_out when dq_oe = '1' else (others => 'Z');
  ctrl_idle   <= '1' when state = S_IDLE else '0';

end architecture;
