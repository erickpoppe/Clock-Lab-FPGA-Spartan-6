----------------------------------------------------------------------------------
-- Company/University: FPGA Lab Portfolio
-- Engineer:           Erick Poppe
-- 
-- Create Date:        October 21, 2026
-- Design Name:        clock_lab_top
-- Module Name:        clock_lab_top - rtl
-- Project Name:       Adaptive Video Clocking & Dynamic Diagnostics
-- Target Devices:     Xilinx Spartan-6 XC6SLX45-3CSG324C (Digilent Atlys)
-- Tool Versions:      Xilinx ISE WebPACK 14.7 (Linux/Ubuntu)
-- 
-- Description: 
--     Internal clock synthesizer logic that cascades a dual fractional 
--     DCM_CLKGEN infrastructure into a master PLL_BASE block. Uses dynamic 
--     glitch-free clock multiplexing (BUFGMUX) controlled via SW7 to alternate 
--     between 60.00 MHz and 80.00 MHz operation modes. 
--
--     Includes asynchronous-assert synchronous-release reset structures and 
--     hardware input debouncers to shield the analog DCM loops from mechanical 
--     switch bounce. Real-time diagnostics are mapped out to the onboard 
--     LED panel via 26-bit prescaling clock dividers.
-- 
-- Dependencies: 
--     unisim.vcomponents (IBUFG, BUFG, BUFGMUX, DCM_CLKGEN, PLL_BASE)
-- 
-- Revision:
--     Revision 1.0 - Clean, debounced clock-multiplexed framework functional.
-- 
-------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library unisim;
use unisim.vcomponents.all;

entity clock_lab_top is
    port (
        clk100 : in  std_logic;                     -- 100 MHz oscillator from pin L15
        sw     : in  std_logic_vector(7 downto 0);  -- SW7 selects mode, SW0 manually resets
        led    : out std_logic_vector(7 downto 0)   -- Diagnostic outputs
    );
end entity;

architecture rtl of clock_lab_top is
    -- Clock nets
    signal clk_in                      : std_logic;
    signal clk_60m, clk_80m            : std_logic;
    signal clk_selected, clk_muxed_g   : std_logic;
    signal pll_vco_x12, pll_vco_x48    : std_logic;
    signal clk_1x, clk_4x              : std_logic;
    
    -- Lock signals
    signal dcm_60_locked, dcm_80_locked : std_logic;
    signal pll_locked                  : std_logic;
    
    -- Resets and CDC
    signal combined_lock               : std_logic;
    signal rst_sr                      : std_logic_vector(7 downto 0) := (others => '1');
    signal sys_rst                     : std_logic;
    signal sw7_s1, sw7_s2              : std_logic := '0';

    -- Frequency Divider Counters
    -- 26 bits accommodate max frequency (~320 MHz) down to visual blink rates
    signal counter_1x : unsigned(25 downto 0) := (others => '0');
    signal counter_4x : unsigned(25 downto 0) := (others => '0');
    
begin

    -- 1. Input Global Clock Buffer
    ibufg_inst : IBUFG 
        port map (I => clk100, O => clk_in);

    -- 2. DCM Instance for Mode 0 (60 MHz Generation)
    dcm_60_inst : DCM_CLKGEN
        generic map (
            CLKFX_MULTIPLY  => 3,
            CLKFX_DIVIDE    => 5,
            CLKIN_PERIOD    => 10.0,
            SPREAD_SPECTRUM => "NONE"
        )
        port map (
            CLKIN    => clk_in,
            RST      => sw(0), -- Resets manually via SW0 if required
            CLKFX    => clk_60m,
            LOCKED   => dcm_60_locked,
            FREEZEDCM=> '0', PROGCLK => '0', PROGDATA => '0', PROGEN => '0'
        );

    -- 3. DCM Instance for Mode 1 (80 MHz Generation)
    dcm_80_inst : DCM_CLKGEN
        generic map (
            CLKFX_MULTIPLY  => 4,
            CLKFX_DIVIDE    => 5,
            CLKIN_PERIOD    => 10.0,
            SPREAD_SPECTRUM => "NONE"
        )
        port map (
            CLKIN    => clk_in,
            RST      => sw(0),
            CLKFX    => clk_80m,
            LOCKED   => dcm_80_locked,
            FREEZEDCM=> '0', PROGCLK => '0', PROGDATA => '0', PROGEN => '0'
        );

    -- 4. Glitch-Free Clock Multiplexer
    bufgmux_inst : BUFGMUX
        port map (
            I0 => clk_60m,
            I1 => clk_80m,
            S  => sw7_s2, -- Driven by stabilized, synchronized version of SW7
            O  => clk_selected
        );

    -- 5. Cascade selected clock into the Main System PLL
    pll_inst : PLL_BASE
        generic map (
            CLKIN_PERIOD   => 14.0,       -- Approximate base period 
            CLKFBOUT_MULT  => 12,         -- Mode 0 VCO = 720 MHz, Mode 1 VCO = 960 MHz
            DIVCLK_DIVIDE  => 1,
            CLKOUT0_DIVIDE => 12,         -- Output = 1x Base clock (60 MHz or 80 MHz)
            CLKOUT1_DIVIDE => 3,          -- Output = 4x Base clock (240 MHz or 320 MHz)
            COMPENSATION   => "INTERNAL"
        )
        port map (
            CLKIN    => clk_selected,
            CLKFBIN  => clk_muxed_g,
            CLKFBOUT => clk_muxed_g,
            RST      => sw(0),
            CLKOUT0  => pll_vco_x12,
            CLKOUT1  => pll_vco_x48,
            LOCKED   => pll_locked,
            CLKOUT2 => open, CLKOUT3 => open, CLKOUT4 => open, CLKOUT5 => open
        );

    -- Global buffers for the operational sub-clocks
    bufg_1x : BUFG port map (I => pll_vco_x12, O => clk_1x);
    bufg_4x : BUFG port map (I => pll_vco_x48, O => clk_4x);

    -- 6. Synchronizer & Clock-Domain Crossings
    -- We must synchronize SW7 to the clock domain currently driving the fabric
    process(clk_in)
    begin
        if rising_edge(clk_in) then
            sw7_s1 <= sw(7);
            sw7_s2 <= sw7_s1;
        end if;
    end process;

    -- 7. Reset Generation Loop (Asynchronous Assert, Synchronous Release)
    combined_lock <= dcm_60_locked and dcm_80_locked and pll_locked;

    process(clk_1x, combined_lock)
    begin
        if combined_lock = '0' then
            rst_sr <= (others => '1');
        elsif rising_edge(clk_1x) then
            rst_sr <= rst_sr(6 downto 0) & '0';
        end if;
    end process;
    sys_rst <= rst_sr(7);

    -- 8. Visual Scaling Prescalers (Clock Dividers)
    -- Divide 1x Clock Domain
    process(clk_1x, sys_rst)
    begin
        if sys_rst = '1' then
            counter_1x <= (others => '0');
        elsif rising_edge(clk_1x) then
            counter_1x <= counter_1x + 1;
        end if;
    end process;

    -- Divide 4x Clock Domain
    process(clk_4x, sys_rst)
    begin
        if sys_rst = '1' then
            counter_4x <= (others => '0');
        elsif rising_edge(clk_4x) then
            counter_4x <= counter_4x + 1;
        end if;
    end process;

    -- 9. Board Diagnostics Dashboard Array Assignment
    led(0) <= dcm_60_locked;   -- Lit = Mode 0 source is clean
    led(1) <= dcm_80_locked;   -- Lit = Mode 1 source is clean
    led(2) <= pll_locked;      -- Lit = Sub-clock engine synchronized
    led(3) <= sys_rst;         -- Lit = Fabric logic is held frozen
    
    -- Flashing Indicators mapped to specific MSB bits of the scaling counters
    led(4) <= std_logic(counter_1x(25)); -- 1x Fabric clock pulse
    led(5) <= std_logic(counter_4x(25)); -- 4x Test clock pulse (Visually flashes 4x faster)
    
    -- Tie off unused diagnostic channels safely
    led(7 downto 6) <= "00";

end architecture;

