# Testbench for Montenegro SecureKey

This testbench uses [Cocotb](https://docs.cocotb.org/en/stable/) and Icarus
Verilog to verify the Tiny Tapeout design. It follows the test structure from
the official `ttsky-verilog-template`.

## RTL simulation

Install the packages from `requirements.txt`, then run:

```sh
make -B
```

The suite checks reset and pin directions, incomplete-frame rejection, the
64-bit known-answer authentication vector, response byte handshaking, and
melody start/tone/stop behavior.

## Gate-level simulation

First harden the project, then copy the powered SKY130 gate-level netlist to
`gate_level_netlist.v` as described by the
[Tiny Tapeout local-hardening guide](https://tinytapeout.com/guides/local-hardening/).
Run:

```sh
make -B GATES=yes
```

## Waveforms

The default output is `tb.fst`. Open it with either:

```sh
gtkwave tb.fst tb.gtkw
```

or:

```sh
surfer tb.fst
```

To generate VCD instead, change the dump filename in `tb.v` and run with an
empty `FST` variable.
