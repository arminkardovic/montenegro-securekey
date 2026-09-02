#!/usr/bin/env python3
"""Reference model for the Montenegro SecureKey demonstration transform."""

import argparse


DEVICE_ID = 0x45490001
DEVICE_MIX = ((DEVICE_ID & 0xFFFF) << 16) | (DEVICE_ID >> 16)
DEMO_KEY = (0xA91B82C7, 0x71EF1234, 0x6D6F6E74, 0x656E6567)
MASK32 = 0xFFFFFFFF


def securekey_response(challenge: int) -> int:
    if not 0 <= challenge <= 0xFFFFFFFFFFFFFFFF:
        raise ValueError("challenge must fit in 64 bits")

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


def parse_challenge(value: str) -> int:
    cleaned = value.removeprefix("0x").replace("_", "")
    if len(cleaned) > 16:
        raise argparse.ArgumentTypeError("challenge must contain at most 16 hex digits")
    try:
        return int(cleaned, 16)
    except ValueError as error:
        raise argparse.ArgumentTypeError("challenge must be hexadecimal") from error


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Calculate a Montenegro SecureKey demo response"
    )
    parser.add_argument("challenge", type=parse_challenge, help="64-bit hex challenge")
    args = parser.parse_args()
    print(f"{securekey_response(args.challenge):016X}")


if __name__ == "__main__":
    main()
