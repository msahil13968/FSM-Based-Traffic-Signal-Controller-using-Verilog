//==============================================================================
// Self-checking testbench for traffic_signal_controller
//   T1 : reset state + full normal cycle, phase durations measured
//   T2 : emergency pre-emption (EW request while NS green)
//   T3 : priority HOLD (EW green extended while emg_ew held)
//   T4 : both emergencies asserted -> normal timing (conflict = no priority)
//   T5 : mid-operation reset returns to all-red, then restarts
//   Plus a continuous safety monitor: N/S and E/W may never both be
//   non-red at the same time.
//==============================================================================
`timescale 1ns / 1ps

module tb_traffic_signal_controller;

    // small values so the simulation is short (1 tick = 1 clock)
    localparam GREEN_T = 6, YELLOW_T = 2, RED_T = 1, MIN_G = 2;

    localparam [2:0] R = 3'b100, Y = 3'b010, G = 3'b001;

    reg clk = 0, rst = 1, emg_ns = 0, emg_ew = 0;
    wire [2:0] n_light, s_light, e_light, w_light;

    integer errors = 0;
    integer cnt;

    traffic_signal_controller #(
        .CLKS_PER_TICK(1),
        .GREEN_TICKS(GREEN_T),
        .YELLOW_TICKS(YELLOW_T),
        .ALL_RED_TICKS(RED_T),
        .MIN_GREEN_TICKS(MIN_G)
    ) dut (
        .clk(clk), .rst(rst), .emg_ns(emg_ns), .emg_ew(emg_ew),
        .n_light(n_light), .s_light(s_light),
        .e_light(e_light), .w_light(w_light)
    );

    always #5 clk = ~clk;   // 100 MHz

    // ---------- helpers (all sampling/driving on negedge) ----------
    task expect_lights(input [2:0] ns, input [2:0] ew, input [255:0] msg);
        begin
            if (n_light !== ns || s_light !== ns ||
                e_light !== ew || w_light !== ew) begin
                errors = errors + 1;
                $display("[FAIL] %0s @%0t : got N=%b S=%b E=%b W=%b, expected NS=%b EW=%b",
                         msg, $time, n_light, s_light, e_light, w_light, ns, ew);
            end else
                $display("[ OK ] %0s @%0t", msg, $time);
        end
    endtask

    task wait_for(input [2:0] ns, input [2:0] ew);
        begin
            while (!(n_light === ns && e_light === ew)) @(negedge clk);
        end
    endtask

    task count_while(input [2:0] ns, input [2:0] ew, output integer c);
        begin
            c = 0;
            while (n_light === ns && e_light === ew) begin
                c = c + 1;
                @(negedge clk);
            end
        end
    endtask

    task check_duration(input integer got, input integer exp, input [255:0] msg);
        begin
            if (got !== exp) begin
                errors = errors + 1;
                $display("[FAIL] %0s : duration %0d, expected %0d", msg, got, exp);
            end else
                $display("[ OK ] %0s : duration %0d", msg, got);
        end
    endtask

    // ---------- continuous safety monitor ----------
    wire ns_active = (n_light != R) || (s_light != R);
    wire ew_active = (e_light != R) || (w_light != R);
    always @(negedge clk)
        if (!rst && ns_active && ew_active) begin
            errors = errors + 1;
            $display("[FAIL] SAFETY: conflicting lights @%0t", $time);
        end

    // ---------- watchdog ----------
    initial begin
        #200000;
        $display("[FAIL] TIMEOUT");
        $finish;
    end

    // ---------- stimulus ----------
    initial begin
        $dumpfile("sim/traffic.vcd");
        $dumpvars(0, tb_traffic_signal_controller);

        // ---- T1: reset + normal cycle ----
        $display("--- T1: reset and normal cycle ---");
        repeat (3) @(negedge clk);
        expect_lights(R, R, "reset -> all red");
        rst = 0;

        wait_for(G, R);
        count_while(G, R, cnt); check_duration(cnt, GREEN_T,  "NS green");
        count_while(Y, R, cnt); check_duration(cnt, YELLOW_T, "NS yellow");
        count_while(R, R, cnt); check_duration(cnt, RED_T,    "all red (NS->EW)");
        count_while(R, G, cnt); check_duration(cnt, GREEN_T,  "EW green");
        count_while(R, Y, cnt); check_duration(cnt, YELLOW_T, "EW yellow");
        count_while(R, R, cnt); check_duration(cnt, RED_T,    "all red (EW->NS)");
        expect_lights(G, R, "cycle repeats: NS green");

        // ---- T2: emergency pre-emption ----
        $display("--- T2: EW emergency pre-empts NS green ---");
        wait_for(R, R);  wait_for(G, R);        // wait for a fresh NS green
        repeat (MIN_G + 1) @(negedge clk);      // satisfy minimum green
        emg_ew = 1;
        @(negedge clk);
        expect_lights(Y, R, "pre-empt -> NS yellow");
        wait_for(R, G);
        expect_lights(R, G, "EW green granted");

        // ---- T3: priority hold ----
        $display("--- T3: priority hold ---");
        repeat (GREEN_T * 2) @(negedge clk);    // well past normal green time
        expect_lights(R, G, "EW green held while emg_ew=1");
        emg_ew = 0;
        @(negedge clk);
        expect_lights(R, Y, "emg released -> EW yellow");

        // ---- T4: both emergencies -> normal timing ----
        $display("--- T4: both emergencies = no priority ---");
        wait_for(G, R);
        emg_ns = 1; emg_ew = 1;
        count_while(G, R, cnt); check_duration(cnt, GREEN_T, "NS green (conflict, normal timing)");
        emg_ns = 0; emg_ew = 0;

        // ---- T5: reset in the middle of operation ----
        $display("--- T5: mid-operation reset ---");
        wait_for(R, G);
        repeat (2) @(negedge clk);
        rst = 1;
        @(negedge clk);
        expect_lights(R, R, "reset during EW green -> all red");
        @(negedge clk);
        rst = 0;
        wait_for(G, R);
        expect_lights(G, R, "restart -> NS green");

        // ---- summary ----
        $display("-----------------------------------------");
        if (errors == 0) $display("RESULT: ALL TESTS PASSED");
        else             $display("RESULT: %0d ERROR(S)", errors);
        $finish;
    end

endmodule
