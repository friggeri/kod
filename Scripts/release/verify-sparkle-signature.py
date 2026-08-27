#!/usr/bin/env python3
"""Strictly verify Sparkle Ed25519 enclosure signatures without dependencies."""

from __future__ import annotations

import argparse
import base64
import hashlib
import sys
import xml.etree.ElementTree as element_tree
from pathlib import Path

FIELD_PRIME = 2**255 - 19
GROUP_ORDER = 2**252 + 27742317777372353535851937790883648493
CURVE_D = (-121665 * pow(121666, FIELD_PRIME - 2, FIELD_PRIME)) % FIELD_PRIME
SQRT_MINUS_ONE = pow(2, (FIELD_PRIME - 1) // 4, FIELD_PRIME)
IDENTITY = (0, 1)


class VerificationError(ValueError):
    pass


def inverse(value: int) -> int:
    return pow(value, FIELD_PRIME - 2, FIELD_PRIME)


def recover_x(y: int, sign: int) -> int:
    x_squared = (y * y - 1) * inverse(CURVE_D * y * y + 1) % FIELD_PRIME
    x = pow(x_squared, (FIELD_PRIME + 3) // 8, FIELD_PRIME)
    if (x * x - x_squared) % FIELD_PRIME:
        x = x * SQRT_MINUS_ONE % FIELD_PRIME
    if (x * x - x_squared) % FIELD_PRIME:
        raise VerificationError("encoded point is not on the Ed25519 curve")
    if x & 1 != sign:
        x = FIELD_PRIME - x
    return x


def decode_point(encoded: bytes) -> tuple[int, int]:
    if len(encoded) != 32:
        raise VerificationError("Ed25519 public key or point must be exactly 32 bytes")
    value = int.from_bytes(encoded, "little")
    sign = value >> 255
    y = value & ((1 << 255) - 1)
    if y >= FIELD_PRIME:
        raise VerificationError("Ed25519 point is not canonically encoded")
    point = (recover_x(y, sign), y)
    if encode_point(point) != encoded:
        raise VerificationError("Ed25519 point is not canonically encoded")
    return point


def encode_point(point: tuple[int, int]) -> bytes:
    x, y = point
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def add_points(first: tuple[int, int], second: tuple[int, int]) -> tuple[int, int]:
    x1, y1 = first
    x2, y2 = second
    denominator_x = inverse(1 + CURVE_D * x1 * x2 * y1 * y2 % FIELD_PRIME)
    denominator_y = inverse(1 - CURVE_D * x1 * x2 * y1 * y2 % FIELD_PRIME)
    return (
        (x1 * y2 + x2 * y1) * denominator_x % FIELD_PRIME,
        (y1 * y2 + x1 * x2) * denominator_y % FIELD_PRIME,
    )


def scalar_multiply(point: tuple[int, int], scalar: int) -> tuple[int, int]:
    result = IDENTITY
    while scalar:
        if scalar & 1:
            result = add_points(result, point)
        point = add_points(point, point)
        scalar >>= 1
    return result


BASE_POINT = (recover_x(4 * inverse(5) % FIELD_PRIME, 0), 4 * inverse(5) % FIELD_PRIME)


def is_small_order(point: tuple[int, int]) -> bool:
    return scalar_multiply(point, 8) == IDENTITY


def decode_base64(value: str, label: str, expected_length: int) -> bytes:
    try:
        decoded = base64.b64decode(value.strip(), validate=True)
    except ValueError as error:
        raise VerificationError(f"{label} is not canonical base64") from error
    if len(decoded) != expected_length:
        raise VerificationError(f"{label} must be exactly {expected_length} bytes")
    return decoded


def verify_signature(public_key: bytes, message: bytes, signature: bytes) -> None:
    if len(signature) != 64:
        raise VerificationError("Ed25519 signature must be exactly 64 bytes")
    public_point = decode_point(public_key)
    encoded_r = signature[:32]
    r_point = decode_point(encoded_r)
    scalar_s = int.from_bytes(signature[32:], "little")
    if scalar_s >= GROUP_ORDER:
        raise VerificationError("Ed25519 signature scalar is not canonical")
    if is_small_order(public_point) or is_small_order(r_point):
        raise VerificationError("Ed25519 public key or signature point has small order")
    challenge = int.from_bytes(
        hashlib.sha512(encoded_r + public_key + message).digest(), "little"
    ) % GROUP_ORDER
    if scalar_multiply(BASE_POINT, scalar_s) != add_points(
        r_point, scalar_multiply(public_point, challenge)
    ):
        raise VerificationError("Ed25519 signature verification failed")


def local_name(name: str) -> str:
    return name.rsplit("}", 1)[-1]


def sparkle_attribute(element: element_tree.Element, name: str) -> str | None:
    values = [value for key, value in element.attrib.items() if local_name(key) == name]
    if len(values) > 1:
        raise VerificationError(f"appcast enclosure contains duplicate {name} attributes")
    return values[0] if values else None


def verify_appcast(public_key: bytes, appcast: Path, archive: Path, expected_url: str) -> None:
    try:
        root = element_tree.parse(appcast).getroot()
    except (OSError, element_tree.ParseError) as error:
        raise VerificationError(f"unable to parse appcast: {error}") from error
    enclosures = [
        element
        for element in root.iter()
        if local_name(element.tag) == "enclosure" and element.attrib.get("url") == expected_url
    ]
    if len(enclosures) != 1:
        raise VerificationError("appcast must contain exactly one enclosure for the expected archive URL")
    enclosure = enclosures[0]
    signature = sparkle_attribute(enclosure, "edSignature")
    if signature is None:
        raise VerificationError("appcast enclosure does not contain sparkle:edSignature")
    length = enclosure.attrib.get("length")
    if length is None or not length.isdecimal() or int(length) != archive.stat().st_size:
        raise VerificationError("appcast enclosure length does not match the archive")
    verify_signature(
        public_key,
        archive.read_bytes(),
        decode_base64(signature, "Sparkle enclosure signature", 64),
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public-key", required=True, help="base64-encoded SUPublicEDKey")
    parser.add_argument("--file", type=Path, help="file signed by --signature")
    parser.add_argument("--signature", help="base64-encoded Ed25519 signature for --file")
    parser.add_argument("--appcast", type=Path, help="Sparkle appcast to inspect")
    parser.add_argument("--archive", type=Path, help="archive referenced by --appcast")
    parser.add_argument("--expected-url", help="exact archive URL expected in --appcast")
    arguments = parser.parse_args()
    direct_mode = arguments.file is not None or arguments.signature is not None
    appcast_mode = any(
        value is not None for value in (arguments.appcast, arguments.archive, arguments.expected_url)
    )
    if direct_mode == appcast_mode:
        parser.error("use either --file and --signature or --appcast, --archive, and --expected-url")
    if direct_mode and (arguments.file is None or arguments.signature is None):
        parser.error("--file and --signature must be used together")
    if appcast_mode and (
        arguments.appcast is None or arguments.archive is None or arguments.expected_url is None
    ):
        parser.error("--appcast, --archive, and --expected-url must be used together")
    return arguments


def main() -> int:
    arguments = parse_arguments()
    try:
        public_key = decode_base64(arguments.public_key, "SUPublicEDKey", 32)
        if arguments.file is not None:
            verify_signature(
                public_key,
                arguments.file.read_bytes(),
                decode_base64(arguments.signature, "Ed25519 signature", 64),
            )
        else:
            if not arguments.archive.is_file():
                raise VerificationError(f"archive does not exist: {arguments.archive}")
            verify_appcast(public_key, arguments.appcast, arguments.archive, arguments.expected_url)
    except (OSError, VerificationError) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 65
    print("==> Sparkle Ed25519 signature verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
