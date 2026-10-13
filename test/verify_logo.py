"""Offline checks of the existing logo bytes and metadata; creates or downloads nothing.

Run: python3 test/verify_logo.py
Foundry has no filesystem read permissions in this project, so asset checks live here.
The Solidity suite separately checks the on-chain URI and digest against these same values.
"""

import base64
import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
LOGO_SHA256 = "c2aeb53e69e10a7a4654a97ce8b26bd0a99a843d024ad6f09f6f7d235ca2eaec"
LOGO_CID = "QmWJsrdD9smahpdyqjBzDBodJkJJGNznMA2Wrh15R1hhCp"


def varint(value):
    result = bytearray()
    while value >= 128:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def base58(data):
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    number = int.from_bytes(data, "big")
    result = ""
    while number:
        number, remainder = divmod(number, 58)
        result = alphabet[remainder] + result
    return "1" * (len(data) - len(data.lstrip(b"\x00"))) + result


class ExistingBloxLogoTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image = (ROOT / "assets/logo/blox.jpg").read_bytes()
        cls.metadata = json.loads((ROOT / "assets/token-metadata.json").read_text())

    def test_bytes_match_the_existing_original_image(self):
        self.assertEqual(len(self.image), 56060)
        self.assertEqual(hashlib.sha256(self.image).hexdigest(), LOGO_SHA256)

    def test_metadata_describes_the_same_unmodified_image_and_token(self):
        metadata = self.metadata
        self.assertEqual(metadata["name"], "Blox")
        self.assertEqual(metadata["symbol"], "BLOX")
        self.assertEqual(metadata["decimals"], 18)
        self.assertEqual(metadata["totalSupply"], str(1_000_000_000 * 10**18))
        self.assertEqual(metadata["contract"], "BloxToken")
        self.assertEqual(metadata["logoURI"], "ipfs://" + LOGO_CID)
        logo = metadata["logo"]
        self.assertEqual(logo["file"], "assets/logo/blox.jpg")
        self.assertEqual(logo["source"], "https://x.com/blox_imd")
        self.assertEqual(
            logo["sourceImage"],
            "https://pbs.twimg.com/profile_images/2108499797414236160/QJxnGSNM.jpg",
        )
        self.assertEqual(logo["mimeType"], "image/jpeg")
        self.assertEqual(logo["bytes"], len(self.image))
        self.assertEqual(logo["sha256"], hashlib.sha256(self.image).hexdigest())
        self.assertIs(logo["modified"], False)

    def test_ipfs_identifiers_are_derived_from_the_file_bytes(self):
        # The delivered CID uses a single UnixFS File leaf in a DAG-PB node,
        # CIDv0 and SHA-256 (not a raw-file SHA-256 masquerading as an IPFS CID).
        self.assertLess(len(self.image), 256 * 1024)
        size = varint(len(self.image))
        unixfs = b"\x08\x02\x12" + size + self.image + b"\x18" + size
        node = b"\x0a" + varint(len(unixfs)) + unixfs
        multihash = b"\x12\x20" + hashlib.sha256(node).digest()
        cid_v0 = base58(multihash)
        cid_v1 = "b" + base64.b32encode(b"\x01\x70" + multihash).decode().lower().rstrip("=")
        self.assertEqual(cid_v0, LOGO_CID)
        self.assertEqual(self.metadata["logo"]["ipfsCidV0"], cid_v0)
        self.assertEqual(self.metadata["logo"]["ipfsCidV1"], cid_v1)


if __name__ == "__main__":
    unittest.main()
