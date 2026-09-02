[![GDS](https://github.com/arminkardovic/montenegro-securekey/actions/workflows/gds.yaml/badge.svg)](https://github.com/arminkardovic/montenegro-securekey/actions/workflows/gds.yaml)
[![Docs](https://github.com/arminkardovic/montenegro-securekey/actions/workflows/docs.yaml/badge.svg)](https://github.com/arminkardovic/montenegro-securekey/actions/workflows/docs.yaml)
[![Tests](https://github.com/arminkardovic/montenegro-securekey/actions/workflows/test.yaml/badge.svg)](https://github.com/arminkardovic/montenegro-securekey/actions/workflows/test.yaml)

# Montenegro SecureKey

Montenegro SecureKey is a Tiny Tapeout educational ASIC that combines two
independent functions:

1. a byte-serial, 64-bit challenge/response hardware-licensing demonstration;
2. a 48-note monophonic approximation of the opening part of Montenegro's
   national anthem, *Oj, svijetla majska zoro*.

The project is implemented directly in synthesizable Verilog. It uses a 10 MHz
clock and is configured for a `2x2` Tiny Tapeout tile.

> **Security warning:** this is an open-source proof of concept, not a secure
> element. The fixed XTEA key and fixed device ID are visible in the RTL and
> are identical in every manufactured copy. Do not use this implementation to
> protect a real commercial product.

## Architecture

```text
                            Montenegro SecureKey
                    +--------------------------------+
DATA[7:0] ---------->|  8-byte challenge register   |
DATA_LOAD ---------->|  32-round XTEA demo engine   |----> RESPONSE[7:0]
AUTH_START ----------|  fixed key + fixed device ID |----> VALID/OK/BUSY
                    |                                |
MUSIC_START -------->|  48-entry melody ROM         |
MUSIC_STOP --------->|  note timer + tone divider   |----> AUDIO_OUT
                    +--------------------------------+
```

The authentication and melody state machines can run at the same time. The
authentication engine takes exactly 32 calculation clocks after a valid start.
The music engine stores note numbers and durations, not sampled audio.

## Pinout

| Tiny Tapeout pins | Direction | Function |
| --- | --- | --- |
| `ui_in[7:0]` | input | Challenge byte data, loaded MSB-first |
| `uo_out[7:0]` | output | Current response byte; zero when invalid |
| `uio[0]` | input | `DATA_LOAD` while receiving; `RESPONSE_NEXT` while transmitting |
| `uio[1]` | input | `AUTH_START` |
| `uio[2]` | output | `RESPONSE_VALID` |
| `uio[3]` | input | `MUSIC_START` |
| `uio[4]` | input | `MUSIC_STOP` |
| `uio[5]` | output | `AUDIO_OUT`, 1-bit square wave |
| `uio[6]` | output | `AUTH_OK`, valid frame was processed |
| `uio[7]` | output | `AUTH_BUSY` |
| `clk` | input | 10 MHz design clock |
| `rst_n` | input | Active-low synchronous reset |
| `ena` | input | Tiny Tapeout project enable; intentionally ignored |

The `uio_oe` mask is always `0xE4`: only `uio[2]`, `uio[5]`, `uio[6]`, and
`uio[7]` are driven by the ASIC. A controller must never drive those four pins.

## Authentication protocol

All control signals are rising-edge detected. Hold each control pulse high
across at least one rising edge of `clk`, then return it low for at least one
rising edge. Keep `ui_in` stable around the `DATA_LOAD` edge.

1. Apply `rst_n=0` for at least two clock cycles, then set `rst_n=1`.
2. Put challenge byte 0, the most-significant byte, on `ui_in[7:0]` and pulse
   `DATA_LOAD` on `uio[0]`.
3. Repeat for bytes 1 through 7. Exactly eight bytes are required.
4. Pulse `AUTH_START` on `uio[1]`.
5. Wait while `AUTH_BUSY` is high. An incomplete frame is rejected and does
   not raise `AUTH_BUSY`.
6. When `RESPONSE_VALID` goes high, read response byte 0 from `uo_out[7:0]`.
7. Pulse `RESPONSE_NEXT` (`uio[0]`) before reading each of bytes 1 through 7.
8. After reading byte 7, pulse `RESPONSE_NEXT` once more to acknowledge it and
   clear `RESPONSE_VALID`.
9. The host calculates the expected response and compares all 64 bits. Only
   the host should make the real `LICENSE_OK` decision.

`AUTH_OK` means that the ASIC accepted a complete frame and generated a
response. It does **not** mean that a host has verified the response.

### Demonstration transform

The 64-bit challenge is whitened with `DEVICE_ID`, encrypted with 32 rounds of
XTEA using the fixed 128-bit demo key, then whitened again:

```text
DEVICE_ID = 0x45490001
DEMO_KEY  = 0xA91B82C771EF12346D6F6E74656E6567
```

Known-answer vector:

| Challenge | Response |
| --- | --- |
| `2791A218447310CB` | `9CDECC9AB218FD6A` |

The dependency-free host model in
[`examples/securekey_reference.py`](examples/securekey_reference.py) can
calculate additional expected responses.

## Melody demo

Pulse `MUSIC_START` on `uio[3]` to restart the melody from note zero. Pulse
`MUSIC_STOP` on `uio[4]` to stop immediately and force `AUDIO_OUT` low. At the
nominal 10 MHz clock, each duration unit is 125 ms and the tone table spans D4
through A5. Changing the clock changes both pitch and tempo proportionally.

`AUDIO_OUT` is a digital logic signal. Do not connect a low-impedance speaker
or a large piezo load directly to a Tiny Tapeout pin. Use a suitable
transistor/MOSFET driver, current limiting where appropriate, and a shared
ground. An oscilloscope or logic analyzer can test the output without sound.

## Run the verification

Install Icarus Verilog, Python 3.11, and the Python packages from
`test/requirements.txt`, then run:

```sh
cd test
make clean
make
```

The Cocotb test verifies:

- reset values and the `uio_oe` direction mask;
- rejection of an incomplete challenge;
- busy/valid/acknowledge handshaking;
- all eight response bytes against both a software model and a fixed known
  answer;
- clearing `AUTH_OK` for a new transaction;
- melody start, square-wave generation, independence from `AUTH_BUSY`, and
  immediate stop/mute.

GitHub Actions runs the same RTL test on every push. The GDS workflow then
synthesizes and hardens the design with LibreLane and runs Tiny Tapeout
precheck. Before submitting, both `test` and `gds`/`precheck` must be green and
the generated layout/timing reports must be reviewed.

## Why this is not production security

- The demo key is committed to a public repository and can be extracted from
  RTL, netlist, or layout.
- `DEVICE_ID` is a build-time constant, so it is not unique per physical die.
- XTEA is used here for compact educational logic and has not been selected or
  reviewed for this product's security requirements.
- There is no OTP/eFuse/PUF storage, tamper resistance, side-channel
  protection, monotonic counter, or on-chip replay database.
- Replay resistance depends on the host generating unpredictable, non-reused
  challenges and applying an appropriate policy.

A commercial revision should use a reviewed authentication construction and
inject a unique secret during trusted manufacturing, for example through
protected OTP/eFuse storage. It also needs threat modeling, side-channel and
fault-injection review, secure firmware, and independent security testing.

## Tiny Tapeout resources

- [Project datasheet](docs/info.md)
- [Tiny Tapeout](https://tinytapeout.com/)
- [Tiny Tapeout FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Local hardening guide](https://www.tinytapeout.com/guides/local-hardening/)
- [Submit to a shuttle](https://app.tinytapeout.com/)

Enable GitHub Pages for the repository so the `docs` and `gds` workflows can
publish the generated project page and layout viewer.

## License

Apache-2.0. See [LICENSE](LICENSE).
