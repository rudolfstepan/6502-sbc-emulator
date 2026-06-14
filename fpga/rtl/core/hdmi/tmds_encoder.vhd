-- TMDS (Transition Minimized Differential Signaling) encoder.
-- DVI 1.0 spec Section 3.3.3.
--
-- During active video (de='1'): 8-bit pixel data -> 10-bit TMDS codeword
--   with DC balance tracking via running disparity counter.
-- During blanking  (de='0'): outputs one of four fixed control symbols
--   selected by (c1, c0): HS, VS on blue channel; tied '0' on G and R.
-- Pipeline latency: 1 clock cycle.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tmds_encoder is
  port (
    clk     : in  std_logic;
    reset_n : in  std_logic;
    de      : in  std_logic;                     -- data enable
    d       : in  std_logic_vector(7 downto 0);  -- pixel data
    c0      : in  std_logic;                     -- control 0 (HS on blue channel)
    c1      : in  std_logic;                     -- control 1 (VS on blue channel)
    q       : out std_logic_vector(9 downto 0)   -- TMDS 10-bit output
  );
end entity;

architecture rtl of tmds_encoder is
  function count_ones(v : std_logic_vector(7 downto 0)) return unsigned is
    variable n : unsigned(3 downto 0) := (others => '0');
  begin
    for i in 0 to 7 loop
      if v(i) = '1' then n := n + 1; end if;
    end loop;
    return n;
  end function;

  -- Stage 1: XOR/XNOR chain (combinatorial)
  signal q_m : std_logic_vector(8 downto 0);

  -- Stage 2: DC balance counter (5-bit signed, range -8..+8)
  signal cnt : signed(4 downto 0) := (others => '0');

  constant CTRL_00 : std_logic_vector(9 downto 0) := "1101010100";
  constant CTRL_01 : std_logic_vector(9 downto 0) := "0010101011";
  constant CTRL_10 : std_logic_vector(9 downto 0) := "0101010100";
  constant CTRL_11 : std_logic_vector(9 downto 0) := "1010101011";
begin
  -- Stage 1: compute q_m using XOR (q_m[8]=1) or XNOR (q_m[8]=0) chain
  process(d)
    variable n1 : unsigned(3 downto 0);
    variable m  : std_logic_vector(8 downto 0);
  begin
    n1   := count_ones(d);
    m(0) := d(0);
    if n1 > 4 or (n1 = 4 and d(0) = '0') then
      for i in 1 to 7 loop
        m(i) := not (m(i-1) xor d(i));
      end loop;
      m(8) := '0';
    else
      for i in 1 to 7 loop
        m(i) := m(i-1) xor d(i);
      end loop;
      m(8) := '1';
    end if;
    q_m <= m;
  end process;

  -- Stage 2: registered DC balance and output
  process(clk)
    variable n1m  : signed(4 downto 0);
    variable n0m  : signed(4 downto 0);
    variable diff : signed(4 downto 0);
    variable qv   : std_logic_vector(9 downto 0);
  begin
    if rising_edge(clk) then
      if reset_n = '0' then
        q   <= (others => '0');
        cnt <= (others => '0');
      elsif de = '0' then
        cnt <= (others => '0');
        case c1 & c0 is
          when "00"   => q <= CTRL_00;
          when "01"   => q <= CTRL_01;
          when "10"   => q <= CTRL_10;
          when others => q <= CTRL_11;
        end case;
      else
        n1m  := signed("0" & std_logic_vector(count_ones(q_m(7 downto 0))));
        n0m  := to_signed(8, 5) - n1m;
        diff := n1m - n0m;

        if cnt = 0 or n1m = n0m then
          qv(9) := not q_m(8);
          qv(8) := q_m(8);
          if q_m(8) = '1' then
            qv(7 downto 0) := q_m(7 downto 0);
            cnt <= cnt + diff;
          else
            qv(7 downto 0) := not q_m(7 downto 0);
            cnt <= cnt - diff;
          end if;
        elsif (cnt > 0 and n1m > n0m) or (cnt < 0 and n0m > n1m) then
          qv(9) := '1';
          qv(8) := q_m(8);
          qv(7 downto 0) := not q_m(7 downto 0);
          if q_m(8) = '1' then
            cnt <= cnt - diff + 2;
          else
            cnt <= cnt - diff;
          end if;
        else
          qv(9) := '0';
          qv(8) := q_m(8);
          qv(7 downto 0) := q_m(7 downto 0);
          if q_m(8) = '0' then
            cnt <= cnt + diff - 2;
          else
            cnt <= cnt + diff;
          end if;
        end if;
        q <= qv;
      end if;
    end if;
  end process;
end architecture;
