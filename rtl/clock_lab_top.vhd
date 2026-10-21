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
    
    -- Debounced Hardware Reset Signals
    signal reset_stabilizer            : std_logic_vector(3 downto 0) := (others => '1');
    signal clean_hw_rst                : std_logic;
    
    -- Fabric Resets and CDC
    signal combined_lock               : std_logic;
    signal rst_sr                      : std_logic_vector(7 downto 0) := (others => '1');
    signal sys_rst                     : std_logic;
    signal sw7_s1, sw7_s2              : std_logic := '0';

    -- Frequency Divider Counters
    signal counter_1x : unsigned(25 downto 0) := (others => '0');
    signal counter_4x : unsigned(25 downto 0) := (others => '0');
    
begin

    -- 1. Input Global Clock Buffer
    ibufg_inst : IBUFG 
        port map (I => clk100, O => clk_in);

    -- 2. Hardware Switch Debouncer for Reset
    -- Filters out the electrical noise spikes caused by the mechanical switch contacts
    process(clk_in)
    begin
        if rising_edge(clk_in) then
            reset_stabilizer <= reset_stabilizer(2 downto 0) & sw(0);
        end if;
    end process;
    clean_hw_rst <= reset_stabilizer(3); -- Clean, synchronized hardware reset

    -- 3. DCM Instance for Mode 0 (60 MHz Generation)
    dcm_60_inst : DCM_CLKGEN
        generic map (
            CLKFX_MULTIPLY  => 3,
            CLKFX_DIVIDE    => 5,
            CLKIN_PERIOD    => 10.0,
            SPREAD_SPECTRUM => "NONE"
        )
        port map (
            CLKIN    => clk_in,
            RST      => clean_hw_rst, -- Using the debounced clean reset signal
            CLKFX    => clk_60m,
            LOCKED   => dcm_60_locked,
            FREEZEDCM=> '0', PROGCLK => '0', PROGDATA => '0', PROGEN => '0'
        );

    -- 4. DCM Instance for Mode 1 (80 MHz Generation)
    dcm_80_inst : DCM_CLKGEN
        generic map (
            CLKFX_MULTIPLY  => 4,
            CLKFX_DIVIDE    => 5,
            CLKIN_PERIOD    => 10.0,
            SPREAD_SPECTRUM => "NONE"
        )
        port map (
            CLKIN    => clk_in,
            RST      => clean_hw_rst, -- Using the debounced clean reset signal
            CLKFX    => clk_80m,
            LOCKED   => dcm_80_locked,
            FREEZEDCM=> '0', PROGCLK => '0', PROGDATA => '0', PROGEN => '0'
        );

    -- 5. Glitch-Free Clock Multiplexer
    bufgmux_inst : BUFGMUX
        port map (
            I0 => clk_60m,
            I1 => clk_80m,
            S  => sw7_s2, 
            O  => clk_selected
        );

    -- 6. Cascade selected clock into the Main System PLL
    pll_inst : PLL_BASE
        generic map (
            CLKIN_PERIOD   => 14.0,       
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
            RST      => clean_hw_rst,
            CLKOUT0  => pll_vco_x12,
            CLKOUT1  => pll_vco_x48,
            LOCKED   => pll_locked,
            CLKOUT2 => open, CLKOUT3 => open, CLKOUT4 => open, CLKOUT5 => open
        );

    -- Global buffers for the operational sub-clocks
    bufg_1x : BUFG port map (I => pll_vco_x12, O => clk_1x);
    bufg_4x : BUFG port map (I => pll_vco_x48, O => clk_4x);

    -- 7. Synchronizer for Mode Select Switch (SW7)
    process(clk_in)
    begin
        if rising_edge(clk_in) then
            sw7_s1 <= sw(7);
            sw7_s2 <= sw7_s1;
        end if;
    end process;

    -- 8. Reset Generation Loop (Asynchronous Assert, Synchronous Release)
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

    -- 9. Visual Scaling Prescalers (Clock Dividers)
    process(clk_1x, sys_rst)
    begin
        if sys_rst = '1' then
            counter_1x <= (others => '0');
        elsif rising_edge(clk_1x) then
            counter_1x <= counter_1x + 1;
        end if;
    end process;

    process(clk_4x, sys_rst)
    begin
        if sys_rst = '1' then
            counter_4x <= (others => '0');
        elsif rising_edge(clk_4x) then
            counter_4x <= counter_4x + 1;
        end if;
    end process;

    -- 10. Board Diagnostics Dashboard Array Assignment
    led(0) <= dcm_60_locked;   -- Should light up solid
    led(1) <= dcm_80_locked;   -- Should light up solid
    led(2) <= pll_locked;      -- Should light up solid
    led(3) <= sys_rst;         -- Should remain completely dark
    
    led(4) <= std_logic(counter_1x(25)); -- 1x Fabric clock pulse
    led(5) <= std_logic(counter_4x(25)); -- 4x Test clock pulse (Flashes 4x faster)
    led(7 downto 6) <= "00";

end architecture;

