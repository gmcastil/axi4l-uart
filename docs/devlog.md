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
