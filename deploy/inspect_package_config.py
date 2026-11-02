"""Extract store_config.json from a built portable package and verify it.

The package blob is a custom format written by libs/portable/generate.py:

    "rustdesk"
    per file: path_len(4, big endian) | path | data_len(4) | brotli(data) | md5(32)
    "rustdesk"
    exe path

The payload may live in the embedded data.bin section or in the RDPKG
resource; this script scans the whole file for the marker and parses the
first blob it can decode.
"""
import io
import sys

try:
    import brotli
except ImportError:
    print('brotli module missing: pip install brotli')
    sys.exit(2)

LENGTH = 4
IDENTIFIER = b'rustdesk'
MD5_LENGTH = 32


def parse_blob(data, start):
    """Parse one blob beginning at start. Returns (files, exe, end) or None."""
    if data[start:start + len(IDENTIFIER)] != IDENTIFIER:
        return None
    pos = start + len(IDENTIFIER)
    files = []
    while True:
        if data[pos:pos + len(IDENTIFIER)] == IDENTIFIER:
            pos += len(IDENTIFIER)
            break
        path_len = int.from_bytes(data[pos:pos + LENGTH], 'big')
        pos += LENGTH
        path = data[pos:pos + path_len].decode('utf-8', 'replace')
        pos += path_len
        data_len = int.from_bytes(data[pos:pos + LENGTH], 'big')
        pos += LENGTH
        blob = data[pos:pos + data_len]
        pos += data_len
        pos += MD5_LENGTH
        try:
            raw = brotli.decompress(blob)
        except Exception:
            return None
        files.append((path, raw))
    return files, data[pos:].split(b'\x00')[0].decode('utf-8', 'replace'), pos


def find_configs(pkg_path):
    data = open(pkg_path, 'rb').read()
    out = []
    idx = 0
    while True:
        idx = data.find(IDENTIFIER, idx)
        if idx < 0:
            break
        parsed = parse_blob(data, idx)
        if parsed:
            files, exe, _ = parsed
            out.append((files, exe))
            idx += 1
        else:
            idx += 1
    return out


def main():
    pkg = sys.argv[1]
    for files, exe in find_configs(pkg):
        hits = [(p, c) for p, c in files if p.lower().endswith('store_config.json')]
        if not hits:
            continue
        print('=== store_config.json found in package ===')
        for path, content in hits:
            print('path:', path)
            print(content.decode('utf-8', 'replace'))
        return 0
    print('store_config.json NOT found in package')
    return 1


if __name__ == '__main__':
    sys.exit(main())
