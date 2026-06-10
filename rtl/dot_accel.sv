// MMIO Dot-Product Accelerator
// Computes 16-element signed dot product via memory-mapped register interface

`timescale 1ns / 1ps

module dot_accel (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        wr_en,
    input  logic        rd_en,
    input  logic [7:0]  addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata
);

    // Register Address Constants
    localparam logic [7:0] CTRL_ADDR       = 8'h00;
    localparam logic [7:0] STATUS_ADDR     = 8'h04;
    localparam logic [7:0] RESULT_LO_ADDR  = 8'h08;
    localparam logic [7:0] RESULT_HI_ADDR  = 8'h0C;
    localparam logic [7:0] A_BASE_ADDR     = 8'h10;
    localparam logic [7:0] A_LAST_ADDR     = 8'h4C;
    localparam logic [7:0] B_BASE_ADDR     = 8'h50;
    localparam logic [7:0] B_LAST_ADDR     = 8'h8C;

    // State Machine Definition
    typedef enum logic [1:0] {
        IDLE = 2'b00,
        RUN  = 2'b01,
        DONE = 2'b10
    } state_t;

    // Internal Registers
    state_t state, next_state;

    // Input vectors: A[0..15] and B[0..15], signed 32-bit
    logic signed [31:0] a_regs [0:15];
    logic signed [31:0] b_regs [0:15];

    // Result: signed 64-bit, split into LO (31:0) and HI (63:32)
    logic signed [63:0] result, next_result;

    // Loop counter (for 16 elements)
    logic [4:0] idx, next_idx;

    // Accumulator
    logic signed [63:0] acc, next_acc;

    // Decoded control/status and datapath helpers
    logic busy, done, start_cmd;
    logic a_addr_hit, b_addr_hit;
    logic [3:0] a_index, b_index;
    logic signed [63:0] product;
    logic [31:0] result_lo, result_hi;

    assign busy       = (state == RUN);
    assign done       = (state == DONE);
    assign start_cmd  = wr_en && (addr == CTRL_ADDR) && ((wdata & 32'h0000_0001) != 32'h0);
    assign a_addr_hit = (addr >= A_BASE_ADDR) && (addr <= A_LAST_ADDR);
    assign b_addr_hit = (addr >= B_BASE_ADDR) && (addr <= B_LAST_ADDR);
    assign a_index    = addr[5:2] - A_BASE_ADDR[5:2];
    assign b_index    = addr[5:2] - B_BASE_ADDR[5:2];
    assign product    = $signed(a_regs[idx[3:0]]) * $signed(b_regs[idx[3:0]]);
    assign result_lo  = result[31:0];
    assign result_hi  = result[63:32];

    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            state  <= IDLE;
            result <= 64'h0;
            idx    <= 5'h0;
            acc    <= 64'h0;
        end else begin
            state  <= next_state;
            result <= next_result;
            idx    <= next_idx;
            acc    <= next_acc;
        end
    end

    always_comb begin
        // Default: hold state
        next_state  = state;
        next_result = result;
        next_idx    = idx;
        next_acc    = acc;

        case (state)
            IDLE: begin
                if (start_cmd) begin
                    next_acc    = 64'h0;
                    next_result = 64'h0;
                    next_idx    = 5'h0;
                    next_state  = RUN;
                end
            end

            RUN: begin
                next_acc = acc + product;
                
                if (idx == 5'd15) begin
                    next_result = acc + product;
                    next_state  = DONE;
                end else begin
                    next_idx = idx + 5'h1;
                end
            end

            DONE: begin
                next_result = result;
                if (start_cmd) begin
                    next_acc    = 64'h0;
                    next_result = 64'h0;
                    next_idx    = 5'h0;
                    next_state  = RUN;
                end
            end

            default: begin
                next_state = IDLE;
            end
        endcase
    end

    // MMIO Write Handler
    always_ff @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            for (int i = 0; i < 16; i = i + 1) begin
                a_regs[i] <= 32'sh0;
                b_regs[i] <= 32'sh0;
            end
        end else if (wr_en && (state != RUN)) begin
            // Input vector writes are ignored while BUSY/RUN is active.
            if (a_addr_hit) begin
                a_regs[a_index] <= $signed(wdata);
            end else if (b_addr_hit) begin
                b_regs[b_index] <= $signed(wdata);
            end
        end
    end

    // MMIO Read Handler (Combinational)
    always_comb begin
        rdata = 32'h0;

        if (rd_en) begin
            case (addr)
                CTRL_ADDR: begin
                    rdata = 32'h0;  // CTRL is write-only
                end

                STATUS_ADDR: begin
                    rdata = {30'h0, busy, done};  // bit 1 = BUSY, bit 0 = DONE
                end

                RESULT_LO_ADDR: rdata = result_lo;
                RESULT_HI_ADDR: rdata = result_hi;

                default: begin
                    if (a_addr_hit) begin
                        rdata = a_regs[a_index];
                    end else if (b_addr_hit) begin
                        rdata = b_regs[b_index];
                    end else begin
                        rdata = 32'h0;
                    end
                end
            endcase
        end
    end

endmodule
