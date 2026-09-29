// =============================================================================
// soc_pkg
// -----------------------------------------------------------------------------
// Purpose    : SoC-level constants: reset vector, system memory map and
//              cacheability boundary. This is the single source of truth for
//              the memory map (CLAUDE.md §5.4); docs/memory_map.md and the C
//              header in sw/common mirror it and must be kept in sync.
// Interfaces : none (package).
// Timing     : n/a.
//
// Peripheral register offsets are added alongside each peripheral (Phase 6).
// =============================================================================
package soc_pkg;

  // Waiver: a package is a catalogue of constants; not every constant is
  // referenced by every module or build configuration, so UNUSEDPARAM is
  // noise here. It stays enabled for parameters declared inside modules.
  /* verilator lint_off UNUSEDPARAM */

  localparam int unsigned ADDR_W = 32;

  typedef logic [ADDR_W-1:0] addr_t;

  // ---------------------------------------------------------------------------
  // Memory map: base addresses and region sizes in bytes
  // ---------------------------------------------------------------------------
  localparam addr_t CLINT_BASE = 32'h0200_0000;
  localparam addr_t CLINT_SIZE = 32'h0001_0000;  // 64 KB

  localparam addr_t PLIC_BASE  = 32'h0C00_0000;
  localparam addr_t PLIC_SIZE  = 32'h0040_0000;  // 4 MB

  localparam addr_t UART_BASE  = 32'h1000_0000;
  localparam addr_t UART_SIZE  = 32'h0000_1000;  // 4 KB

  localparam addr_t SPI_BASE   = 32'h1000_1000;
  localparam addr_t SPI_SIZE   = 32'h0000_1000;  // 4 KB

  localparam addr_t MEM_BASE   = 32'h8000_0000;  // main memory (external AXI4-Lite port)
  localparam addr_t MEM_SIZE   = 32'h0001_0000;  // 64 KB

  // Reserved, simulation only (D-029): the core testbench's sim_ctrl device
  // (interrupt lines, acknowledge/force registers). The SoC never decodes this
  // window, so on real hardware an access to it is an access fault.
  localparam addr_t SIMCTRL_BASE = 32'h4000_0000;
  localparam addr_t SIMCTRL_SIZE = 32'h0000_1000;  // 4 KB

  // ---------------------------------------------------------------------------
  // Reset and cacheability
  // ---------------------------------------------------------------------------
  // The core boots from the start of main memory.
  localparam addr_t RESET_PC = MEM_BASE;

  // Every address below this boundary bypasses the D-cache; all MMIO lives
  // there.
  localparam addr_t CACHEABLE_BASE = 32'h8000_0000;

  /* verilator lint_on UNUSEDPARAM */

endpackage : soc_pkg
