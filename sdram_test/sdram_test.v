// SDRAM self-test for the C406 board. Fills all 32 MB of the W9825G6KH with an
// address-derived pattern, reads it back, then repeats with the pattern inverted.
//
// LED: toggles after every passed fill+check round (about 6 s); blinks fast after any error.
// KEY: restarts the test.
// Status is also readable over JTAG (ISSP instance "SDT", see status.tcl); its source
// sets the read capture delay, so the timing can be tuned without recompiling.
module sdram_test (
    input  wire        clk_50m,
    input  wire        key_n,
    output reg         led,
    output wire        sdr_clk,
    output wire        sdr_cke,
    output wire        sdr_cs_n,
    output wire        sdr_ras_n,
    output wire        sdr_cas_n,
    output wire        sdr_we_n,
    output reg  [1:0]  sdr_ba,
    output reg  [12:0] sdr_a,
    output wire [1:0]  sdr_dqm,
    inout  wire [15:0] sdr_dq
);
    localparam CMD_NOP = 4'b0111, CMD_ACT = 4'b0011, CMD_READ = 4'b0101, CMD_WRITE = 4'b0100,
               CMD_PRE = 4'b0010, CMD_REF = 4'b0001, CMD_MRS = 4'b0000;

    // 50 MHz = 20 ns per cycle; every wait is above the -6 speed grade minimums.
    localparam INIT_CYCLES  = 15'd12000;  // > 200 us power-up wait
    localparam REF_INTERVAL = 9'd360;     // 7.2 us, below the 7.8 us refresh period

    localparam S_INIT = 4'd0, S_PRECHARGE = 4'd1, S_INIT_REF = 4'd2, S_MODE = 4'd3,
               S_IDLE = 4'd4, S_ACCESS = 4'd5, S_CAPTURE = 4'd6, S_NEXT = 4'd7, S_WAIT = 4'd8;

    // The SDRAM clock is the inverted system clock: commands launched on our rising
    // edge are sampled by the SDRAM half a cycle later.
    altddio_out #(.width(1), .intended_device_family("Cyclone IV E")) clk_out (
        .datain_h(1'b0), .datain_l(1'b1), .outclock(clk_50m), .dataout(sdr_clk),
        .aclr(1'b0), .aset(1'b0), .sclr(1'b0), .sset(1'b0), .oe(1'b1), .outclocken(1'b1), .oe_out()
    );

    reg  [3:0]  cmd = CMD_NOP;
    assign {sdr_cs_n, sdr_ras_n, sdr_cas_n, sdr_we_n} = cmd;
    assign sdr_cke = 1'b1;
    assign sdr_dqm = 2'b00;

    reg  [15:0] dq_out;
    reg         dq_oe = 1'b0;
    reg  [15:0] dq_in;
    assign sdr_dq = dq_oe ? dq_out : 16'bz;

    reg  [2:0]  key_sync = 3'b111;
    reg  [3:0]  state = S_INIT, next_state;
    reg  [14:0] wait_cnt = INIT_CYCLES;
    reg  [3:0]  init_refs;
    reg  [8:0]  ref_cnt;
    reg  [23:0] addr;                    // {bank[1:0], row[12:0], column[8:0]}
    reg         reading;                 // 0 = fill, 1 = check
    reg  [15:0] pass_cnt = 0, err_cnt = 0;
    reg  [23:0] err_addr = 0;
    reg  [15:0] err_exp = 0, err_got = 0;
    reg  [22:0] blink;
    // Read capture: the SDRAM drives data from ~36 to ~52 ns after we issue READ (CL=2,
    // inverted clock). Default 1 samples at 40 ns; 2 and 3 only pass because the
    // undriven bus keeps its level for a while, and 0 is too early.
    wire [1:0]  cap_wait;                // from JTAG, default 1

    wire [15:0] pattern = addr[15:0] ^ {addr[23:16], addr[23:16]} ^ {16{pass_cnt[0]}};

    always @(posedge clk_50m) begin
        key_sync <= {key_sync[1:0], key_n};
        blink    <= blink + 1'b1;
        led      <= (err_cnt != 0) ? blink[22] : pass_cnt[0];

        cmd   <= CMD_NOP;
        dq_oe <= 1'b0;
        dq_in <= sdr_dq;
        if (ref_cnt != 0) ref_cnt <= ref_cnt - 1'b1;

        if (!key_sync[2]) begin
            state    <= S_INIT;
            wait_cnt <= INIT_CYCLES;
            pass_cnt <= 0;
            err_cnt  <= 0;
            err_addr <= 0;
            err_exp  <= 0;
            err_got  <= 0;
        end else case (state)
            S_INIT:
                if (wait_cnt == 0) state <= S_PRECHARGE; else wait_cnt <= wait_cnt - 1'b1;
            S_PRECHARGE: begin
                cmd        <= CMD_PRE;
                sdr_a[10]  <= 1'b1;            // all banks
                init_refs  <= 4'd8;
                wait_cnt   <= 3;
                next_state <= S_INIT_REF;
                state      <= S_WAIT;
            end
            S_INIT_REF:
                if (init_refs == 0) begin
                    state <= S_MODE;
                end else begin
                    cmd        <= CMD_REF;
                    init_refs  <= init_refs - 1'b1;
                    wait_cnt   <= 4;
                    next_state <= S_INIT_REF;
                    state      <= S_WAIT;
                end
            S_MODE: begin
                cmd        <= CMD_MRS;
                sdr_ba     <= 2'b00;
                sdr_a      <= 13'b000_0_00_010_0_000;   // burst length 1, sequential, CAS latency 2
                addr       <= 0;
                reading    <= 1'b0;
                ref_cnt    <= REF_INTERVAL;
                wait_cnt   <= 3;
                next_state <= S_IDLE;
                state      <= S_WAIT;
            end
            S_IDLE:
                if (ref_cnt == 0) begin
                    cmd        <= CMD_REF;
                    ref_cnt    <= REF_INTERVAL;
                    wait_cnt   <= 4;
                    next_state <= S_IDLE;
                    state      <= S_WAIT;
                end else begin
                    cmd        <= CMD_ACT;
                    sdr_ba     <= addr[23:22];
                    sdr_a      <= addr[21:9];
                    wait_cnt   <= 0;              // one NOP: tRCD
                    next_state <= S_ACCESS;
                    state      <= S_WAIT;
                end
            S_ACCESS: begin
                sdr_a <= {2'b00, 1'b1, 1'b0, addr[8:0]};   // A10 = auto precharge
                if (reading) begin
                    cmd        <= CMD_READ;
                    wait_cnt   <= cap_wait;
                    next_state <= S_CAPTURE;
                end else begin
                    cmd        <= CMD_WRITE;
                    dq_oe      <= 1'b1;
                    dq_out     <= pattern;
                    wait_cnt   <= 4;              // tWR + tRP
                    next_state <= S_NEXT;
                end
                state <= S_WAIT;
            end
            S_CAPTURE: begin
                if (dq_in != pattern) begin
                    if (err_cnt == 0) begin
                        err_addr <= addr;
                        err_exp  <= pattern;
                        err_got  <= dq_in;
                    end
                    if (err_cnt != 16'hFFFF) err_cnt <= err_cnt + 1'b1;
                end
                wait_cnt   <= 1;
                next_state <= S_NEXT;
                state      <= S_WAIT;
            end
            S_NEXT: begin
                addr <= addr + 1'b1;
                if (&addr) begin
                    if (reading) pass_cnt <= pass_cnt + 1'b1;
                    reading <= ~reading;
                end
                state <= S_IDLE;
            end
            S_WAIT:
                if (wait_cnt == 0) state <= next_state; else wait_cnt <= wait_cnt - 1'b1;
            default:
                state <= S_INIT;
        endcase
    end

    altsource_probe #(
        .sld_auto_instance_index("YES"),
        .sld_instance_index(0),
        .instance_id("SDT"),
        .probe_width(93),
        .source_width(2),
        .source_initial_value("1"),
        .enable_metastability("NO")
    ) status (
        .probe({state, reading, pass_cnt, err_cnt, err_addr, err_exp, err_got}),
        .source(cap_wait)
    );
endmodule
