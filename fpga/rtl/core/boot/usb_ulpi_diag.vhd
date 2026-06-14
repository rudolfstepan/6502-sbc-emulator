-- USB3317/ULPI diagnostic sampler.
--
-- This is intentionally not a USB host yet. It releases the PHY from reset,
-- samples basic ULPI bus activity, and attempts to read the first four ULPI
-- ID registers so the boot screen can report whether the PHY is reachable.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity usb_ulpi_diag is
  port (
    clk       : in  std_logic;
    reset_n   : in  std_logic;

    ulpi_clk  : in  std_logic;
    ulpi_dir  : in  std_logic;
    ulpi_nxt  : in  std_logic;
    ulpi_data_i : in  std_logic_vector(7 downto 0);
    ulpi_data_o : out std_logic_vector(7 downto 0);
    ulpi_data_oe : out std_logic;
    ulpi_stp  : out std_logic;
    ulpi_rst  : out std_logic;

    status    : out std_logic_vector(7 downto 0);
    phy_id    : out std_logic_vector(31 downto 0)
  );
end entity;

architecture rtl of usb_ulpi_diag is
  constant ULPI_DIV_ZERO : unsigned(18 downto 0) := (others => '0');
  constant ULPI_READ_CMD : std_logic_vector(7 downto 6) := "11";
  constant ULPI_WRITE_CMD : std_logic_vector(7 downto 6) := "10";
  constant ULPI_SCRATCH_ADDR : std_logic_vector(5 downto 0) := "010110"; -- 0x16
  constant ULPI_SCRATCH_VALUE : std_logic_vector(7 downto 0) := x"A5";

  type read_state_t is (
    R_RESET_WAIT,
    R_WAIT_IDLE,
    R_CMD,
    R_RELEASE,
    R_WAIT_DIR,
    R_CAPTURE,
    R_GAP,
    W_SCR_CMD,
    W_SCR_DATA,
    W_SCR_GAP,
    R_SCR_CMD,
    R_SCR_RELEASE,
    R_SCR_WAIT_DIR,
    R_SCR_GAP,
    R_DONE,
    R_ERROR
  );

  signal ulpi_div      : unsigned(18 downto 0) := (others => '0');
  signal ulpi_tick     : std_logic := '0';
  signal ulpi_last_data : std_logic_vector(7 downto 0) := (others => '0');
  signal ulpi_status   : std_logic_vector(6 downto 0) := (others => '0');
  signal ulpi_id       : std_logic_vector(31 downto 0) := (others => '0');
  signal read_state    : read_state_t := R_RESET_WAIT;
  signal read_addr     : unsigned(1 downto 0) := (others => '0');
  signal wait_count    : unsigned(15 downto 0) := (others => '0');
  signal data_o_reg    : std_logic_vector(7 downto 0) := (others => '0');
  signal data_oe_reg   : std_logic := '0';
  signal stp_reg       : std_logic := '0';
  signal error_code    : std_logic_vector(3 downto 0) := (others => '0');
  signal scratch_read  : std_logic_vector(7 downto 0) := (others => '0');

  signal tick_meta     : std_logic := '0';
  signal tick_sync     : std_logic := '0';
  signal tick_prev     : std_logic := '0';
  signal clk_seen      : std_logic := '0';
  signal stat_meta     : std_logic_vector(6 downto 0) := (others => '0');
  signal stat_sync     : std_logic_vector(6 downto 0) := (others => '0');
  signal id_meta       : std_logic_vector(31 downto 0) := (others => '0');
  signal id_sync       : std_logic_vector(31 downto 0) := (others => '0');
begin
  ulpi_data_o <= data_o_reg;
  ulpi_data_oe <= data_oe_reg;
  ulpi_stp <= stp_reg;
  ulpi_rst <= reset_n;
  phy_id <= id_sync;

  process(ulpi_clk)
  begin
    if rising_edge(ulpi_clk) then
      if reset_n = '0' then
        ulpi_div <= (others => '0');
        ulpi_tick <= '0';
        ulpi_last_data <= (others => '0');
        ulpi_status <= (others => '0');
        ulpi_id <= (others => '0');
        read_state <= R_RESET_WAIT;
        read_addr <= (others => '0');
        wait_count <= (others => '0');
        data_o_reg <= (others => '0');
        data_oe_reg <= '0';
        stp_reg <= '0';
        error_code <= (others => '0');
        scratch_read <= (others => '0');
      else
        ulpi_div <= ulpi_div + 1;
        if ulpi_div = ULPI_DIV_ZERO then
          ulpi_tick <= not ulpi_tick;
        end if;

        if ulpi_dir = '1' then
          ulpi_status(5) <= '1';
        end if;
        if ulpi_nxt = '1' then
          ulpi_status(4) <= '1';
        end if;
        if ulpi_data_i /= ulpi_last_data then
          ulpi_status(3) <= '1';
        end if;

        ulpi_last_data <= ulpi_data_i;
        ulpi_status(6) <= '1';
        ulpi_status(2) <= ulpi_dir;
        ulpi_status(1) <= ulpi_nxt;
        if read_state = R_DONE then
          ulpi_status(0) <= '1';
        else
          ulpi_status(0) <= '0';
        end if;

        data_oe_reg <= '0';
        stp_reg <= '0';

        case read_state is
          when R_RESET_WAIT =>
            if wait_count = x"0FFF" then
              wait_count <= (others => '0');
              read_state <= R_WAIT_IDLE;
            else
              wait_count <= wait_count + 1;
            end if;

          when R_WAIT_IDLE =>
            if ulpi_dir = '0' then
              read_state <= R_CMD;
            end if;

          when R_CMD =>
            data_o_reg <= ULPI_READ_CMD & "0000" & std_logic_vector(read_addr);
            data_oe_reg <= '1';
            if wait_count = x"0000" then
              -- The command reaches the pins after this clock edge. Start
              -- sampling NXT on the following ULPI clock.
              wait_count <= wait_count + 1;
            elsif ulpi_nxt = '1' and ulpi_dir = '0' then
              wait_count <= (others => '0');
              read_state <= R_RELEASE;
            elsif wait_count = x"0FFF" then
              wait_count <= (others => '0');
              error_code <= x"1";
              read_state <= R_ERROR;
            else
              wait_count <= wait_count + 1;
            end if;

          when R_RELEASE =>
            -- One ULPI clock with OE deasserted before looking at DIR/data.
            -- Without this turn-around cycle, the sampled value can be the
            -- command byte we just drove (C0, C1, C2, C3).
            wait_count <= (others => '0');
            read_state <= R_WAIT_DIR;

          when R_WAIT_DIR =>
            if ulpi_dir = '1' then
              if ulpi_data_i = (ULPI_READ_CMD & "0000" & std_logic_vector(read_addr)) then
                wait_count <= (others => '0');
                read_state <= R_CAPTURE;
              else
                case read_addr is
                  when "00" => ulpi_id(7 downto 0) <= ulpi_data_i;
                  when "01" => ulpi_id(15 downto 8) <= ulpi_data_i;
                  when "10" => ulpi_id(23 downto 16) <= ulpi_data_i;
                  when others => ulpi_id(31 downto 24) <= ulpi_data_i;
                end case;
                wait_count <= (others => '0');
                read_state <= R_GAP;
              end if;
            elsif wait_count = x"0FFF" then
              wait_count <= (others => '0');
              error_code <= x"2";
              read_state <= R_ERROR;
            else
              wait_count <= wait_count + 1;
            end if;

          when R_CAPTURE =>
            if ulpi_dir = '1' then
              if ulpi_data_i = (ULPI_READ_CMD & "0000" & std_logic_vector(read_addr)) then
                if wait_count = x"00FF" then
                  wait_count <= (others => '0');
                  error_code <= x"3";
                  read_state <= R_ERROR;
                else
                  wait_count <= wait_count + 1;
                end if;
              else
                case read_addr is
                  when "00" => ulpi_id(7 downto 0) <= ulpi_data_i;
                  when "01" => ulpi_id(15 downto 8) <= ulpi_data_i;
                  when "10" => ulpi_id(23 downto 16) <= ulpi_data_i;
                  when others => ulpi_id(31 downto 24) <= ulpi_data_i;
                end case;
                wait_count <= (others => '0');
                read_state <= R_GAP;
              end if;
            else
              error_code <= x"4";
              read_state <= R_ERROR;
            end if;

          when R_GAP =>
            if ulpi_dir = '0' then
              if read_addr = "11" then
                wait_count <= (others => '0');
                read_state <= W_SCR_CMD;
              else
                read_addr <= read_addr + 1;
                wait_count <= (others => '0');
                read_state <= R_WAIT_IDLE;
              end if;
            elsif wait_count = x"0FFF" then
              wait_count <= (others => '0');
              error_code <= x"5";
              read_state <= R_ERROR;
            else
              wait_count <= wait_count + 1;
            end if;

          when W_SCR_CMD =>
            data_o_reg <= ULPI_WRITE_CMD & ULPI_SCRATCH_ADDR;
            data_oe_reg <= '1';
            if wait_count = x"0000" then
              wait_count <= wait_count + 1;
            elsif ulpi_nxt = '1' and ulpi_dir = '0' then
              wait_count <= (others => '0');
              read_state <= W_SCR_DATA;
            elsif wait_count = x"0FFF" then
              wait_count <= (others => '0');
              error_code <= x"6";
              read_state <= R_ERROR;
            else
              wait_count <= wait_count + 1;
            end if;

          when W_SCR_DATA =>
            data_o_reg <= ULPI_SCRATCH_VALUE;
            data_oe_reg <= '1';
            if wait_count = x"0000" then
              wait_count <= wait_count + 1;
            elsif ulpi_nxt = '1' and ulpi_dir = '0' then
              wait_count <= (others => '0');
              read_state <= W_SCR_GAP;
            elsif wait_count = x"0FFF" then
              wait_count <= (others => '0');
              error_code <= x"7";
              read_state <= R_ERROR;
            else
              wait_count <= wait_count + 1;
            end if;

          when W_SCR_GAP =>
            if ulpi_dir = '0' then
              wait_count <= (others => '0');
              read_state <= R_SCR_CMD;
            elsif wait_count = x"0FFF" then
              wait_count <= (others => '0');
              error_code <= x"8";
              read_state <= R_ERROR;
            else
              wait_count <= wait_count + 1;
            end if;

          when R_SCR_CMD =>
            data_o_reg <= ULPI_READ_CMD & ULPI_SCRATCH_ADDR;
            data_oe_reg <= '1';
            if wait_count = x"0000" then
              wait_count <= wait_count + 1;
            elsif ulpi_nxt = '1' and ulpi_dir = '0' then
              wait_count <= (others => '0');
              read_state <= R_SCR_RELEASE;
            elsif wait_count = x"0FFF" then
              wait_count <= (others => '0');
              error_code <= x"9";
              read_state <= R_ERROR;
            else
              wait_count <= wait_count + 1;
            end if;

          when R_SCR_RELEASE =>
            wait_count <= (others => '0');
            read_state <= R_SCR_WAIT_DIR;

          when R_SCR_WAIT_DIR =>
            if ulpi_dir = '1' then
              if ulpi_data_i /= (ULPI_READ_CMD & ULPI_SCRATCH_ADDR) then
                scratch_read <= ulpi_data_i;
                wait_count <= (others => '0');
                read_state <= R_SCR_GAP;
              elsif wait_count = x"00FF" then
                wait_count <= (others => '0');
                error_code <= x"A";
                read_state <= R_ERROR;
              else
                wait_count <= wait_count + 1;
              end if;
            elsif wait_count = x"0FFF" then
              wait_count <= (others => '0');
              error_code <= x"B";
              read_state <= R_ERROR;
            else
              wait_count <= wait_count + 1;
            end if;

          when R_SCR_GAP =>
            if ulpi_dir = '0' then
              read_state <= R_DONE;
            elsif wait_count = x"0FFF" then
              wait_count <= (others => '0');
              error_code <= x"D";
              read_state <= R_ERROR;
            else
              wait_count <= wait_count + 1;
            end if;

          when R_DONE =>
            ulpi_id <= scratch_read & ulpi_id(23 downto 0);

          when R_ERROR =>
            ulpi_status(0) <= '0';
            ulpi_id <= x"E" & error_code & std_logic_vector(read_addr) &
                       ulpi_dir & ulpi_nxt & data_oe_reg & stp_reg &
                       ulpi_data_i & data_o_reg & "00";
        end case;
      end if;
    end if;
  end process;

  process(clk)
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        tick_meta <= '0';
        tick_sync <= '0';
        tick_prev <= '0';
        clk_seen <= '0';
        stat_meta <= (others => '0');
        stat_sync <= (others => '0');
        id_meta <= (others => '0');
        id_sync <= (others => '0');
      else
        tick_meta <= ulpi_tick;
        tick_sync <= tick_meta;
        tick_prev <= tick_sync;
        if tick_sync /= tick_prev then
          clk_seen <= '1';
        end if;

        stat_meta <= ulpi_status;
        stat_sync <= stat_meta;
        id_meta <= ulpi_id;
        id_sync <= id_meta;
      end if;
    end if;
  end process;

  -- bit7: ULPI clock observed from sysclk domain
  -- bit6: ULPI domain running
  -- bit5: DIR has asserted since reset
  -- bit4: NXT has asserted since reset
  -- bit3: DATA changed since reset
  -- bit2: current DIR
  -- bit1: current NXT
  -- bit0: PHY ID read and scratch write/read test done
  status <= clk_seen & stat_sync;
end architecture;
