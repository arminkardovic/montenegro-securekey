## How it works

Montenegro SecureKey contains two independent synchronous engines.

The authentication engine receives a 64-bit challenge as eight bytes on
`ui_in[7:0]`. Bytes are loaded most-significant first by rising edges on
`uio[0]`. After exactly eight bytes, a rising edge on `uio[1]` starts a
32-round XTEA demonstration transform. A fixed 32-bit device ID is mixed into
the input and output, and the key is a fixed 128-bit constant in the public
RTL. `uio[7]` is high during calculation. When finished, `uio[2]` and `uio[6]`
go high and the first response byte appears on `uo_out[7:0]`. Further rising
edges on `uio[0]` advance through the remaining seven response bytes; one final
edge acknowledges byte 7 and clears `uio[2]`.

The melody engine contains a 48-entry note/duration ROM approximating the
opening section of *Oj, svijetla majska zoro*. A programmable divider converts
the nominal 10 MHz clock into musical square waves on `uio[5]`. `uio[3]`
starts or restarts playback and `uio[4]` stops and mutes it. Authentication and
music can run concurrently.

This is an educational proof of concept. The public key and device ID are not
secrets or unique per die, and `AUTH_OK` only reports that a complete local
transaction was processed. The host must compare the response. The design is
not suitable as a production secure element.

## How to test

Use a 10 MHz clock and hold `rst_n` low for at least two rising clock edges.
After releasing reset, verify `uio_oe == 0xE4` and all status outputs are low.

For the published authentication vector, load the bytes `27 91 A2 18 44 73 10
CB` in that order. Hold each byte on `ui_in`, pulse `uio[0]` high for one clock,
then pulse `uio[1]`. `uio[7]` must be high for the calculation. When `uio[2]`
goes high, read the first response byte and pulse `uio[0]` to advance each
following byte. The eight bytes must be `9C DE CC 9A B2 18 FD 6A`. Pulse
`uio[0]` once more after the last byte to clear `uio[2]`.

To test the demo mode, pulse `uio[3]`. Observe a square wave on `uio[5]` with
an oscilloscope or through a properly buffered piezo driver. Pulse `uio[4]` and
verify that `uio[5]` immediately stays low. Do not attach a speaker or other
low-impedance load directly to the ASIC pin.

The automated Cocotb suite in `test/test.py` covers reset, I/O directions,
invalid frames, the known-answer vector, byte handshaking, and music start/stop.
Run it with `cd test && make clean && make` after installing Icarus Verilog and
the packages in `test/requirements.txt`.

## External hardware

Authentication testing needs a controller or logic analyzer capable of driving
the synchronous byte/control protocol. Audible playback needs a piezo element
and an appropriate transistor/MOSFET driver stage; the Tiny Tapeout output pin
must not supply the transducer current directly.
