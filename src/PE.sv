module pe_block (
    input  logic weight_swap_en,
    input  logic weight_load_en,
    input  logic act_valid_in,
    input  logic psum_valid_in,
    input  logic clk,
    input  logic rst,
    input  logic signed [15:0]act_in,
    input  logic signed [15:0]weight_in,
    input  logic signed [39:0]psum_in,
    output logic psum_valid_out,
    output logic act_valid_out,
    output logic signed [15:0]act_out,
    output logic signed [15:0]weight_out,
    output logic signed [39:0]psum_out
);

logic signed [15:0]weight_reg;
logic signed [15:0]weight_shdw_reg;

assign weight_out = weight_shdw_reg;

mac u_mac (
    .act_in(act_in),
    .weight_in(weight_reg),
    .psum_in(psum_in),
    .valid_in(psum_valid_in & act_valid_in),
    .clk(clk),
    .rst(rst),
    .psum_out(psum_out),
    .done(psum_valid_out)
);

always @(posedge clk)
begin 
    if (rst)
    begin 

        act_valid_out <= 1'b0;
        weight_shdw_reg <= 16'b0;
        weight_reg <= 16'b0;
        act_out <= 16'b0;
        
    end 
    else 
    begin 
        act_valid_out <= act_valid_in;

        if (act_valid_in)
        begin 
            act_out <= act_in;
        end

        if(weight_load_en)
        begin
            weight_shdw_reg <= weight_in;
        end

        if(weight_swap_en)
        begin
            weight_reg <= weight_shdw_reg;
        end
    end
end

endmodule
