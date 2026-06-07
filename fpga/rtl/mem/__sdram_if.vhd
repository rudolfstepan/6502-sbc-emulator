-- SDRAM Interface: translates single-byte 6502 bus accesses into burst-1
-- requests to sdram_ctrl.  Asserts rdy='0' while the SDRAM is busy.
--
-- Key design decisions:
--  * Does NOT submit any access until ctrl_idle='1' (SDRAM init complete).
--    This prevents the ~300 us startup deadlock.
--  * CPU writes are latched immediately, even while ctrl_idle='0'.  The
--    T65/6502 ignores RDY during write cycles, so the one-clock cpu_bus_we
--    pulse would otherwise be lost if it collides with refresh/busy SDRAM.
--  * Only releases the CPU (rdy='1') after ctrl_idle='1', ensuring sdram_ctrl
--    has fully returned to S_IDLE.  The "premature-finish" race that caused
--    back-to-back accesses to dead-lock is eliminated.
--  * Writes are triggered by cpu_bus_we='1' (cpu_we AND NOT cpu_enable),
--    which is already gated to the correct write phase.
--  * Reads are triggered by cs='1' AND cpu_we='0' (T65 raw WE='0' for reads).
--  * A one-clock S_LOCKED cooldown after each access prevents the same cs='1'
--    level from immediately re-triggering in S_IDLE.
--
-- Address mapping (32 KB):
--   6502 addr[14:0]  →  SDRAM 24-bit word address {9'b0, addr[14:0]}
--   Lower byte (DQ[7:0]) used; DQM="10" masks upper byte on writes.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.sbc_pkg.all;

entity sdram_if is
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;
    -- 6502 bus
    addr      : in  std_logic_vector(14 downto 0);  -- A[14:0] = 32 KB
    din       : in  data_t;
    dout      : out data_t;
    cs        : in  std_logic;   -- high when SDRAM range is selected
    cpu_we    : in  std_logic;   -- T65 raw WE (distinguishes read from write)
    cpu_bus_we: in  std_logic;   -- cpu_we AND NOT cpu_enable (write phase gate)
    rdy       : out std_logic;   -- '0' = CPU wait state
    -- sdram_ctrl status
    ctrl_idle : in  std_logic;   -- '1' when sdram_ctrl is in S_IDLE
    -- sdram_ctrl burst interface
    wr_burst_req      : out std_logic;
    wr_burst_data     : out std_logic_vector(15 downto 0);
    wr_burst_len      : out std_logic_vector(9 downto 0);
    wr_burst_addr     : out std_logic_vector(23 downto 0);
    wr_dqm            : out std_logic_vector(1 downto 0);
    wr_burst_data_req : in  std_logic;
    wr_burst_finish   : in  std_logic;
    rd_burst_req      : out std_logic;
    rd_burst_len      : out std_logic_vector(9 downto 0);
    rd_burst_addr     : out std_logic_vector(23 downto 0);
    rd_burst_data     : in  std_logic_vector(15 downto 0);
    rd_burst_data_valid : in std_logic;
    rd_burst_finish   : in  std_logic
  );
end entity;

architecture rtl of sdram_if is

  type state_t is (S_IDLE, S_LOCKED, S_RD_REQ, S_RD_WAIT, S_WR_HOLD, S_WR_REQ, S_WR_WAIT);
  signal state    : state_t;
  signal dout_reg : data_t;
  signal addr_lat : std_logic_vector(23 downto 0);
  signal din_lat  : data_t;

begin

  wr_burst_len  <= std_logic_vector(to_unsigned(1, 10));
  rd_burst_len  <= std_logic_vector(to_unsigned(1, 10));
  wr_burst_data <= "00000000" & din_lat;
  wr_dqm        <= "10";          -- write lower byte only (DQ[7:0])
  wr_burst_addr <= addr_lat;
  rd_burst_addr <= addr_lat;
  dout          <= dout_reg;

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        state        <= S_IDLE;
        wr_burst_req <= '0';
        rd_burst_req <= '0';
        rdy          <= '1';
        dout_reg     <= (others => '0');
        addr_lat     <= (others => '0');
        din_lat      <= (others => '0');
      else
        case state is

          -- ---- Idle: latch writes immediately; reads can wait via RDY ----
          when S_IDLE =>
            wr_burst_req <= '0';
            rd_burst_req <= '0';
            rdy          <= '1';
            if cs = '1' and cpu_bus_we = '1' then
              -- Write: cpu_bus_we is a one-clock pulse.  Capture it even if
              -- the SDRAM controller is currently in refresh or another access.
              addr_lat <= "000000000" & addr;
              din_lat  <= din;
              rdy      <= '0';
              if ctrl_idle = '1' then
                state    <= S_WR_REQ;
              else
                state    <= S_WR_HOLD;
              end if;
            elsif ctrl_idle = '1' then
              if cs = '1' and cpu_we = '0' then
                -- Read: cpu_we='0' throughout the read cycle.
                addr_lat <= "000000000" & addr;
                rdy      <= '0';
                state    <= S_RD_REQ;
              end if;
            elsif cs = '1' then
              -- A selected read must wait through init/refresh.
              rdy <= '0';
            end if;

          -- ---- One-clock cooldown: prevents level-triggered re-entry --------
          when S_LOCKED =>
            rdy   <= '1';
            state <= S_IDLE;

          -- ---- Write path --------------------------------------------------
          when S_WR_HOLD =>
            wr_burst_req <= '0';
            rd_burst_req <= '0';
            rdy          <= '0';
            if ctrl_idle = '1' then
              state <= S_WR_REQ;
            end if;

          when S_WR_REQ =>
            wr_burst_req <= '1';
            rdy          <= '0';
            -- Keep the request asserted until the controller really accepts it.
            -- A refresh can take priority in S_IDLE and would otherwise drop a
            -- one-clock request.
            if wr_burst_data_req = '1' then
              state <= S_WR_WAIT;
            end if;

          when S_WR_WAIT =>
            wr_burst_req <= '0';
            rdy          <= '0';
            -- Wait until sdram_ctrl returns to S_IDLE (fully committed + precharged)
            if ctrl_idle = '1' then
              rdy   <= '1';
              state <= S_LOCKED;
            end if;

          -- ---- Read path ---------------------------------------------------
          when S_RD_REQ =>
            rd_burst_req <= '1';
            rdy          <= '0';
            -- Hold through possible refresh arbitration until read data appears.
            if rd_burst_data_valid = '1' then
              dout_reg <= rd_burst_data(7 downto 0);
              state    <= S_RD_WAIT;
            end if;

          when S_RD_WAIT =>
            rd_burst_req <= '0';
            rdy          <= '0';
            -- Capture data as soon as valid
            if rd_burst_data_valid = '1' then
              dout_reg <= rd_burst_data(7 downto 0);
            end if;
            -- Release CPU only after SDRAM is back in S_IDLE
            if ctrl_idle = '1' then
              rdy   <= '1';
              state <= S_LOCKED;
            end if;

          when others =>
            state <= S_IDLE;
        end case;
      end if;
    end if;
  end process;

end architecture;
