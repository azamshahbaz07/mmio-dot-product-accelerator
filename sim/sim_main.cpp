#include "Vdot_accel.h"

#include "verilated.h"
#include "verilated_vcd_c.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <exception>
#include <filesystem>
#include <iomanip>
#include <iostream>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>

namespace {

constexpr int NumElems = 16;
constexpr int NumRandomTests = 100;

constexpr uint8_t CtrlAddr = 0x00;
constexpr uint8_t StatusAddr = 0x04;
constexpr uint8_t ResultLoAddr = 0x08;
constexpr uint8_t ResultHiAddr = 0x0c;
constexpr uint8_t ABaseAddr = 0x10;
constexpr uint8_t BBaseAddr = 0x50;

vluint64_t sim_time_ps = 0;

int64_t bits_to_i64(uint64_t bits) {
    int64_t value = 0;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

class DotAccelHarness {
  public:
    DotAccelHarness() {
        std::filesystem::create_directories("waves");

        Verilated::traceEverOn(true);
        dut_.trace(&trace_, 99);
        trace_.open("waves/dot_accel_cpp.vcd");

        dut_.clk = 0;
        dut_.rst_n = 1;
        dut_.wr_en = 0;
        dut_.rd_en = 0;
        dut_.addr = 0;
        dut_.wdata = 0;
        eval();
    }

    ~DotAccelHarness() {
        trace_.close();
    }

    void reset() {
        dut_.rst_n = 0;
        dut_.wr_en = 0;
        dut_.rd_en = 0;
        dut_.addr = 0;
        dut_.wdata = 0;
        last_start_cycle_ = 0;
        last_done_cycle_ = 0;
        last_latency_cycles_ = 0;
        total_pass_count_ = 0;

        for (int i = 0; i < 5; ++i) {
            tick();
        }

        dut_.rst_n = 1;

        for (int i = 0; i < 2; ++i) {
            tick();
        }
    }

    void load_vectors() {
        for (int i = 0; i < NumElems; ++i) {
            mmio_write(static_cast<uint8_t>(ABaseAddr + 4 * i),
                       static_cast<uint32_t>(a_[i]));
        }

        for (int i = 0; i < NumElems; ++i) {
            mmio_write(static_cast<uint8_t>(BBaseAddr + 4 * i),
                       static_cast<uint32_t>(b_[i]));
        }
    }

    void verify_vectors() {
        for (int i = 0; i < NumElems; ++i) {
            const auto actual = static_cast<int32_t>(
                mmio_read(static_cast<uint8_t>(ABaseAddr + 4 * i)));
            if (actual != a_[i]) {
                throw std::runtime_error("A register readback mismatch");
            }
        }

        for (int i = 0; i < NumElems; ++i) {
            const auto actual = static_cast<int32_t>(
                mmio_read(static_cast<uint8_t>(BBaseAddr + 4 * i)));
            if (actual != b_[i]) {
                throw std::runtime_error("B register readback mismatch");
            }
        }
    }

    void start_accel() {
        dut_.wr_en = 1;
        dut_.rd_en = 0;
        dut_.addr = CtrlAddr;
        dut_.wdata = 0x00000001;
        last_start_cycle_ = cycle_count_;

        tick();

        dut_.wr_en = 0;
        dut_.wdata = 0;
        dut_.addr = 0;
        eval();
    }

    void wait_done() {
        for (int poll = 0; poll < 100; ++poll) {
            const uint32_t status = mmio_read(StatusAddr);
            if ((status & 0x1) != 0) {
                last_done_cycle_ = cycle_count_;
                last_latency_cycles_ = last_done_cycle_ - last_start_cycle_;
                return;
            }
        }

        throw std::runtime_error("DONE timeout");
    }

    int64_t read_result() {
        const uint32_t lo = mmio_read(ResultLoAddr);
        const uint32_t hi = mmio_read(ResultHiAddr);
        const uint64_t bits = (static_cast<uint64_t>(hi) << 32) | lo;
        return bits_to_i64(bits);
    }

    int64_t dotprod_sw() const {
        int64_t sum = 0;

        for (int i = 0; i < NumElems; ++i) {
            sum += static_cast<int64_t>(a_[i]) * static_cast<int64_t>(b_[i]);
        }

        return sum;
    }

    void run_test(const std::string& name) {
        load_vectors();
        verify_vectors();
        start_accel();
        wait_done();

        const int64_t hw_result = read_result();
        const int64_t sw_result = dotprod_sw();

        if (hw_result != sw_result) {
            std::cout << "[FAIL] " << name << ": expected=" << sw_result
                      << " got=" << hw_result << '\n';
            throw std::runtime_error("hardware/software mismatch");
        }

        ++total_pass_count_;
        std::cout << "[PASS] " << name << ": expected=" << sw_result
                  << " got=" << hw_result
                  << " latency=" << last_latency_cycles_ << " cycles\n";
    }

    void set_all(int32_t a_value, int32_t b_value) {
        a_.fill(a_value);
        b_.fill(b_value);
    }

    void set_increasing() {
        for (int i = 0; i < NumElems; ++i) {
            a_[i] = i;
            b_[i] = i;
        }
    }

    void set_mixed_signs() {
        for (int i = 0; i < NumElems; ++i) {
            a_[i] = i - 8;
            b_[i] = 8 - i;
        }
    }

    void set_alternating_signs() {
        for (int i = 0; i < NumElems; ++i) {
            a_[i] = i;
            b_[i] = (i % 2 == 0) ? i : -i;
        }
    }

    void set_random(std::mt19937& rng) {
        std::uniform_int_distribution<int32_t> dist(-1000, 1000);

        for (int i = 0; i < NumElems; ++i) {
            a_[i] = dist(rng);
            b_[i] = dist(rng);
        }
    }

    int total_pass_count() const {
        return total_pass_count_;
    }

  private:
    void mmio_write(uint8_t write_addr, uint32_t write_data) {
        dut_.wr_en = 1;
        dut_.rd_en = 0;
        dut_.addr = write_addr;
        dut_.wdata = write_data;

        tick();

        dut_.wr_en = 0;
        dut_.wdata = 0;
        dut_.addr = 0;
        eval();
    }

    uint32_t mmio_read(uint8_t read_addr) {
        dut_.wr_en = 0;
        dut_.rd_en = 1;
        dut_.addr = read_addr;
        dut_.wdata = 0;

        tick();
        const uint32_t read_data = dut_.rdata;

        dut_.rd_en = 0;
        dut_.addr = 0;
        eval();

        return read_data;
    }

    void tick() {
        dut_.clk = 0;
        eval();
        trace_.dump(sim_time_ps);
        advance_time(5);

        dut_.clk = 1;
        eval();
        trace_.dump(sim_time_ps);
        advance_time(5);
        ++cycle_count_;
    }

    void eval() {
        dut_.eval();
    }

    void advance_time(vluint64_t delta_ps) {
        sim_time_ps += delta_ps;
    }

    Vdot_accel dut_;
    VerilatedVcdC trace_;
    int cycle_count_ = 0;
    int last_start_cycle_ = 0;
    int last_done_cycle_ = 0;
    int last_latency_cycles_ = 0;
    int total_pass_count_ = 0;
    std::array<int32_t, NumElems> a_{};
    std::array<int32_t, NumElems> b_{};
};

}  // namespace

double sc_time_stamp() {
    return static_cast<double>(sim_time_ps);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    try {
        DotAccelHarness tb;
        std::mt19937 rng(1);

        int deterministic_pass_count = 0;
        int random_pass_count = 0;

        std::cout << "\n=== MMIO Dot-Product Accelerator C++ Regression ===\n";

        tb.reset();

        tb.set_all(0, 0);
        tb.run_test("all_zeros");
        ++deterministic_pass_count;

        tb.set_all(1, 1);
        tb.run_test("all_ones");
        ++deterministic_pass_count;

        tb.set_increasing();
        tb.run_test("increasing");
        ++deterministic_pass_count;

        tb.set_mixed_signs();
        tb.run_test("mixed_signs");
        ++deterministic_pass_count;

        tb.set_alternating_signs();
        tb.run_test("alternating_signs");
        ++deterministic_pass_count;

        tb.set_all(1000000, 1000000);
        tb.run_test("overflow_64bit");
        ++deterministic_pass_count;

        for (int test_id = 0; test_id < NumRandomTests; ++test_id) {
            tb.set_random(rng);

            std::ostringstream name;
            name << "random_" << std::setw(3) << std::setfill('0') << test_id;
            tb.run_test(name.str());
            ++random_pass_count;
        }

        std::cout << "\nDeterministic tests: " << deterministic_pass_count
                  << "/6 PASS\n";
        std::cout << "Random tests:        " << random_pass_count << "/"
                  << NumRandomTests << " PASS\n";
        std::cout << "Total tests:         " << tb.total_pass_count() << "/"
                  << (6 + NumRandomTests) << " PASS\n";
        std::cout << "All C++ tests passed.\n";
        std::cout << "VCD saved to waves/dot_accel_cpp.vcd\n\n";
    } catch (const std::exception& e) {
        std::cerr << "[ERROR] " << e.what() << '\n';
        return 1;
    }

    return 0;
}
