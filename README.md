# CAD for VLSI Systems (CS6230)

Hardware design assignments from **CS6230: CAD for VLSI Systems** at IIT Madras (Jul–Nov 2026), written in **Bluespec SystemVerilog**, verified in Bluesim, and synthesised with **Synopsys Design Compiler** on the **SAED 14 nm** educational standard-cell library (slow corner: SS, 0.72 V, 125 °C).

**Author:** N Yasho Srikar Adithya Reddy, B.Tech Electrical Engineering, IIT Madras

## Assignments

| # | Design | Highlights |
|---|---|---|
| 1 | [Parameterised IEEE-754 floating-point adder](assignment-1-floating-point-adder/) | Any exponent / fraction width (2 ≤ e ≤ 15, 2 ≤ m ≤ 63); pipelined; round-to-nearest-even with full exception handling; verified with 20,000 vectors on each of 7 formats against an exact Python oracle; binary32 closes at **0.71 ns (1.408 GHz)** |
| 2 | [4×4 mesh network-on-chip](assignment-2-noc-4x4-mesh/) | 16 five-port routers, X-Y routing, deadlock-free; three output arbiters compared; best design reaches **191.21 B/cycle** network throughput and meets timing at **1.0 GHz** |

## Tools

Bluespec SystemVerilog (`bsc`, Bluesim) · Python · Synopsys Design Compiler U-2022.12 · SAED 14 nm RVT standard cells

Synthesised netlists and Design Compiler database files are not included, since they embed the Synopsys library; the scripts and reports are.
