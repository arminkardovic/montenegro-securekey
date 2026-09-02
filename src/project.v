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
    localparam [31:0] DEVICE_ID = 32'h4549_0001; // "EI" + device 0001
    localparam [63:0] DEMO_KEY  = 64'hA91B_82C7_71EF_1234;
    localparam [31:0]  DEVICE_MIX = {DEVICE_ID[15:0], DEVICE_ID[31:16]};
    localparam [63:0] ROUND_SECRET = DEMO_KEY ^ {DEVICE_ID, DEVICE_MIX};

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
    // Authentication engine: 8 input bytes -> 128 cycles of a compact keyed
    // nonlinear feedback mixer -> 8 output bytes. This educational transform
    // is deliberately tiny enough for a 1x1 tile; it is not cryptography.
    // ---------------------------------------------------------------------
    reg [63:0] challenge_register;
    reg [3:0]  challenge_byte_count;
    reg [6:0]  auth_round;
    reg [2:0]  response_byte_index;
    reg        response_valid;
    reg        auth_busy;
    reg        auth_ok;

    // The old state bit 63 participates linearly, so every round remains a
    // permutation. Nonlinear tap products, a counter-dependent round bit and
    // the fixed key/device schedule provide diffusion over 128 cycles.
    wire round_secret_bit = ROUND_SECRET[auth_round[5:0]] ^ auth_round[6];
    wire mixer_feedback = challenge_register[63] ^
                          challenge_register[62] ^
                          challenge_register[60] ^
                          challenge_register[59] ^
                          challenge_register[37] ^
                          (challenge_register[0] & challenge_register[13]) ^
                          (challenge_register[7] & challenge_register[38]) ^
                          (challenge_register[26] & challenge_register[45]) ^
                          auth_round[0] ^ auth_round[3] ^
                          round_secret_bit;

    reg [7:0] selected_response_byte;
    always @(*) begin
        case (response_byte_index)
            3'd0: selected_response_byte = challenge_register[63:56];
            3'd1: selected_response_byte = challenge_register[55:48];
            3'd2: selected_response_byte = challenge_register[47:40];
            3'd3: selected_response_byte = challenge_register[39:32];
            3'd4: selected_response_byte = challenge_register[31:24];
            3'd5: selected_response_byte = challenge_register[23:16];
            3'd6: selected_response_byte = challenge_register[15:8];
            default: selected_response_byte = challenge_register[7:0];
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
            auth_round           <= 7'd0;
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
                challenge_register <= {challenge_register[62:0],
                                       mixer_feedback};

                if (auth_round == 7'd127) begin
                    response_byte_index  <= 3'd0;
                    response_valid       <= 1'b1;
                    challenge_byte_count <= 4'd0;
                    auth_busy            <= 1'b0;
                    auth_ok              <= 1'b1;
                end else begin
                    auth_round <= auth_round + 1'b1;
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
                    auth_round     <= 7'd0;
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
    // Melody engine. The ROM contains two opening refrain phrases from
    // "Oj, svijetla majska zoro". Audio is a 50% duty
    // cycle square wave intended for an external piezo driver.
    // ---------------------------------------------------------------------
    localparam [3:0] NOTE_REST = 4'd0;
    localparam [3:0] NOTE_E4   = 4'd1;
    localparam [3:0] NOTE_F4   = 4'd2;
    localparam [3:0] NOTE_G4   = 4'd3;
    localparam [5:0] MELODY_LAST_INDEX = 6'd39;

    function [7:0] melody_word;
        input [5:0] address;
        begin
            // Upper nibble: note code. Lower nibble: 125 ms units.
            // Transcribed from the F-major, 2/4 score at quarter note = 80.
            // Three units are an eighth note; six units are a quarter note.
            case (address)
                // Score measures 1-7: opening refrain
                6'd0:  melody_word = {NOTE_E4, 4'd3};
                6'd1:  melody_word = {NOTE_E4, 4'd3};
                6'd2:  melody_word = {NOTE_E4, 4'd3};
                6'd3:  melody_word = {NOTE_F4, 4'd3};
                6'd4:  melody_word = {NOTE_E4, 4'd6};
                6'd5:  melody_word = {NOTE_E4, 4'd3};
                6'd6:  melody_word = {NOTE_F4, 4'd3};
                6'd7:  melody_word = {NOTE_G4, 4'd6};
                6'd8:  melody_word = {NOTE_G4, 4'd3};
                6'd9:  melody_word = {NOTE_E4, 4'd3};
                6'd10: melody_word = {NOTE_E4, 4'd6};
                6'd11: melody_word = {NOTE_E4, 4'd3};
                6'd12: melody_word = {NOTE_F4, 4'd3};
                6'd13: melody_word = {NOTE_G4, 4'd6};
                6'd14: melody_word = {NOTE_G4, 4'd3};
                6'd15: melody_word = {NOTE_E4, 4'd3};
                6'd16: melody_word = {NOTE_F4, 4'd6};
                6'd17: melody_word = {NOTE_F4, 4'd6};
                6'd18: melody_word = {NOTE_F4, 4'd6};
                6'd19: melody_word = {NOTE_F4, 4'd6};

                // Score measures 8-14: continuation of the refrain
                6'd20: melody_word = {NOTE_E4, 4'd3};
                6'd21: melody_word = {NOTE_E4, 4'd3};
                6'd22: melody_word = {NOTE_E4, 4'd3};
                6'd23: melody_word = {NOTE_F4, 4'd3};
                6'd24: melody_word = {NOTE_E4, 4'd6};
                6'd25: melody_word = {NOTE_E4, 4'd3};
                6'd26: melody_word = {NOTE_F4, 4'd3};
                6'd27: melody_word = {NOTE_G4, 4'd6};
                6'd28: melody_word = {NOTE_G4, 4'd3};
                6'd29: melody_word = {NOTE_F4, 4'd3};
                6'd30: melody_word = {NOTE_E4, 4'd6};
                6'd31: melody_word = {NOTE_E4, 4'd3};
                6'd32: melody_word = {NOTE_F4, 4'd3};
                6'd33: melody_word = {NOTE_G4, 4'd6};
                6'd34: melody_word = {NOTE_G4, 4'd3};
                6'd35: melody_word = {NOTE_E4, 4'd3};
                6'd36: melody_word = {NOTE_F4, 4'd6};
                6'd37: melody_word = {NOTE_F4, 4'd6};
                6'd38: melody_word = {NOTE_F4, 4'd6};
                6'd39: melody_word = {NOTE_F4, 4'd6};

                default: melody_word = {NOTE_REST, 4'd1};
            endcase
        end
    endfunction

    // At the nominal 10 MHz clock the lowest note needs 15,151 cycles, so
    // 15 bits are sufficient. NOTE_UNIT_CYCLES is 1,250,000 (21 bits).
    /* verilator lint_off WIDTHTRUNC */
    function [14:0] half_period_for_note;
        input [3:0] note_code;
        begin
            case (note_code)
                NOTE_E4:  half_period_for_note = CLOCK_HZ / (2 * 330);
                NOTE_F4:  half_period_for_note = CLOCK_HZ / (2 * 349);
                NOTE_G4:  half_period_for_note = CLOCK_HZ / (2 * 392);
                default:  half_period_for_note = 15'd0;
            endcase
        end
    endfunction
    /* verilator lint_on WIDTHTRUNC */

    reg [5:0]  melody_index;
    reg [14:0] tone_counter;
    reg [20:0] note_unit_counter;
    reg [3:0]  note_units_elapsed;
    reg        music_playing;
    reg        audio_out;

    wire [7:0]  current_melody_word = melody_word(melody_index);
    wire [3:0]  current_note = current_melody_word[7:4];
    wire [3:0]  current_duration_units = current_melody_word[3:0];
    wire [14:0] current_half_period = half_period_for_note(current_note);
    wire        final_note_unit =
                    note_units_elapsed + 1'b1 >= current_duration_units;
    /* verilator lint_off WIDTHEXPAND */
    wire        articulation_gap = final_note_unit &&
                    note_unit_counter >=
                    NOTE_UNIT_CYCLES - (NOTE_UNIT_CYCLES / 4);
    /* verilator lint_on WIDTHEXPAND */

    always @(posedge clk) begin
        if (!rst_n) begin
            melody_index       <= 6'd0;
            tone_counter       <= 15'd0;
            note_unit_counter  <= 21'd0;
            note_units_elapsed <= 4'd0;
            music_playing      <= 1'b0;
            audio_out          <= 1'b0;
        end else if (music_stop_rise) begin
            melody_index       <= 6'd0;
            tone_counter       <= 15'd0;
            note_unit_counter  <= 21'd0;
            note_units_elapsed <= 4'd0;
            music_playing      <= 1'b0;
            audio_out          <= 1'b0;
        end else if (music_start_rise) begin
            melody_index       <= 6'd0;
            tone_counter       <= 15'd0;
            note_unit_counter  <= 21'd0;
            note_units_elapsed <= 4'd0;
            music_playing      <= 1'b1;
            audio_out          <= 1'b0;
        end else if (music_playing) begin
            if (current_note == NOTE_REST || current_half_period == 15'd0 ||
                articulation_gap) begin
                tone_counter <= 15'd0;
                audio_out    <= 1'b0;
            end else if (tone_counter >= current_half_period - 1'b1) begin
                tone_counter <= 15'd0;
                audio_out    <= ~audio_out;
            end else begin
                tone_counter <= tone_counter + 1'b1;
            end

            // NOTE_UNIT_CYCLES is intentionally limited to the 21-bit counter.
            /* verilator lint_off WIDTHEXPAND */
            if (note_unit_counter >= NOTE_UNIT_CYCLES - 1) begin
            /* verilator lint_on WIDTHEXPAND */
                note_unit_counter <= 21'd0;
                if (note_units_elapsed + 1'b1 >= current_duration_units) begin
                    note_units_elapsed <= 4'd0;
                    tone_counter       <= 15'd0;
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
