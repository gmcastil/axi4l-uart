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