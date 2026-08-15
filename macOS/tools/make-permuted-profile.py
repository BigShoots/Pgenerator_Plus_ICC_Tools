#!/usr/bin/env python3
"""Build a deliberately wrong display profile, for one experiment.

The question it answers: does macOS colour-manage the Patch Companion's
CAMetalLayer? SDL only sets `layer.colorspace` for the scRGB path, so for an
ordinary SDR window the property is left alone, and it is not obvious from the
documentation whether WindowServer then converts our pixels into the display
profile or passes them through as device values.

That distinction decides what `system`, `clut` and `matrix` correction modes
mean on macOS, so it has to be settled by observation rather than by reading.

The test: take a real display profile, swap the red and green colorant tags,
and strip any vcgt so the GPU LUT cannot confound the result. Assign it, then
show a pure red patch.

    red patch turns green  -> macOS converts our pixels into the display
                              profile. Retagging the layer is both necessary
                              and sufficient, and clut/matrix mean what they
                              mean on Windows.
    red patch stays red    -> macOS hands our device values straight to the
                              panel. `system` then means "device values plus
                              vcgt", and clut/matrix would double-correct.

Usage:
    make-permuted-profile.py inspect SOURCE.icc
    make-permuted-profile.py build   SOURCE.icc OUTPUT.icc [--keep-vcgt|--minimal]

--keep-vcgt leaves the video card gamma table in place. Use it to separate the
two stages: vcgt is loaded into the GPU and applied after compositing, so it
reaches an unmanaged layer, whereas the ICC transform does not. With vcgt kept,
an unmanaged layer should measure the same under this profile as under the
display's own.
"""

import struct
import sys


def read_tag_table(data):
    """ICC layout: 128-byte header, then a uint32 tag count followed by
    12-byte (signature, offset, size) entries."""
    if len(data) < 132 or data[36:40] != b"acsp":
        raise ValueError("not an ICC profile")
    count = struct.unpack(">I", data[128:132])[0]
    tags = []
    for index in range(count):
        base = 132 + index * 12
        signature, offset, size = struct.unpack(">4sII", data[base:base + 12])
        tags.append((signature, offset, size))
    return tags


def inspect(path):
    data = open(path, "rb").read()
    tags = read_tag_table(data)
    print(f"{path}")
    print(f"  {len(data)} bytes, {len(tags)} tags, "
          f"class {data[12:16].decode('ascii', 'replace')}, "
          f"space {data[16:20].decode('ascii', 'replace')}")
    for signature, offset, size in tags:
        name = signature.decode("ascii", "replace")
        kind = data[offset:offset + 4].decode("ascii", "replace")
        extra = ""
        if name in ("rXYZ", "gXYZ", "bXYZ", "wtpt") and size >= 20:
            x, y, z = struct.unpack(">iii", data[offset + 8:offset + 20])
            extra = f"  X={x / 65536:.4f} Y={y / 65536:.4f} Z={z / 65536:.4f}"
        print(f"    {name}  type={kind}  offset={offset} size={size}{extra}")


def build_minimal(source_path, output_path):
    """Swap only the rXYZ and gXYZ tag signatures, in place.

    Every other byte is left exactly as it was: same tags, same offsets, same
    payloads, same length. This is the only version that isolates a single
    variable.

    The fuller build() rewrites the profile and drops Apple's private tags
    (aarg/aabg/aagg parametric gamma, ndin, mmod). Those may feed the GPU
    transfer table the way vcgt does, in which case dropping them changes what
    an unmanaged layer measures - a change to the GPU path, not the ICC path,
    which confounds the experiment entirely.
    """
    data = bytearray(open(source_path, "rb").read())
    tags = read_tag_table(data)

    swap = {b"rXYZ": b"gXYZ", b"gXYZ": b"rXYZ"}
    swapped = 0
    for index, (signature, _, _) in enumerate(tags):
        if signature not in swap:
            continue
        base = 132 + index * 12
        data[base:base + 4] = swap[signature]
        swapped += 1

    if swapped != 2:
        raise SystemExit(f"expected rXYZ and gXYZ; swapped {swapped} tag(s)")

    # The profile ID is an MD5 of the content; zero it rather than leave a
    # stale one, so ColorSync recomputes instead of matching a cached profile.
    data[84:100] = b"\x00" * 16
    open(output_path, "wb").write(bytes(data))
    print(f"wrote {output_path}  ({len(data)} bytes, byte-identical to the "
          "source except the two swapped tag signatures)")


def build(source_path, output_path, keep_vcgt=False):
    data = open(source_path, "rb").read()
    tags = read_tag_table(data)
    names = {signature for signature, _, _ in tags}

    for required in (b"rXYZ", b"gXYZ", b"bXYZ"):
        if required not in names:
            raise SystemExit(
                f"{source_path} has no {required.decode()} tag, so it is not a "
                "matrix/TRC profile and cannot be permuted this way. Pick a "
                "display profile that is.")

    # Swap the red and green colorant signatures so a colour-managed red
    # renders through green's colorant.
    swap = {b"rXYZ": b"gXYZ", b"gXYZ": b"rXYZ"}

    # Drop everything that could confound the observation:
    #   vcgt, vcgp  load the GPU transfer table, which would change the output
    #               independently of any conversion
    #   aarg/aabg/aagg  Apple's private parametric TRC tags, which macOS
    #               prefers over the standard rTRC/gTRC/bTRC curves - leaving
    #               them in risks the permutation being bypassed entirely
    #   ndin, mmod  Apple's native display information, which lets macOS
    #               reconstruct the real panel behaviour behind our back
    dropped = {b"vcgt", b"vcgp", b"aarg", b"aabg", b"aagg", b"ndin", b"mmod"}
    if keep_vcgt:
        # Leaving vcgt and vcgp in place isolates one variable. vcgt is loaded
        # into the GPU transfer table, which is applied after compositing and
        # so reaches even a layer macOS does not colour-manage - unlike the ICC
        # transform. Keeping it means the only thing changing between the
        # display's own profile and this one is the ICC path, so an unmanaged
        # layer should measure identically under both.
        dropped -= {b"vcgt", b"vcgp"}

    kept = [(swap.get(signature, signature), offset, size)
            for signature, offset, size in tags
            if signature not in dropped]
    kept.sort(key=lambda entry: entry[0])

    # Rebuild: header, tag table, then each tag's payload 4-byte aligned.
    table_size = 4 + len(kept) * 12
    body_offset = 128 + table_size
    body_offset += (-body_offset) % 4

    out = bytearray(data[:128])
    table = bytearray(struct.pack(">I", len(kept)))
    body = bytearray()

    for signature, offset, size in kept:
        payload_offset = body_offset + len(body)
        table += struct.pack(">4sII", signature, payload_offset, size)
        body += data[offset:offset + size]
        body += b"\x00" * ((-len(body)) % 4)

    out += table
    out += b"\x00" * (body_offset - len(out))
    out += body

    struct.pack_into(">I", out, 0, len(out))          # header size
    out[84:100] = b"\x00" * 16                        # profile ID: recomputed by ColorSync
    # Give it an obvious description so it is unmistakable in the Displays pane.
    open(output_path, "wb").write(bytes(out))

    print(f"wrote {output_path}  ({len(out)} bytes, {len(kept)} tags)")
    print("  red and green colorants swapped, vcgt "
          + ("kept" if keep_vcgt else "removed"))
    print("  a colour-managed red patch will render green through this profile")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    command = sys.argv[1]
    if command == "inspect":
        inspect(sys.argv[2])
    elif command == "build":
        args = [a for a in sys.argv[2:] if not a.startswith("--")]
        if len(args) < 2:
            print("build needs SOURCE and OUTPUT")
            return 2
        if "--minimal" in sys.argv:
            build_minimal(args[0], args[1])
        else:
            build(args[0], args[1], keep_vcgt="--keep-vcgt" in sys.argv)
    else:
        print(f"unknown command: {command}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
