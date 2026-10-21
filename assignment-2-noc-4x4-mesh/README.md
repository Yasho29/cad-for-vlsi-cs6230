# Assignment 2: 4×4 Mesh Network-on-Chip

A 4×4 mesh network-on-chip in Bluespec SystemVerilog: 16 five-port routers (N, E, S, W and local PE), with three output-arbiter designs compared in simulation and after synthesis.

## Microarchitecture

- **Packets:** 268 bits, moved as one unit (no flits).
- **Routing:** X-Y routing. One path per source–destination pair keeps packets in order, and forbidding Y-to-X turns makes the mesh deadlock-free.
- **Router:** a 2-entry input FIFO and a 2-entry output FIFO on every port (20 entries × 268 bits = 5,360 bits of buffering per router). A single `do_crossbar` rule reads the head of every input FIFO each cycle, computes its output port, lets one arbiter per output pick a winner (only if that output FIFO has room) and moves the winners across.
- **Links:** rules in `mkNoc` move each output FIFO head into the neighbour's input FIFO, so a hop costs two cycles.
- **Flow control:** back-pressure through FIFO occupancy; nothing is dropped.

## Arbiter designs

Everything except the output arbiter is identical across the three designs.

| Design | Arbiter | Behaviour | Arbiter flops |
|---|---|---|---|
| 1 | Round-robin | One 3-bit pointer per output; first requester at or after the pointer wins, then the pointer moves past it. A waiting input is served within four grants. | 15 |
| **2** | **Fixed, transit first** | Fixed per-output order that serves traffic already in the network before local injection. **Best design.** | 0 |
| 3 | Fixed, local first | One order for every output: local > N > E > S > W. | 0 |

## Performance (Bluesim)

L<sub>0</sub> and B<sub>S</sub> come from directed tests on an idle network. B<sub>N</sub> uses 16 PEs sending 8-packet messages to random nodes (xorshift32, seed 42) over a 10,000-cycle window after a 200-cycle warm-up. Time units assume the 1.0 ns synthesis clock.

| Quantity | Estimate | Design 1 | Design 2 | Design 3 |
|---|---|---|---|---|
| Zero-load latency L<sub>0</sub> | 14 cycles | 15 cycles | 15 cycles | 15 cycles |
| Router bandwidth B<sub>R</sub> (structural peak) | 160 B/cycle | 160 B/cycle | 160 B/cycle | 160 B/cycle |
| Single-link bandwidth B<sub>S</sub> | 32 B/cycle | 17.07 B/cycle | 17.07 B/cycle | 17.07 B/cycle |
| Network throughput B<sub>N</sub> | ≈ 170 B/cycle | 183.79 B/cycle | **191.21 B/cycle** | 187.50 B/cycle |

All runs drained fully (PASS). The B<sub>N</sub> estimate (mean distance 2.67 hops, about 2h + 3 cycles per path) was conservative by 8–12%; the network is far from saturation, so the arbiters differ by about 4%.

## Synthesis (SAED 14 nm, SS 0.72 V 125 °C, 1.0 ns clock)

All three designs meet timing at **1.0 GHz** with zero total negative slack and no design-rule violations; the critical path in each is register to register.

| Design | Slack at 1.0 ns | Leaf cells | Design area (µm²) | Levels of logic | Critical path | B<sub>N</sub> / design area |
|---|---|---|---|---|---|---|
| 1 Round-robin | 0.00 ns | 239,929 | 562,978.02 | 17 | 0.98 ns | 326.5 kB/(s·µm²) |
| **2 Transit first** | **0.06 ns** | 226,142 | **481,332.37** | 20 | 0.91 ns | **397.3 kB/(s·µm²)** |
| 3 Local first | 0.00 ns | 220,172 | 486,393.44 | 13 | 0.97 ns | 385.5 kB/(s·µm²) |

**Design 2 was submitted.** It has the highest throughput (+4.0% over Design 1, +2.0% over Design 3), the smallest area, positive slack left at 1.0 ns, and no arbiter state. Its limitation, shared with Design 3, is that fixed priorities give no bound on waiting; Design 1 is the only one with a bounded wait. The round-robin pointer update and rotating search make Design 1 17% larger than Design 2.

## Files

| Path | Contents |
|---|---|
| `src/Noc.bsv` | `mkNoc`: 16 routers wired as a 4×4 mesh |
| `src/NocRouter.bsv` | Router with the Design 2 arbiter (submitted) |
| `configs/design_1_round_robin/`, `configs/design_3_fixed_local_first/` | Router variants for Designs 1 and 3 |
| `src/NocMetrics.bsv` | Helper for the latency and bandwidth measurements |
| `src/TbNocRouter.bsv` | Single-router testbench |
| `src/TbNoc.bsv` | NoC testbench: random traffic and back-pressure with many PEs |
| `src/TbNocNetworkPerf.bsv` | B<sub>N</sub> measurement |
| `src/NocTypes.bsv`, `src/TbNocBasic.bsv` | Provided with the assignment (unmodified) |
| `synthesis/scripts/` | Exact Design Compiler TCL and SDC for each design |
| `synthesis/reports/design_<n>/` | QoR, timing, power and design-check reports |
| `results/` | Submitted BSV and synthesis result write-ups |

## Running (Bluesim)

From `src/`:

```bash
mkdir -p build
bsc -u -sim -bdir build -simdir build -info-dir build -g mkTbNoc TbNoc.bsv
bsc -sim -bdir build -simdir build -e mkTbNoc -o simTbNoc
./simTbNoc
```

Use `mkTbNocRouter` / `TbNocRouter.bsv`, `mkTbNocNetworkPerf` / `TbNocNetworkPerf.bsv` or `mkTbNocBasic` / `TbNocBasic.bsv` the same way. To try another arbiter, copy its `NocRouter.bsv` from `configs/` over `src/NocRouter.bsv` and rebuild in a fresh `build` directory.

To generate Verilog for synthesis:

```bash
bsc -u -verilog -bdir build -vdir build -info-dir build -g mkNoc Noc.bsv
```

Then place `build/mkNoc.v` and `FIFO2.v` (from `$BLUESPECDIR/Verilog`) in an `rtl/` folder and run Design Compiler with the matching TCL and SDC.
