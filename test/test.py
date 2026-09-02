# SPDX-FileCopyrightText: 2026 Armin
# SPDX-License-Identifier: Apache-2.0

import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer


DEVICE_ID = 0x45490001
DEVICE_MIX = ((DEVICE_ID & 0xFFFF) << 16) | (DEVICE_ID >> 16)
DEMO_KEY = (0xA91B82C7, 0x71EF1234, 0x6D6F6E74, 0x656E6567)
MASK32 = 0xFFFFFFFF


def xtea_response(challenge: int) -> int:
    """Independent software model of the documented demo transform."""
    v0 = ((challenge >> 32) ^ DEVICE_ID) & MASK32
    v1 = ((challenge & MASK32) ^ DEVICE_MIX) & MASK32
    total = 0

    for _ in range(32):
        mix0 = ((((v1 << 4) ^ (v1 >> 5)) + v1) & MASK32) ^ (
            (total + DEMO_KEY[total & 3]) & MASK32
        )
        v0 = (v0 + mix0) & MASK32
        total = (total + 0x9E3779B9) & MASK32
        mix1 = ((((v0 << 4) ^ (v0 >> 5)) + v0) & MASK32) ^ (
            (total + DEMO_KEY[(total >> 11) & 3]) & MASK32
        )
        v1 = (v1 + mix1) & MASK32

    return (((v0 ^ DEVICE_ID) & MASK32) << 32) | ((v1 ^ DEVICE_MIX) & MASK32)


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

    for _ in range(40):
        if (int(dut.uio_out.value) >> 2) & 1:
            break
        await RisingEdge(dut.clk)
        await settle()
    else:
        raise AssertionError("RESPONSE_VALID did not assert within 32 XTEA rounds")

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
    expected = 0x9CDECC9AB218FD6A
    assert xtea_response(challenge) == expected
    response = await run_authentication(dut, challenge)
    assert response == expected, (
        f"response mismatch: expected {expected:016X}, got {response:016X}"
    )

    # Loading a new frame clears AUTH_OK.
    dut.ui_in.value = 0xAA
    await pulse_uio(dut, 0)
    assert not ((int(dut.uio_out.value) >> 6) & 1)

    await reset_dut(dut)

    # Melody starts, toggles AUDIO_OUT, does not make AUTH_BUSY high, and stops.
    await pulse_uio(dut, 3)
    assert not ((int(dut.uio_out.value) >> 7) & 1)

    last_audio = (int(dut.uio_out.value) >> 5) & 1
    toggles = 0
    # The gate netlist has the production 10 MHz divider constants folded in.
    # Two A4 half-periods require about 22,726 clock cycles.
    timeout = 30_000 if os.getenv("GATES") == "yes" else 400
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
