# Waveform Walkthrough

The verification flows write VCD files when they run:

```bash
waves/dot_accel.vcd      # SystemVerilog/Icarus
waves/dot_accel_cpp.vcd  # C++/Verilator
```

Open it with:

```bash
make wave
make wave-cpp
```

The included preview image, `screenshots/waveform_mmio_run.png`, is generated from the VCD and focuses on the `all_ones` case. It shows the START write, the RUN phase, 16 MAC cycles, DONE, and the result value of 16.

## Signals To Inspect

Add these signals in GTKWave:

```text
dot_accel_tb.clk
dot_accel_tb.rst_n
dot_accel_tb.wr_en
dot_accel_tb.rd_en
dot_accel_tb.addr
dot_accel_tb.wdata
dot_accel_tb.rdata
dot_accel_tb.dut.state
dot_accel_tb.dut.idx
dot_accel_tb.dut.acc
dot_accel_tb.dut.result
dot_accel_tb.dut.busy
dot_accel_tb.dut.done
dot_accel_tb.dut.a_regs[0]
dot_accel_tb.dut.b_regs[0]
dot_accel_tb.dut.a_regs[15]
dot_accel_tb.dut.b_regs[15]
```

## Reset

At the start of simulation:

- `rst_n` is held low for five clock cycles.
- `state` settles to `IDLE`.
- `idx`, `acc`, and `result` clear to zero.
- `done` and `busy` are both zero.

## MMIO Register Writes

During vector load:

- `wr_en` pulses for each register write.
- `addr` walks through `0x10` to `0x4C` for `A[0]` through `A[15]`.
- `addr` then walks through `0x50` to `0x8C` for `B[0]` through `B[15]`.
- `wdata` carries the signed 32-bit vector value.

The testbench reads the registers back after loading them, so `rd_en`, `addr`, and `rdata` also show the register-file verification phase.

## START Command

The accelerator starts when the testbench writes:

```text
addr  = 0x00
wdata = 0x00000001
wr_en = 1
```

On the accepting clock edge:

- `state` moves into `RUN`.
- `idx` resets to zero.
- `acc` clears.
- `result` clears for the new run.
- `busy` asserts.
- `done` deasserts.

## RUN Phase

During `RUN`, the accelerator performs one multiply-accumulate per clock cycle:

```text
acc <= acc + signed(A[idx]) * signed(B[idx])
idx <= idx + 1
```

For the `all_ones` case:

```text
idx: 0, 1, 2, ... 15
acc: 1, 2, 3, ... 16
```

This is the easiest waveform to inspect for off-by-one errors because the accumulator should increase by exactly one each MAC cycle.

## DONE And Result Reads

After element 15 is processed:

- `state` transitions to `DONE`.
- `busy` clears.
- `done` asserts.
- `result` holds the final 64-bit value.

The testbench then reads:

```text
0x08 RESULT_LO
0x0C RESULT_HI
```

For `all_ones`, the combined result is:

```text
0x00000000_00000010 = 16
```

## Latency

The measured latency is:

```text
START write issued -> DONE observed: 17 cycles
```

This includes the control write being issued, the transition into `RUN`, 16 MAC cycles, and the observation of `DONE` through the status register.

## Debugging Tips

- If `state` never leaves `IDLE`, check the `CTRL` write address and `wdata[0]`.
- If `idx` skips or reaches 16, inspect the `idx == 15` terminal condition.
- If `acc` is wrong only for large values, check signed casts and 64-bit widths.
- If the result reads as zero after DONE, check the `RESULT_LO` and `RESULT_HI` decode.
- If randomized tests fail but small tests pass, suspect 32-bit truncation in either RTL or the software reference.
