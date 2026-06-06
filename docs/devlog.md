AXI4-Lite UART Development Log

---

## Session 1 - 2026-05-30

### What Was Decided

- **Repo created at `/storage/github-repos/axi4l-uart/`.**
  Separate from the VRF framework repo. VRF is a pinned git submodule at
  `extern/verif`. The UART drives VRF development -- when verification of this
  DUT requires a missing framework feature, that feature is designed in VRF first
  and then used here.

- **Bottom-up verification strategy.**
  Each RTL module is verified in isolation before integration. Order:
  `baud_rate_gen` -> `uart_tx` -> `uart_rx` -> `uart_sync_fifo` -> TX+FIFO ->
  RX+FIFO -> loopback -> register interface -> `uart_top`. Each layer is signed
  off before the next one is added.

- **Mixed-language test infrastructure established.**
  SVUnit test suites use VHDL + SV. `runSVUnit --sim questa -m <vhdl.f>` handles
  the mixed compile: `vcom` for VHDL, `vlog` for SV + SVUnit. SVUnit lives at
  `extern/verif/extern/svunit`. Test suites live under `tests/<module_name>/`.
  Each suite has its own Makefile, a VHDL filelist (`*_vhdl.f`), and the test
  module (`.sv`).

- **Clocking block convention established.**
  All clocked SV testbench code uses `default clocking cb @(posedge clk)` with
  `default input #1step` and `default output #1`. Time advances use `##N`
  notation. Direct `always #N clk = ~clk` for clock generation.

- **`baud_rate_gen` unit test written.**
  Seven tests in `tests/baud_rate_gen/baud_rate_gen_unit_test.sv`:
  `no_tick_when_disabled`, `tick_fires_after_baud_div_plus_one_cycles`,
  `tick_is_one_cycle_wide`, `steady_state_period_is_baud_div_plus_one`,
  `baud_div_zero_ticks_every_cycle`, `disable_resets_counter`,
  `reset_clears_outputs`. Uses `baud_div=4` (not the real 867) for short
  simulation and easy manual verification. Note: `baud_div` is registered
  internally -- tests load it one cycle before asserting `baud_gen_en`.

- **Top-level project infrastructure still needed.**
  Makefile, scripts/, .gitignore additions, Python venv for any pytest-driven
  integration tests.

### Open Design Decisions

None.

### Next Steps

1. Set up top-level Makefile and scripts/ (run_svunit wrapper, hooks)
2. Run `baud_rate_gen` unit tests and confirm all 7 pass
3. Move on to `uart_tx` unit tests once `baud_rate_gen` is signed off

---

## Session 2 - 2026-06-02

### What Was Decided

- **Module header comment template established.**
  Format: Module, Description, Purpose, Usage, Notes. No horizontal rules. No
  Ports or Generics sections -- those are documented inline on each port/generic
  declaration. Header added to `baud_rate_gen.vhd`.

- **`baud_rate_gen` reviewed and left unchanged.**
  The registered `baud_div` input (`baud_div_q`) adds a one-cycle-ahead
  requirement but is harmless in practice since AXI transactions provide ample
  setup time. 15-bit width covers 9600 baud and above at 100 MHz -- sufficient
  for the intended use case. No RTL changes needed.

- **`baud_gen_en` is a global software enable, not a per-frame signal.**
  Driven from a control register. The generator runs continuously while
  asserted. TX and RX consume ticks whenever they have work to do.

- **`baud_rate_gen` runs at 16x the baud rate.**
  `uart_rx` uses the tick directly for oversampling. `uart_tx` counts 16 ticks
  per bit internally. The driver computes
  `baud_div = (f_clk / (baud_rate * 16)) - 1` from the clock frequency read
  from the device tree. `baud_div` must not be changed while the core is
  enabled -- software enforces this by disabling before changing.

- **Top-level hierarchy defined.**
  `uart_top` = `axi4l_regs` + `uart_ctrl` + `uart_core`. `uart_core` =
  `baud_rate_gen` + `uart_tx` + `uart_rx` + TX FIFO + RX FIFO. FIFOs live
  inside `uart_core`, external to `uart_tx` and `uart_rx`. `uart_core` has no
  knowledge of the AXI register interface.

- **`axi4l_regs` is a generic reusable AXI4-Lite slave.**
  Presents a decoded register bus: `reg_addr`, `reg_wdata`, `reg_wren`,
  `reg_be`, `reg_rdata`, `reg_req`, `reg_ack`, `reg_err`. `reg_ack` and
  `reg_err` are registered (1-cycle latency). `ack=1, err=0` = OKAY;
  `ack=1, err=1` = SLVERR. `reg_be` only meaningful on writes.

- **`uart_ctrl` is the UART-specific control and status module.**
  Register bus on one side, control/status signals on the other. Owns the
  interrupt enable and status registers. Drives the single `irq` output.

- **`uart_tx` interface settled.**
  Inputs: `baud_tick`, frame config (`data_bits`, `parity_en`, `parity_odd`,
  `stop_bits`), TX FIFO read port (`tx_data`, `tx_empty`, `tx_rd_en`).
  Outputs: `tx`, `tx_busy`. Frame config is registered at the start of each
  frame -- changes take effect on the next frame. `tx_busy` remains asserted
  until the stop bit has been sent; required for correct `tcdrain()` behavior.

- **`uart_rx` interface settled.**
  Inputs: `baud_tick`, frame config (same as TX), `rx`, `rx_full`. Outputs:
  `rx_data` (12-bit packed), `rx_wr_en`. Start bit validated at oversample
  tick 8. Each bit sampled at tick 8 (mid-bit). Frame config registered at
  frame start. Error recovery: parity/overrun returns to idle immediately;
  framing error/break waits for line to go high first.

- **RX FIFO is 12 bits wide.**
  Bit packing: `[11]=break, [10]=overrun, [9]=parity_err, [8]=framing_err,
  [7:0]=data`. Per-byte error association required for correct use of
  `tty_insert_flip_char()` in the Linux driver. TX FIFO remains 8 bits.

- **Interrupt architecture defined.**
  Three sources: `irq_tx_empty`, `irq_rx_not_empty`, `irq_rx_error`. Masked
  by Interrupt Enable Register (IER). Status held in Interrupt Status Register
  (ISR, write-1-to-clear). Single `irq` output is OR of (ISR & IER). PS
  interrupt controller receives the single line.

- **DMA deferred.**
  Not needed for UART baud rates. Will be learned on the HDMI core project
  where it is actually required.

- **Kernel driver will live in the Arty-Z7 repository, not this one.**
  That repo owns kernel and U-Boot source as externals, plus device tree,
  FSBL, and boot file generation.

- **`docs/design.md` created.**
  Contains full architecture, block diagram, module interfaces, software
  requirements, and driver constraints.

### Open Design Decisions

- FIFO depth: TBD (will fall out of Xilinx primitive selection)
- `uart_core` external port list: TBD
- `uart_ctrl` register map: TBD
- `uart_sync_fifo` FIFO mode (FWFT vs standard): deferred to TX+FIFO integration

### Next Steps

1. Write requirements for `baud_rate_gen`, `uart_tx`, and `uart_rx`
2. Define `uart_core` external port list
3. Define `uart_ctrl` register map (follows naturally from requirements)
4. Begin `uart_tx` RTL and unit tests

---

## Session 3 - 2026-06-02

### What Was Decided

- **Requirement ID format adopted.**
  IDs are module-prefixed and sequential: `BRG-NNN`, `UTX-NNN`, `URX-NNN`.
  Requirements live as subsections in `docs/design.md` under each module.

- **RX FIFO narrowed from 12 to 11 bits.**
  Overrun removed from the FIFO word. Overrun is not a per-byte condition --
  it means a byte was lost and never reached the FIFO -- so it has no business
  being in the FIFO data word. New packing: `[10]=break, [9]=parity_err,
  [8]=framing_err, [7:0]=data`.

- **`rx_overrun` strobe added as a dedicated output on `uart_rx`.**
  One-cycle pulse when a received frame is dropped due to a full FIFO.
  `uart_ctrl` latches it into a status register. Driver sees it via
  `irq_rx_error`. This replaces the removed FIFO bit entirely.

- **Break detection: all-zeros heuristic.**
  If stop bit = 0 AND all data bits = 0 AND parity bit (if enabled) = 0,
  it is a break (`rx_data[10]`). If stop bit = 0 with any other bit = 1,
  it is a framing error (`rx_data[8]`). Matches 8250/16550 convention and
  what `uart_handle_break()` in the Linux serial framework expects.

- **32-bit diagnostic frame counters added.**
  `uart_tx`: `tx_frame_count` -- increments when `tx_busy` deasserts.
  `uart_rx`: `rx_frame_count` -- increments on error-free frames written to
  FIFO. `rx_drop_count` -- increments on error-free frames dropped due to
  overrun. All wrap on overflow, reset to zero on synchronous reset, and are
  software-readable. Glitch-rejected starts are not counted anywhere.
  A received frame is complete, error-free, and successfully written to the
  FIFO. A dropped frame is complete, error-free, and could not be written.

- **`uart_rx` owns the 2-FF input synchronizer.**
  The `rx` pin connects directly to `uart_rx` (via IBUF). The synchronizer
  is internal to `uart_rx`; all internal logic operates on the synchronised
  signal.

- **Software reset and loopback deferred to `uart_core`.**
  Both are `uart_core`-level concerns noted as open items in `design.md`.
  Software reset: a register bit in `uart_ctrl` that asserts `rst` to
  `uart_core`. Loopback: a register bit that muxes `tx` back to the `rx`
  input of `uart_rx`.

### What Was Done

- **Requirements written for all three modules.**
  `design.md` updated with Requirements subsections: BRG-001..007,
  UTX-001..012, URX-001..015. UTX-010 (`tx_rd_en` timing) marked deferred
  pending FIFO mode decision.

- **`design.md` updated throughout for 11-bit RX FIFO.**
  Block diagram, FIFO table, interface blocks, error recovery prose, and
  interrupt source table all updated. `uart_core` Open Items section added.

### Open Design Decisions

- FIFO depth: TBD (Xilinx primitive selection)
- `uart_core` external port list: TBD
- `uart_ctrl` register map: TBD
- `uart_sync_fifo` FIFO mode (FWFT vs standard): deferred to TX+FIFO integration
- `tx_rd_en` assertion timing (UTX-010): deferred to TX+FIFO integration

### Next Steps

1. Define `uart_core` external port list
2. Define `uart_ctrl` register map
3. Begin `uart_tx` RTL and unit tests

---

## Session 4 - 2026-06-02

### What Was Decided

- **Loopback mode confirmed and its driver mapping settled.**
  Loopback is not required by the serial core framework but is kept for
  bring-up testability. From userspace it is controlled via `TIOCM_LOOP`
  (e.g. `ioctl(fd, TIOCMBIS, TIOCM_LOOP)`). The driver's `set_mctrl()`
  callback handles `TIOCM_LOOP` by toggling the loopback register bit in
  `uart_ctrl`.

- **Flow control stance settled.**
  No hardware flow control -- the design has no RTS/CTS lines and the driver
  will not advertise that capability. Software flow control (XON/XOFF) is
  handled entirely by the tty line discipline above the driver and requires
  no driver or hardware support. Both are free consequences of the current
  design.

- **`tx_empty` driver callback must AND `tx_empty` with `!tx_busy`.**
  The serial core calls `tx_empty()` to determine whether the port is truly
  idle (e.g. for `tcdrain()`). Returning TX FIFO empty alone is incorrect --
  a byte may still be in the shift register. The callback must return
  `tx_fifo_empty AND !tx_busy`. This is why UTX-008 requires `tx_busy` to
  remain asserted through the end of the stop bit.

### Open Design Decisions

None beyond those carried from Session 3.

### Next Steps

Same as Session 3.

---

## Session 5 - 2026-06-02

### What Was Decided

- **`uart_ctrl` register map defined.**
  17 registers, word-indexed (0-16). `axi4l_regs` strips the AXI byte offset
  and presents a 5-bit word index to `uart_ctrl`. Indices 17-31 return SLVERR.
  Full register map documented in `docs/design.md` under `uart_ctrl`.

- **`baud_rate_gen` relocated to `uart_top` level.**
  Previously inside `uart_core`. Moved up so its tick is available directly to
  both `uart_ctrl` (RX timeout counter) and `uart_core` (uart_tx, uart_rx)
  without routing it through `uart_core`'s external interface. `uart_ctrl`
  drives `baud_div` and `baud_gen_en` directly to `baud_rate_gen`. `uart_core`
  takes `baud_tick` as an input. Block diagram updated in `design.md`.

- **All signals across module boundaries are now known.**
  `uart_core` is a pure datapath -- no knowledge of thresholds, timeouts, or
  interrupts. All interrupt decision logic lives in `uart_ctrl`.
  `uart_core` exposes two new signals to `uart_ctrl`: `baud_tick` (from
  `baud_rate_gen`, used for timeout counting) and `rx_received` (one-cycle
  pulse when a byte lands in the RX FIFO, used to reset the timeout counter).
  `rxthr` and `rxtout` do not pass into `uart_core`.
  `uart_core` has two reset inputs: `rst` (hardware reset from top level) and
  `sw_rst` (one-cycle pulse from `uart_ctrl` when CTRL[8] is written).
  Software reset is a separate pin from hardware reset.

- **Break stays in the RX FIFO as a null byte.**
  On break detection, `uart_rx` pushes one null byte with `rx_data[10]` set,
  then stalls until `rx` returns high. This preserves byte-stream ordering,
  consistent with 16550 convention. Break is not pushed repeatedly while the
  line stays low -- one entry, then stall.

- **`rx_break` level output added to `uart_rx` interface.**
  Asserts on the same cycle `rx_wr_en` fires for the null byte. Remains
  asserted until `rx` returns high. `uart_ctrl` exposes it as a readable status
  bit in RXSTAT[1]. URX-016 written to `design.md`.

- **FIFO depths resolved by primitive choice.**
  TX FIFO: FIFO18E1 in 9-bit mode = 2048 x 9 (8-bit data, 1 bit unused).
  RX FIFO: FIFO18E1 in 18-bit mode = 1024 x 18 (11-bit data, 7 bits unused).
  "FIFO depth: TBD" open item is closed.

- **RX threshold interrupt added (RXTHR, index 9).**
  `irq_rx_not_empty` fires when RX FIFO fill level >= threshold. Value 0
  disables the interrupt. Avoids interrupting on every received byte, which
  would be expensive on a 32-bit ARM processor at sustained baud rates.

- **RX timeout interrupt added (RXTOUT, index 10).**
  Fires when the RX FIFO is non-empty and no new byte has arrived within the
  configured number of baud ticks. Software-configurable. Value 0 disables.
  Mandatory companion to the threshold: without it, a burst that stops short
  of the threshold would stall in the FIFO indefinitely. Timeout unit is baud
  ticks; software computes the desired timeout from the baud rate.

- **RX and TX fill level registers added (RXLVL index 12, TXLVL index 11).**
  Expose the FIFO DATA_COUNT output from the Xilinx primitive. Hardware has
  this signal anyway; exposing it lets the driver read or write the exact number
  of bytes available in one shot rather than polling empty/full per byte.
  TXLVL is 11 bits (0-2048); RXLVL is 10 bits (0-1024).

- **FIFO flush bits added to CTRL (byte 2).**
  CTRL[16]=`tx_fifo_flush`, CTRL[17]=`rx_fifo_flush`. Both self-clearing.
  Allows the driver to flush either FIFO independently without a full software
  reset.

- **`rx_overrun` sticky status bit added to RXSTAT[8] (W1C).**
  Complements the `irq_rx_error` interrupt source. Allows the driver to
  determine specifically that an overrun occurred, independent of whether
  interrupts were enabled at the time.

- **Scratch register added (index 16).**
  No hardware function. Useful for register interface bringup and testing.

- **Register bit spacing convention adopted.**
  Bits are byte-aligned by functional group rather than packed into the lowest
  positions. CTRL: byte 0 = run/mode, byte 1 = reset, byte 2 = flushes.
  RXSTAT: byte 0 = FIFO/line state (RO), byte 1 = error flags (W1C).
  IER/ISR: byte 0 = TX interrupt, byte 1 = RX interrupts. IER and ISR mirror
  each other so (ISR & IER) masking works at the byte level.

### Open Design Decisions

- `uart_core` external port list: TBD
- `uart_sync_fifo` FIFO mode (FWFT vs standard): deferred to TX+FIFO integration
- UTX-010 (`tx_rd_en` assertion timing): deferred to TX+FIFO integration

### Next Steps

1. Define `uart_core` external port list
2. Begin `uart_tx` RTL and unit tests

---

## Session 6 - 2026-06-02

### What Was Decided

- **`uart_core` external port list defined.**
  Full interface documented in `design.md` under `uart_core`. Groups: clocking
  and reset, baud tick, frame config, TX FIFO write port, TX status and
  counters, FIFO control and mode, RX FIFO read port, RX status and counters,
  serial lines.

- **`sw_rst` confirmed as one-cycle pulse.**
  CTRL[8] is self-clearing. `uart_ctrl` generates a one-cycle pulse on `sw_rst`
  when the bit is written. The Xilinx FIFO reset timing requirements (hold
  duration, control stability before and after RST) are handled internally by
  `uart_core`. Implementation deferred.

- **`rx_received` fires on all FIFO writes.**
  Pulses on every `rx_wr_en`, including errored and break bytes. Does not pulse
  on overrun (byte was dropped, never written). Used by `uart_ctrl` to reset
  the RX timeout counter on any received activity.

- **`irq_rx_not_empty` must be edge-triggered.**
  The ISR bit is set when the RX FIFO fill level crosses RXTHR going upward,
  not while it remains at or above threshold. Must be an explicit implementation
  requirement on `uart_ctrl`, not inferred from the register description.

- **RX FIFO underflow protection is two-layered.**
  Primary: driver reads RXLVL=N and reads RXD exactly N times (snapshot-bounded
  loop -- cannot underflow because bytes do not disappear between the level read
  and the data reads). Backstop: `uart_ctrl` returns SLVERR on RXD read when
  `rx_empty` is asserted, without popping the FIFO. The interrupt re-arms
  naturally when new data arrives and crosses RXTHR again.

### What Was Done

- `docs/design.md` updated: `uart_core` interface section added; FIFOs table
  updated with primitive, mode, and depth; FIFO depth TBD item closed.

### Open Design Decisions

- `uart_core` Xilinx FIFO reset sequencing: deferred to implementation
- `uart_sync_fifo` FIFO mode (FWFT vs standard): deferred to TX+FIFO integration
- UTX-010 (`tx_rd_en` assertion timing): deferred to TX+FIFO integration

### Next Steps

1. Begin `uart_tx` RTL and unit tests

---

## Session 7 - 2026-06-06

### What Was Decided

- **`baud_rate_gen` signed off.**
  Two test gaps found and fixed: `no_tick_when_disabled` was missing the
  `baud_cnt=0` check (BRG-001), and `disable_resets_counter` was missing the
  `baud_tick=0` check (BRG-006). Both one-line additions. All 7 tests pass.

- **`baud_div_q` registration confirmed correct.**
  Registering the divisor input unconditionally on every clock edge is the
  right design. Adding hardware protection against software misuse (gating
  `baud_div_q` on `baud_gen_en`) is not appropriate -- the 16550 and all
  standard UART hardware enforce the disable-before-change rule by convention
  only. Hardware exists to implement behavior, not to babysit the software.

- **FWFT FIFO mode selected for both TX and RX FIFOs.**
  In FWFT mode the first word is already valid on the output when `tx_empty`
  deasserts. `uart_tx` latches `tx_data` and asserts `tx_rd_en` on the same
  clock cycle -- `tx_rd_en` means "advance to next word", not "give me this
  word". The FIFO going empty on that cycle is not a hazard because the data
  was already latched. This closes the `uart_sync_fifo` FIFO mode open item.

- **`data_bits` interface changed to actual bit count.**
  `data_bits` is now `unsigned(3 downto 0)` carrying the actual count (5, 6,
  7, or 8) rather than a 2-bit encoded value. `uart_ctrl` converts the 2-bit
  LCR register field to the actual count before driving the port. `design.md`
  updated throughout: `uart_tx`, `uart_rx`, and `uart_core` interface blocks,
  requirements UTX-005 and URX-005, and LCR register description.

- **`uart_tx` unit tests written.**
  20 tests in `tests/uart_tx/uart_tx_unit_test.sv` covering UTX-001 through
  UTX-012. `baud_tick` is driven directly from the testbench; no
  `baud_rate_gen` instance. The TX FIFO interface is modeled with simple
  procedural logic per test; no structural FIFO. Key helpers: `tick()` drives
  one baud_tick pulse; `bit_period(expected)` advances the DUT through one
  16-tick bit window and verifies `tx` at tick 1 and tick 8; `check_frame()`
  covers a complete frame. UTX-010 (`tx_rd_en` exact timing) remains deferred.

### Open Design Decisions

- `uart_core` Xilinx FIFO reset sequencing: deferred to implementation
- UTX-010 (`tx_rd_en` assertion timing): deferred to TX+FIFO integration

### Next Steps

1. Write `uart_tx` RTL
2. Run `uart_tx` unit tests and sign off

---
