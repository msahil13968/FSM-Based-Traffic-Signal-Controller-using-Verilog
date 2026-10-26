//==============================================================================
// Module  : traffic_signal_controller
// Project : FSM-Based Traffic Signal Controller (4-way intersection)
// Author  : Muhammad Sahil
//
// Description
//   Moore FSM controlling a 4-way intersection. North/South share one phase,
//   East/West share the other. Each phase runs Green -> Yellow -> All-Red.
//
//   Light encoding (per direction): {RED, YELLOW, GREEN}, one-hot
//       3'b100 = RED   3'b010 = YELLOW   3'b001 = GREEN
//
//   States (6):
//       S_RED_TO_NS : all red, next -> NS green   (also the reset state)
//       S_NS_GREEN  : N/S green, E/W red
//       S_NS_YELLOW : N/S yellow, E/W red
//       S_RED_TO_EW : all red, next -> EW green
//       S_EW_GREEN  : E/W green, N/S red
//       S_EW_YELLOW : E/W yellow, N/S red
//
//   Priority logic (emergency / priority-vehicle inputs)
//       * emg_ns only : NS green is HELD while asserted; if EW is currently
//                       green, it is pre-empted after MIN_GREEN_TICKS.
//       * emg_ew only : same, mirrored for EW.
//       * both / none : normal timed operation (conflict -> no priority).
//     Pre-emption always goes through Yellow and All-Red, never straight to
//     green, so the intersection can never show conflicting greens.
//
//   Reset : synchronous, active-high. Forces the safe all-red state.
//
//   Timing : one "tick" = CLKS_PER_TICK clock cycles (e.g. set to the clock
//            frequency in Hz for a 1-second tick on hardware). For simulation
//            use CLKS_PER_TICK = 1.
//==============================================================================
`timescale 1ns / 1ps

module traffic_signal_controller #(
    parameter CLKS_PER_TICK   = 1,   // clock cycles per time tick
    parameter GREEN_TICKS     = 10,  // green duration
    parameter YELLOW_TICKS    = 3,   // yellow duration
    parameter ALL_RED_TICKS   = 1,   // all-red clearance duration
    parameter MIN_GREEN_TICKS = 4    // min green before an emergency pre-empt
)(
    input  wire       clk,
    input  wire       rst,        // synchronous, active-high
    input  wire       emg_ns,     // priority request, North/South
    input  wire       emg_ew,     // priority request, East/West
    output reg  [2:0] n_light,    // {R,Y,G}
    output reg  [2:0] s_light,
    output reg  [2:0] e_light,
    output reg  [2:0] w_light
);

    // ---------------- light encodings ----------------
    localparam [2:0] RED    = 3'b100;
    localparam [2:0] YELLOW = 3'b010;
    localparam [2:0] GREEN  = 3'b001;

    // ---------------- state encodings ----------------
    localparam [2:0] S_RED_TO_NS = 3'd0;
    localparam [2:0] S_NS_GREEN  = 3'd1;
    localparam [2:0] S_NS_YELLOW = 3'd2;
    localparam [2:0] S_RED_TO_EW = 3'd3;
    localparam [2:0] S_EW_GREEN  = 3'd4;
    localparam [2:0] S_EW_YELLOW = 3'd5;

    reg [2:0]  state, next_state;
    reg [7:0]  timer;                 // ticks spent in current state (saturates)
    reg [31:0] clk_cnt;               // clock cycles within current tick

    wire tick = (clk_cnt == CLKS_PER_TICK - 1);

    // ---------------- priority decode ----------------
    wire hold_ns = emg_ns & ~emg_ew;   // NS has exclusive priority
    wire hold_ew = emg_ew & ~emg_ns;   // EW has exclusive priority

    // ---------------- timing flags ----------------
    wire green_done   = tick && (timer >= GREEN_TICKS   - 1);
    wire yellow_done  = tick && (timer >= YELLOW_TICKS  - 1);
    wire red_done     = tick && (timer >= ALL_RED_TICKS - 1);
    wire min_green_ok = (timer >= MIN_GREEN_TICKS);

    // ---------------- next-state logic (combinational) ----------------
    always @(*) begin
        next_state = state;
        case (state)
            S_RED_TO_NS: if (red_done) next_state = S_NS_GREEN;

            S_NS_GREEN: begin
                // leave when time is up (unless NS holds priority),
                // or when EW pre-empts after the minimum green
                if ((green_done && !hold_ns) || (hold_ew && min_green_ok))
                    next_state = S_NS_YELLOW;
            end

            S_NS_YELLOW: if (yellow_done) next_state = S_RED_TO_EW;

            S_RED_TO_EW: if (red_done) next_state = S_EW_GREEN;

            S_EW_GREEN: begin
                if ((green_done && !hold_ew) || (hold_ns && min_green_ok))
                    next_state = S_EW_YELLOW;
            end

            S_EW_YELLOW: if (yellow_done) next_state = S_RED_TO_NS;

            default: next_state = S_RED_TO_NS;   // recover from illegal state
        endcase
    end

    // ---------------- state / counters (sequential) ----------------
    always @(posedge clk) begin
        if (rst) begin
            state   <= S_RED_TO_NS;      // safe state: all red
            timer   <= 8'd0;
            clk_cnt <= 32'd0;
        end else begin
            state <= next_state;
            if (next_state != state) begin
                timer   <= 8'd0;         // new state -> restart timing
                clk_cnt <= 32'd0;
            end else if (tick) begin
                clk_cnt <= 32'd0;
                if (timer != 8'hFF)      // saturate, never wrap
                    timer <= timer + 8'd1;
            end else begin
                clk_cnt <= clk_cnt + 32'd1;
            end
        end
    end

    // ---------------- output logic (Moore) ----------------
    always @(*) begin
        case (state)
            S_NS_GREEN : begin
                n_light = GREEN;  s_light = GREEN;
                e_light = RED;    w_light = RED;
            end
            S_NS_YELLOW: begin
                n_light = YELLOW; s_light = YELLOW;
                e_light = RED;    w_light = RED;
            end
            S_EW_GREEN : begin
                n_light = RED;    s_light = RED;
                e_light = GREEN;  w_light = GREEN;
            end
            S_EW_YELLOW: begin
                n_light = RED;    s_light = RED;
                e_light = YELLOW; w_light = YELLOW;
            end
            default    : begin    // S_RED_TO_NS, S_RED_TO_EW, illegal
                n_light = RED;    s_light = RED;
                e_light = RED;    w_light = RED;
            end
        endcase
    end

endmodule
