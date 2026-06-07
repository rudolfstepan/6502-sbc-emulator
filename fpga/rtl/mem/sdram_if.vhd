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
--  * A small write FIFO captures CPU writes in every FSM state. This makes
--    NMOS/T65 write cycles robust against dummy reads, refresh slots and
--    back-to-back writes that cannot be stretched with RDY.
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

  -- Write FIFO.
  -- Needed for NMOS 6502/T65 write cycles which cannot reliably be stretched
  -- with RDY. In particular, STA abs,X performs a dummy read immediately before
  -- the real write; that write pulse can arrive while this interface is still
  -- servicing the dummy read.  A FIFO is safer than a single pending latch,
  -- because refresh or long SDRAM service can overlap more than one CPU write.
  constant WR_FIFO_DEPTH : natural := 32;
  type wr_addr_fifo_t is array (0 to WR_FIFO_DEPTH-1) of std_logic_vector(23 downto 0);
  type wr_data_fifo_t is array (0 to WR_FIFO_DEPTH-1) of data_t;

  signal wr_fifo_addr : wr_addr_fifo_t;
  signal wr_fifo_data : wr_data_fifo_t;
  signal wr_head      : natural range 0 to WR_FIFO_DEPTH-1;
  signal wr_tail      : natural range 0 to WR_FIFO_DEPTH-1;
  signal wr_count     : natural range 0 to WR_FIFO_DEPTH;
  signal wr_overflow  : std_logic;

begin

  wr_burst_len  <= std_logic_vector(to_unsigned(1, 10));
  rd_burst_len  <= std_logic_vector(to_unsigned(1, 10));
  wr_burst_data <= "00000000" & din_lat;
  wr_dqm        <= "10";          -- write lower byte only (DQ[7:0])
  wr_burst_addr <= addr_lat;
  rd_burst_addr <= addr_lat;
  dout          <= dout_reg;

  process(clk)
    variable v_count : natural range 0 to WR_FIFO_DEPTH;
    variable v_head  : natural range 0 to WR_FIFO_DEPTH-1;
    variable v_tail          : natural range 0 to WR_FIFO_DEPTH-1;
    variable push_write      : boolean;
    variable push_consumed   : boolean;
    variable push_addr       : std_logic_vector(23 downto 0);
    variable push_data       : data_t;
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
        wr_head      <= 0;
        wr_tail      <= 0;
        wr_count     <= 0;
        wr_overflow  <= '0';
      else
        -- Default pulse outputs low unless the active state keeps them asserted.
        -- Capture every CPU write pulse logically in this clock.  If the FSM can
        -- service it immediately, use the live addr/din values.  Otherwise push
        -- it into the FIFO at the end of the clock.  This avoids reading a FIFO
        -- entry in the same edge in which it was just written.
        v_count       := wr_count;
        v_head        := wr_head;
        v_tail        := wr_tail;
        push_write    := (cs = '1' and cpu_bus_we = '1');
        push_consumed := false;
        push_addr     := "000000000" & addr;
        push_data     := din;

        case state is

          -- ---- Idle: writes have priority; reads can wait via RDY ----------
          when S_IDLE =>
            wr_burst_req <= '0';
            rd_burst_req <= '0';
            rdy          <= '1';

            if v_count > 0 or push_write then
              -- Drain oldest queued write before accepting any read.  If no
              -- queued write exists, a live write pulse may be serviced directly
              -- from addr/din in this same clock.
              if v_count > 0 then
                addr_lat <= wr_fifo_addr(v_head);
                din_lat  <= wr_fifo_data(v_head);
                if v_head = WR_FIFO_DEPTH-1 then
                  v_head := 0;
                else
                  v_head := v_head + 1;
                end if;
                v_count := v_count - 1;
              else
                addr_lat      <= push_addr;
                din_lat       <= push_data;
                push_consumed := true;
              end if;
              rdy <= '0';
              if ctrl_idle = '1' then
                state <= S_WR_REQ;
              else
                state <= S_WR_HOLD;
              end if;

            elsif ctrl_idle = '1' then
              if cs = '1' and cpu_we = '0' then
                -- Read: cpu_we='0' throughout the read cycle.  Only start a
                -- read when no write is queued, so queued writes cannot be
                -- starved by level-triggered read cycles.
                addr_lat <= "000000000" & addr;
                rdy      <= '0';
                state    <= S_RD_REQ;
              end if;
            elsif cs = '1' then
              -- A selected read must wait through init/refresh.
              rdy <= '0';
            end if;

          -- ---- One-clock cooldown: pending writes still win ---------------
          when S_LOCKED =>
            wr_burst_req <= '0';
            rd_burst_req <= '0';
            rdy          <= '1';

            if v_count > 0 or push_write then
              if v_count > 0 then
                addr_lat <= wr_fifo_addr(v_head);
                din_lat  <= wr_fifo_data(v_head);
                if v_head = WR_FIFO_DEPTH-1 then
                  v_head := 0;
                else
                  v_head := v_head + 1;
                end if;
                v_count := v_count - 1;
              else
                addr_lat      <= push_addr;
                din_lat       <= push_data;
                push_consumed := true;
              end if;
              rdy <= '0';
              if ctrl_idle = '1' then
                state <= S_WR_REQ;
              else
                state <= S_WR_HOLD;
              end if;
            else
              state <= S_IDLE;
            end if;

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
            rd_burst_req <= '0';
            rdy          <= '0';
            -- Keep the request asserted until the controller really accepts it.
            -- A refresh can take priority in S_IDLE and would otherwise drop a
            -- one-clock request.
            if wr_burst_data_req = '1' then
              state <= S_WR_WAIT;
            end if;

          when S_WR_WAIT =>
            wr_burst_req <= '0';
            rd_burst_req <= '0';
            rdy          <= '0';
            -- Wait until sdram_ctrl returns to S_IDLE (fully committed + precharged)
            if ctrl_idle = '1' then
              if v_count > 0 or push_write then
                if v_count > 0 then
                  addr_lat <= wr_fifo_addr(v_head);
                  din_lat  <= wr_fifo_data(v_head);
                  if v_head = WR_FIFO_DEPTH-1 then
                    v_head := 0;
                  else
                    v_head := v_head + 1;
                  end if;
                  v_count := v_count - 1;
                else
                  addr_lat      <= push_addr;
                  din_lat       <= push_data;
                  push_consumed := true;
                end if;
                rdy   <= '0';
                state <= S_WR_REQ;
              else
                rdy   <= '1';
                state <= S_LOCKED;
              end if;
            end if;

          -- ---- Read path ---------------------------------------------------
          when S_RD_REQ =>
            wr_burst_req <= '0';
            rd_burst_req <= '1';
            rdy          <= '0';
            -- Hold through possible refresh arbitration until read data appears.
            if rd_burst_data_valid = '1' then
              dout_reg <= rd_burst_data(7 downto 0);
              state    <= S_RD_WAIT;
            end if;

          when S_RD_WAIT =>
            wr_burst_req <= '0';
            rd_burst_req <= '0';
            rdy          <= '0';
            -- Capture data as soon as valid.
            if rd_burst_data_valid = '1' then
              dout_reg <= rd_burst_data(7 downto 0);
            end if;
            -- Release CPU only after SDRAM is back in S_IDLE.  If one or more
            -- writes arrived while the dummy read was in progress, drain them
            -- immediately instead of releasing/re-entering idle.
            if ctrl_idle = '1' then
              if v_count > 0 or push_write then
                if v_count > 0 then
                  addr_lat <= wr_fifo_addr(v_head);
                  din_lat  <= wr_fifo_data(v_head);
                  if v_head = WR_FIFO_DEPTH-1 then
                    v_head := 0;
                  else
                    v_head := v_head + 1;
                  end if;
                  v_count := v_count - 1;
                else
                  addr_lat      <= push_addr;
                  din_lat       <= push_data;
                  push_consumed := true;
                end if;
                rdy   <= '0';
                state <= S_WR_REQ;
              else
                rdy   <= '1';
                state <= S_LOCKED;
              end if;
            end if;

          when others =>
            wr_burst_req <= '0';
            rd_burst_req <= '0';
            rdy          <= '1';
            state        <= S_IDLE;
        end case;

        -- Queue a write pulse only if it was not already used directly by the
        -- selected state above.  This preserves every write without a same-edge
        -- FIFO read-after-write hazard.
        if push_write and not push_consumed then
          if v_count < WR_FIFO_DEPTH then
            wr_fifo_addr(v_tail) <= push_addr;
            wr_fifo_data(v_tail) <= push_data;
            if v_tail = WR_FIFO_DEPTH-1 then
              v_tail := 0;
            else
              v_tail := v_tail + 1;
            end if;
            v_count := v_count + 1;
          else
            wr_overflow <= '1';
          end if;
        end if;

        wr_count <= v_count;
        wr_head  <= v_head;
        wr_tail  <= v_tail;
      end if;
    end if;
  end process;

end architecture;
