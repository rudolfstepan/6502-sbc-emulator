`timescale 1ns / 1ps
// Raw-sector SD ROM loader.
//
// Reads the image created by fpga/tools/make_sd_boot_image.py:
//   sector 0      header
//   sectors 1..32 16 KiB payload for $C000-$FFFF
module sd_rom_loader (
    input             clk,
    input             rst,

    input             sd_init_done,
    output reg        sd_sec_read,
    output reg [31:0] sd_sec_read_addr,
    input      [7:0]  sd_sec_read_data,
    input             sd_sec_read_data_valid,
    input             sd_sec_read_end,

    output reg        rom_load_we,
    output reg [13:0] rom_load_addr,
    output reg [7:0]  rom_load_data,

    output reg        boot_done,
    output reg        boot_error,
    output     [3:0]  dbg_state
);

localparam S_WAIT_INIT      = 4'd0;
localparam S_HEADER_REQ     = 4'd1;
localparam S_HEADER_READ    = 4'd2;
localparam S_HEADER_CHECK   = 4'd3;
localparam S_PAYLOAD_REQ    = 4'd4;
localparam S_PAYLOAD_READ   = 4'd5;
localparam S_DONE           = 4'd6;
localparam S_ERROR          = 4'd7;

reg [3:0]  state;
reg [8:0]  byte_count;
reg [5:0]  sector_count;
reg [7:0]  magic [0:7];
reg [15:0] load_addr;
reg [15:0] image_len;

assign dbg_state = state;

wire magic_ok =
    magic[0] == "S" &&
    magic[1] == "B" &&
    magic[2] == "C" &&
    magic[3] == "R" &&
    magic[4] == "O" &&
    magic[5] == "M" &&
    magic[6] == "0" &&
    magic[7] == "1";

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= S_WAIT_INIT;
        sd_sec_read <= 1'b0;
        sd_sec_read_addr <= 32'd0;
        rom_load_we <= 1'b0;
        rom_load_addr <= 14'd0;
        rom_load_data <= 8'd0;
        boot_done <= 1'b0;
        boot_error <= 1'b0;
        byte_count <= 9'd0;
        sector_count <= 6'd0;
        load_addr <= 16'd0;
        image_len <= 16'd0;
    end else begin
        sd_sec_read <= 1'b0;
        rom_load_we <= 1'b0;

        case (state)
            S_WAIT_INIT: begin
                boot_done <= 1'b0;
                boot_error <= 1'b0;
                if (sd_init_done) begin
                    state <= S_HEADER_REQ;
                end
            end

            S_HEADER_REQ: begin
                sd_sec_read_addr <= 32'd0;
                sd_sec_read <= 1'b1;
                byte_count <= 9'd0;
                state <= S_HEADER_READ;
            end

            S_HEADER_READ: begin
                if (sd_sec_read_data_valid) begin
                    if (byte_count < 9'd8) begin
                        magic[byte_count[2:0]] <= sd_sec_read_data;
                    end else if (byte_count == 9'h008) begin
                        load_addr[7:0] <= sd_sec_read_data;
                    end else if (byte_count == 9'h009) begin
                        load_addr[15:8] <= sd_sec_read_data;
                    end else if (byte_count == 9'h00a) begin
                        image_len[7:0] <= sd_sec_read_data;
                    end else if (byte_count == 9'h00b) begin
                        image_len[15:8] <= sd_sec_read_data;
                    end
                    byte_count <= byte_count + 9'd1;
                end

                if (sd_sec_read_end) begin
                    state <= S_HEADER_CHECK;
                end
            end

            S_HEADER_CHECK: begin
                if (magic_ok && load_addr == 16'hC000 && image_len == 16'h4000) begin
                    sector_count <= 6'd0;
                    state <= S_PAYLOAD_REQ;
                end else begin
                    state <= S_ERROR;
                end
            end

            S_PAYLOAD_REQ: begin
                sd_sec_read_addr <= {26'd0, sector_count} + 32'd1;
                sd_sec_read <= 1'b1;
                byte_count <= 9'd0;
                state <= S_PAYLOAD_READ;
            end

            S_PAYLOAD_READ: begin
                if (sd_sec_read_data_valid) begin
                    rom_load_we <= 1'b1;
                    rom_load_addr <= {sector_count[4:0], byte_count};
                    rom_load_data <= sd_sec_read_data;
                    byte_count <= byte_count + 9'd1;
                end

                if (sd_sec_read_end) begin
                    if (sector_count == 6'd31) begin
                        state <= S_DONE;
                    end else begin
                        sector_count <= sector_count + 6'd1;
                        state <= S_PAYLOAD_REQ;
                    end
                end
            end

            S_DONE: begin
                boot_done <= 1'b1;
                boot_error <= 1'b0;
            end

            S_ERROR: begin
                boot_done <= 1'b0;
                boot_error <= 1'b1;
            end

            default: begin
                state <= S_ERROR;
            end
        endcase
    end
end

endmodule
