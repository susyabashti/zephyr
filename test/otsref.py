#!/usr/bin/env python3
"""Independent reference for Zephyr's OpenTimestamps v1 anchor.

Implements the .ots detached-timestamp format per spec/ots-anchor.md
(mirroring opentimestamps/python-opentimestamps master: core/serialize.py,
core/op.py, core/notary.py, core/timestamp.py, bitcoin.py) using only the
Python standard library. It is deliberately independent of the Zig
implementation in src/core/ots.zig.

It also includes a minimal Bitcoin block parser (legacy transactions) so
the pinned vectors can be audited against the raw block hex stored in the
vector file, and a proof generator that reproduces the upstream
make_timestamp_from_block construction, for (re)generating the vectors.

Usage:
  python3 test/otsref.py --gen    (re)write spec/vectors/ots.json
  python3 test/otsref.py --check  validate the pinned OTS vectors end to end
"""

import hashlib
import json
import os
import struct
import sys

OTs_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "spec", "vectors", "ots.json")

# ---------------------------------------------------------------- constants

HEADER_MAGIC = b"\x00OpenTimestamps\x00\x00Proof\x00\xbf\x89\xe2\xe8\x84\xe8\x92\x94"
MAJOR_VERSION = 1
SHA256_TAG = 0x08
APPEND_TAG = 0xF0
PREPEND_TAG = 0xF1
BITCOIN_TAG = b"\x05\x88\x96\x0d\x73\xd7\x19\x01"
LITECOIN_TAG = b"\x06\x86\x9a\x0d\x73\xd7\x1b\x45"
PENDING_TAG = b"\x83\xdf\xe3\x0d\x2e\xf9\x0c\x8e"
MAX_MSG_LENGTH = 4096
MAX_OP_ARG_LENGTH = 4096
MAX_ATTESTATION_PAYLOAD = 8192
MAX_URI_LENGTH = 1000
ALLOWED_URI_CHARS = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._/:")
RECURSION_LIMIT = 256
MAX_PROOF_LENGTH = 1024 * 1024


class OtsError(Exception):
    """Carries the machine-readable failure reason (see spec section 6.1)."""

    def __init__(self, reason, detail=""):
        super().__init__(detail or reason)
        self.reason = reason
        self.detail = detail


# ---------------------------------------------------------------- reading

class _Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def read(self, n):
        if self.pos + n > len(self.data):
            raise OtsError("Truncated", f"read of {n} byte(s) at offset {self.pos}")
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out

    def byte(self):
        return self.read(1)[0]

    def read_varuint(self):
        value = 0
        shift = 0
        for i in range(10):
            b = self.byte()
            value |= (b & 0x7F) << shift
            if not b & 0x80:
                return value
            shift += 7
        raise OtsError("VaruintTooLong", "varint longer than 10 bytes")

    def read_varbytes(self, max_len, min_len=0, too_long="TooLong", too_short="TooShort"):
        n = self.read_varuint()
        if n < min_len:
            raise OtsError(too_short)
        if n > max_len:
            raise OtsError(too_long)
        return self.read(n)


# ---------------------------------------------------------------- the tree

def apply_op(tag, arg, msg):
    if len(msg) > MAX_MSG_LENGTH:
        raise OtsError("MsgTooLong", f"message of {len(msg)} bytes")
    if tag == SHA256_TAG:
        return hashlib.sha256(msg).digest()
    if tag == APPEND_TAG:
        child = msg + arg
    elif tag == PREPEND_TAG:
        child = arg + msg
    else:
        raise OtsError("UnknownOp", f"0x{tag:02x}")
    if len(child) > MAX_MSG_LENGTH:
        raise OtsError("ResultTooLong", f"result of {len(child)} bytes")
    return child


def parse_attestation(tag, payload):
    if tag in (BITCOIN_TAG, LITECOIN_TAG):
        r = _Reader(payload)
        height = r.read_varuint()
        if r.pos != len(payload):
            raise OtsError("BadAttestation", "trailing bytes in block attestation")
        return {"kind": "bitcoin" if tag == BITCOIN_TAG else "litecoin", "height": height}
    if tag == PENDING_TAG:
        r = _Reader(payload)
        uri = r.read_varbytes(MAX_URI_LENGTH, too_long="BadUri")
        for c in uri:
            if c not in ALLOWED_URI_CHARS:
                raise OtsError("BadUri", f"invalid character 0x{c:02x}")
        if r.pos != len(payload):
            raise OtsError("BadAttestation", "trailing bytes in pending attestation")
        return {"kind": "pending", "uri": uri.decode("ascii")}
    return {"kind": "unknown", "tag": tag.hex()}


def parse_entry(r, msg, entry, depth, attestations):
    if entry == 0x00:
        att_tag = r.read(8)
        payload = r.read_varbytes(
            MAX_ATTESTATION_PAYLOAD, too_long="AttestationPayloadTooLong")
        att = parse_attestation(att_tag, payload)
        att["msg"] = msg.hex()
        attestations.append(att)
        return
    arg = b""
    if entry in (APPEND_TAG, PREPEND_TAG):
        arg = r.read_varbytes(
            MAX_OP_ARG_LENGTH, min_len=1,
            too_long="OpArgTooLong", too_short="OpArgEmpty")
    child = apply_op(entry, arg, msg)
    parse_node(r, child, depth + 1, attestations)


def parse_node(r, msg, depth, attestations):
    if depth > RECURSION_LIMIT:
        raise OtsError("RecursionLimit", f"depth {depth}")
    tag = r.byte()
    while tag == 0xFF:
        entry = r.byte()
        parse_entry(r, msg, entry, depth, attestations)
        tag = r.byte()
    parse_entry(r, msg, tag, depth, attestations)


def verify_proof(proof, expected_digest):
    """Verifies a .ots file against the expected stamped-file digest.

    Returns (root, attestations) where root is the tree root message
    (== expected_digest) and attestations is the list of every
    attestation in the tree. Raises OtsError on any failure.
    """
    if len(proof) > MAX_PROOF_LENGTH:
        raise OtsError("TooLarge", f"{len(proof)} bytes")
    r = _Reader(proof)
    if r.read(len(HEADER_MAGIC)) != HEADER_MAGIC:
        raise OtsError("BadMagic")
    version = r.byte()
    if version != MAJOR_VERSION:
        raise OtsError("BadVersion", f"version {version}")
    hash_op = r.byte()
    if hash_op != SHA256_TAG:
        raise OtsError("BadHashOp", f"0x{hash_op:02x}")
    file_digest = r.read(32)
    if file_digest != expected_digest:
        raise OtsError("DigestMismatch")
    attestations = []
    parse_node(r, file_digest, 0, attestations)
    if r.pos != len(proof):
        raise OtsError("TrailingGarbage", f"{len(proof) - r.pos} byte(s) after the tree")
    return file_digest, attestations


# ---------------------------------------------------------------- writing

def _varuint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _varbytes(b):
    return _varuint(len(b)) + b


def serialize_proof(file_digest, ops, height):
    """Serializes a linear bitcoin-anchored proof (the shape every
    Bitcoin-backed .ots proof has: one op per node, one attestation at
    the root). `ops` is a list of (tag, arg)."""
    out = bytearray()
    out += HEADER_MAGIC
    out.append(MAJOR_VERSION)
    out.append(SHA256_TAG)
    out += file_digest
    for tag, arg in ops:
        out.append(tag)
        if tag in (APPEND_TAG, PREPEND_TAG):
            out += _varbytes(arg)
    out.append(0x00)
    out += BITCOIN_TAG + _varbytes(_varuint(height))
    return bytes(out)


# ---------------------------------------------------------------- bitcoin

def sha256d(data):
    return hashlib.sha256(hashlib.sha256(data).digest()).digest()


def _read_varint(data, pos):
    value = 0
    shift = 0
    for i in range(10):
        if pos + 1 > len(data):
            raise ValueError("truncated varint")
        b = data[pos]
        pos += 1
        value |= (b & 0x7F) << shift
        if not b & 0x80:
            return value, pos
        shift += 7
    raise ValueError("varint too long")


def parse_tx(data, pos):
    """Parses one legacy (non-segwit) transaction; returns its raw bytes."""
    start = pos
    version = struct.unpack_from("<I", data, pos)[0]
    if version == 0 and pos + 6 <= len(data) and data[pos + 4] == 0x00 and data[pos + 5] == 0x01:
        raise ValueError("segwit transactions are not supported")
    pos += 4
    n_in, pos = _read_varint(data, pos)
    for _ in range(n_in):
        pos += 36  # prevout hash + index
        script_len, pos = _read_varint(data, pos)
        pos += script_len + 4  # script + sequence
    n_out, pos = _read_varint(data, pos)
    for _ in range(n_out):
        pos += 8  # value
        script_len, pos = _read_varint(data, pos)
        pos += script_len
    pos += 4  # locktime
    return data[start:pos], pos


def parse_block(block):
    """Parses a legacy Bitcoin block; verifies nothing (the merkle check
    happens in the vector checks)."""
    if len(block) < 80:
        raise ValueError("block too short")
    version, = struct.unpack_from("<I", block, 0)
    prev_block = block[4:36]
    merkleroot = block[36:68]
    timestamp, bits, nonce = struct.unpack_from("<III", block, 68)
    pos = 80
    n_tx, pos = _read_varint(block, pos)
    txs = []
    for _ in range(n_tx):
        tx, pos = parse_tx(block, pos)
        txs.append(tx)
    if pos != len(block):
        raise ValueError(f"{len(block) - pos} trailing byte(s) after the last transaction")
    return {
        "version": version,
        "prev_block": prev_block,
        "merkleroot": merkleroot,
        "timestamp": timestamp,
        "bits": bits,
        "nonce": nonce,
        "txs": txs,
        "txids": [sha256d(tx) for tx in txs],
    }


def merkle_root(txids):
    """The Satoshi-doubling merkle root (bitcoin.py: __make_btc_block_merkle_tree)."""
    level = list(txids)
    if not level:
        raise ValueError("empty tx list")
    while len(level) > 1:
        if len(level) % 2:
            level.append(level[-1])
        level = [sha256d(level[i] + level[i + 1]) for i in range(0, len(level), 2)]
    return level[0]


def make_btc_proof(committed, block, height):
    """Reproduces opentimestamps/bitcoin.py: make_timestamp_from_block.

    `committed` is the message embedded in the block (== the proof's
    file_digest, == the tree root): in a real .ots it is the stamped
    file's SHA-256 digest. It must occur verbatim in some transaction's
    serialized bytes; the smallest such transaction is used. Returns
    (proof, root) where root is the block's merkle root.
    """
    best = None
    prefix = suffix = b""
    for tx in block["txs"]:
        i = tx.find(committed)
        if i < 0:
            continue
        if best is None or len(tx) < len(best):
            best, prefix, suffix = tx, tx[:i], tx[i + len(committed):]
    if best is None:
        raise ValueError("committed message not found in any block transaction")

    ops = [(PREPEND_TAG, prefix), (APPEND_TAG, suffix),
           (SHA256_TAG, b""), (SHA256_TAG, b"")]
    msg = apply_op(PREPEND_TAG, prefix, committed)
    msg = apply_op(APPEND_TAG, suffix, msg)
    msg = apply_op(SHA256_TAG, b"", msg)
    msg = apply_op(SHA256_TAG, b"", msg)  # the txid
    if msg not in block["txids"]:
        raise ValueError("derived txid is not in the block")
    index = block["txids"].index(msg)

    level = list(block["txids"])
    while len(level) > 1:
        if len(level) % 2:
            level.append(level[-1])
        if index % 2 == 0:
            sibling = level[index + 1]
            ops.append((APPEND_TAG, sibling))
        else:
            sibling = level[index - 1]
            ops.append((PREPEND_TAG, sibling))
        ops += [(SHA256_TAG, b""), (SHA256_TAG, b"")]
        msg = apply_op(APPEND_TAG, sibling, msg) if index % 2 == 0 \
            else apply_op(PREPEND_TAG, sibling, msg)
        msg = apply_op(SHA256_TAG, b"", msg)
        msg = apply_op(SHA256_TAG, b"", msg)
        level = [sha256d(level[i] + level[i + 1]) for i in range(0, len(level), 2)]
        index //= 2
    if msg != block["merkleroot"]:
        raise ValueError("merkle path does not reach the block's merkle root")
    return serialize_proof(committed, ops, height), msg


# ---------------------------------------------------------------- vectors

# Raw block and ground-truth constants from
# opentimestamps/python-opentimestamps master, tests/test_bitcoin.py
# (test.test): mainnet block 586 (first block with three transactions).
BLOCK586 = bytes.fromhex(
    "0100000038babc9586a5fcd60713573494f4377e7c401c33aa24729a4f6cff46"
    "000000004d5969c0d10dcce60868fee4d4de80ba5ef38abaeed8a75daa63e48c"
    "963d7b1950476f49ffff001d2d97913703010000000100000000000000000000"
    "00000000000000000000000000000000000000000000ffffffff0804ffff001d"
    "025d06ffffffff0100f2052a0100000043410410daf049ef402de0b6adba8b0f"
    "7c392bcf9a6385116efc8b4143b8b7a7841e7de73b478ffe13b60c50ea01e24b"
    "4b48c24f5e0fbc5d6c8433c7ca7c3ed3ab8173ac0000000001000000050f40f5"
    "e65e115eb4bdb3007f0fb8beaa404cf7ae45de16074e8acc9b69bbf0c3000000"
    "004847304402201092da40af6dea8abcbeefb8586335b26d39d36be9b6c38d6c"
    "9cc18f20dd5886022045964de79a9008f68d53fc9bc58f9e30b224a1b98dbfda"
    "5c7b7b860f32c6aef101ffffffff1bb875b247332e558731c2c510f611d3dde9"
    "91ea9fe69365bf445a0ccd513b190000000049483045022100b0a1d0a00251c5"
    "6809a5ab5d7ba6cbe68b82c9bf4f806ee39c568ae537572c840220781ce69017"
    "ec3b2d6f96ffff4d19c80c224f40c73b8c26cba4b30e7f4171579b01ffffffff"
    "2099e1a92d94c35f0645683257c4c255165385f3e9129a85fed5a3f3d867c9b6"
    "0000000049483045022100c8e980f43c616232e2d59dce08a5edb84aaa0915ea"
    "49780a8af367330216084a02203cc2628f16f995c7aaf6104cba64971963a4e0"
    "84e4fbd0b6bcf825b47a09f8e301ffffffff5fb770c4de700aca7f74f5e6295f"
    "248edafa9423e446d76f4650df9b90f939a700000000494830450220745a8d99"
    "c51f98f5c93b8d2f5f14a1f2d8cc42ff7329645681bcafe846cbf50d022100b2"
    "4e31186129f3ae6cc8a226d1eda389373652a9cf2095631fcc4345067c1ff301"
    "ffffffff968d4c096ee861307935d21d797a902b647dc970d3c8374cc13551f8"
    "397abbd80000000049483045022100ca65b3f290724d6c56fc333570fa342f24"
    "77f34b2a6c93c2e2d7216d9fe9088e022077e259a29ed1f988fab2b9f2ce17a4"
    "a56a20c188cadc72bca94e06a73826966501ffffffff0100ba1dd20500000043"
    "410497304efd3ab14d0dcbf1e901045a25f4b5dbaf576d074506fd8ded4122ba"
    "6f6bec0ed4698ce0e7928c0eaf9ddfb5387929b5d697e82e7aabebe04c10e5c8"
    "7164ac0000000001000000010d26ba57ff82fefcb43826b45019043e2b6ef9aa"
    "8118b7f743167584a7f9cae70000000049483045022024fd7345df2b2bd0e6f8"
    "416529046b7d52bda5ffdb70146bc6d72b1ba73cabcd022100ff99c03006cc8f"
    "28d92e686f0ae640d20395177f329d0a9dbd560fd2a55aeee701ffffffff0100"
    "f2052a01000000434104888d890e1bd84c9e2ac363a9774414a081eb805cd2c0"
    "d52e49efc7170ebf342f1cdb284a2e2eb754fc8dd4525fe0caa3d3a525214d0b"
    "504dd75376b2f63804a8ac00000000")
BLOCK586_UPSTREAM_ROOT = bytes.fromhex(
    "197b3d968ce463aa5da7d8eeba8af35eba80ded4e4fe6808e6cc0dd1c069594d")[::-1]
# A spent transaction's hash (internal byte order) appearing in a block
# input: the 32-byte message committed in the block-586 vector.
BLOCK586_DOCUMENT = bytes.fromhex(
    "c3f0bb699bcc8a4e0716de45aef74c40aabeb80f7f00b3bdb45e115ee6f5400f")[::-1]


def _opreturn_block(committed, timestamp, bits, nonce):
    """A well-formed single-coinbase legacy block whose coinbase commits
    `committed` via OP_RETURN — the shape of a real calendar commitment."""
    prev_block = hashlib.sha256(b"zephyr-ots-anchor synthetic block prev").digest()
    coinbase = (
        struct.pack("<I", 1)                       # version
        + b"\x01"                                  # 1 input
        + b"\x00" * 32                             # coinbase prevout hash
        + struct.pack("<I", 0xFFFFFFFF)            # prevout index
        + b"\x05" + b"\x04\xff\xff\x00\x1d"        # scriptSig
        + struct.pack("<I", 0xFFFFFFFF)            # sequence
        + b"\x01"                                  # 1 output
        + struct.pack("<Q", 50 * 10**8)            # value (50 BTC)
        + bytes([0x22, 0x6a, 0x20]) + committed    # OP_RETURN <32 bytes>
        + struct.pack("<I", 0)                     # locktime
    )
    txid = sha256d(coinbase)  # single tx: the merkle root is the coinbase txid
    header = struct.pack("<I", 1) + prev_block + txid + struct.pack("<III", timestamp, bits, nonce)
    return header + b"\x01" + coinbase


# A synthetic 32-byte stamped document standing in for a segment's
# footer_head; its SHA-256 is the message committed in the synthetic block.
SYNTHETIC_DOCUMENT = hashlib.sha256(b"zephyr-ots-anchor test document").digest()
SYNTHETIC_BLOCK = _opreturn_block(hashlib.sha256(SYNTHETIC_DOCUMENT).digest(),
                                  1767225600, 0x1D00FFFF, 42)
SYNTHETIC_HEIGHT = 900000


def _vector_specs():
    return [
        {
            "id": "bitcoin-block-586",
            "source": ("opentimestamps/python-opentimestamps master, tests/test_bitcoin.py "
                       "(test.test, mainnet block 586, first block with three transactions; "
                       "the committed message is a spent transaction hash in a block input; "
                       "no Zephyr document is bound to this vector)"),
            "document": None,
            "committed": BLOCK586_DOCUMENT,
            "block": BLOCK586,
            "upstream_root": BLOCK586_UPSTREAM_ROOT,
            "height": 586,
        },
        {
            "id": "opreturn-synthetic",
            "source": ("Synthetic single-coinbase legacy block committing "
                       "SHA-256(document) via OP_RETURN (the shape of a real calendar "
                       "commitment); self-contained: the block hex is pinned so the checker "
                       "recomputes the txid and merkle root from it"),
            "document": SYNTHETIC_DOCUMENT,
            "committed": hashlib.sha256(SYNTHETIC_DOCUMENT).digest(),
            "block": SYNTHETIC_BLOCK,
            "upstream_root": None,
            "height": SYNTHETIC_HEIGHT,
        },
    ]


def generate():
    """(Re)builds spec/vectors/ots.json from the pinned blocks."""
    vectors = []
    for spec in _vector_specs():
        block = parse_block(spec["block"])
        if merkle_root(block["txids"]) != block["merkleroot"]:
            raise SystemExit(f"{spec['id']}: block merkle root does not match its txids")
        if spec["upstream_root"] is not None and block["merkleroot"] != spec["upstream_root"]:
            raise SystemExit(f"{spec['id']}: block merkle root differs from the upstream test constant")
        if spec["document"] is not None \
                and hashlib.sha256(spec["document"]).digest() != spec["committed"]:
            raise SystemExit(f"{spec['id']}: committed message is not SHA-256(document)")
        proof, root = make_btc_proof(spec["committed"], block, spec["height"])
        # The generated proof must round-trip through our own verifier: the
        # tree root is the file digest; the attested node must be the
        # block's merkle root at the pinned height.
        vroot, atts = verify_proof(proof, spec["committed"])
        if vroot != spec["committed"] or len(atts) != 1 or atts[0]["kind"] != "bitcoin" \
                or atts[0]["height"] != spec["height"] or atts[0]["msg"] != root.hex():
            raise SystemExit(f"{spec['id']}: generated proof fails its own verification")
        vectors.append({
            "id": spec["id"],
            "source": spec["source"],
            "document_hex": spec["document"].hex() if spec["document"] is not None else None,
            "file_digest_hex": spec["committed"].hex(),
            "block_hex": spec["block"].hex(),
            "block_height": spec["height"],
            "expected": {
                "root_hex": block["merkleroot"].hex(),
                "attestations": [{"kind": "bitcoin", "height": spec["height"]}],
            },
            "proof_hex": proof.hex(),
        })
        print(f"{spec['id']}: {len(proof)}-byte proof, root {block['merkleroot'].hex()}")
    data = {"format_version": 1, "vectors": vectors}
    with open(OTs_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {os.path.normpath(OTs_PATH)} ({len(vectors)} vector(s))")


# ---------------------------------------------------------------- checking

def _corruptions(proof):
    """(bytes, expected OtsError reason) pairs; each must be rejected."""
    out = []
    b = bytearray(proof)
    b[0] ^= 1
    out.append((bytes(b), "BadMagic"))
    b = bytearray(proof)
    b[len(HEADER_MAGIC)] = 2
    out.append((bytes(b), "BadVersion"))
    b = bytearray(proof)
    b[len(HEADER_MAGIC) + 1] = 0x02
    out.append((bytes(b), "BadHashOp"))
    b = bytearray(proof)
    b[len(HEADER_MAGIC) + 2] ^= 1
    out.append((bytes(b), "DigestMismatch"))
    out.append((proof[:-1], "Truncated"))
    out.append((proof + b"\x00", "TrailingGarbage"))
    b = bytearray(proof)
    b[len(HEADER_MAGIC) + 2 + 32] = 0xF2
    out.append((bytes(b), "UnknownOp"))
    return out


def check_ots():
    """Independently validates spec/vectors/ots.json.
    Returns (problems, n_vectors, n_corruptions)."""
    with open(OTs_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)
    if data.get("format_version") != 1:
        return ["ots: unsupported format_version"], 0, 0
    problems = []
    count = 0
    n_corruptions = 0
    for v in data.get("vectors", []):
        vid = v["id"]
        document = bytes.fromhex(v["document_hex"]) if v.get("document_hex") is not None else None
        proof = bytes.fromhex(v["proof_hex"])
        file_digest = bytes.fromhex(v["file_digest_hex"])
        try:
            block = parse_block(bytes.fromhex(v["block_hex"]))
        except ValueError as e:
            problems.append(f"ots {vid}: pinned block does not parse ({e})")
            return problems, 1, 0
        if document is not None and hashlib.sha256(document).digest() != file_digest:
            problems.append(f"ots {vid}: file_digest is not SHA-256(document)")
        if merkle_root(block["txids"]) != block["merkleroot"]:
            problems.append(f"ots {vid}: block merkle root does not match its txids")
        expected = v["expected"]
        if block["merkleroot"].hex() != expected["root_hex"]:
            problems.append(f"ots {vid}: pinned root differs from the block's merkle root")
        try:
            vroot, atts = verify_proof(proof, file_digest)
        except OtsError as e:
            problems.append(f"ots {vid}: pinned proof fails ({e.reason}: {e.detail})")
            return problems, count + 1, n_corruptions
        if vroot != file_digest:
            problems.append(f"ots {vid}: tree root is not the file digest")
        got_atts = []
        for a in atts:
            if a["kind"] in ("bitcoin", "litecoin"):
                if a["msg"] != expected["root_hex"]:
                    problems.append(f"ots {vid}: {a['kind']} attestation msg is not the pinned root")
                got_atts.append({"kind": a["kind"], "height": a["height"]})
            elif a["kind"] == "pending":
                got_atts.append({"kind": a["kind"], "uri": a["uri"]})
            else:
                got_atts.append({"kind": a["kind"], "tag": a["tag"]})
        if got_atts != expected["attestations"]:
            problems.append(f"ots {vid}: attestations {got_atts} != pinned {expected['attestations']}")
        for i, (corrupted, want_reason) in enumerate(_corruptions(proof)):
            n_corruptions += 1
            try:
                verify_proof(corrupted, file_digest)
                problems.append(f"ots {vid}: corruption {i} ({want_reason}) passed verify")
            except OtsError as e:
                if e.reason != want_reason:
                    problems.append(f"ots {vid}: corruption {i} reported {e.reason}, want {want_reason}")
        count += 1
    return problems, count, n_corruptions


def main(argv):
    if argv == ["--gen"]:
        generate()
        return 0
    if argv == ["--check"]:
        problems, n_vectors, n_corruptions = check_ots()
        if problems:
            for p in problems:
                print("FAIL:", p, file=sys.stderr)
            return 1
        print(f"ok: {n_vectors} OTS vector(s), {n_corruptions} corruption check(s)")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
