// SDRAM stress test for the C406 board, driven over JTAG by stress.tcl.
//
// A PLL makes the system clock (c0) and the SDRAM clock (c1) at the same frequency;
// the phase of c1 can be stepped at run time so the host can map the timing window.
// The host starts fill/check operations over a region with one of several data
// patterns; 8-word bursts run back to back at full clock rate.
//
// JTAG (ISSP instance "SDS"):
//   source {seed[7:0], len[1:0], cap[1:0], inv, mode[2:0], step, check, fill}
//     fill/check/step: toggle to request; len: 64K/1M/4M/16M words;
//     cap: extra read-capture delay in cycles; mode: see rpat/hpat
//   probe  {locked, step_ack[7:0], done_seq[7:0], busy, err_cnt[31:0],
//           err_bits[15:0], err_addr[23:0], err_exp[15:0], err_got[15:0]}
module sdram_stress #(
    parameter PLL_MUL = 10,     // clock = 50 MHz * PLL_MUL / PLL_DIV
    parameter PLL_DIV = 3,
    parameter CLK_PS  = 6000    // that clock's period, for the SDRAM timing below
) (
    input  wire        clk_50m,
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
    // W9825G6KH-6: tRCD = tRP = 18 ns, tRC = 60 ns, tWR = 2 tCK, 8192 refreshes / 64 ms.
    localparam CL       = 3;
    localparam T_RCD    = (18000 + CLK_PS - 1) / CLK_PS;
    localparam T_RP     = (18000 + CLK_PS - 1) / CLK_PS;
    localparam T_RFC    = (60000 + CLK_PS - 1) / CLK_PS + 1;
    localparam T_WR     = 2;
    localparam REF_INT  = 7000000 / CLK_PS;          // 7.0 us
    localparam INIT_CYC = 200000000 / CLK_PS + 100;  // 200 us

    localparam CMD_NOP = 4'b0111, CMD_ACT = 4'b0011, CMD_READ = 4'b0101, CMD_WRITE = 4'b0100,
               CMD_PRE = 4'b0010, CMD_REF = 4'b0001, CMD_MRS = 4'b0000;
    localparam S_INIT = 4'd0, S_PRE = 4'd1, S_IREF = 4'd2, S_MRS = 4'd3, S_IDLE = 4'd4,
               S_WR = 4'd5, S_RD = 4'd6, S_WAIT = 4'd7, S_NEXT = 4'd8;

    // ---- clocks ----------------------------------------------------------------
    wire [4:0] pll_clk;
    wire       pll_locked;
    wire       phasedone;
    reg        phasestep = 1'b0;

    altpll #(
        .intended_device_family("Cyclone IV E"),
        .lpm_type("altpll"),
        .operation_mode("NORMAL"),
        .pll_type("AUTO"),
        .compensate_clock("CLK0"),
        .inclk0_input_frequency(20000),
        .clk0_multiply_by(PLL_MUL), .clk0_divide_by(PLL_DIV), .clk0_duty_cycle(50), .clk0_phase_shift("0"),
        .clk1_multiply_by(PLL_MUL), .clk1_divide_by(PLL_DIV), .clk1_duty_cycle(50), .clk1_phase_shift("0"),
        .width_clock(5),
        .width_phasecounterselect(3),
        .port_clk0("PORT_USED"),
        .port_clk1("PORT_USED"),
        .port_phasecounterselect("PORT_USED"),
        .port_phasedone("PORT_USED"),
        .port_phasestep("PORT_USED"),
        .port_phaseupdown("PORT_USED"),
        .port_scanclk("PORT_USED")
    ) pll (
        .inclk({1'b0, clk_50m}),
        .clk(pll_clk),
        .locked(pll_locked),
        .scanclk(clk_50m),
        .phasecounterselect(3'b011),    // C1 = SDRAM clock
        .phaseupdown(1'b1),
        .phasestep(phasestep),
        .phasedone(phasedone)
    );

    wire clk = pll_clk[0];

    // Forward c1 to the SDRAM pin through a DDIO register.
    altddio_out #(.width(1), .intended_device_family("Cyclone IV E")) clk_out (
        .datain_h(1'b1), .datain_l(1'b0), .outclock(pll_clk[1]), .dataout(sdr_clk),
        .aclr(1'b0), .aset(1'b0), .sclr(1'b0), .sset(1'b0), .oe(1'b1), .outclocken(1'b1), .oe_out()
    );

    // ---- host interface ----------------------------------------------------------
    wire [18:0] src;
    wire        src_fill  = src[0];
    wire        src_check = src[1];
    wire        src_step  = src[2];

    // Phase stepping runs on the PLL scan clock (50 MHz).
    reg  [2:0] step_sync = 3'b000;
    reg        step_seen = 1'b0;
    reg  [7:0] step_ack = 8'd0;
    reg  [1:0] st = 2'd0;
    reg  [4:0] st_cnt;
    always @(posedge clk_50m) begin
        step_sync <= {step_sync[1:0], src_step};
        case (st)
            2'd0: if (step_sync[2] != step_seen) begin
                      step_seen <= step_sync[2];
                      phasestep <= 1'b1;
                      st_cnt    <= 0;
                      st        <= 2'd1;
                  end
            2'd1: begin                          // hold PHASESTEP for 4 scan clocks
                      st_cnt <= st_cnt + 1'b1;
                      if (st_cnt == 3) begin phasestep <= 1'b0; st_cnt <= 0; st <= 2'd2; end
                  end
            2'd2: begin                          // wait for PHASEDONE low (or give up)
                      st_cnt <= st_cnt + 1'b1;
                      if (!phasedone || st_cnt == 31) st <= 2'd3;
                  end
            2'd3: if (phasedone) begin step_ack <= step_ack + 1'b1; st <= 2'd0; end
        endcase
    end

    // ---- data patterns -------------------------------------------------------------
    // word(addr) = hpat(addr without low 4 bits) ^ rpat(addr[3:0]) ^ {16{inv}}
    function [15:0] rpat(input [2:0] m, input [3:0] i);
        case (m)
            3'd0: rpat = {13'd0, i[2:0]};                 // address (with hpat)
            3'd1: rpat = 16'd1 << i;                       // walking ones
            3'd2: rpat = i[0] ? 16'hAAAA : 16'h5555;       // checkerboard, all bits toggle
            3'd3: case (i)                                 // random (with hpat)
                      4'd0: rpat = 16'h3A7C;  4'd1: rpat = 16'hC5E1;  4'd2: rpat = 16'h9B02;  4'd3: rpat = 16'h64DF;
                      4'd4: rpat = 16'hE8A5;  4'd5: rpat = 16'h1F36;  4'd6: rpat = 16'h7D49;  4'd7: rpat = 16'hA2B8;
                      4'd8: rpat = 16'h5C13;  4'd9: rpat = 16'hB0EE;  4'd10: rpat = 16'h4F67; 4'd11: rpat = 16'hD38A;
                      4'd12: rpat = 16'h06F9; 4'd13: rpat = 16'h8D24; 4'd14: rpat = 16'hF15B; 4'd15: rpat = 16'h29C0;
                  endcase
            default: rpat = 16'h0000;                      // solid
        endcase
    endfunction

    function [15:0] hpat(input [2:0] m, input [23:0] b, input [7:0] s);
        reg [28:0] x;
        begin
            x = {s, b[23:3]};
            case (m)
                3'd0: hpat = {b[15:3], 3'b000} ^ {b[23:16], b[23:16]};
                3'd3: hpat = x[15:0] ^ {x[28:16], x[15:13]} ^ {x[6:0], x[28:20]} ^ {x[20:13], x[12:5]};
                default: hpat = 16'h0000;
            endcase
        end
    endfunction

    // ---- SDRAM controller and checker -----------------------------------------------
    reg  [3:0]  cmd = CMD_NOP;
    assign {sdr_cs_n, sdr_ras_n, sdr_cas_n, sdr_we_n} = cmd;
    assign sdr_cke = 1'b1;
    assign sdr_dqm = 2'b00;

    reg  [15:0] dq_out;
    reg         dq_oe = 1'b0;
    reg  [15:0] dq_in;
    assign sdr_dq = dq_oe ? dq_out : 16'bz;

    reg  [1:0]  lock_sync = 2'b00;
    reg  [3:0]  state = S_INIT, ret;
    reg  [15:0] cnt = INIT_CYC;
    reg  [3:0]  irefs;
    reg  [15:0] ref_cnt;
    reg         ref_due = 1'b0;          // ref_cnt reached 0 (one cycle late, harmless)
    reg  [2:0]  fill_sync = 3'b000, check_sync = 3'b000;
    reg         fill_seen = 1'b0, check_seen = 1'b0;
    reg         op_on = 1'b0, op_check = 1'b0, busy = 1'b0;
    reg  [7:0]  done_seq = 8'd0;
    reg  [2:0]  mode = 3'd0;
    reg         inv = 1'b0;
    reg  [1:0]  cap = 2'd0;
    reg  [7:0]  seed = 8'd0;
    reg  [24:0] len = 25'd0;
    reg  [23:0] base = 24'd0;            // first word of the current burst
    reg         last = 1'b0;             // current burst is the last of the region
    reg  [15:0] hb;
    reg  [15:0] pat [0:7];               // the 8 words of the current burst
    reg  [15:0] wsh [0:6];
    reg  [2:0]  wcnt = 3'd0;
    reg  [15:0] rd_mark = 16'd0;         // bit n: a READ went out n+1 edges ago
    reg         cap_on = 1'b0;
    reg  [2:0]  cap_k;
    reg  [15:0] c_word, c_exp;
    reg  [2:0]  c_k;
    reg         c_v = 1'b0, d_v = 1'b0;
    reg  [15:0] diff, d_exp, d_got;
    reg  [23:0] d_addr;
    reg  [31:0] err_cnt = 0;
    reg  [15:0] err_bits = 0, err_exp = 0, err_got = 0;
    reg  [23:0] err_addr = 0;
    reg  [25:0] blink = 0;
    integer k;

    always @(posedge clk) begin
        lock_sync  <= {lock_sync[0], pll_locked};
        fill_sync  <= {fill_sync[1:0], src_fill};
        check_sync <= {check_sync[1:0], src_check};
        blink      <= blink + 1'b1;
        led        <= blink[25];

        cmd     <= CMD_NOP;
        dq_oe   <= 1'b0;
        dq_in   <= sdr_dq;
        rd_mark <= {rd_mark[14:0], 1'b0};
        if (ref_cnt != 0) ref_cnt <= ref_cnt - 1'b1;
        ref_due <= ref_cnt == 0;

        // base only changes in S_NEXT, many cycles before this is used again.
        last <= {1'b0, base} + 25'd8 == len;

        // Burst words, two pipeline stages behind base/mode.
        hb <= hpat(mode, base, seed);
        for (k = 0; k < 8; k = k + 1)
            pat[k] <= hb ^ rpat(mode, {base[3], k[2:0]}) ^ {16{inv}};

        // Write burst words 1..7 follow word 0 on consecutive cycles.
        if (wcnt != 0) begin
            dq_oe  <= 1'b1;
            dq_out <= wsh[0];
            for (k = 0; k < 6; k = k + 1) wsh[k] <= wsh[k + 1];
            wcnt <= wcnt - 1'b1;
        end

        // Read capture: when rd_mark[CL + cap] is set, dq_in holds word 0.
        if (rd_mark[CL + cap]) begin
            c_word <= dq_in; c_exp <= pat[0]; c_k <= 3'd0; c_v <= 1'b1;
            cap_k  <= 3'd1;  cap_on <= 1'b1;
        end else if (cap_on) begin
            c_word <= dq_in; c_exp <= pat[cap_k]; c_k <= cap_k; c_v <= 1'b1;
            cap_k  <= cap_k + 1'b1;
            if (cap_k == 3'd7) cap_on <= 1'b0;
        end else begin
            c_v <= 1'b0;
        end
        d_v    <= c_v;
        diff   <= c_word ^ c_exp;
        d_exp  <= c_exp;
        d_got  <= c_word;
        d_addr <= {base[23:3], c_k};
        if (d_v && diff != 16'd0) begin
            if (err_cnt == 0) begin
                err_addr <= d_addr;
                err_exp  <= d_exp;
                err_got  <= d_got;
            end
            if (err_cnt != 32'hFFFFFFFF) err_cnt <= err_cnt + 1'b1;
            err_bits <= err_bits | diff;
        end

        if (!lock_sync[1]) begin
            state <= S_INIT;
            cnt   <= INIT_CYC;
            op_on <= 1'b0;
            busy  <= 1'b0;
        end else case (state)
            S_INIT:
                if (cnt == 0) state <= S_PRE; else cnt <= cnt - 1'b1;
            S_PRE: begin
                cmd       <= CMD_PRE;
                sdr_a[10] <= 1'b1;               // all banks
                irefs     <= 4'd8;
                cnt       <= T_RP;
                ret       <= S_IREF;
                state     <= S_WAIT;
            end
            S_IREF:
                if (irefs == 0) begin
                    state <= S_MRS;
                end else begin
                    cmd   <= CMD_REF;
                    irefs <= irefs - 1'b1;
                    cnt   <= T_RFC;
                    ret   <= S_IREF;
                    state <= S_WAIT;
                end
            S_MRS: begin
                cmd     <= CMD_MRS;
                sdr_ba  <= 2'b00;
                sdr_a   <= 13'b000_0_00_011_0_011;   // burst length 8, sequential, CAS latency 3
                ref_cnt <= REF_INT;
                cnt     <= 3;
                ret     <= S_IDLE;
                state   <= S_WAIT;
            end
            S_IDLE:
                if (ref_due) begin
                    cmd     <= CMD_REF;
                    ref_cnt <= REF_INT;
                    cnt     <= T_RFC;
                    ret     <= S_IDLE;
                    state   <= S_WAIT;
                end else if (op_on) begin
                    cmd    <= CMD_ACT;
                    sdr_ba <= base[23:22];
                    sdr_a  <= base[21:9];
                    cnt    <= (T_RCD > 2) ? T_RCD - 2 : 0;
                    ret    <= op_check ? S_RD : S_WR;
                    state  <= S_WAIT;
                end else if (fill_sync[2] != fill_seen || check_sync[2] != check_seen) begin
                    op_check <= check_sync[2] != check_seen;
                    if (check_sync[2] != check_seen) begin
                        err_cnt  <= 0;
                        err_bits <= 0;
                        err_addr <= 0;
                        err_exp  <= 0;
                        err_got  <= 0;
                    end
                    fill_seen  <= fill_sync[2];
                    check_seen <= check_sync[2];
                    mode  <= src[5:3];
                    inv   <= src[6];
                    cap   <= src[8:7];
                    len   <= 25'd1 << (src[10:9] == 2'd0 ? 16 : src[10:9] == 2'd1 ? 20 :
                                       src[10:9] == 2'd2 ? 22 : 24);
                    seed  <= src[18:11];
                    base  <= 24'd0;
                    op_on <= 1'b1;
                    busy  <= 1'b1;
                    // Re-initialise at the current SDRAM clock phase: the power-up
                    // mode-register write may have happened at a phase that fails.
                    state <= S_PRE;
                end
            S_WR: begin
                cmd    <= CMD_WRITE;
                sdr_a  <= {2'b00, 1'b1, 1'b0, base[8:0]};   // A10 = auto precharge
                dq_oe  <= 1'b1;
                dq_out <= pat[0];
                for (k = 0; k < 7; k = k + 1) wsh[k] <= pat[k + 1];
                wcnt   <= 3'd7;
                cnt    <= 7 + T_WR + T_RP;
                ret    <= S_NEXT;
                state  <= S_WAIT;
            end
            S_RD: begin
                cmd     <= CMD_READ;
                sdr_a   <= {2'b00, 1'b1, 1'b0, base[8:0]};
                rd_mark <= {rd_mark[14:0], 1'b1};
                cnt     <= CL + 3 + 8 + 4 + T_RP;           // capture and compare drain
                ret     <= S_NEXT;
                state   <= S_WAIT;
            end
            S_NEXT: begin
                if (last) begin
                    op_on    <= 1'b0;
                    busy     <= 1'b0;
                    done_seq <= done_seq + 1'b1;
                end else begin
                    base <= base + 24'd8;
                end
                state <= S_IDLE;
            end
            S_WAIT:
                if (cnt == 0) state <= ret; else cnt <= cnt - 1'b1;
            default:
                state <= S_INIT;
        endcase
    end

    altsource_probe #(
        .sld_auto_instance_index("YES"),
        .sld_instance_index(0),
        .instance_id("SDS"),
        .probe_width(122),
        .source_width(19),
        .source_initial_value("0"),
        .enable_metastability("NO")
    ) host (
        .probe({pll_locked, step_ack, done_seq, busy, err_cnt, err_bits, err_addr, err_exp, err_got}),
        .source(src)
    );
endmodule
