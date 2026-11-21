
module fp_addsub (
  input  logic        clk,
  input  logic        reset,       // active high, synchronous
  input  logic        in_valid,
  input  logic        sub,         // 0: a + b, 1: a - b
  input  logic [31:0] a,
  input  logic [31:0] b,
  output logic        out_valid,
  output logic [31:0] result
);

  localparam logic [31:0] QNAN = 32'h7FC0_0000;
  logic        sa, sb;
  logic [7:0]  ea, eb;
  logic [22:0] fa, fb;
  assign sa = a[31];
  assign sb = b[31] ^ sub;          // a - b == a + (-b), also for 0 / inf / NaN
  assign ea = a[30:23];
  assign eb = b[30:23];
  assign fa = a[22:0];
  assign fb = b[22:0];

  logic a_nan, b_nan, a_inf, b_inf;
  assign a_nan = (ea == 8'hFF) && (fa != 23'd0);
  assign b_nan = (eb == 8'hFF) && (fb != 23'd0);
  assign a_inf = (ea == 8'hFF) && (fa == 23'd0);
  assign b_inf = (eb == 8'hFF) && (fb == 23'd0);

  logic a_ge_b;
  assign a_ge_b = ({ea, fa} >= {eb, fb});

  logic        sl, ss;              // sign of larger / smaller magnitude
  logic [7:0]  el, es;
  logic [22:0] fl, fs;

  always_comb begin
    if (a_ge_b) begin
      sl = sa; el = ea; fl = fa;
      ss = sb; es = eb; fs = fb;
    end else begin
      sl = sb; el = eb; fl = fb;
      ss = sa; es = ea; fs = fa;
    end
  end

  // effective exponents (subnormals use exponent 1) and 24-bit significands
  logic [8:0]  el_eff, es_eff;
  logic [23:0] ml, ms;
  assign el_eff = (el == 8'd0) ? 9'd1 : {1'b0, el};
  assign es_eff = (es == 8'd0) ? 9'd1 : {1'b0, es};
  assign ml     = {(el != 8'd0), fl};
  assign ms     = {(es != 8'd0), fs};

  // --------------------------------------------------- align smaller operand
  // 27 bits: {24-bit significand, guard, round, sticky}
  logic [8:0]  diff;
  logic [26:0] ext_l, ext_s, mask, aligned;
  logic        eff_sub;

  assign diff    = el_eff - es_eff;
  assign ext_l   = {ml, 3'b000};
  assign ext_s   = {ms, 3'b000};
  assign mask    = (27'd1 << diff) - 27'd1;               // all ones if diff>=27
  assign aligned = (ext_s >> diff) | {26'd0, |(ext_s & mask)};
  assign eff_sub = sl ^ ss;

  // ------------------------------------------------------------- add / sub
  logic [27:0] sum;
  assign sum = eff_sub ? ({1'b0, ext_l} - {1'b0, aligned})
                       : ({1'b0, ext_l} + {1'b0, aligned});

  // ------------------------------------------------------------- normalize
  logic [4:0]  lz;
  logic [9:0]  e_pre, em1;
  logic [4:0]  shamt;
  logic [26:0] norm;
  logic [9:0]  e_n;

  always_comb begin
    lz = 5'd27;
    for (int i = 0; i <= 26; i++) begin
      if (sum[i]) lz = 5'(26 - i);
    end
  end

  always_comb begin
    e_pre = {1'b0, el_eff};
    em1   = e_pre - 10'd1;
    if (sum[27]) begin                         // carry out: shift right by one
      norm  = {sum[27:2], sum[1] | sum[0]};
      shamt = 5'd0;
      e_n   = e_pre + 10'd1;
    end else begin
      shamt = (10'(lz) <= em1) ? lz : em1[4:0]; // stop at exponent 1 (subnormal)
      norm  = 27'(sum[26:0] << shamt);
      e_n   = e_pre - 10'(shamt);
      if (!norm[26]) e_n = 10'd0;              // subnormal
    end
  end

  // -------------------------------------------------------------- round RNE
  logic        round_up;
  logic [24:0] mant_r;
  logic [9:0]  e_r;

  assign round_up = norm[2] & (norm[1] | norm[0] | norm[3]);
  assign mant_r   = {1'b0, norm[26:3]} + 25'(round_up);

  always_comb begin
    e_r = e_n;
    if (mant_r[24])                      e_r = e_n + 10'd1;  // mantissa overflow
    else if (e_n == 10'd0 && mant_r[23]) e_r = 10'd1;        // subnormal -> normal
  end

  // ---------------------------------------------------------------- result
  logic [31:0] res_c;

  always_comb begin
    if (a_nan || b_nan) begin
      res_c = QNAN;
    end else if (a_inf && b_inf) begin
      res_c = (sa != sb) ? QNAN : {sa, 8'hFF, 23'd0};
    end else if (a_inf) begin
      res_c = {sa, 8'hFF, 23'd0};
    end else if (b_inf) begin
      res_c = {sb, 8'hFF, 23'd0};
    end else if (sum == 28'd0) begin
      res_c = {(eff_sub ? 1'b0 : sl), 31'd0};   // exact zero
    end else if (e_r >= 10'd255) begin
      res_c = {sl, 8'hFF, 23'd0};               // overflow -> infinity
    end else begin
      res_c = {sl, e_r[7:0], mant_r[22:0]};
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      out_valid <= 1'b0;
      result    <= 32'd0;
    end else begin
      out_valid <= in_valid;
      if (in_valid) result <= res_c;
    end
  end

endmodule
