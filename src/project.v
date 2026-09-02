/*
 * Copyright (c) 2026 Armin
 * SPDX-License-Identifier: Apache-2.0
 *
 * Montenegro SecureKey
 *
 * Educational Tiny Tapeout proof of concept combining a byte-serial,
 * 64-bit challenge/response engine with a small monophonic melody player.
 * The key and device ID are constants in this open-source RTL and therefore
 * MUST NOT be treated as production secrets.
 */

`default_nettype none

module tt_um_arminkardovic_montenegro_securekey #(
    parameter integer CLOCK_HZ         = 10_000_000,
    parameter integer NOTE_UNIT_CYCLES = 1_250_000
) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ---------------------------------------------------------------------
    // Public demonstration identity and key.
    // A production device needs a non-public, per-device provisioned key.
    // ---------------------------------------------------------------------
    localparam [31:0]  DEVICE_ID = 32'h4549_0001; // "EI" + device 0001
    localparam [127:0] DEMO_KEY  = 128'hA91B82C771EF12346D6F6E74656E6567;
    localparam [31:0]  XTEA_DELTA = 32'h9E37_79B9;
    localparam [31:0]  DEVICE_MIX = {DEVICE_ID[15:0], DEVICE_ID[31:16]};

    // Rising-edge detection for the four synchronous control inputs.
    // Control pulses must be held high across at least one rising clk edge.
    reg byte_strobe_previous;
    reg auth_start_previous;
    reg music_start_previous;
    reg music_stop_previous;
    wire byte_strobe_rise = uio_in[0] & ~byte_strobe_previous;
    wire auth_start_rise  = uio_in[1] & ~auth_start_previous;
    wire music_start_rise = uio_in[3] & ~music_start_previous;
    wire music_stop_rise  = uio_in[4] & ~music_stop_previous;

    // ---------------------------------------------------------------------
    // Authentication engine: 8 input bytes -> 32 XTEA rounds -> 8 bytes.
    // The device ID is mixed before and after XTEA so it is part of the
    // deterministic response function.
    // ---------------------------------------------------------------------
    reg [63:0] challenge_register;
    reg [3:0]  challenge_byte_count;
    reg [31:0] xtea_v0;
    reg [31:0] xtea_v1;
    reg [31:0] xtea_sum;
    reg [5:0]  xtea_round;
    reg [63:0] response_register;
    reg [2:0]  response_byte_index;
    reg        response_valid;
    reg        auth_busy;
    reg        auth_ok;

    function [31:0] key_word;
        input [1:0] index;
        begin
            case (index)
                2'd0: key_word = DEMO_KEY[127:96];
                2'd1: key_word = DEMO_KEY[95:64];
                2'd2: key_word = DEMO_KEY[63:32];
                default: key_word = DEMO_KEY[31:0];
            endcase
        end
    endfunction

    wire [31:0] xtea_mix0 =
        ((((xtea_v1 << 4) ^ (xtea_v1 >> 5)) + xtea_v1) ^
         (xtea_sum + key_word(xtea_sum[1:0])));
    wire [31:0] xtea_v0_next = xtea_v0 + xtea_mix0;
    wire [31:0] xtea_sum_next = xtea_sum + XTEA_DELTA;
    wire [31:0] xtea_mix1 =
        ((((xtea_v0_next << 4) ^ (xtea_v0_next >> 5)) + xtea_v0_next) ^
         (xtea_sum_next + key_word(xtea_sum_next[12:11])));
    wire [31:0] xtea_v1_next = xtea_v1 + xtea_mix1;

    reg [7:0] selected_response_byte;
    always @(*) begin
        case (response_byte_index)
            3'd0: selected_response_byte = response_register[63:56];
            3'd1: selected_response_byte = response_register[55:48];
            3'd2: selected_response_byte = response_register[47:40];
            3'd3: selected_response_byte = response_register[39:32];
            3'd4: selected_response_byte = response_register[31:24];
            3'd5: selected_response_byte = response_register[23:16];
            3'd6: selected_response_byte = response_register[15:8];
            default: selected_response_byte = response_register[7:0];
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            byte_strobe_previous <= 1'b0;
            auth_start_previous  <= 1'b0;
            music_start_previous <= 1'b0;
            music_stop_previous  <= 1'b0;
            challenge_register   <= 64'b0;
            challenge_byte_count <= 4'd0;
            xtea_v0              <= 32'b0;
            xtea_v1              <= 32'b0;
            xtea_sum             <= 32'b0;
            xtea_round           <= 6'd0;
            response_register    <= 64'b0;
            response_byte_index  <= 3'd0;
            response_valid       <= 1'b0;
            auth_busy            <= 1'b0;
            auth_ok              <= 1'b0;
        end else begin
            byte_strobe_previous <= uio_in[0];
            auth_start_previous  <= uio_in[1];
            music_start_previous <= uio_in[3];
            music_stop_previous  <= uio_in[4];

            if (auth_busy) begin
                xtea_v0  <= xtea_v0_next;
                xtea_v1  <= xtea_v1_next;
                xtea_sum <= xtea_sum_next;

                if (xtea_round == 6'd31) begin
                    response_register <= {
                        xtea_v0_next ^ DEVICE_ID,
                        xtea_v1_next ^ DEVICE_MIX
                    };
                    response_byte_index  <= 3'd0;
                    response_valid       <= 1'b1;
                    challenge_byte_count <= 4'd0;
                    auth_busy            <= 1'b0;
                    auth_ok              <= 1'b1;
                end else begin
                    xtea_round <= xtea_round + 1'b1;
                end
            end else if (response_valid && byte_strobe_rise) begin
                // The same strobe used to load the challenge advances the
                // response stream. An extra strobe acknowledges byte 7.
                if (response_byte_index == 3'd7) begin
                    response_valid      <= 1'b0;
                    response_byte_index <= 3'd0;
                end else begin
                    response_byte_index <= response_byte_index + 1'b1;
                end
            end else if (auth_start_rise) begin
                if (challenge_byte_count == 4'd8) begin
                    xtea_v0        <= challenge_register[63:32] ^ DEVICE_ID;
                    xtea_v1        <= challenge_register[31:0] ^ DEVICE_MIX;
                    xtea_sum       <= 32'b0;
                    xtea_round     <= 6'd0;
                    response_valid <= 1'b0;
                    auth_busy      <= 1'b1;
                    auth_ok        <= 1'b0;
                end else begin
                    // Reject incomplete frames without disturbing bytes that
                    // have already been loaded; reset starts a fresh frame.
                    auth_ok <= 1'b0;
                end
            end else if (byte_strobe_rise) begin
                if (challenge_byte_count < 4'd8) begin
                    challenge_register <= {challenge_register[55:0], ui_in};
                    challenge_byte_count <= challenge_byte_count + 1'b1;
                    auth_ok <= 1'b0;
                end
            end
        end
    end

    // ---------------------------------------------------------------------
    // Melody engine. The ROM contains a compact monophonic approximation of
    // the opening section of "Oj, svijetla majska zoro". Audio is a 50% duty
    // cycle square wave intended for an external piezo driver.
    // ---------------------------------------------------------------------
    localparam [3:0] NOTE_REST = 4'd0;
    localparam [3:0] NOTE_D4   = 4'd1;
    localparam [3:0] NOTE_E4   = 4'd2;
    localparam [3:0] NOTE_F4   = 4'd3;
    localparam [3:0] NOTE_G4   = 4'd4;
    localparam [3:0] NOTE_A4   = 4'd5;
    localparam [3:0] NOTE_BB4  = 4'd6;
    localparam [3:0] NOTE_C5   = 4'd7;
    localparam [3:0] NOTE_D5   = 4'd8;
    localparam [3:0] NOTE_E5   = 4'd9;
    localparam [3:0] NOTE_F5   = 4'd10;
    localparam [3:0] NOTE_G5   = 4'd11;
    localparam [3:0] NOTE_A5   = 4'd12;
    localparam [5:0] MELODY_LAST_INDEX = 6'd47;

    function [7:0] melody_word;
        input [5:0] address;
        begin
            // Upper nibble: note code. Lower nibble: 125 ms units.
            case (address)
                6'd0:  melody_word = {NOTE_A4,  4'd2};
                6'd1:  melody_word = {NOTE_A4,  4'd2};
                6'd2:  melody_word = {NOTE_BB4, 4'd2};
                6'd3:  melody_word = {NOTE_C5,  4'd2};
                6'd4:  melody_word = {NOTE_D5,  4'd4};
                6'd5:  melody_word = {NOTE_C5,  4'd2};
                6'd6:  melody_word = {NOTE_BB4, 4'd2};
                6'd7:  melody_word = {NOTE_A4,  4'd4};
                6'd8:  melody_word = {NOTE_G4,  4'd2};
                6'd9:  melody_word = {NOTE_A4,  4'd2};
                6'd10: melody_word = {NOTE_BB4, 4'd2};
                6'd11: melody_word = {NOTE_A4,  4'd4};
                6'd12: melody_word = {NOTE_G4,  4'd2};
                6'd13: melody_word = {NOTE_F4,  4'd4};
                6'd14: melody_word = {NOTE_REST, 4'd1};
                6'd15: melody_word = {NOTE_A4,  4'd2};
                6'd16: melody_word = {NOTE_A4,  4'd2};
                6'd17: melody_word = {NOTE_BB4, 4'd2};
                6'd18: melody_word = {NOTE_C5,  4'd2};
                6'd19: melody_word = {NOTE_D5,  4'd4};
                6'd20: melody_word = {NOTE_E5,  4'd2};
                6'd21: melody_word = {NOTE_F5,  4'd2};
                6'd22: melody_word = {NOTE_E5,  4'd4};
                6'd23: melody_word = {NOTE_D5,  4'd2};
                6'd24: melody_word = {NOTE_C5,  4'd2};
                6'd25: melody_word = {NOTE_BB4, 4'd2};
                6'd26: melody_word = {NOTE_A4,  4'd4};
                6'd27: melody_word = {NOTE_G4,  4'd2};
                6'd28: melody_word = {NOTE_A4,  4'd2};
                6'd29: melody_word = {NOTE_BB4, 4'd2};
                6'd30: melody_word = {NOTE_A4,  4'd4};
                6'd31: melody_word = {NOTE_D4,  4'd4};
                6'd32: melody_word = {NOTE_F4,  4'd2};
                6'd33: melody_word = {NOTE_G4,  4'd2};
                6'd34: melody_word = {NOTE_A4,  4'd4};
                6'd35: melody_word = {NOTE_BB4, 4'd2};
                6'd36: melody_word = {NOTE_A4,  4'd2};
                6'd37: melody_word = {NOTE_G4,  4'd4};
                6'd38: melody_word = {NOTE_F4,  4'd2};
                6'd39: melody_word = {NOTE_E4,  4'd2};
                6'd40: melody_word = {NOTE_D4,  4'd4};
                6'd41: melody_word = {NOTE_A4,  4'd2};
                6'd42: melody_word = {NOTE_D5,  4'd2};
                6'd43: melody_word = {NOTE_C5,  4'd2};
                6'd44: melody_word = {NOTE_BB4, 4'd2};
                6'd45: melody_word = {NOTE_A4,  4'd2};
                6'd46: melody_word = {NOTE_G4,  4'd2};
                6'd47: melody_word = {NOTE_D4,  4'd8};
                default: melody_word = {NOTE_REST, 4'd1};
            endcase
        end
    endfunction

    function [31:0] half_period_for_note;
        input [3:0] note_code;
        begin
            case (note_code)
                NOTE_D4:  half_period_for_note = CLOCK_HZ / (2 * 294);
                NOTE_E4:  half_period_for_note = CLOCK_HZ / (2 * 330);
                NOTE_F4:  half_period_for_note = CLOCK_HZ / (2 * 349);
                NOTE_G4:  half_period_for_note = CLOCK_HZ / (2 * 392);
                NOTE_A4:  half_period_for_note = CLOCK_HZ / (2 * 440);
                NOTE_BB4: half_period_for_note = CLOCK_HZ / (2 * 466);
                NOTE_C5:  half_period_for_note = CLOCK_HZ / (2 * 523);
                NOTE_D5:  half_period_for_note = CLOCK_HZ / (2 * 587);
                NOTE_E5:  half_period_for_note = CLOCK_HZ / (2 * 659);
                NOTE_F5:  half_period_for_note = CLOCK_HZ / (2 * 698);
                NOTE_G5:  half_period_for_note = CLOCK_HZ / (2 * 784);
                NOTE_A5:  half_period_for_note = CLOCK_HZ / (2 * 880);
                default:  half_period_for_note = 32'd0;
            endcase
        end
    endfunction

    reg [5:0]  melody_index;
    reg [31:0] tone_counter;
    reg [31:0] note_unit_counter;
    reg [3:0]  note_units_elapsed;
    reg        music_playing;
    reg        audio_out;

    wire [7:0]  current_melody_word = melody_word(melody_index);
    wire [3:0]  current_note = current_melody_word[7:4];
    wire [3:0]  current_duration_units = current_melody_word[3:0];
    wire [31:0] current_half_period = half_period_for_note(current_note);

    always @(posedge clk) begin
        if (!rst_n) begin
            melody_index       <= 6'd0;
            tone_counter       <= 32'd0;
            note_unit_counter  <= 32'd0;
            note_units_elapsed <= 4'd0;
            music_playing      <= 1'b0;
            audio_out          <= 1'b0;
        end else if (music_stop_rise) begin
            melody_index       <= 6'd0;
            tone_counter       <= 32'd0;
            note_unit_counter  <= 32'd0;
            note_units_elapsed <= 4'd0;
            music_playing      <= 1'b0;
            audio_out          <= 1'b0;
        end else if (music_start_rise) begin
            melody_index       <= 6'd0;
            tone_counter       <= 32'd0;
            note_unit_counter  <= 32'd0;
            note_units_elapsed <= 4'd0;
            music_playing      <= 1'b1;
            audio_out          <= 1'b0;
        end else if (music_playing) begin
            if (current_note == NOTE_REST || current_half_period == 32'd0) begin
                tone_counter <= 32'd0;
                audio_out    <= 1'b0;
            end else if (tone_counter >= current_half_period - 1'b1) begin
                tone_counter <= 32'd0;
                audio_out    <= ~audio_out;
            end else begin
                tone_counter <= tone_counter + 1'b1;
            end

            if (note_unit_counter >= NOTE_UNIT_CYCLES - 1) begin
                note_unit_counter <= 32'd0;
                if (note_units_elapsed + 1'b1 >= current_duration_units) begin
                    note_units_elapsed <= 4'd0;
                    tone_counter       <= 32'd0;
                    audio_out          <= 1'b0;
                    if (melody_index == MELODY_LAST_INDEX) begin
                        melody_index  <= 6'd0;
                        music_playing <= 1'b0;
                    end else begin
                        melody_index <= melody_index + 1'b1;
                    end
                end else begin
                    note_units_elapsed <= note_units_elapsed + 1'b1;
                end
            end else begin
                note_unit_counter <= note_unit_counter + 1'b1;
            end
        end else begin
            audio_out <= 1'b0;
        end
    end

    // Dedicated response bus and bidirectional status/audio pins.
    assign uo_out  = response_valid ? selected_response_byte : 8'h00;
    assign uio_out = {auth_busy, auth_ok, audio_out, 2'b00,
                      response_valid, 2'b00};
    assign uio_oe  = 8'b1110_0100; // uio[7], [6], [5], and [2] are outputs

    // ena and the input paths of output-only uio pins are intentionally unused.
    wire _unused = &{ena, uio_in[7:5], uio_in[2], 1'b0};

endmodule

`default_nettype wire
