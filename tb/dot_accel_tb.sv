// Self-checking testbench for the MMIO dot-product accelerator.

`timescale 1ns / 1ps

module dot_accel_tb;

    localparam int NUM_ELEMS = 16;
    localparam int NUM_RANDOM_TESTS = 100;

    localparam logic [7:0] CTRL_ADDR      = 8'h00;
    localparam logic [7:0] STATUS_ADDR    = 8'h04;
    localparam logic [7:0] RESULT_LO_ADDR = 8'h08;
    localparam logic [7:0] RESULT_HI_ADDR = 8'h0C;
    localparam logic [7:0] A_BASE_ADDR    = 8'h10;
    localparam logic [7:0] B_BASE_ADDR    = 8'h50;

    logic        clk;
    logic        rst_n;
    logic        wr_en;
    logic        rd_en;
    logic [7:0]  addr;
    logic [31:0] wdata;
    logic [31:0] rdata;

    int cycle_count;
    int last_start_cycle;
    int last_done_cycle;
    int last_latency_cycles;
    int total_pass_count;

    int signed tb_a [0:NUM_ELEMS-1];
    int signed tb_b [0:NUM_ELEMS-1];

    dot_accel dut (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .rd_en(rd_en),
        .addr(addr),
        .wdata(wdata),
        .rdata(rdata)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
        end
    end

    initial begin
        $dumpfile("waves/dot_accel.vcd");
        $dumpvars(0, dot_accel_tb);
    end

    task automatic mmio_write(input logic [7:0] write_addr,
                              input logic [31:0] write_data);
        @(negedge clk);
        wr_en = 1'b1;
        rd_en = 1'b0;
        addr  = write_addr;
        wdata = write_data;

        @(posedge clk);
        #1;

        @(negedge clk);
        wr_en = 1'b0;
        wdata = 32'h0;
        addr  = 8'h00;
    endtask

    task automatic mmio_read(input logic [7:0] read_addr,
                             output logic [31:0] read_data);
        @(negedge clk);
        wr_en = 1'b0;
        rd_en = 1'b1;
        addr  = read_addr;
        wdata = 32'h0;

        @(posedge clk);
        #1;
        read_data = rdata;

        @(negedge clk);
        rd_en = 1'b0;
        addr  = 8'h00;
    endtask

    task automatic load_vectors();
        int i;

        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            mmio_write(A_BASE_ADDR + (i << 2), tb_a[i]);
        end

        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            mmio_write(B_BASE_ADDR + (i << 2), tb_b[i]);
        end
    endtask

    task automatic verify_vectors();
        int i;
        int errors;
        logic [31:0] read_data;

        errors = 0;

        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            mmio_read(A_BASE_ADDR + (i << 2), read_data);
            if ($signed(read_data) != tb_a[i]) begin
                $display("[FAIL] A[%0d] readback: expected=%0d got=%0d",
                         i, tb_a[i], $signed(read_data));
                errors = errors + 1;
            end
        end

        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            mmio_read(B_BASE_ADDR + (i << 2), read_data);
            if ($signed(read_data) != tb_b[i]) begin
                $display("[FAIL] B[%0d] readback: expected=%0d got=%0d",
                         i, tb_b[i], $signed(read_data));
                errors = errors + 1;
            end
        end

        if (errors != 0) begin
            $fatal;
        end
    endtask

    task automatic start_accel();
        @(negedge clk);
        wr_en = 1'b1;
        rd_en = 1'b0;
        addr  = CTRL_ADDR;
        wdata = 32'h0000_0001;
        last_start_cycle = cycle_count;

        @(posedge clk);
        #1;

        @(negedge clk);
        wr_en = 1'b0;
        wdata = 32'h0;
        addr  = 8'h00;
    endtask

    task automatic wait_done();
        int poll_count;
        logic [31:0] status_val;

        status_val = 32'h0;

        @(negedge clk);
        wr_en = 1'b0;
        rd_en = 1'b1;
        addr  = STATUS_ADDR;
        wdata = 32'h0;

        for (poll_count = 0; poll_count < 100; poll_count = poll_count + 1) begin
            @(posedge clk);
            #1;
            status_val = rdata;

            if (status_val[0]) begin
                last_done_cycle = cycle_count;
                last_latency_cycles = last_done_cycle - last_start_cycle;
                break;
            end
        end

        @(negedge clk);
        rd_en = 1'b0;
        addr  = 8'h00;

        if (!status_val[0]) begin
            $display("[FAIL] wait_done timeout: last STATUS=0x%08h", status_val);
            $fatal;
        end
    endtask

    task automatic read_result(output longint signed result_val);
        logic [31:0] result_lo;
        logic [31:0] result_hi;

        mmio_read(RESULT_LO_ADDR, result_lo);
        mmio_read(RESULT_HI_ADDR, result_hi);

        result_val = {result_hi, result_lo};
    endtask

    function automatic longint signed dotprod_sw();
        longint signed sum;
        longint signed a_ext;
        longint signed b_ext;
        int i;

        sum = 0;
        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            a_ext = tb_a[i];
            b_ext = tb_b[i];
            sum = sum + (a_ext * b_ext);
        end

        return sum;
    endfunction

    function automatic int signed rand_small();
        rand_small = $urandom_range(0, 2000) - 1000;
    endfunction

    task automatic run_test(input string test_name);
        longint signed sw_result;
        longint signed hw_result;

        load_vectors();
        verify_vectors();
        start_accel();
        wait_done();
        read_result(hw_result);

        sw_result = dotprod_sw();

        if (hw_result != sw_result) begin
            $display("[FAIL] %s: expected=%0d got=%0d",
                     test_name, sw_result, hw_result);
            $fatal;
        end

        total_pass_count = total_pass_count + 1;
        $display("[PASS] %s: expected=%0d got=%0d latency=%0d cycles",
                 test_name, sw_result, hw_result, last_latency_cycles);
    endtask

    task automatic reset_tb();
        rst_n = 1'b0;
        wr_en = 1'b0;
        rd_en = 1'b0;
        addr  = 8'h00;
        wdata = 32'h0;
        last_start_cycle = 0;
        last_done_cycle = 0;
        last_latency_cycles = 0;
        total_pass_count = 0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
    endtask

    initial begin
        int i;
        int test_id;
        int deterministic_pass_count;
        int random_pass_count;
        string random_name;

        $display("");
        $display("=== MMIO Dot-Product Accelerator Regression ===");

        reset_tb();

        deterministic_pass_count = 0;
        random_pass_count = 0;

        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            tb_a[i] = 0;
            tb_b[i] = 0;
        end
        run_test("all_zeros");
        deterministic_pass_count = deterministic_pass_count + 1;

        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            tb_a[i] = 1;
            tb_b[i] = 1;
        end
        run_test("all_ones");
        deterministic_pass_count = deterministic_pass_count + 1;

        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            tb_a[i] = i;
            tb_b[i] = i;
        end
        run_test("increasing");
        deterministic_pass_count = deterministic_pass_count + 1;

        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            tb_a[i] = i - 8;
            tb_b[i] = 8 - i;
        end
        run_test("mixed_signs");
        deterministic_pass_count = deterministic_pass_count + 1;

        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            tb_a[i] = i;
            tb_b[i] = (i % 2 == 0) ? i : -i;
        end
        run_test("alternating_signs");
        deterministic_pass_count = deterministic_pass_count + 1;

        for (i = 0; i < NUM_ELEMS; i = i + 1) begin
            tb_a[i] = 1000000;
            tb_b[i] = 1000000;
        end
        run_test("overflow_64bit");
        deterministic_pass_count = deterministic_pass_count + 1;

        for (test_id = 0; test_id < NUM_RANDOM_TESTS; test_id = test_id + 1) begin
            for (i = 0; i < NUM_ELEMS; i = i + 1) begin
                tb_a[i] = rand_small();
                tb_b[i] = rand_small();
            end

            $sformat(random_name, "random_%03d", test_id);
            run_test(random_name);
            random_pass_count = random_pass_count + 1;
        end

        $display("");
        $display("Deterministic tests: %0d/6 PASS", deterministic_pass_count);
        $display("Random tests:        %0d/%0d PASS", random_pass_count, NUM_RANDOM_TESTS);
        $display("Total tests:         %0d/%0d PASS", total_pass_count,
                 6 + NUM_RANDOM_TESTS);
        $display("All tests passed.");
        $display("VCD saved to waves/dot_accel.vcd");
        $display("");

        $finish;
    end

endmodule