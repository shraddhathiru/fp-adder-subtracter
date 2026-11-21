
module fp_addsub (
    input  logic        clk,
    input  logic        reset,
    input  logic        in_valid,
    input  logic        sub,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic        out_valid,
    output logic [31:0] result
);

    // Right shift with sticky-bit preservation
    function automatic [26:0] shift_right_jam (
        input logic [26:0] value,
        input integer shift
    );
        logic [26:0] temp;
        logic sticky;
        integer i;
        begin
            temp = 27'b0;
            sticky = 1'b0;

            if (shift <= 0) begin
                temp = value;
            end
            else if (shift >= 27) begin
                temp[0] = |value;
            end
            else begin
                temp = value >> shift;

                for (i = 0; i < 27; i = i + 1) begin
                    if (i < shift)
                        sticky = sticky | value[i];
                end

                temp[0] = temp[0] | sticky;
            end

            shift_right_jam = temp;
        end
    endfunction


    // Floating-point addition / subtraction
    function automatic [31:0] fp_calculate (
        input logic [31:0] x,
        input logic [31:0] y,
        input logic do_sub
    );

        logic sign_a, sign_b, sign_big, sign_result;

        logic [7:0] exp_a, exp_b;

        logic [22:0] frac_a, frac_b;

        logic [23:0] mant_a, mant_b;
        logic [23:0] mant_big, mant_small;

        logic [26:0] ext_big, ext_small, ext_result;

        logic [27:0] sum;

        logic [24:0] round_temp;
        logic [23:0] mant_rounded;

        logic guard_bit, round_bit, sticky_bit;

        integer ea, eb, exp_big, exp_small;
        integer difference;
        integer i;

        logic [31:0] answer;

        begin

            sign_a = x[31];
            sign_b = y[31] ^ do_sub;

            exp_a = x[30:23];
            exp_b = y[30:23];

            frac_a = x[22:0];
            frac_b = y[22:0];

            answer = 32'b0;

            // --------------------------------
            // NaN handling
            // --------------------------------

            if ((exp_a == 8'hFF && frac_a != 0) ||
                (exp_b == 8'hFF && frac_b != 0)) begin

                answer = 32'h7FC00000;

            end

            // --------------------------------
            // Infinity handling
            // --------------------------------

            else if ((exp_a == 8'hFF) &&
                     (exp_b == 8'hFF) &&
                     (sign_a != sign_b)) begin

                answer = 32'h7FC00000;

            end

            else if (exp_a == 8'hFF) begin

                answer = {sign_a, 8'hFF, 23'b0};

            end

            else if (exp_b == 8'hFF) begin

                answer = {sign_b, 8'hFF, 23'b0};

            end

            else begin

                // --------------------------------
                // Exponent preparation
                // --------------------------------

                ea = (exp_a == 0) ? 1 : exp_a;
                eb = (exp_b == 0) ? 1 : exp_b;

                // Hidden bit is zero for subnormal values
                mant_a = { (exp_a != 0), frac_a };
                mant_b = { (exp_b != 0), frac_b };

                // --------------------------------
                // Select larger operand
                // --------------------------------

                if ((ea > eb) ||
                    ((ea == eb) && (mant_a >= mant_b))) begin

                    mant_big = mant_a;
                    mant_small = mant_b;

                    exp_big = ea;
                    exp_small = eb;

                    sign_big = sign_a;

                end
                else begin

                    mant_big = mant_b;
                    mant_small = mant_a;

                    exp_big = eb;
                    exp_small = ea;

                    sign_big = sign_b;

                end

                // --------------------------------
                // Extend mantissas with GRS bits
                // --------------------------------

                ext_big = {mant_big, 3'b000};
                ext_small = {mant_small, 3'b000};

                // --------------------------------
                // Align exponents
                // --------------------------------

                difference = exp_big - exp_small;

                ext_small = shift_right_jam(
                    ext_small, difference
                );

                // --------------------------------
                // Addition or subtraction
                // --------------------------------

                if (sign_a == sign_b) begin

                    sum = {1'b0, ext_big} +
                          {1'b0, ext_small};

                    sign_result = sign_big;

                end
                else begin

                    sum = {1'b0, ext_big} -
                          {1'b0, ext_small};

                    sign_result = sign_big;

                end

                exp_big = exp_big;

                // --------------------------------
                // Handle exact zero
                // --------------------------------

                if (sum == 0) begin

                    if ((x[30:0] == 0) &&
                        (y[30:0] == 0) &&
                        sign_a && sign_b)

                        answer = 32'h80000000;

                    else
                        answer = 32'h00000000;

                end
                else begin

                    // --------------------------------
                    // Normalize
                    // --------------------------------

                    if (sum[27]) begin

                        ext_result = sum[27:1];
                        ext_result[0] =
                            ext_result[0] | sum[0];

                        exp_big = exp_big + 1;

                    end
                    else begin

                        ext_result = sum[26:0];

                        for (i = 0; i < 26; i = i + 1) begin

                            if ((!ext_result[26]) &&
                                (exp_big > 1)) begin

                                ext_result = ext_result << 1;
                                exp_big = exp_big - 1;

                            end

                        end

                    end

                    // --------------------------------
                    // Extract GRS bits
                    // --------------------------------

                    guard_bit  = ext_result[2];
                    round_bit  = ext_result[1];
                    sticky_bit = ext_result[0];

                    // --------------------------------
                    // Round to nearest, ties to even
                    // --------------------------------

                    round_temp = {1'b0, ext_result[26:3]};

                    if (guard_bit &&
                        (round_bit ||
                         sticky_bit ||
                         ext_result[3])) begin

                        round_temp = round_temp + 25'd1;

                    end

                    // Handle rounding carry
                    if (round_temp[24]) begin

                        mant_rounded = round_temp[24:1];
                        exp_big = exp_big + 1;

                    end
                    else begin

                        mant_rounded = round_temp[23:0];

                    end

                    // --------------------------------
                    // Overflow
                    // --------------------------------

                    if (exp_big >= 255) begin

                        answer = {sign_result, 8'hFF, 23'b0};

                    end

                    // --------------------------------
                    // Subnormal result
                    // --------------------------------

                    else if ((exp_big == 1) &&
                             (!mant_rounded[23])) begin

                        answer = {
                            sign_result,
                            8'b0,
                            mant_rounded[22:0]
                        };

                    end

                    // --------------------------------
                    // Normal result
                    // --------------------------------

                    else begin

                        answer = {
                            sign_result,
                            exp_big[7:0],
                            mant_rounded[22:0]
                        };

                    end

                end
            end

            fp_calculate = answer;

        end

    endfunction


    // --------------------------------
    // Sequential output stage
    // --------------------------------

    always_ff @(posedge clk) begin

        if (reset) begin

            result <= 32'b0;
            out_valid <= 1'b0;

        end
        else begin

            out_valid <= in_valid;

            if (in_valid) begin

                result <= fp_calculate(a, b, sub);

            end

        end

    end

endmodule
