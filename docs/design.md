# AXI4-Lite UART Design

## Architecture

The design is split into three levels:

- `uart_top` -- AXI4-Lite register interface + `baud_rate_gen` + `uart_ctrl` + `uart_core`
- `uart_core` -- datapath: `uart_tx`, `uart_rx`, TX FIFO, RX FIFO
- Individual RTL modules verified bottom-up before integration

`baud_rate_gen` lives at the `uart_top` level so its tick is available to both
`uart_ctrl` (RX timeout counter) and `uart_core` (TX and RX serializers) without
routing it through `uart_core`'s external interface.

The FIFOs live inside `uart_core` but are external to `uart_tx` and `uart_rx`.

```mermaid
graph LR
    AXIM((AXI4-Lite\nMaster))
    TX((tx))
    RX((rx))

    subgraph uart_top["uart_top"]
        AXI["axi4l_regs"]
        BRG["baud_rate_gen"]
        CTRL["uart_ctrl"]

        subgraph uart_core["uart_core"]
            TXFIFO["TX FIFO\n8b"]
            UTX["uart_tx"]
            URX["uart_rx"]
            RXFIFO["RX FIFO\n11b"]
        end
    end

    AXIM -->|AXI4-Lite| AXI
    AXI <-->|reg bus| CTRL
    CTRL -->|baud_div\nbaud_gen_en| BRG
    BRG -->|baud_tick| CTRL
    BRG -->|baud_tick| uart_core
    CTRL -->|frame cfg| uart_core
    CTRL -->|tx_data\ntx_wr_en| TXFIFO
    CTRL -->|rx_rd_en| RXFIFO
    CTRL -->|sw_rst\nloopback\ntx_fifo_flush\nrx_fifo_flush| uart_core
    uart_core -->|tx_full\ntx_empty\ntx_busy\ntx_lvl\ntx_frame_count| CTRL
    uart_core -->|rx_data\nrx_empty\nrx_break\nrx_overrun\nrx_received\nrx_lvl\nrx_frame_count\nrx_drop_count| CTRL
    TXFIFO -->|tx_data 8b\ntx_empty| UTX
    UTX -->|tx_rd_en| TXFIFO
    URX -->|rx_data 11b\nrx_wr_en| RXFIFO
    RXFIFO -->|rx_full| URX
    UTX --> TX
    RX --> URX
    CTRL -->|irq| IRQ((irq))
```

---

## Software

The UART is intended for use in a Zynq design running Linux on the PS. The PL
UART is accessed by the PS via memory-mapped AXI4-Lite registers. The Linux
driver registers as a tty device using the serial core framework
(`drivers/tty/serial/serial_core.c`).

Driver source will live in the Arty-Z7 repository, not this one.

### Device Tree Requirements

The driver requires the following properties in the device tree node:

- `reg` -- base address and size of the AXI4-Lite register window
- `clocks` / `clock-frequency` -- peripheral clock frequency; used to compute
  `baud_div`
- `interrupts` -- interrupt line for TX empty and RX data available events

### Initialization Sequence

1. Read clock frequency from device tree
2. Disable the core (`baud_gen_en = 0`)
3. Configure frame format (`data_bits`, `parity_en`, `parity_odd`, `stop_bits`)
4. Compute and write `baud_div = (f_clk / (baud_rate * 16)) - 1`
5. Enable the core (`baud_gen_en = 1`)
6. Enable interrupts

### Baud Rate Change Procedure

Changing the baud rate requires disabling the core first. `baud_div` is
registered on every clock edge in hardware -- changing it while enabled
produces a corrupted baud tick. The correct sequence is:

1. Disable the core (`baud_gen_en = 0`)
2. Write new `baud_div`
3. Re-enable the core (`baud_gen_en = 1`)

This is satisfied naturally by the serial core framework since `set_termios`
is only called when the port is quiescent.

### Frame Configuration

`data_bits`, `parity_en`, `parity_odd`, and `stop_bits` are written to control
registers and can be changed at any time -- `uart_tx` and `uart_rx` latch these
at the start of each frame. No disable/enable cycle is required. Changes take
effect on the next frame after the write.

### TX Operation

TX is interrupt-driven. The driver implements the `start_tx` callback as
follows:

1. Read bytes from the serial core's circular transmit buffer
2. Write bytes one at a time to the TX data register until the TX FIFO is full
   or the buffer is empty
3. When the TX FIFO drains (TX empty interrupt), repeat from step 1

For `tcdrain()` (wait until all data has left the wire), the driver must wait
until both the TX FIFO is empty AND `tx_busy` is deasserted. TX FIFO empty
alone is not sufficient -- there may still be a byte in the shift register.

### RX Operation

RX is interrupt-driven:

1. Hardware fires an interrupt when the RX FIFO is non-empty
2. The driver reads bytes from the RX data register and checks associated error
   flags for each byte
3. Each byte is pushed to the tty layer via `tty_insert_flip_char()` with the
   appropriate flag

### Error Handling

Received error conditions map directly to Linux tty layer flags:

| Hardware flag     | tty flag       |
|-------------------|----------------|
| `rx_framing_err`  | `TTY_FRAME`    |
| `rx_parity_err`   | `TTY_PARITY`   |
| `rx_overrun`      | `TTY_OVERRUN`  |
| `rx_break`        | `TTY_BREAK`    |

### Interrupt Handling

The UART presents a single interrupt line to the PS interrupt controller. The
driver's ISR reads the Interrupt Status Register (ISR) to determine which
source fired, handles each active source, and clears the handled bits by
writing 1 to the corresponding ISR bits (write-1-to-clear).

| ISR bit           | Action                                              |
|-------------------|-----------------------------------------------------|
| `irq_tx_empty`    | Refill TX FIFO from serial core circular buffer     |
| `irq_rx_not_empty`| Drain RX FIFO, push bytes to tty layer             |
| `irq_rx_error`    | Read and report error byte from RX FIFO to tty layer|

Individual sources are masked via the Interrupt Enable Register (IER). The
driver enables all three sources during `startup` and disables them during
`shutdown`.

### Hardware Assumptions and Requirements

The following constraints are placed on the driver by the hardware design:

- `baud_div` must be written before `baud_gen_en` is asserted on startup
- `baud_gen_en` must be deasserted before changing `baud_div`
- Frame configuration registers may be written at any time
- TX data register writes are dropped if the TX FIFO is full; the driver must
  respect the TX FIFO full status before writing
- RX overrun occurs in hardware when a received byte cannot be written to a
  full RX FIFO; the byte is dropped, `rx_overrun` is pulsed for one cycle,
  and the event is recorded in a status register visible to the driver

---

## axi4l_regs

A generic AXI4-Lite slave. Handles AXI4-Lite handshaking and presents a simple
decoded register bus to the downstream module. Has no knowledge of the register
map or register semantics. Reusable across any IP that implements the register
bus interface.

### Register Bus Interface

This is the interface between `axi4l_regs` and `uart_ctrl`:

```vhdl
reg_addr  : in  unsigned(REG_ADDR_WIDTH-1 downto 0);
reg_wdata : in  std_logic_vector(31 downto 0);
reg_wren  : in  std_logic;
reg_be    : in  std_logic_vector(3 downto 0);
reg_rdata : out std_logic_vector(31 downto 0);
reg_req   : in  std_logic;
reg_ack   : out std_logic;
reg_err   : out std_logic;
```

- `reg_req` is asserted for one cycle to initiate an access
- `reg_ack` and `reg_err` are registered; response arrives one cycle after `reg_req`
- `reg_ack=1, reg_err=0` -- OKAY (maps to AXI4-Lite OKAY response)
- `reg_ack=1, reg_err=1` -- error (maps to AXI4-Lite SLVERR response)
- `reg_err` is only meaningful when `reg_ack` is asserted
- `reg_be` is only meaningful on writes (`reg_wren=1`); `axi4l_regs` drives `1111` on reads
- `reg_rdata` must be valid on the same cycle as `reg_ack`

---

## uart_ctrl

UART-specific control and status logic. Implements the register bus interface
on one side and drives/reads all control and status signals into `uart_core` on
the other. Handles illegal accesses (unmapped addresses, RO write violations)
and generates the single interrupt output for the driver.

### Interrupts

Three interrupt sources feed into `uart_ctrl` from `uart_core`:

| Source            | Condition                        |
|-------------------|----------------------------------|
| `irq_tx_empty`    | TX FIFO became empty             |
| `irq_rx_not_empty`| RX FIFO is not empty             |
| `irq_rx_error`    | RX error flag set in RX FIFO entry (framing, parity, or break), or `rx_overrun` pulsed |

`uart_ctrl` implements two interrupt registers:

- **Interrupt Enable Register (IER)** -- one bit per source; gates whether a
  source contributes to the interrupt output
- **Interrupt Status Register (ISR)** -- one bit per source; set when the
  condition occurs, cleared by writing 1 to the bit (write-1-to-clear)

The single `irq` output is the OR of all `(ISR & IER)` bits. The PS interrupt
controller receives this line.

### Register Map

`uart_ctrl` decodes a 5-bit word index presented by `axi4l_regs` on `reg_addr`.
Each index corresponds to one 32-bit register. `axi4l_regs` strips the AXI byte
offset before presenting the address; `uart_ctrl` never sees raw byte addresses.
Indices 17-31 are unmapped and return SLVERR.

| Index | Name     | Access  | Description                        |
|-------|----------|---------|------------------------------------|
| 0     | CTRL     | R/W     | Global control                     |
| 1     | LCR      | R/W     | Line (frame format) control        |
| 2     | BAUD     | R/W     | Baud rate divisor                  |
| 3     | TXSTAT   | RO      | TX status                          |
| 4     | RXSTAT   | RO/W1C  | RX status                          |
| 5     | TXD      | WO      | TX data (writes to TX FIFO)        |
| 6     | RXD      | RO      | RX data (reads from RX FIFO)       |
| 7     | IER      | R/W     | Interrupt enable                   |
| 8     | ISR      | W1C     | Interrupt status                   |
| 9     | RXTHR    | R/W     | RX FIFO interrupt threshold        |
| 10    | RXTOUT   | R/W     | RX timeout                         |
| 11    | TXLVL    | RO      | TX FIFO fill level                 |
| 12    | RXLVL    | RO      | RX FIFO fill level                 |
| 13    | TX_CNT   | RO      | TX frame counter                   |
| 14    | RX_CNT   | RO      | RX frame counter                   |
| 15    | DROP_CNT | RO      | RX drop counter                    |
| 16    | SCRATCH  | R/W     | Scratch                            |

#### CTRL (index 0) -- R/W

| Bits    | Field         | Description                                                         |
|---------|---------------|---------------------------------------------------------------------|
| [0]     | baud_gen_en   | Enable baud rate generator. Must be 0 when changing baud_div.       |
| [1]     | loopback      | Muxes tx output back to rx input of uart_rx, bypassing external serial lines. |
| [7:2]   | --            | Reserved, reads as 0.                                               |
| [8]     | sw_reset      | Self-clearing. Write 1 to assert synchronous reset to uart_core for one clock cycle. Reads as 0. |
| [15:9]  | --            | Reserved, reads as 0.                                               |
| [16]    | tx_fifo_flush | Self-clearing. Write 1 to flush the TX FIFO. Reads as 0.            |
| [17]    | rx_fifo_flush | Self-clearing. Write 1 to flush the RX FIFO. Reads as 0.            |
| [31:18] | --            | Reserved, reads as 0.                                               |

#### LCR (index 1) -- R/W

| Bits   | Field      | Description                                                   |
|--------|------------|---------------------------------------------------------------|
| [1:0]  | data_bits  | 00=5, 01=6, 10=7, 11=8 data bits per frame. uart_ctrl converts this to the actual count (5-8) before driving the data_bits port on uart_core. |
| [2]    | parity_en  | Enable parity bit.                                            |
| [3]    | parity_odd | 0=even parity, 1=odd parity. Ignored when parity_en=0.        |
| [4]    | stop_bits  | 0=1 stop bit, 1=2 stop bits.                                  |
| [31:5] | --         | Reserved, reads as 0.                                         |

#### BAUD (index 2) -- R/W

| Bits    | Field    | Description                                                        |
|---------|----------|--------------------------------------------------------------------|
| [14:0]  | baud_div | Baud rate divisor. Formula: baud_div = (f_clk / (baud_rate * 16)) - 1. Must not be changed while baud_gen_en is asserted. |
| [31:15] | --       | Reserved, reads as 0.                                              |

#### TXSTAT (index 3) -- RO

| Bits   | Field    | Description                                                         |
|--------|----------|---------------------------------------------------------------------|
| [0]    | tx_full  | TX FIFO is full. Driver must not write TXD when asserted.           |
| [1]    | tx_empty | TX FIFO is empty.                                                   |
| [2]    | tx_busy  | Serializer is actively shifting a frame. tx_empty AND NOT tx_busy indicates the line is truly idle; required for tcdrain(). |
| [31:3] | --       | Reserved, reads as 0.                                               |

#### RXSTAT (index 4) -- RO / W1C

| Bits   | Field      | Access | Description                                                    |
|--------|------------|--------|----------------------------------------------------------------|
| [0]    | rx_empty   | RO     | RX FIFO is empty.                                              |
| [1]    | rx_break   | RO     | Line is currently in break. Asserts when break is confirmed; deasserts when rx returns high. |
| [7:2]  | --         | RO     | Reserved, reads as 0.                                          |
| [8]    | rx_overrun | W1C    | Set when a received byte was dropped due to a full RX FIFO. Write 1 to clear. |
| [31:9] | --         | RO     | Reserved, reads as 0.                                          |

#### TXD (index 5) -- WO

| Bits   | Field | Description                                                              |
|--------|-------|--------------------------------------------------------------------------|
| [7:0]  | data  | Write byte to TX FIFO. Silently dropped if tx_full is asserted.          |
| [31:8] | --    | Ignored on write.                                                        |

#### RXD (index 6) -- RO

| Bits    | Field       | Description                                                       |
|---------|-------------|-------------------------------------------------------------------|
| [7:0]   | data        | Received byte.                                                    |
| [8]     | framing_err | Stop bit was 0 and at least one other received bit was 1.         |
| [9]     | parity_err  | Received parity did not match expected parity.                    |
| [10]    | break       | Break: stop bit 0 and all data/parity bits 0. Data byte is 0x00. |
| [31:11] | --          | Reserved, reads as 0.                                             |

Each read pops one entry from the RX FIFO. Reading when rx_empty is asserted
returns SLVERR.

#### IER (index 7) -- R/W

| Bits    | Field           | Description                                           |
|---------|-----------------|-------------------------------------------------------|
| [0]     | tx_empty_en     | Enable TX empty interrupt.                            |
| [7:1]   | --              | Reserved, reads as 0.                                 |
| [8]     | rx_not_empty_en | Enable RX threshold interrupt.                        |
| [9]     | rx_error_en     | Enable RX error interrupt.                            |
| [10]    | rx_timeout_en   | Enable RX timeout interrupt.                          |
| [31:11] | --              | Reserved, reads as 0.                                 |

#### ISR (index 8) -- W1C

| Bits    | Field            | Description                                                       |
|---------|------------------|-------------------------------------------------------------------|
| [0]     | irq_tx_empty     | TX FIFO became empty.                                             |
| [7:1]   | --               | Reserved, reads as 0.                                             |
| [8]     | irq_rx_not_empty | RX FIFO fill level reached RXTHR.                                 |
| [9]     | irq_rx_error     | RX error: framing, parity, break, or overrun.                     |
| [10]    | irq_rx_timeout   | RX FIFO non-empty and no new byte received within RXTOUT baud ticks. |
| [31:11] | --               | Reserved, reads as 0.                                             |

Bits are cleared by writing 1; writing 0 has no effect. The irq output is the
OR of all (ISR & IER) bits.

#### RXTHR (index 9) -- R/W

| Bits    | Field     | Description                                                       |
|---------|-----------|-------------------------------------------------------------------|
| [9:0]   | threshold | RX FIFO fill level at which irq_rx_not_empty is set. Range 1-1024. Value 0 disables the threshold interrupt. |
| [31:10] | --        | Reserved, reads as 0.                                             |

#### RXTOUT (index 10) -- R/W

| Bits    | Field   | Description                                                         |
|---------|---------|---------------------------------------------------------------------|
| [15:0]  | timeout | Timeout in baud ticks. Counter resets on each received byte. If the RX FIFO is non-empty and no new byte arrives within this many baud ticks, irq_rx_timeout is set. Value 0 disables the timeout interrupt. |
| [31:16] | --      | Reserved, reads as 0.                                               |

#### TXLVL (index 11) -- RO

| Bits    | Field | Description                             |
|---------|-------|-----------------------------------------|
| [10:0]  | level | Current number of bytes in the TX FIFO. |
| [31:11] | --    | Reserved, reads as 0.                   |

#### RXLVL (index 12) -- RO

| Bits    | Field | Description                             |
|---------|-------|-----------------------------------------|
| [9:0]   | level | Current number of bytes in the RX FIFO. |
| [31:10] | --    | Reserved, reads as 0.                   |

#### TX_CNT (index 13) -- RO

| Bits   | Field          | Description                                       |
|--------|----------------|---------------------------------------------------|
| [31:0] | tx_frame_count | Transmitted frame count. Wraps on overflow.       |

#### RX_CNT (index 14) -- RO

| Bits   | Field          | Description                                                            |
|--------|----------------|------------------------------------------------------------------------|
| [31:0] | rx_frame_count | Error-free frames received and written to RX FIFO. Wraps on overflow. |

#### DROP_CNT (index 15) -- RO

| Bits   | Field         | Description                                                           |
|--------|---------------|-----------------------------------------------------------------------|
| [31:0] | rx_drop_count | Error-free frames dropped due to RX FIFO full. Wraps on overflow.    |

#### SCRATCH (index 16) -- R/W

| Bits   | Field | Description           |
|--------|-------|-----------------------|
| [31:0] | data  | No hardware function. |

---

## uart_core

Datapath wrapper. Instantiates `uart_tx`, `uart_rx`, and the TX and RX FIFOs.
Has no knowledge of thresholds, timeouts, or interrupts; all interrupt decision
logic lives in `uart_ctrl`.

### Interface

```vhdl
clk    : in  std_logic;
rst    : in  std_logic;
sw_rst : in  std_logic;

-- from baud_rate_gen at uart_top level
baud_tick : in  std_logic;

-- frame configuration (from uart_ctrl registers)
data_bits  : in  unsigned(3 downto 0);   -- actual bit count: 5, 6, 7, or 8
parity_en  : in  std_logic;
parity_odd : in  std_logic;
stop_bits  : in  std_logic;

-- TX FIFO write port (from uart_ctrl)
tx_data  : in  std_logic_vector(7 downto 0);
tx_wr_en : in  std_logic;

-- TX status and counters
tx_full        : out std_logic;
tx_empty       : out std_logic;
tx_busy        : out std_logic;
tx_lvl         : out unsigned(10 downto 0);
tx_frame_count : out unsigned(31 downto 0);

-- FIFO control and mode (from uart_ctrl)
tx_fifo_flush : in  std_logic;
rx_fifo_flush : in  std_logic;
loopback      : in  std_logic;

-- RX FIFO read port (to/from uart_ctrl)
rx_data  : out std_logic_vector(10 downto 0);
rx_rd_en : in  std_logic;

-- RX status and counters
rx_empty       : out std_logic;
rx_break       : out std_logic;
rx_overrun     : out std_logic;
rx_received    : out std_logic;
rx_lvl         : out unsigned(9 downto 0);
rx_frame_count : out unsigned(31 downto 0);
rx_drop_count  : out unsigned(31 downto 0);

-- serial lines
tx : out std_logic;
rx : in  std_logic
```

`sw_rst` is a one-cycle pulse generated by `uart_ctrl` when CTRL[8] is written.
The Xilinx FIFO reset timing requirements (hold duration, control stability
before and after RST) are handled internally; the port carries a pulse.

`rx_received` pulses for one cycle on every `rx_wr_en`, including errored and
break bytes. It does not pulse on overrun. Used by `uart_ctrl` to reset the RX
timeout counter on any received activity.

`rx_data` bit packing: `[10]=break, [9]=parity_err, [8]=framing_err, [7:0]=data`.

---

## baud_rate_gen

Status: signed off. All 7 unit tests pass.

Generates a one-clock-wide `baud_tick` at 16x the configured baud rate. A
single instance is shared by `uart_tx` and `uart_rx`. `uart_tx` counts 16
ticks per bit internally. `uart_rx` uses the tick directly for oversampling.

`baud_gen_en` is a global software enable driven from a control register. It
is not a per-frame signal. The generator runs continuously while asserted.

`baud_div` is driven from a software register and must be stable before
`baud_gen_en` is asserted. In practice this is always satisfied since multiple
AXI transactions separate the two writes.

Divisor formula: `baud_div = (f_clk / (baud_rate * 16)) - 1`

`baud_div` is not latched at a safe point -- it is registered on every clock
edge. Changing it while the core is enabled will produce a corrupted baud tick.
Software must disable the core (deassert `baud_gen_en`) before changing
`baud_div`. This is enforced by convention, not hardware. The Linux serial
driver satisfies this naturally since `set_termios` is only called when the
port is quiescent.

### Requirements

- **BRG-001** -- While `baud_gen_en` is deasserted, `baud_tick` shall be 0 and `baud_cnt` shall be 0.
- **BRG-002** -- When `baud_gen_en` is asserted, the first `baud_tick` shall fire after `baud_div + 1` clock cycles. The value in effect is the `baud_div` presented on the cycle immediately before `baud_gen_en` is asserted, due to one-cycle internal registration.
- **BRG-003** -- Each `baud_tick` pulse shall be exactly one clock cycle wide.
- **BRG-004** -- In steady state, `baud_tick` shall fire with a period of exactly `baud_div + 1` clock cycles.
- **BRG-005** -- When `baud_div = 0`, `baud_tick` shall fire on every clock cycle while `baud_gen_en` is asserted.
- **BRG-006** -- Deasserting `baud_gen_en` shall suppress `baud_tick` and reset `baud_cnt` to 0 on the next clock edge.
- **BRG-007** -- A synchronous reset shall clear `baud_tick` to 0 and `baud_cnt` to 0, regardless of `baud_gen_en`.

---

## uart_tx

Serializes bytes from the TX FIFO onto the `tx` line, one frame at a time,
using `baud_tick` to advance the bit counter. Counts 16 ticks per bit to
align with the 16x oversample tick from `baud_rate_gen`.

### Interface

```vhdl
clk        : in  std_logic;
rst        : in  std_logic;

-- from baud_rate_gen
baud_tick  : in  std_logic;

-- frame configuration (driven from control registers via uart_ctrl)
data_bits  : in  unsigned(3 downto 0);   -- actual bit count: 5, 6, 7, or 8
parity_en  : in  std_logic;
parity_odd : in  std_logic;              -- 0=even, 1=odd; ignored when parity_en=0
stop_bits  : in  std_logic;              -- 0=1 stop bit, 1=2 stop bits

-- TX FIFO read port
tx_data    : in  std_logic_vector(7 downto 0);
tx_empty   : in  std_logic;
tx_rd_en   : out std_logic;

-- serial output
tx         : out std_logic;

-- status
tx_busy        : out std_logic;

-- diagnostic counters
tx_frame_count : out unsigned(31 downto 0)
```

`tx_busy` is asserted whenever the serializer is actively shifting out a frame.
It remains asserted until the stop bit has been sent. Used by `uart_ctrl` to
distinguish TX FIFO empty (ready to accept more data) from line truly idle
(FIFO empty and shift register done). Required for correct `tcdrain()`
behavior in the Linux serial driver.

Frame configuration inputs are registered internally at the start of each
frame, so changes mid-frame do not affect the frame in progress. The new
configuration takes effect on the next frame.

### Requirements

- **UTX-001** -- While idle (no frame in progress), `tx` shall be 1 and `tx_busy` shall be 0.
- **UTX-002** -- Frame configuration (`data_bits`, `parity_en`, `parity_odd`, `stop_bits`) shall be latched at the start of each frame. Changes mid-frame do not affect the frame in progress; the new configuration takes effect on the next frame.
- **UTX-003** -- When idle and `tx_empty` is deasserted, a new frame shall begin on the next `baud_tick`.
- **UTX-004** -- A frame shall begin with a start bit: `tx = 0` held for 16 consecutive `baud_tick` pulses.
- **UTX-005** -- Data bits shall be transmitted LSB-first, one bit per 16 `baud_tick` pulses. The number of data bits is determined by `data_bits`, which carries the actual bit count: 5, 6, 7, or 8.
- **UTX-006** -- When `parity_en = 1`, a parity bit shall be transmitted after the last data bit, held for 16 `baud_tick` pulses. When `parity_odd = 0`, even parity is used; when `parity_odd = 1`, odd parity is used.
- **UTX-007** -- A stop bit (`tx = 1`) shall be transmitted after the last data or parity bit, held for 16 `baud_tick` pulses per stop bit. When `stop_bits = 0`, one stop bit is sent; when `stop_bits = 1`, two stop bits are sent.
- **UTX-008** -- `tx_busy` shall be asserted from the start of the start bit through the end of the last stop bit. It shall deassert on the clock cycle following the last stop bit tick.
- **UTX-009** -- When a frame completes and `tx_empty` is deasserted, the next frame shall begin on the immediately following `baud_tick`, with no idle cycle inserted between frames.
- **UTX-010** -- `tx_rd_en` shall not be asserted while `tx_empty` is asserted. When a byte is latched at the start of a frame, `tx_rd_en` shall be asserted on the same clock cycle to advance the FWFT FIFO to the next word. Exact timing details are confirmed at TX+FIFO integration.
- **UTX-011** -- A synchronous reset shall set `tx` to 1, `tx_busy` to 0, and `tx_rd_en` to 0.
- **UTX-012** -- `uart_tx` shall maintain a 32-bit transmit frame count (`tx_frame_count`) that increments by 1 on the clock cycle that `tx_busy` deasserts after each transmitted frame. The counter wraps on overflow and resets to 0 on synchronous reset.

---

## FIFOs

Both FIFOs are `uart_sync_fifo` instances wrapping Xilinx FIFO primitives.
They live inside `uart_core`, external to `uart_tx` and `uart_rx`.

| FIFO    | Primitive | Width mode | Read mode | Depth | Width   | Notes                                                                   |
|---------|-----------|------------|-----------|-------|---------|-------------------------------------------------------------------------|
| TX FIFO | FIFO18E1  | 9-bit      | FWFT      | 2048  | 8 bits  | data only; 1 bit unused                                                 |
| RX FIFO | FIFO18E1  | 18-bit     | FWFT      | 1024  | 11 bits | [10]=break, [9]=parity_err, [8]=framing_err, [7:0]=data; 7 bits unused  |

Bundling error flags with RX data in the FIFO preserves per-byte error
association, which is required for correct use of `tty_insert_flip_char()` in
the Linux driver. Overrun is not a per-byte flag and is not stored in the FIFO;
it is reported via a separate `rx_overrun` strobe from `uart_rx` to `uart_ctrl`.

---

## uart_rx

Deserializes frames from the `rx` line into the RX FIFO using 16x oversampling
for mid-bit sampling and start bit validation.

### Interface

```vhdl
clk        : in  std_logic;
rst        : in  std_logic;

-- from baud_rate_gen
baud_tick  : in  std_logic;

-- frame configuration (driven from control registers via uart_ctrl)
data_bits  : in  unsigned(3 downto 0);   -- actual bit count: 5, 6, 7, or 8
parity_en  : in  std_logic;
parity_odd : in  std_logic;              -- 0=even, 1=odd; ignored when parity_en=0
stop_bits  : in  std_logic;              -- 0=1 stop bit, 1=2 stop bits

-- serial input
rx         : in  std_logic;

-- RX FIFO write port
-- rx_data bit packing: [10]=break, [9]=parity_err, [8]=framing_err, [7:0]=data
rx_data    : out std_logic_vector(10 downto 0);
rx_wr_en   : out std_logic;
rx_full    : in  std_logic;

-- overrun strobe, break level, and diagnostic counters
rx_overrun     : out std_logic;
rx_break       : out std_logic;
rx_frame_count : out unsigned(31 downto 0);
rx_drop_count  : out unsigned(31 downto 0)
```

Frame configuration inputs are registered internally at the start of each
frame, same as `uart_tx`.

### Start Bit Detection

`uart_rx` watches for a falling edge on `rx`. On detecting the edge it waits
until oversample tick 8 (the middle of the start bit) and re-samples. If `rx`
is still low the start bit is valid and frame reception begins. If `rx` has
returned high the edge was a glitch and the receiver returns to idle. This
prevents noise spikes from triggering spurious frames.

### Sampling

Each bit is sampled at oversample tick 8 (mid-bit). The 16x `baud_tick` from
`baud_rate_gen` is used directly -- no internal tick generation.

### Error Recovery

- **Parity error** -- frame timing was intact. The parity error flag is set in
  the FIFO word, the byte is written to the FIFO, and the receiver immediately
  returns to hunting for the next start bit.
- **Overrun** -- the RX FIFO was full when the byte was ready. The byte is
  discarded, `rx_overrun` is pulsed for one cycle, and the receiver immediately
  returns to hunting for the next start bit.
- **Framing error / break** -- the stop bit was 0, so the line is still low.
  The receiver waits for `rx` to return high before resuming start bit hunting.
  Jumping straight to the next start bit would produce incorrect frame timing.

Overrun is detected when `rx_full` is asserted at the moment a new byte is
ready to write. The byte is dropped and `rx_overrun` is pulsed for one cycle.

### Requirements

- **URX-001** -- The `rx` input shall be synchronised to the system clock using a two-register (2-FF) synchroniser before any processing. All internal logic operates on the synchronised signal.
- **URX-002** -- While idle, the receiver shall monitor the synchronised `rx` line for a falling edge to detect the start of a start bit.
- **URX-003** -- On detecting a falling edge on `rx`, the receiver shall reset its oversample counter and wait until the 8th subsequent `baud_tick`. If `rx` is still 0 at tick 8, the start bit is valid and frame reception begins. If `rx` has returned to 1, the edge is a glitch and the receiver returns to idle.
- **URX-004** -- Frame configuration (`data_bits`, `parity_en`, `parity_odd`, `stop_bits`) shall be latched when a valid start bit is confirmed. Changes mid-frame do not affect the frame in progress.
- **URX-005** -- Each data bit shall be sampled at tick 8 of its 16-tick oversample window, LSB-first. The number of data bits is determined by `data_bits`, which carries the actual bit count: 5, 6, 7, or 8.
- **URX-006** -- When `parity_en = 1`, the parity bit shall be sampled at tick 8 of the parity window. A mismatch against the expected parity shall set `rx_data[9]` (parity_err).
- **URX-007** -- The stop bit shall be sampled at tick 8 of the stop bit window. If the stop bit is 0, `rx_data[8]` (framing_err) shall be set.
- **URX-008** -- A break is distinguished from a framing error as follows: if the stop bit is 0 and all data bits are 0 and the parity bit (if enabled) is 0, the condition is a break (`rx_data[10]` set); if the stop bit is 0 and any other received bit is 1, it is a framing error (`rx_data[8]` set, `rx_data[10]` clear).
- **URX-009** -- When `rx_full` is asserted at the moment a received frame is ready to write, the byte shall be discarded: `rx_wr_en` shall not be asserted and `rx_overrun` shall be pulsed for exactly one clock cycle.
- **URX-010** -- On a successfully received byte, `rx_wr_en` shall be asserted for one clock cycle with `rx_data` valid. `rx_data[7:0]` contains the received byte; `rx_data[10:8]` contains error flags from the frame.
- **URX-011** -- On a parity error or overrun, the receiver shall return to idle immediately after the frame completes, without waiting for `rx` to return high.
- **URX-012** -- On a framing error or break, the receiver shall wait for `rx` to return to 1 before resuming start bit detection.
- **URX-013** -- A synchronous reset shall return the receiver to idle with `rx_wr_en` and `rx_overrun` both 0.
- **URX-014** -- `uart_rx` shall maintain a 32-bit received frame count (`rx_frame_count`) that increments by 1 each time a complete, error-free frame is successfully written to the FIFO (`rx_wr_en` asserted with `rx_data[10:8]` all zero). Dropped frames, errored frames, and glitch-rejected starts shall not increment this counter. The counter wraps on overflow and resets to 0 on synchronous reset.
- **URX-015** -- `uart_rx` shall maintain a 32-bit dropped frame count (`rx_drop_count`) that increments by 1 each time a complete, error-free frame is discarded because `rx_full` is asserted when the byte is ready. Errored frames and glitch-rejected starts shall not increment this counter. The counter wraps on overflow and resets to 0 on synchronous reset.
- **URX-016** -- `uart_rx` shall assert `rx_break` on the cycle that a break condition is confirmed (the same cycle `rx_wr_en` is asserted with the null byte). `rx_break` shall remain asserted until the synchronised `rx` input returns to 1, at which point `rx_break` shall deassert and the receiver shall resume start-bit detection. `rx_break` shall be 0 on synchronous reset.

