"""Read files out of an AppImage without running it.

A type 2 AppImage is an ELF runtime with a squashfs image appended. The usual
way to look inside is `--appimage-extract`, which executes that runtime: the
file's own code, chosen by whoever built it. That is fine once someone has
decided to install the thing, and not fine for a file that was only opened or
happens to sit in ~/AppImages. This module reads the squashfs directly, as
bytes, so nothing in the image is ever executed.

It reads only what the depot needs — the desktop entry and an icon — and
gives up quietly on anything it does not understand: a type 1 (ISO 9660)
image, a DwarFS runtime, an lz4 or lzo compressor. Every size it is handed
is bounded, since the image is as untrusted as the code it replaces running.
"""

import lzma
import posixpath
import struct
import zlib

try:
    from compression import zstd as _zstd  # Python 3.14+

    def _unzstd(data):
        return _zstd.decompress(data)
except ImportError:
    try:
        import zstandard as _zstandard

        def _unzstd(data):
            return _zstandard.ZstdDecompressor().decompress(data, max_output_size=1 << 20)
    except ImportError:
        _unzstd = None

MAGIC = b"hsqs"
NO_FRAGMENT = 0xFFFFFFFF
MAX_FILE = 16 * 1024 * 1024  # an icon or a desktop entry, never a payload
MAX_SYMLINKS = 8

# Inode types
DIR, FILE, SYMLINK = 1, 2, 3
XDIR, XFILE, XSYMLINK = 8, 9, 10
INODE_SIZE = {DIR: 32, FILE: 32, SYMLINK: 24, XDIR: 40, XFILE: 56, XSYMLINK: 24}


class SquashfsError(Exception):
    pass


def payload_offset(path):
    """Where the squashfs starts: right after the ELF runtime, which ends
    with its section header table."""
    with open(path, "rb") as f:
        head = f.read(64)
        if head[:4] != b"\x7fELF":
            raise SquashfsError("not an ELF file")
        if head[4] == 2:
            shoff, = struct.unpack_from("<Q", head, 0x28)
            shentsize, shnum = struct.unpack_from("<HH", head, 0x3A)
        elif head[4] == 1:
            shoff, = struct.unpack_from("<I", head, 0x20)
            shentsize, shnum = struct.unpack_from("<HH", head, 0x2E)
        else:
            raise SquashfsError("unknown ELF class")
        offset = shoff + shentsize * shnum
        f.seek(offset)
        if f.read(4) != MAGIC:
            raise SquashfsError("no squashfs after the runtime")
    return offset


class Image:
    """A read-only view of the squashfs inside an AppImage."""

    def __init__(self, path):
        self._f = open(path, "rb")
        try:
            self._base = payload_offset(path)
            self._f.seek(self._base)
            sb = self._f.read(96)
            (_, _, _, self.block_size, _, comp, _, self.flags, _, major, _,
             self.root_ref, _, _, _, self.inode_table, self.dir_table,
             self.frag_table, _) = struct.unpack("<IIIIIHHHHHHQQQQQQQQ", sb)
            if major != 4:
                raise SquashfsError("squashfs version %d" % major)
            self._decompress = self._decompressor(comp)
        except Exception:
            self._f.close()
            raise

    def close(self):
        self._f.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    @staticmethod
    def _decompressor(comp):
        if comp == 1:
            return zlib.decompress
        if comp == 2:
            return lambda d: lzma.decompress(d, format=lzma.FORMAT_ALONE)
        if comp == 4:
            return lzma.decompress
        if comp == 6 and _unzstd is not None:
            return _unzstd
        raise SquashfsError("unsupported compressor %d" % comp)

    def _read(self, pos, size):
        self._f.seek(self._base + pos)
        data = self._f.read(size)
        if len(data) != size:
            raise SquashfsError("truncated image")
        return data

    def _metadata(self, table, block, offset, length):
        """`length` bytes of a metadata stream, starting `offset` bytes into
        the block at `table + block`. Streams run across 8 KiB blocks."""
        out = b""
        pos = table + block
        while len(out) < offset + length:
            header, = struct.unpack("<H", self._read(pos, 2))
            size = header & 0x7FFF
            raw = self._read(pos + 2, size)
            out += raw if header & 0x8000 else self._decompress(raw)
            pos += 2 + size
            if len(out) > offset + length + 16384:
                break
        if len(out) < offset + length:
            raise SquashfsError("metadata ends early")
        return out[offset:offset + length]

    def _inode(self, ref):
        block, offset = ref >> 16, ref & 0xFFFF
        kind, = struct.unpack("<H", self._metadata(self.inode_table, block, offset, 2))
        # Only as much as this type's fixed part: an inode can end the table.
        # A file's block list is fetched separately once its length is known.
        raw = self._metadata(self.inode_table, block, offset, INODE_SIZE.get(kind, 16))
        node = {"type": kind, "block": block, "offset": offset}
        if kind == DIR:
            start, _, size, boff, _ = struct.unpack_from("<IIHHI", raw, 16)
            node.update(dir_start=start, dir_size=size, dir_offset=boff)
        elif kind == XDIR:
            _, size, start, _, _, boff = struct.unpack_from("<IIIIHH", raw, 16)
            node.update(dir_start=start, dir_size=size, dir_offset=boff)
        elif kind == FILE:
            start, frag, foff, size = struct.unpack_from("<IIII", raw, 16)
            node.update(start=start, frag=frag, frag_offset=foff, size=size, list_at=32)
        elif kind == XFILE:
            start, size, _, _, frag, foff, _ = struct.unpack_from("<QQQIIII", raw, 16)
            node.update(start=start, frag=frag, frag_offset=foff, size=size, list_at=56)
        elif kind in (SYMLINK, XSYMLINK):
            _, length = struct.unpack_from("<II", raw, 16)
            if length > 4096:
                raise SquashfsError("symlink target too long")
            target = self._metadata(self.inode_table, block, offset + 24, length)
            node["target"] = target.decode("utf-8", "replace")
        return node

    def _listdir(self, node):
        """{name: inode ref} for a directory inode."""
        length = node["dir_size"] - 3  # the size counts "." and ".."
        if length <= 0:
            return {}
        if length > 4 * 1024 * 1024:
            raise SquashfsError("directory too large")
        raw = self._metadata(self.dir_table, node["dir_start"], node["dir_offset"], length)
        entries, pos = {}, 0
        while pos + 12 <= len(raw):
            count, start, _ = struct.unpack_from("<III", raw, pos)
            pos += 12
            for _ in range(count + 1):
                if pos + 8 > len(raw):
                    break
                offset, _, _, name_size = struct.unpack_from("<HhHH", raw, pos)
                pos += 8
                name = raw[pos:pos + name_size + 1].decode("utf-8", "replace")
                pos += name_size + 1
                entries[name] = (start << 16) | offset
        return entries

    def _lookup(self, path, follow=True, depth=0):
        if depth > MAX_SYMLINKS:
            raise SquashfsError("symlink loop")
        node = self._inode(self.root_ref)
        parts = [p for p in path.split("/") if p not in ("", ".")]
        walked = []
        for i, part in enumerate(parts):
            if node["type"] not in (DIR, XDIR):
                return None
            if part == "..":
                walked = walked[:-1]
                node = self._lookup("/".join(walked), True, depth + 1)
                continue
            ref = self._listdir(node).get(part)
            if ref is None:
                return None
            node = self._inode(ref)
            last = i == len(parts) - 1
            if node["type"] in (SYMLINK, XSYMLINK) and (follow or not last):
                target = node["target"]
                joined = target if target.startswith("/") else posixpath.join("/".join(walked), target)
                rest = "/".join(parts[i + 1:])
                return self._lookup(posixpath.join(joined, rest) if rest else joined, follow, depth + 1)
            walked.append(part)
        return node

    def listdir(self, path=""):
        node = self._lookup(path)
        if not node or node["type"] not in (DIR, XDIR):
            return []
        return sorted(self._listdir(node))

    def is_dir(self, path):
        node = self._lookup(path)
        return bool(node) and node["type"] in (DIR, XDIR)

    def read(self, path):
        """The contents of a regular file, following symlinks, or None."""
        node = self._lookup(path)
        if not node or node["type"] not in (FILE, XFILE):
            return None
        size = node["size"]
        if size > MAX_FILE:
            raise SquashfsError("file too large")
        has_frag = node["frag"] != NO_FRAGMENT
        blocks = size // self.block_size if has_frag else -(-size // self.block_size)
        sizes = struct.unpack("<%dI" % blocks, self._metadata(
            self.inode_table, node["block"], node["offset"] + node["list_at"], 4 * blocks)) if blocks else ()
        out = b""
        pos = node["start"]
        for word in sizes:
            length = word & 0xFFFFFF
            if length == 0:
                out += b"\0" * self.block_size
                continue
            raw = self._read(pos, length)
            out += raw if word & 0x1000000 else self._decompress(raw)
            pos += length
        if has_frag:
            out += self._fragment(node["frag"])[node["frag_offset"]:][:size - len(out)]
        return out[:size]

    def _fragment(self, index):
        pointer_at = self.frag_table + (index // 512) * 8
        block, = struct.unpack("<Q", self._read(pointer_at, 8))
        entry = self._metadata(block, 0, (index % 512) * 16, 16)
        start, word, _ = struct.unpack("<QII", entry)
        length = word & 0xFFFFFF
        raw = self._read(start, length)
        return raw if word & 0x1000000 else self._decompress(raw)

    def walk(self, path, limit=4000):
        """Paths of the regular files and symlinks under `path`, bounded."""
        top = self._lookup(path)
        if not top or top["type"] not in (DIR, XDIR):
            return []
        out, stack = [], [(path.strip("/"), top)]
        while stack and len(out) < limit:
            current, node = stack.pop()
            for name, ref in sorted(self._listdir(node).items(), reverse=True):
                child = current + "/" + name if current else name
                inode = self._inode(ref)
                if inode["type"] in (DIR, XDIR):
                    stack.append((child, inode))
                elif inode["type"] in (FILE, XFILE, SYMLINK, XSYMLINK):
                    out.append(child)
        return out
