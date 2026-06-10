# Architecture: MMIO Dot-Product Accelerator

## System Overview

The MMIO Dot-Product Accelerator is a simple coprocessor accessed by CPU-like verification harnesses through a memory-mapped I/O (MMIO) bus. The architecture separates control flow (FSM), data flow (MAC datapath), and register storage.

## Block Diagram

```
┌─────────────────────────────────────────────┐
│         Testbench / Software               │
│    (Firmware-like MMIO interface)          │
│                                             │
│  mmio_write(0x00, START)                   │
│  poll STATUS register for DONE             │
│  mmio_read(RESULT_LO/HI)                   │
└────────────────┬────────────────────────────┘
                 │
        ┌────────┴─────────┐
        │  MMIO Bus (32-bit│
        │   address/data)  │
        └────────┬─────────┘
                 │
┌────────────────▼────────────────────────────┐
│    Dot-Product Accelerator                 │
│                                             │
│  ┌────────────────────────────────────┐   │
│  │  Control Registers & Decode        │   │
│  │  - CTRL (write-only)               │   │
│  │  - STATUS (read-only)              │   │
│  │  - RESULT_LO / RESULT_HI           │   │
│  └────────────────────────────────────┘   │
│                                             │
│  ┌────────────────────────────────────┐   │
│  │  Storage                           │   │
│  │  - A[0..15] (32-bit signed)       │   │
│  │  - B[0..15] (32-bit signed)       │   │
│  │  - Result (64-bit signed)         │   │
│  └────────────────────────────────────┘   │
│                                             │
│  ┌────────────────────────────────────┐   │
│  │  Control FSM                       │   │
│  │                                     │   │
│  │  IDLE ──START──> RUN ──16 MAC──>   │   │
│  │   ▲               │                 │   │
│  │   │         (accumulate)            │   │
│  │   └────────────DONE                 │   │
│  └────────────────────────────────────┘   │
│                                             │
│  ┌────────────────────────────────────┐   │
│  │  Datapath                          │   │
│  │                                     │   │
│  │  product[63:0] = A[idx] × B[idx]   │   │
│  │  acc <= acc + product              │   │
│  │  idx <= idx + 1                    │   │
│  └────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

## MMIO Interface

The accelerator is accessed via a 32-bit MMIO bus with:
- **Address Width:** 8 bits (allows up to 256 registers)
- **Data Width:** 32 bits
- **Read/Write:** Separate `rd_en` and `wr_en` signals
- **Timing:** Combinational read, synchronous write

```
Module Interface:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Input  clk              Clock
Input  rst_n            Active-low reset
Input  wr_en            Write enable
Input  rd_en            Read enable
Input  addr[7:0]        Byte address
Input  wdata[31:0]      Write data
Output rdata[31:0]      Read data (combinational)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**Bus Assumptions:**
- One operation per cycle (no concurrent reads/writes)
- Addresses are byte-addressed (but aligned to 32-bit words)
- No wait states; all operations complete in one cycle
- No bus errors; invalid addresses return 0

## Finite State Machine (FSM)

The control FSM has three states:

### IDLE (Wait for START)
- **BUSY:** 0
- **DONE:** 0
- **Action:** Waits for START command
- **Transition:** On `CTRL.START = 1` → RUN
- **Side Effects:** Clear accumulator, index, and result

### RUN (Process 16 MAC Operations)
- **BUSY:** 1
- **DONE:** 0
- **Action:** Each cycle:
  - Compute `product = A[idx] × B[idx]` (signed)
  - Accumulate: `acc <= acc + product`
  - Increment: `idx <= idx + 1`
- **Transition:** When `idx == 15` at end of cycle → DONE
- **Latency:** 16 cycles (processes indices 0 through 15)

### DONE (Result Ready)
- **BUSY:** 0
- **DONE:** 1
- **Action:** Result registers hold stable value
- **Transition:** On `CTRL.START = 1` → RUN (allows continuous operation)
- **Side Effects:** Clear accumulator and result for next run

**FSM State Diagram:**
```
        ┌─────────────────────┐
        │       IDLE          │
        │  BUSY=0, DONE=0    │
        └──────────┬──────────┘
                   │
         START=1 (CTRL[0])
                   │
                   ▼
        ┌─────────────────────┐
        │       RUN           │
        │  BUSY=1, DONE=0    │
        │  idx: 0→1→...→15   │
        └──────────┬──────────┘
              (16 cycles)
                   │
            idx==15 at end
                   │
                   ▼
        ┌─────────────────────┐
        │       DONE          │
        │  BUSY=0, DONE=1    │
        └──────────┬──────────┘
                   │
         START=1 (CTRL[0])
                   └─────────► (back to RUN)
```

## Datapath: Signed Multiply-Accumulate

The datapath performs one 32×32 signed multiplication per cycle and accumulates into a 64-bit result:

```
        A[idx]           B[idx]
        (signed)         (signed)
          │                │
          └────────┬────────┘
                   │
          ┌────────▼────────┐
          │ Signed 32×32    │
          │   Multiplier    │
          │ (combinational) │
          └────────┬────────┘
                   │
              product[63:0]
              (64-bit signed)
                   │
                   │ acc[63:0]
                   ▼
          ┌─────────────────┐
          │ 64-bit Adder    │
          │ (combinational) │
          └────────┬────────┘
                   │
            next_acc[63:0]
                   │
                   ▼
          (registered on clock)
          acc <= next_acc
```

**Signed Arithmetic:**
- Inputs: 32-bit signed integers (-2^31 to 2^31 - 1)
- Product: 64-bit signed result
- Accumulator: 64-bit signed (supports up to +/-2^63 - 1)
- The RTL does not saturate or flag overflow; software must choose inputs whose final dot product fits in signed 64-bit range.

**Example Computation:**
```
A = [1, 2, 3, 4, ...]
B = [1, 2, 3, 4, ...]

Cycle 1: acc = 0 + (1×1) = 1
Cycle 2: acc = 1 + (2×2) = 5
Cycle 3: acc = 5 + (3×3) = 14
...
Cycle 16: acc = ... + (15×15) = 1240
```

## Register Storage

### Input Vectors
- **A[0..15]:** 16 × 32-bit signed registers (offset 0x10–0x4C)
- **B[0..15]:** 16 × 32-bit signed registers (offset 0x50–0x8C)
- Written by testbench via MMIO before START
- Read by accelerator during RUN state

### Control and Status
- **CTRL (0x00):** Write-only control register
  - Bit 0: START (write 1 to begin computation)
  - Other bits ignored
  
- **STATUS (0x04):** Read-only status register
  - Bit 0: DONE (1 when result is ready)
  - Bit 1: BUSY (1 while computing)
  - Other bits return 0

### Result
- **RESULT_LO (0x08):** Lower 32 bits (combinational read)
- **RESULT_HI (0x0C):** Upper 32 bits (combinational read)
- Latched from accumulator when transitioning RUN→DONE

## HW/SW Boundary

### Hardware Responsibilities
- Perform signed arithmetic (no overflow protection—64-bit accumulation handles reasonable ranges)
- Maintain FSM state and cycle-by-cycle accumulation
- Provide clean MMIO read/write interface for all registers

### Software/Testbench Responsibilities
- Load A and B vectors via MMIO writes
- Poll STATUS register for DONE bit
- Read RESULT_LO and RESULT_HI and combine into 64-bit value
- Compute software reference (for verification)
- Compare hardware result with software reference

The repository includes both a SystemVerilog testbench and a C++/Verilator harness that implement this flow.

## Synthesis vs. Simulation

**Synthesizable RTL:**
- No `$display` statements in hardware module
- No `$random` in hardware
- Only synthesizable constructs: `always_ff`, `always_comb`, `logic`, `enum`, simple operators
- Uses procedural case statements for register decode (single-cycle)

**Testbench (unsynthesizable):**
- Uses `@(posedge clk)` timing control
- Uses `$display` for logging
- Uses `$urandom_range` for random test generation
- Uses `$dumpvars` for VCD generation
- Hierarchical signal access (`dut.state`, `dut.idx`)

## Timing Assumptions

**Reset:**
- Asynchronous active-low reset
- Clears all state while asserted low

**Write Timing:**
- Address, data, and `wr_en` asserted on clock cycle
- Registers updated on rising clock edge
- FSM transitions occur on same rising edge

**Read Timing:**
- Address set on clock cycle
- Data appears combinationally on `rdata` (no registered delay)
- Data valid for entire clock cycle after address is stable

**MAC Latency:**
- FSM enters RUN on rising edge after START write
- First MAC on cycle 1 of RUN (computes A[0] × B[0])
- Cycle 16 of RUN processes A[15] × B[15]
- DONE is observed 17 cycles after the START write is issued in the testbench
- **Measured: 17 cycles from START write issued to DONE observed**

## Limitations and Simplifications

1. **No DMA:** All data transferred via individual MMIO writes/reads
2. **No Interrupts:** Software must poll STATUS register
3. **Single-Issue MAC:** One multiplication per cycle (not pipelined)
4. **No Error Reporting:** Invalid addresses silently return 0
5. **Fixed Vector Size:** Always processes exactly 16 elements
6. **No Early Exit:** Cannot stop mid-computation

These simplifications make the design educational and easy to verify; a production accelerator would address them.
