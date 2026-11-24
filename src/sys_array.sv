module sys_array #(
    ARR_SIZE = 4
)(
    input  logic weight_load_en,
    input  logic weight_swap_en,
    input  logic valid_in[(ARR_SIZE - 1) : 0],
    input  logic clk,
    input  logic rst,
    input  logic signed [15:0]input_act[(ARR_SIZE - 1) : 0],
    input  logic signed [15:0]input_weight[(ARR_SIZE -1) : 0],
    //input  logic signed [39:0]psum_in[(ARR_SIZE - 1) : 0],
    output logic psum_valid_out[(ARR_SIZE -1) : 0],
    output logic signed [39:0]psum_out[(ARR_SIZE - 1) : 0]
);

logic signed [15:0]act_wire[(ARR_SIZE - 1) : 0][(ARR_SIZE) : 0];
logic signed [15:0]weight_wire[(ARR_SIZE) : 0][(ARR_SIZE - 1) : 0];
logic signed [39:0]psum_wire[(ARR_SIZE) : 0][(ARR_SIZE - 1) : 0];

logic act_valid_wire[(ARR_SIZE - 1) : 0][(ARR_SIZE) : 0];
logic psum_valid_wire[(ARR_SIZE) : 0][(ARR_SIZE - 1) : 0];

generate

    for (genvar row = 0; row <= (ARR_SIZE - 1); row++)
    begin:act_assign
        assign act_wire[row][0] = input_act[row];
        assign act_valid_wire[row][0] = valid_in[row];
    end

    for(genvar col = 0; col <= (ARR_SIZE - 1); col++)
    begin:w_ps_assign
        assign weight_wire[0][col] = input_weight[col];
        assign psum_wire[0][col] = 40'b0;
        assign psum_valid_wire[0][col] = 1'b1;
    end

    for(genvar col = 0; col <= (ARR_SIZE - 1); col++)
    begin:ps_out_assign
        assign psum_out[col] = psum_wire[ARR_SIZE][col];
        assign psum_valid_out[col] = psum_valid_wire[ARR_SIZE][col];
    end 

    for (genvar row = 0; row <= (ARR_SIZE - 1); row++)
    begin:sys_row

        for(genvar col = 0; col <= (ARR_SIZE - 1); col++)
        begin:sys_col
            pe_block u_pe (
                .weight_swap_en(weight_swap_en),
                .weight_load_en(weight_load_en),
                .act_valid_in(act_valid_wire[row][col]),
                .psum_valid_in(psum_valid_wire[row][col]),
                .clk(clk),
                .rst(rst),
                .act_in(act_wire[row][col]),
                .weight_in(weight_wire[row][col]),
                .psum_in(psum_wire[row][col]),
                .psum_valid_out(psum_valid_wire[row + 1][col]),
                .act_valid_out(act_valid_wire[row][col + 1]),
                .act_out(act_wire[row][col + 1]),
                .weight_out(weight_wire[row + 1][col]),
                .psum_out(psum_wire[row + 1][col])
            );
        end

    end 
endgenerate


endmodule
