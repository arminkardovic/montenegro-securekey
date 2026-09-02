#!/usr/bin/env python3
"""Reference model for the Montenegro SecureKey demonstration transform."""

import argparse


DEVICE_ID = 0x45490001
DEVICE_MIX = ((DEVICE_ID & 0xFFFF) << 16) | (DEVICE_ID >> 16)
DEMO_KEY = 0xA91B82C771EF1234
ROUND_SECRET = DEMO_KEY ^ ((DEVICE_ID << 32) | DEVICE_MIX)
MASK64 = 0xFFFFFFFFFFFFFFFF


def securekey_response(challenge: int) -> int:
    if not 0 <= challenge <= 0xFFFFFFFFFFFFFFFF:
        raise ValueError("challenge must fit in 64 bits")

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
