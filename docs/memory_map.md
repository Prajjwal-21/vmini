# Memory map

`rtl/pkg/soc_pkg.sv` is the source of truth. This file and the C header in `sw/common/` (added in Phase 6) mirror it, so change all three together.

| Region | Base | Size | End (inclusive) | Bus | `soc_pkg` constants |
|---|---|---|---|---|---|
| CLINT | `0x0200_0000` | 64 KB | `0x0200_FFFF` | APB | `CLINT_BASE`, `CLINT_SIZE` |
| PLIC | `0x0C00_0000` | 4 MB | `0x0C3F_FFFF` | APB | `PLIC_BASE`, `PLIC_SIZE` |
| UART | `0x1000_0000` | 4 KB | `0x1000_0FFF` | APB | `UART_BASE`, `UART_SIZE` |
| SPI | `0x1000_1000` | 4 KB | `0x1000_1FFF` | APB | `SPI_BASE`, `SPI_SIZE` |
| Main memory (external port) | `0x8000_0000` | 64 KB | `0x8000_FFFF` | AXI4-Lite | `MEM_BASE`, `MEM_SIZE` |

- **Reset PC:** `0x8000_0000` (`RESET_PC = MEM_BASE`).
- **Cacheability:** addresses below `0x8000_0000` (`CACHEABLE_BASE`) bypass the D-cache. All MMIO is in that range.
- **Unmapped addresses:** return SLVERR/PSLVERR, which the core reports as a load or store access fault.

Peripheral register maps are added in Phase 6.
