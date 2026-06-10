# Verification Plan

## Strategy

The project has two verification harnesses:

- `tb/dot_accel_tb.sv`: SystemVerilog testbench run with Icarus Verilog.
- `sim/sim_main.cpp`: C++ testbench run against a Verilated model of `dot_accel`.

Both harnesses verify the accelerator as a CPU would use it:

1. Load `A[0..15]` and `B[0..15]` through MMIO writes.
2. Read back every input register to check the register file.
3. Write `CTRL.START`.
4. Poll `STATUS.DONE`.
5. Read `RESULT_LO` and `RESULT_HI`.
6. Compare the hardware result against a 64-bit software reference.

The simulation stops immediately with `$fatal` on the first mismatch.

## Testbench Tasks

The SystemVerilog testbench implements these tasks:

```systemverilog
task automatic mmio_write(input logic [7:0] write_addr,
                          input logic [31:0] write_data);

task automatic mmio_read(input logic [7:0] read_addr,
                         output logic [31:0] read_data);

task automatic load_vectors();
task automatic start_accel();
task automatic wait_done();
task automatic read_result(output longint signed result_val);
function automatic longint signed dotprod_sw();
task automatic run_test(input string test_name);
```

The vector arrays are global (`tb_a` and `tb_b`) for Icarus Verilog compatibility with unpacked arrays.

The C++ harness mirrors the same API with methods:

```cpp
mmio_write(addr, data);
mmio_read(addr);
load_vectors();
verify_vectors();
start_accel();
wait_done();
read_result();
dotprod_sw();
run_test(name);
```

This demonstrates the same register-level verification strategy from software.

## Deterministic Tests

| Test | Vector Pattern | Expected |
| --- | --- | ---: |
| `all_zeros` | `A[i] = 0`, `B[i] = 0` | 0 |
| `all_ones` | `A[i] = 1`, `B[i] = 1` | 16 |
| `increasing` | `A[i] = i`, `B[i] = i` | 1240 |
| `mixed_signs` | `A[i] = i - 8`, `B[i] = 8 - i` | -344 |
| `alternating_signs` | `A[i] = i`, `B[i] = i` for even `i`, else `-i` | -120 |
| `overflow_64bit` | `A[i] = 1_000_000`, `B[i] = 1_000_000` | 16000000000000 |

The `overflow_64bit` case proves that the design is not truncating products or the accumulator to 32 bits.

## Random Tests

The random campaign runs 100 tests. Each test uses:

```text
-1000 <= A[i] <= 1000
-1000 <= B[i] <= 1000
```

This range produces a mix of positive products, negative products, zero values, and cancellation patterns while keeping the expected result easy to reason about in signed 64-bit arithmetic.

## Signed Arithmetic Checks

The software reference extends each operand to `longint signed` before multiplication:

```systemverilog
a_ext = tb_a[i];
b_ext = tb_b[i];
sum = sum + (a_ext * b_ext);
```

This avoids a false pass or false fail caused by accidental 32-bit overflow inside the reference model.

## Cycle Measurement

The testbench keeps a simple cycle counter. `start_accel()` records the cycle when the START write is issued, and `wait_done()` records the cycle when `STATUS.DONE` is observed.

Current measured latency in both harnesses:

```text
START write issued -> DONE observed: 17 cycles
```

## Waveform Checklist

Inspect either VCD with GTKWave:

```text
waves/dot_accel.vcd      # SystemVerilog/Icarus flow
waves/dot_accel_cpp.vcd  # C++/Verilator flow
```

Confirm:

- Reset drives the FSM to `IDLE`.
- MMIO writes load A and B registers.
- A write to `CTRL` with bit 0 set starts the accelerator.
- `state` transitions `IDLE -> RUN -> DONE`.
- `idx` advances through 0 to 15.
- `acc` updates once per RUN cycle.
- `STATUS.DONE` asserts after computation.
- `RESULT_LO` and `RESULT_HI` expose the final signed 64-bit result.

The included `screenshots/waveform_mmio_run.png` focuses on the all-ones run, where the accumulator reaches 16 and the result latches to 16.

## Limitations

- The testbench assumes legal MMIO use: no simultaneous `wr_en` and `rd_en`.
- Invalid addresses are not treated as errors; the RTL returns zero.
- Timing, area, power, and FPGA resource usage are outside this simulation-only scope.
- Formal properties are not included yet.
