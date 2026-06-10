# Register Map: MMIO Dot-Product Accelerator

## Overview

The accelerator exposes its state through an 8-bit address space with two groups of registers:
1. **Control/Status/Result** (4 registers)
2. **Input Vectors** (32 registers for A[0..15] and B[0..15])

**Total used:** 36 addressable 32-bit words (addresses 0x00 through 0x8C, with unused gaps between defined ranges)

## Control and Status Registers

| Address | Name | Access | Width | Description |
|---------|------|--------|-------|-------------|
| 0x00 | CTRL | W | 32-bit | Control register |
| 0x04 | STATUS | R | 32-bit | Status register |
| 0x08 | RESULT_LO | R | 32-bit | Result lower 32 bits |
| 0x0C | RESULT_HI | R | 32-bit | Result upper 32 bits |

### CTRL Register (0x00)

**Access:** Write-only (reading returns 0x00000000)

**Bit Layout:**
```
┌────────────────────────────────────────┐
│        CTRL Register (31:0)            │
├────────────────────────────────────────┤
│ Bit(s) │ Name         │ R/W │ Value   │
├────────┼──────────────┼─────┼─────────┤
│ [0]    │ START        │ W   │ START   │
│ [1]    │ SOFT_RESET   │ W   │ (Res.)  │
│ [31:2] │ Reserved     │ W   │ (Ign.)  │
└────────┴──────────────┴─────┴─────────┘
```

**Bit Definitions:**

| Bit | Name | Type | Description |
|-----|------|------|-------------|
| 0 | START | W | Write `1` to start computation. Transitions `IDLE -> RUN` or `DONE -> RUN`, clears accumulator, clears result. Ignored while already in `RUN`. |
| 1 | SOFT_RESET | W | Reserved for future use (optional soft reset). Currently ignored. |
| 31:2 | Reserved | W | Ignored. Writing 0 recommended. |

**Behavior:**
- Writing any value with bit 0 set to `1` starts the accelerator
- Writing with bit 0 = `0` has no effect
- CTRL is write-only; reading it returns `0x00000000`
- Multiple START writes while BUSY are ignored
- START writes in DONE begin a new computation

**Example:**
```
mmio_write(0x00, 0x00000001)  # Start computation
```

### STATUS Register (0x04)

**Access:** Read-only (writing has no effect)

**Bit Layout:**
```
┌────────────────────────────────────────┐
│        STATUS Register (31:0)          │
├────────────────────────────────────────┤
│ Bit(s) │ Name         │ Value           │
├────────┼──────────────┼─────────────────┤
│ [0]    │ DONE         │ (see below)     │
│ [1]    │ BUSY         │ (see below)     │
│ [31:2] │ Reserved (0) │ Always 0        │
└────────┴──────────────┴─────────────────┘
```

**Bit Definitions:**

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | DONE | `1` when result is ready (FSM in DONE state); `0` otherwise |
| 1 | BUSY | `1` while computation is in progress (FSM in RUN state); `0` otherwise |
| 31:2 | Reserved | Always read as `0` |

**FSM Status Encoding:**

| FSM State | BUSY | DONE | Description |
|-----------|------|------|-------------|
| IDLE | 0 | 0 | Waiting for START; no computation |
| RUN | 1 | 0 | Computing (16 cycles of MAC) |
| DONE | 0 | 1 | Result ready; waiting for next START |

**Software Polling Pattern:**
```
while (STATUS[0] == 0) {  // Poll until DONE bit is set
    // Wait and retry
}
// DONE bit is now 1; result ready
```

**Example:**
```
uint32_t status = mmio_read(0x04);
if (status & 0x1) {
    // Bit 0 is set → DONE
    // Read result now
} else if (status & 0x2) {
    // Bit 1 is set → BUSY (still computing)
}
```

### RESULT_LO Register (0x08)

**Access:** Read-only (combinational)

**Content:** Lower 32 bits of the 64-bit result

```
result[63:0] = {RESULT_HI[31:0], RESULT_LO[31:0]}
```

**Timing:**
- Read is combinational (result appears immediately on `rdata` bus)
- Value is latched when FSM transitions from RUN→DONE
- Remains stable until next START command

### RESULT_HI Register (0x0C)

**Access:** Read-only (combinational)

**Content:** Upper 32 bits of the 64-bit result

```
result[63:0] = {RESULT_HI[31:0], RESULT_LO[31:0]}
```

**Timing:**
- Read is combinational (result appears immediately on `rdata` bus)
- Value is latched when FSM transitions from RUN→DONE
- Remains stable until next START command

**Example - Reading 64-bit Result:**
```c
uint32_t result_lo = mmio_read(0x08);
uint32_t result_hi = mmio_read(0x0C);
int64_t result = ((int64_t)result_hi << 32) | result_lo;
printf("Result: 0x%016lx = %ld\n", result, result);
```

## Input Vector Registers

### A Vector (0x10 – 0x4C)

**Access:** Read/Write

**Layout:**

| Address | Register | Offset Formula |
|---------|----------|-----------------|
| 0x10 | A[0] | 0x10 + 4×0 |
| 0x14 | A[1] | 0x10 + 4×1 |
| 0x18 | A[2] | 0x10 + 4×2 |
| ... | ... | ... |
| 0x48 | A[14] | 0x10 + 4×14 |
| 0x4C | A[15] | 0x10 + 4×15 |

**Bit Width:** 32-bit signed (two's complement)

**Range:** -2,147,483,648 to 2,147,483,647

**Writing:**
- Software writes A[0..15] before START command
- Each write stores the 32-bit value into A[index]
- Values are signed; SystemVerilog automatically interprets as signed integers
- Writes while `STATUS.BUSY = 1` are ignored

**Reading:**
- Software can read back the loaded values to verify
- Useful for debugging register load operations

**Example:**
```c
int32_t a[16] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};

for (int i = 0; i < 16; i++) {
    mmio_write(0x10 + 4*i, (uint32_t)a[i]);
}
```

### B Vector (0x50 – 0x8C)

**Access:** Read/Write

**Layout:**

| Address | Register | Offset Formula |
|---------|----------|-----------------|
| 0x50 | B[0] | 0x50 + 4×0 |
| 0x54 | B[1] | 0x50 + 4×1 |
| 0x58 | B[2] | 0x50 + 4×2 |
| ... | ... | ... |
| 0x88 | B[14] | 0x50 + 4×14 |
| 0x8C | B[15] | 0x50 + 4×15 |

**Bit Width:** 32-bit signed (two's complement)

**Range:** -2,147,483,648 to 2,147,483,647

**Writing:**
- Software writes B[0..15] before START command
- Each write stores the 32-bit value into B[index]
- Values are signed; SystemVerilog automatically interprets as signed integers
- Writes while `STATUS.BUSY = 1` are ignored

**Reading:**
- Software can read back the loaded values to verify
- Useful for debugging register load operations

**Example:**
```c
int32_t b[16] = {16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1};

for (int i = 0; i < 16; i++) {
    mmio_write(0x50 + 4*i, (uint32_t)b[i]);
}
```

## Address Space Summary

| Range | Count | Type | Description |
|-------|-------|------|-------------|
| 0x00–0x0F | 4 | Control/Status/Result | CTRL, STATUS, RESULT_LO, RESULT_HI |
| 0x10–0x4C | 16 | Input Vector A | A[0] through A[15] |
| 0x50–0x8C | 16 | Input Vector B | B[0] through B[15] |
| 0x90–0xFF | (unused) | (reserved) | Available for future expansion |

**Total defined registers:** 36

## Register Access Patterns

### Typical Software Flow

```
// 1. Load input vectors
for (i = 0; i < 16; i++) {
    mmio_write(0x10 + 4*i, A[i]);  // Write A[i]
    mmio_write(0x50 + 4*i, B[i]);  // Write B[i]
}

// 2. Start computation
mmio_write(0x00, 0x1);  // Write START

// 3. Poll for completion
while ((mmio_read(0x04) & 0x1) == 0) {
    // DONE bit not set yet
}

// 4. Read result
uint32_t lo = mmio_read(0x08);
uint32_t hi = mmio_read(0x0C);
int64_t result = ((int64_t)hi << 32) | lo;
```

### Register Write Timing

```
Cycle N:     wr_en=1, addr=0x10, wdata=A[0]
             (combinational decode)
Cycle N+1:   a_regs[0] <= wdata
             (synchronous capture on rising edge)
             (now a_regs[0] = A[0])
```

### Register Read Timing

```
Cycle N:     rd_en=1, addr=0x10
             (combinational mux)
             rdata = a_regs[0]
             (data appears immediately)
Cycle N+1:   Read rdata value from previous cycle
```

## Design Decisions

1. **32-bit Element Size:** Matches a typical software word and keeps the register map simple
2. **64-bit Result:** Preserves full 32x32 products and supports results far beyond 32-bit range; software is still responsible for avoiding signed 64-bit overflow
3. **Sequential Writes:** Simpler than DMA; suitable for small vectors
4. **Combinational Reads:** Result available immediately; no latency penalty
5. **Separate LO/HI:** Matches 32-bit bus; allows flexible read ordering

## Future Extensions

1. **LEN Register (0x90):** Compute only first LEN elements (1–16)
2. **CYCLE_COUNT Register (0x94):** READ-only; returns START-to-DONE cycles
3. **Parameterizable Size:** Support vectors of any length N
4. **Selective Reads:** Enable/disable individual elements (masking)
