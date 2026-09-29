# Memory map

`rtl/pkg/soc_pkg.sv` is the source of truth. This file and the C header in `sw/common/` (added in Phase 6) mirror it, so change all three together.

| Region | Base | Size | End (inclusive) | Bus | `soc_pkg` constants |
|---|---|---|---|---|---|
| CLINT | `0x0200_0000` | 64 KB | `0x0200_FFFF` | APB | `CLINT_BASE`, `CLINT_SIZE` |
| PLIC | `0x0C00_0000` | 4 MB | `0x0C3F_FFFF` | APB | `PLIC_BASE`, `PLIC_SIZE` |
| UART | `0x1000_0000` | 4 KB | `0x1000_0FFF` | APB | `UART_BASE`, `UART_SIZE` |
| SPI | `0x1000_1000` | 4 KB | `0x1000_1FFF` | APB | `SPI_BASE`, `SPI_SIZE` |
| Main memory (external port) | `0x8000_0000` | 64 KB | `0x8000_FFFF` | AXI4-Lite | `MEM_BASE`, `MEM_SIZE` |

### Reserved, simulation only

| Region | Base | Size | End (inclusive) | Used by | `soc_pkg` constants |
|---|---|---|---|---|---|
| Simulation control (`sim_ctrl`) | `0x4000_0000` | 4 KB | `0x4000_0FFF` | core testbench only (D-029) | `SIMCTRL_BASE`, `SIMCTRL_SIZE` |

This window is **never decoded by the SoC**: on the real bus it is unmapped and an access returns an access fault. In the core testbench (`tb/core_tb`), `mem_model` routes D-port accesses here to `tb/common/sim_ctrl.sv`:

| Offset | Register | Access | Effect |
|---|---|---|---|
| `0x0` | `IRQ_ACK` | W | Write a cause code (3, 7 or 11): lowers that interrupt line and counts one acknowledgement |
| `0x4` | `IRQ_FORCE` | W | Bits 3/7/11: raise the MSIP/MTIP/MEIP line |
| `0x8` | `IRQ_LINES` | R | Current line state, bits 3/7/11 |
| `0xC` | `IRQ_RANDOM` | R/W | Write 0 to pause the random interrupt generator, 1 to resume (lines already high stay high until acknowledged); reads 1 while running |

The C/assembly mirror is `sw/common/simctrl.h`. It lies below `CACHEABLE_BASE`, so the Phase 4 D-cache bypasses it.

- **Reset PC:** `0x8000_0000` (`RESET_PC = MEM_BASE`).
- **Cacheability:** addresses below `0x8000_0000` (`CACHEABLE_BASE`) bypass the D-cache. All MMIO is in that range.
- **Unmapped addresses:** return SLVERR/PSLVERR, which the core reports as a load or store access fault.

Peripheral register maps are added in Phase 6.
