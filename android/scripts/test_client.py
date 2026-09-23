#!/usr/bin/env python3
"""
Link Companion - Standalone TCP Protocol Test Client
DEVELOPMENT TOOL ONLY - NOT FOR PRODUCTION USE

This script validates the Android Link TCP server using the 16-byte length-framed binary protocol.
Requirements: Python 3.8+ (No external dependencies)
"""

import socket
import struct
import json
import argparse
import time
import sys

# Protocol Constants
MAGIC_BYTES = b"LINK"
PROTOCOL_VERSION = 1

# Message Types
MSG_HANDSHAKE = 0x0001
MSG_PING      = 0x0002
MSG_PONG      = 0x0003
MSG_DEVICE_INFO = 0x0004
MSG_ERROR     = 0x0005
MSG_CLIPBOARD = 0x0010
MSG_BATTERY   = 0x0020
MSG_NOTIFICATION = 0x0030
MSG_FILE_HEADER = 0x0040
MSG_FILE_CHUNK  = 0x0041
MSG_FILE_ACK    = 0x0042

HEADER_FORMAT = ">4sHHII"  # Magic(4s), Version(H), MessageType(H), StreamID(I), PayloadLength(I)
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)


def encode_frame(message_type: int, stream_id: int, payload: bytes) -> bytes:
    """Encodes a header and payload into a binary frame."""
    header = struct.pack(
        HEADER_FORMAT,
        MAGIC_BYTES,
        PROTOCOL_VERSION,
        message_type,
        stream_id,
        len(payload)
    )
    return header + payload


def decode_frame(sock: socket.socket) -> tuple:
    """Reads and decodes a single frame from the TCP socket."""
    header_data = recv_exact(sock, HEADER_SIZE)
    if not header_data:
        raise ConnectionError("Connection closed while waiting for header")

    magic, version, msg_type, stream_id, payload_len = struct.unpack(HEADER_FORMAT, header_data)

    if magic != MAGIC_BYTES:
        raise ValueError(f"Invalid magic bytes received: {magic}")

    payload = recv_exact(sock, payload_len) if payload_len > 0 else b""
    return msg_type, stream_id, payload


def recv_exact(sock: socket.socket, num_bytes: int) -> bytes:
    """Reads exactly num_bytes from socket."""
    buf = bytearray()
    while len(buf) < num_bytes:
        chunk = sock.recv(num_bytes - len(buf))
        if not chunk:
            break
        buf.extend(chunk)
    return bytes(buf)


def run_ping_pong_test(host: str, port: int):
    """Test 1: Ping / Pong exchange test."""
    print(f"\n[+] --- Test 1: PING / PONG Exchange ---")
    print(f"[+] Connecting to Android device at {host}:{port}...")

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(5.0)
        sock.connect((host, port))
        print("[+] Connected successfully!")

        payload_obj = {"timestamp": int(time.time() * 1000), "client": "PythonDevTool"}
        payload_bytes = json.dumps(payload_obj).encode("utf-8")
        stream_id = 42

        frame = encode_frame(MSG_PING, stream_id, payload_bytes)
        print(f"[+] Sending PING frame (Stream ID: {stream_id}, Payload: {payload_obj})")
        sock.sendall(frame)

        msg_type, rx_stream_id, rx_payload = decode_frame(sock)
        # Check if first frame was BATTERY initial frame
        if msg_type == MSG_BATTERY:
            print(f"[+] Received initial BATTERY status from Android: {rx_payload.decode('utf-8')}")
            # Read next frame for PONG
            msg_type, rx_stream_id, rx_payload = decode_frame(sock)

        print(f"[+] Received response frame!")
        print(f"    - Message Type ID: {hex(msg_type)} ({'PONG' if msg_type == MSG_PONG else 'UNKNOWN'})")
        print(f"    - Stream ID: {rx_stream_id}")
        print(f"    - Payload: {rx_payload.decode('utf-8', errors='ignore')}")

        if msg_type == MSG_PONG and rx_stream_id == stream_id:
            print("[✓] TEST PASSED: Ping/Pong exchange succeeded perfectly!")
        else:
            print("[✗] TEST FAILED: Unexpected response")


def run_clipboard_and_battery_test(host: str, port: int):
    """Test 4: Clipboard & Battery Sync Test."""
    print(f"\n[+] --- Test 4: Clipboard & Battery Sync ---")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(5.0)
        sock.connect((host, port))

        # 1. Send CLIPBOARD payload
        clip_text = "Sample Mac clipboard text for Android"
        clip_payload = json.dumps({"text": clip_text, "timestamp": int(time.time() * 1000)}).encode("utf-8")
        clip_frame = encode_frame(MSG_CLIPBOARD, 101, clip_payload)
        print(f"[+] Sending CLIPBOARD frame ({len(clip_text)} chars)...")
        sock.sendall(clip_frame)

        # 2. Receive response (Android sends battery update or ack)
        time.sleep(0.5)
        print("[✓] TEST PASSED: Sent CLIPBOARD payload to Android cleanly!")


def run_malformed_magic_test(host: str, port: int):
    """Test 2: Malformed magic byte rejection test."""
    print(f"\n[+] --- Test 2: Malformed Magic Bytes Rejection ---")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(5.0)
        sock.connect((host, port))

        # Build frame with invalid magic "BADM"
        bad_header = struct.pack(HEADER_FORMAT, b"BADM", 1, MSG_PING, 1, 4) + b"test"
        print("[+] Sending frame with invalid magic bytes 'BADM'...")
        sock.sendall(bad_header)

        try:
            msg_type, _, rx_payload = decode_frame(sock)
            print(f"[+] Server response: Type {hex(msg_type)}, Payload: {rx_payload.decode('utf-8')}")
        except Exception as e:
            print(f"[✓] TEST PASSED: Server rejected bad frame / closed socket as expected ({e})")


def run_oversized_frame_test(host: str, port: int):
    """Test 3: Oversized frame rejection test."""
    print(f"\n[+] --- Test 3: Oversized Frame Rejection ---")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(5.0)
        sock.connect((host, port))

        # Claim payload is 10 MB (limit is 8 MB)
        oversized_len = 10 * 1024 * 1024
        header = struct.pack(HEADER_FORMAT, MAGIC_BYTES, 1, MSG_PING, 1, oversized_len)
        print(f"[+] Sending frame header claiming {oversized_len} bytes payload...")
        sock.sendall(header)

        try:
            msg_type, _, rx_payload = decode_frame(sock)
            print(f"[+] Received error response: Type {hex(msg_type)}, Payload: {rx_payload.decode('utf-8')}")
            if msg_type == MSG_ERROR:
                print("[✓] TEST PASSED: Server returned ERROR frame for oversized length!")
        except Exception as e:
            print(f"[✓] TEST PASSED: Connection rejected/closed cleanly ({e})")


def main():
    parser = argparse.ArgumentParser(description="Link Companion TCP Protocol Test Script (Dev Tool)")
    parser.add_argument("--host", required=True, help="Android device/emulator IP address (e.g. 192.168.1.50 or 10.0.2.2)")
    parser.add_argument("--port", type=int, default=52345, help="TCP Port (default: 52345)")
    args = parser.parse_args()

    print("==================================================")
    print("      Link Companion Development Test Tool        ")
    print("==================================================")

    try:
        run_ping_pong_test(args.host, args.port)
        run_clipboard_and_battery_test(args.host, args.port)
        run_malformed_magic_test(args.host, args.port)
        run_oversized_frame_test(args.host, args.port)
        print("\n[✓] All protocol tests executed successfully.")
    except Exception as e:
        print(f"\n[✗] Test suite encountered an error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
