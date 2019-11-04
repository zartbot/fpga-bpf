`timescale 1ns / 1ps

/*

This is by far the most complicated of all three adapters. It has to take care 
of calculating the right address in the packet RAM, and then picking out the 
data that were requested by the CPU.

One improvement would be to cache the large value read from RAM, that way we 
don't need to incur any memory delays next time


REGULAR MODE
Schedule (II=1):
C0: (Input: packmem_rd_en, transfer_sz, byte_rd_addr; Output: word_rd_addra)
Note that the bigword input in C1 is the read data from the packet memory 

C1: (Input: bigword; Output: resized_mem_data)


//TODO: Add all the rest of the signals?

*/


//Assumes big-endianness


`include "bpf_defs.vh"


//I kept needing this value in the code
`define N (BYTE_ADDR_WIDTH - ADDR_WIDTH - 1)

//Assumes that 2**ADDR_WIDTH * PORT_DATA_WIDTH == 2**BYTE_ADDR_WIDTH
//where PORT_DATA_WIDTH is in bytes
module cpu_adapter # (
    parameter BYTE_ADDR_WIDTH = 12, // packetmem depth = 2^BYTE_ADDR_WIDTH bytes
    parameter ADDR_WIDTH = 10,
    parameter DATA_WIDTH = 2**(BYTE_ADDR_WIDTH - ADDR_WIDTH)*8,
    //These control pessimistic registers in the p_ng buffers
    parameter BUF_IN = 0,
    parameter BUF_OUT = 0,
    parameter PESS = 0 //If 1, our output will be buffered
)(
    input wire clk,
    input wire rst,
    
    input wire [BYTE_ADDR_WIDTH-1:0] byte_rd_addr, //@0
    input wire cpu_rd_en, //@0
    input wire [1:0] transfer_sz, //@0
    
    output wire rd_en, //@0
    output wire [ADDR_WIDTH-1:0] word_rd_addra, //@0
    
    //A little performance improvement: we have to buffer bigword anyway, so 
    //we can write a little data cache!
    output wire cache_hit, //@1
    output wire [31:0] cached_data, //@1
    
    input wire [DATA_WIDTH-1:0] bigword, //@1+BUF_IN+BUF_OUT
    
    //zero-padded on the left (when necessary)
    output wire [31:0] resized_mem_data //@1+BUF_IN+BUF_OUT+PESS
);
    
    //Memory latency
    parameter MEM_LAT = 1 + BUF_IN + BUF_OUT;
    
    /************************************/
    /**Forward-declare internal signals**/
    /************************************/
    wire [BYTE_ADDR_WIDTH-1:0] byte_rd_addr_i;
    wire cpu_rd_en_i;
    
    //Need to hang onto transfer_sz until memory returns the value
    wire [1:0] transfer_sz_i;
    reg [2*MEM_LAT-1:0] transfer_sz_r;
    
    wire rd_en_i;
    wire [ADDR_WIDTH-1:0] word_rd_addra_i;
    
    wire cache_hit_i;
    wire [31:0] cached_data_i;
    
    wire [DATA_WIDTH-1:0] bigword_i;
    wire [31:0] resized_mem_data_i;
    
    //This is the offset into bigword. We'll grab it in cycle 0, and hold it
    //until the memory is ready
    wire [`N-1:0] offset_i;
    reg [`N*MEM_LAT-1:0] offset_r;
    
    
    
    /***************************************/
    /**Assign internal signals from inputs**/
    /***************************************/
    genvar i;
    
    assign byte_rd_addr_i = byte_rd_addr;
    assign cpu_rd_en_i = cpu_rd_en;
    
    assign bigword_i = bigword;
    
    //Buffer transfer_sz for MEM_LAT cycles
    always @(posedge clk) transfer_sz_r[1:0] <= transfer_sz[1:0];
    for (i = 1; i < MEM_LAT; i = i + 1) begin
        always @(posedge clk) transfer_sz_r[2*(i+1)-1 -: 2] <= transfer_sz_r[2*i-1 -: 2];
    end
    assign transfer_sz_i = transfer_sz_r[2*MEM_LAT-1 -: 2];
    
    //Buffer offset for MEM_LAT cycles
    always @(posedge clk) offset_r[`N-1:0] <= byte_rd_addr_i[`N-1:0];
    for (i = 1; i < MEM_LAT; i = i + 1) begin
        always @(posedge clk) offset_r[`N*(i+1) - 1 -: `N] <= offset_r[`N*i -1 -: `N];
    end
    assign offset_i = offset_r[`N*MEM_LAT-1 -: `N];
    
    
    /****************/
    /**Do the logic**/
    /****************/
    
    //Compute address
    assign word_rd_addra_i = byte_rd_addr_i[BYTE_ADDR_WIDTH-1:`N];
    assign rd_en_i = cpu_rd_en_i; //TODO: check if cache got a hit
    
    //For now, simplify the code and don't do the crazy caching
    assign cache_hit_i = 0;
    assign cached_data_i = 32'h7066607;
    
    //This "selected" vector is the desired part of the bigword, based on the offset
    wire [31:0] selected;
    assign selected = bigword_i[(DATA_WIDTH - {offset_i, 3'b0} )-1 -: 32];
    
    //resized_mem_data is zero-padded if you ask for a smaller size
    assign resized_mem_data_i[7:0] = (transfer_sz_i == `BPF_W) ? selected[7:0]: 
                                    ((transfer_sz_i == `BPF_H) ? selected[23:16] : selected[31:24]); 

    assign resized_mem_data_i[15:8] = (transfer_sz_i == `BPF_W) ? selected[15:8]: 
                                    ((transfer_sz_i == `BPF_H) ? selected[31:24] : 0);

    assign resized_mem_data_i[31:16] = (transfer_sz_i == `BPF_W) ? selected[31:16]: 0;
    
    /****************************************/
    /**Assign outputs from internal signals**/
    /****************************************/
    assign word_rd_addra = word_rd_addra_i;
    assign rd_en = rd_en_i;
    assign cache_hit = cache_hit_i;
    assign cached_data = cached_data_i;
generate
    if(PESS) begin
        reg [31:0] resized_mem_data_r = 0;
        always @(posedge clk) begin
            if (!rst) resized_mem_data_r <= resized_mem_data_i;
            else resized_mem_data_r <= 0;
        end
        
        assign resized_mem_data = resized_mem_data_r;
    end else begin
        assign resized_mem_data = resized_mem_data_i;
    end
endgenerate

endmodule
