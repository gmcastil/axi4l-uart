--
-- Module:      uart_tx
-- Description:
--
-- Purpose:
--
-- Usage:
--   Instantiated in the top level uart_core
--
-- Notes:
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
    port (
        -- Input clock
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- 16X oversampling baud tick
        baud_tick       : in  std_logic;
        -- Data size - 5, 6, 7, or 8
        data_bits       : in  unsigned(3 downto 0);   -- actual bit count: 5, 6, 7, or 8
        -- Enable parity bits
        parity_en       : in  std_logic;
        -- Parity to add (ignored with parity_en == 0).  1 for odd, 0 for even
        parity_odd      : in  std_logic;
        -- Stop bits to add. 0 for 1 stop bit, 1 for 2 stop bits
        stop_bits       : in  std_logic;              -- 0=1 stop bit, 1=2 stop bits

        -- TX FIFO read port
        tx_data         : in  std_logic_vector(7 downto 0);
        tx_empty        : in  std_logic;
        tx_rd_en        : out std_logic;

        -- Serial output (shuold be tied directly to the top level TXD port of the chip)
        tx              : out std_logic;

        -- Busy when transmitting a frame
        tx_busy         : out std_logic;
        -- Total frame count since reset
        tx_frame_count  : out unsigned(31 downto 0)
     );

end entity uart_tx;

architecture behavioral of uart_tx is

begin

end architecture behavioral;

