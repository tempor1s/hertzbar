#!/usr/bin/env python3
"""Inspect and edit the DisplayID "Type I" detailed timings inside an EDID.

Most modern high-refresh monitors (and many 5K/ultrawide ones) list their
high-res timings in a DisplayID extension block rather than the legacy
EDID/CTA blocks. This tool lets you add or change those timings so macOS
offers new refresh rates, then fixes up all checksums.

  show  EDID                         list every Type I timing (and the pixel clock it needs)
  add   EDID OUT --width W --height H --hz R [--hblank 80 --vblank 62]
                                     append a new timing (uses free padding in the block)
  set   EDID OUT --index N --hz R [...]
                                     rewrite timing N (as numbered by `show`)
  scrub EDID OUT                     blank the serial number fields (for sharing)

Defaults use CVT-RB2-style reduced blanking: hblank 80 px, vblank 62 lines.
If the monitor shows no picture with a timing, try a larger --vblank.

Example (Dell U4025QW, 5120x2160):
  python3 tools/edid_timing.py add factory.edid out.edid --width 5120 --height 2160 --hz 100
"""
import argparse
import sys

EDID_HEADER = bytes([0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0])
TYPE1 = 0x03       # DisplayID 1.x "Type I detailed timing" data block tag
DESC_LEN = 20      # bytes per Type I descriptor


def displayid_sections(b):
    """Yield the offset of every DisplayID extension block (tag 0x70)."""
    for off in range(128, len(b), 128):
        if b[off] == 0x70:
            yield off


def type1_blocks(b, did):
    """Yield (header_offset, payload_len) for each Type I data block in a DisplayID section."""
    i, end = did + 5, did + 5 + b[did + 2]
    while i + 3 <= end:
        tag, ln = b[i], b[i + 2]
        if tag == TYPE1:
            yield i, ln
        if tag == 0 and ln == 0 and not any(b[i:end]):
            break  # zero padding to the end of the section
        i += 3 + ln


def descriptors(b):
    for did in displayid_sections(b):
        for hdr, ln in type1_blocks(b, did):
            for d in range(hdr + 3, hdr + 3 + ln, DESC_LEN):
                yield d


def decode(b, o):
    u16 = lambda x: b[x] | (b[x + 1] << 8)
    pclk = ((b[o] | b[o + 1] << 8 | b[o + 2] << 16) + 1) * 10_000
    ha, hb = (u16(o + 4) & 0x7FFF) + 1, (u16(o + 6) & 0x7FFF) + 1
    va, vb = (u16(o + 12) & 0x7FFF) + 1, (u16(o + 14) & 0x7FFF) + 1
    return pclk, ha, hb, va, vb, pclk / ((ha + hb) * (va + vb))


def encode(w, h, hz, hblank, vblank, flags=0x06):
    """20-byte Type I descriptor. flags 0x06: aspect ratio "undefined", not marked preferred."""
    pclk = round((w + hblank) * (h + vblank) * hz / 10_000) - 1
    le = lambda v: v.to_bytes(2, "little")
    return bytes([pclk & 0xFF, pclk >> 8 & 0xFF, pclk >> 16 & 0xFF, flags]) + \
        le(w - 1) + le(hblank - 1) + le(0x8000 | 7) + le(31) + \
        le(h - 1) + le(vblank - 1) + le(2) + le(9)
        # h front porch 8 (+hsync), h sync 32, v front porch 3, v sync 10


def fix_checksums(b):
    for did in displayid_sections(b):
        n = b[did + 2]
        b[did + 5 + n] = (-sum(b[did + 1:did + 5 + n])) & 0xFF   # DisplayID section checksum
    for blk in range(0, len(b), 128):
        b[blk + 127] = (-sum(b[blk:blk + 127])) & 0xFF           # EDID block checksum


def load(path):
    b = bytearray(open(path, "rb").read())
    if b[:8] != EDID_HEADER or len(b) % 128:
        sys.exit(f"{path}: not a raw EDID (expected 128-byte blocks starting with the EDID header)")
    return b


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["show", "add", "set", "scrub"])
    ap.add_argument("src")
    ap.add_argument("dst", nargs="?")
    ap.add_argument("--width", type=int)
    ap.add_argument("--height", type=int)
    ap.add_argument("--hz", type=float)
    ap.add_argument("--hblank", type=int, default=80)
    ap.add_argument("--vblank", type=int, default=62)
    ap.add_argument("--index", type=int, help="timing number from `show` (for set)")
    a = ap.parse_args()
    b = load(a.src)
    descs = list(descriptors(b))

    if a.cmd == "show":
        if not descs:
            print("No DisplayID Type I timings found (this EDID keeps its timings elsewhere).")
        for n, o in enumerate(descs):
            pclk, ha, hb, va, vb, hz = decode(b, o)
            print(f"[{n}] {ha}x{va} @ {hz:.2f} Hz   pixel clock {pclk / 1e6:.2f} MHz   (hblank {hb}, vblank {vb})")
        return

    if not a.dst:
        sys.exit("need an output path")

    if a.cmd == "scrub":
        b[12:16] = bytes(4)                               # 32-bit serial number
        for off in range(54, 109, 18):                    # "display serial number" text descriptor
            if b[off:off + 4] == bytes([0, 0, 0, 0xFF]):
                b[off + 5:off + 18] = b"0\n" + b" " * 11
        print("blanked serial number fields")

    elif a.cmd == "set":
        if a.index is None or not 0 <= a.index < len(descs):
            sys.exit("--index must be one of the numbers printed by `show`")
        o = descs[a.index]
        _, ha, _, va, _, _ = decode(b, o)
        w, h = a.width or ha, a.height or va
        b[o:o + DESC_LEN] = encode(w, h, a.hz, a.hblank, a.vblank, b[o + 3])
        pclk, *_, hz = decode(b, o)
        print(f"timing [{a.index}] -> {w}x{h} @ {hz:.2f} Hz, pixel clock {pclk / 1e6:.2f} MHz")

    elif a.cmd == "add":
        if not (a.width and a.height and a.hz):
            sys.exit("add needs --width, --height and --hz")
        did = next(displayid_sections(b), None)
        blk = next(type1_blocks(b, did), None) if did is not None else None
        if blk is None:
            sys.exit("no DisplayID Type I block to extend")
        hdr, ln = blk
        end_of_block = hdr + 3 + ln
        section_end = did + 5 + b[did + 2]
        # Need 20 bytes of zero padding at the end of the section to shift into.
        if any(b[section_end - DESC_LEN:section_end]):
            sys.exit("no free space left in the DisplayID section for another timing")
        tail = b[end_of_block:section_end - DESC_LEN]
        b[end_of_block:section_end] = encode(a.width, a.height, a.hz, a.hblank, a.vblank) + tail
        b[hdr + 2] = ln + DESC_LEN
        o = end_of_block
        print(f"added {a.width}x{a.height} @ {decode(b, o)[5]:.2f} Hz, pixel clock {decode(b, o)[0] / 1e6:.2f} MHz")

    fix_checksums(b)
    open(a.dst, "wb").write(b)
    print("wrote", a.dst)


if __name__ == "__main__":
    main()
