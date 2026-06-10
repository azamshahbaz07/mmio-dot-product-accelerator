# Makefile for MMIO Dot-Product Accelerator
# SystemVerilog simulation with Icarus Verilog, Verilator C++, and GTKWave

.PHONY: all sim sim-cpp wave wave-cpp clean

VERILATOR ?= verilator
VERILATOR_BUILD := build/verilator/Vdot_accel

# Default target
all: sim

build waves:
	mkdir -p $@

# ============================================================================
# Icarus/SystemVerilog simulation: Compile and run
# ============================================================================
sim: build/dot_accel_tb.vvp | waves
	@echo "Running simulation..."
	vvp build/dot_accel_tb.vvp

# Compile RTL and testbench
build/dot_accel_tb.vvp: rtl/dot_accel.sv tb/dot_accel_tb.sv | build
	@echo "Compiling with Icarus Verilog (SystemVerilog 2012)..."
	iverilog -g2012 -Wall -o build/dot_accel_tb.vvp rtl/dot_accel.sv tb/dot_accel_tb.sv

# ============================================================================
# Verilator/C++ simulation: Compile and run
# ============================================================================
sim-cpp: $(VERILATOR_BUILD) | waves
	@echo "Running Verilator C++ simulation..."
	$(VERILATOR_BUILD)

$(VERILATOR_BUILD): rtl/dot_accel.sv sim/sim_main.cpp | build
	@echo "Compiling with Verilator and C++ harness..."
	$(VERILATOR) -Wall --cc --exe --build --trace --top-module dot_accel \
		-Mdir build/verilator \
		-CFLAGS "-std=c++17 -O2" \
		rtl/dot_accel.sv sim/sim_main.cpp

# ============================================================================
# Waveform viewing
# ============================================================================
wave: sim
	@echo "Opening GTKWave..."
	gtkwave waves/dot_accel.vcd &

wave-cpp: sim-cpp
	@echo "Opening GTKWave for C++ simulation..."
	gtkwave waves/dot_accel_cpp.vcd &

# ============================================================================
# Cleanup
# ============================================================================
clean:
	@echo "Cleaning generated files..."
	rm -rf build waves/*.vcd
