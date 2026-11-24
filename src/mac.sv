 `timescale 1ns / 1ps

(* use_dsp = "yes" *)
module mac #(
    parameter DATA_WIDTH = 16,
    parameter ACC_WIDTH  = 40
)(
input  logic                          clk,
    input  logic                          rst,
input  logic                          valid_in,
input  logic signed [DATA_WIDTH-1:0]  act_in,
input  logic signed [DATA_WIDTH-1:0]  weight_in,
    input  logic signed [ACC_WIDTH-1:0]   psum_in,
output logic signed [ACC_WIDTH-1:0]   psum_out,
output logic                          done
);

    
    logic signed [31:0]          m_reg;
    logic signed [ACC_WIDTH-1:0] psum_stage1;
    logic                        valid_stage1;

    
    always_ff @(posedge clk) begin
        if (rst) begin
            // Synchronous reset ONLY
        m_reg        <= '0;
            psum_stage1  <= '0;
            valid_stage1 <= 1'b0;
        psum_out     <= '0;
            done         <= 1'b0;
        end else begin
            m_reg        <= act_in * weight_in;
            psum_stage1  <= psum_in;
            valid_stage1 <= valid_in;

        if (valid_stage1) begin
                psum_out <= psum_stage1 + signed'({{ (ACC_WIDTH-32){m_reg[31]} }, m_reg});
            end else begin
                psum_out <= psum_stage1;
            end
            done <= valid_stage1;
        end
    end

endmodule
