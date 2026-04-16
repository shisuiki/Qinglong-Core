# Core ↔ SoC memory bus (Stage 0 / Stage 1)

Single-port from each side; valid/ready handshake both directions. No combinational paths across the boundary — all outputs are registered at the bus edge.

## Instruction fetch (read-only)

| Signal | Width | Dir (core→soc) | Notes |
|---|---|---|---|
| `ifetch_req_valid` | 1 | ↗ | Core requests a fetch this cycle. |
| `ifetch_req_addr`  | 32 | ↗ | 4-byte aligned. |
| `ifetch_req_ready` | 1 | ↙ | SoC can accept the request. |
| `ifetch_rsp_valid` | 1 | ↙ | A fetch response is on the bus. |
| `ifetch_rsp_data`  | 32 | ↙ | Instruction word (little-endian). |
| `ifetch_rsp_fault` | 1 | ↙ | 1 if fetch caused an access fault (e.g., address outside SRAM). |
| `ifetch_rsp_ready` | 1 | ↗ | Core can accept the response. Stage 0/1: tie high. |

Transfer semantics: `req` transfers on the cycle `req_valid && req_ready`; `rsp` is guaranteed at some later cycle when `rsp_valid && rsp_ready`. In-order, single outstanding request for Stage 1.

## Data memory (read/write, byte-maskable)

| Signal | Width | Dir | Notes |
|---|---|---|---|
| `dmem_req_valid`  | 1 | ↗ | |
| `dmem_req_addr`   | 32 | ↗ | Byte address. |
| `dmem_req_wen`    | 1 | ↗ | 0=load, 1=store. |
| `dmem_req_wdata`  | 32 | ↗ | Store data, already shifted into the right byte lanes by the core. |
| `dmem_req_wmask`  | 4 | ↗ | Byte enables for this word, computed by the core from size+alignment. |
| `dmem_req_size`   | 2 | ↗ | 00=byte, 01=half, 10=word. Used by loads to pick lane + for fault checks. |
| `dmem_req_ready`  | 1 | ↙ | |
| `dmem_rsp_valid`  | 1 | ↙ | Raised when a load completes (and optionally on store-ack). |
| `dmem_rsp_rdata`  | 32 | ↙ | Raw word; core handles sign/zero-extension. |
| `dmem_rsp_fault`  | 1 | ↙ | 1 if the access was not satisfiable (bad addr, misaligned rejected at SoC, etc.). |
| `dmem_rsp_ready`  | 1 | ↗ | Stage 0/1: tie high. |

Stage 0/1 SoC guarantees 1-cycle response latency for in-SRAM accesses and combinational response for MMIO accesses (suits single-cycle core). Later stages relax this.

## Address map

| Range | Device |
|---|---|
| `0x8000_0000 – 0x8000_FFFF` | 64 KB SRAM (I+D, unified) — BRAM in sim and on FPGA |
| `0xD058_0000` | UART-like console TX (store byte writes one char) |
| `0xD058_0004` | Exit register (store word terminates simulation with that code) |
| `0xD058_0008` | Status/placeholder — reads 0 for now |

The reset vector is `0x8000_0000`. This matches the `_start` address in `sw/common/link.ld`.

## ELF loading

In simulation the harness parses the ELF and populates SRAM via DPI before deasserting reset. On FPGA we'll initialize BRAM from a `$readmemh` file generated from the ELF.
