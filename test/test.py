# SPDX-FileCopyrightText: 2026 Armin
# SPDX-License-Identifier: Apache-2.0

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer


DEVICE_ID = 0x45490001
DEVICE_MIX = ((DEVICE_ID & 0xFFFF) << 16) | (DEVICE_ID >> 16)
DEMO_KEY = 0xA91B82C771EF1234
ROUND_SECRET = DEMO_KEY ^ ((DEVICE_ID << 32) | DEVICE_MIX)
MASK64 = 0xFFFFFFFFFFFFFFFF


def compact_response(challenge: int) -> int:
    """Independent software model of the documented demo transform."""
    state = challenge

    for round_index in range(128):
        bit = lambda index: (state >> index) & 1
        round_secret_bit = (
            ((ROUND_SECRET >> (round_index & 63)) & 1) ^ (round_index >> 6)
        )
        feedback = (
            bit(63)
            ^ bit(62)
            ^ bit(60)
            ^ bit(59)
            ^ bit(37)
            ^ (bit(0) & bit(13))
            ^ (bit(7) & bit(38))
            ^ (bit(26) & bit(45))
            ^ (round_index & 1)
            ^ ((round_index >> 3) & 1)
            ^ round_secret_bit
        )
        state = ((state << 1) & MASK64) | feedback

    return state


async def settle():
    await Timer(1, unit="ns")


async def reset_dut(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    await settle()


async def pulse_uio(dut, bit: int):
    base = int(dut.uio_in.value)
    dut.uio_in.value = base | (1 << bit)
    await RisingEdge(dut.clk)
    await settle()
    dut.uio_in.value = base & ~(1 << bit)
    await RisingEdge(dut.clk)
    await settle()


async def load_challenge(dut, challenge: int):
    for byte in challenge.to_bytes(8, "big"):
        dut.ui_in.value = byte
        await pulse_uio(dut, 0)


async def run_authentication(dut, challenge: int) -> int:
    await load_challenge(dut, challenge)
    await pulse_uio(dut, 1)
    assert (int(dut.uio_out.value) >> 7) & 1, "AUTH_BUSY did not assert"

    for _ in range(136):
        if (int(dut.uio_out.value) >> 2) & 1:
            break
        await RisingEdge(dut.clk)
        await settle()
    else:
        raise AssertionError("RESPONSE_VALID did not assert within 128 mixer cycles")

    assert not ((int(dut.uio_out.value) >> 7) & 1), "AUTH_BUSY stayed high"
    assert (int(dut.uio_out.value) >> 6) & 1, "AUTH_OK did not assert"

    response_bytes = [int(dut.uo_out.value)]
    for _ in range(7):
        await pulse_uio(dut, 0)
        assert (int(dut.uio_out.value) >> 2) & 1
        response_bytes.append(int(dut.uo_out.value))

    # Acknowledge the final response byte.
    await pulse_uio(dut, 0)
    assert not ((int(dut.uio_out.value) >> 2) & 1)
    assert int(dut.uo_out.value) == 0

    return int.from_bytes(response_bytes, "big")


@cocotb.test()
async def test_securekey(dut):
    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    await reset_dut(dut)
    assert int(dut.uio_oe.value) == 0xE4
    assert int(dut.uo_out.value) == 0
    assert int(dut.uio_out.value) == 0

    # An incomplete challenge must not start the authentication engine.
    dut.ui_in.value = 0x12
    await pulse_uio(dut, 0)
    dut.ui_in.value = 0x34
    await pulse_uio(dut, 0)
    await pulse_uio(dut, 1)
    assert not ((int(dut.uio_out.value) >> 7) & 1)
    assert not ((int(dut.uio_out.value) >> 2) & 1)

    await reset_dut(dut)

    # Published known-answer test vector.
    challenge = 0x2791A218447310CB
    expected = 0x9E169266A982792B
    assert compact_response(challenge) == expected
    response = await run_authentication(dut, challenge)
    assert response == expected, (
        f"response mismatch: expected {expected:016X}, got {response:016X}"
    )

    # Loading a new frame clears AUTH_OK.
    dut.ui_in.value = 0xAA
    await pulse_uio(dut, 0)
    assert not ((int(dut.uio_out.value) >> 6) & 1)

    await reset_dut(dut)

    # A second vector guards against a transform that only matches one input.
    zero_expected = 0x1A114BAD46E0AEE1
    assert compact_response(0) == zero_expected
    zero_response = await run_authentication(dut, 0)
    assert zero_response == zero_expected, (
        f"zero response mismatch: expected {zero_expected:016X}, "
        f"got {zero_response:016X}"
    )

    await reset_dut(dut)

    # Melody starts, toggles AUDIO_OUT, does not make AUTH_BUSY high, and stops.
    await pulse_uio(dut, 3)
    assert not ((int(dut.uio_out.value) >> 7) & 1)

    last_audio = (int(dut.uio_out.value) >> 5) & 1
    toggles = 0
    # The gate netlist has the production 10 MHz divider constants folded in.
    # Two E4 half-periods require about 30,302 clock cycles.
    timeout = 35_000 if os.getenv("GATES") == "yes" else 400
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        await settle()
        audio = (int(dut.uio_out.value) >> 5) & 1
        if audio != last_audio:
            toggles += 1
            last_audio = audio
            if toggles >= 2:
                break
    assert toggles >= 2, "AUDIO_OUT did not generate a square wave"

    await pulse_uio(dut, 4)
    assert not ((int(dut.uio_out.value) >> 5) & 1), "MUSIC_STOP did not mute audio"
