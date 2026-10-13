// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Blox (BLOX)
/// @notice A fixed-supply ERC-20 launched on IdentityMD.
/// @dev The whole supply is minted exactly once, in the constructor, to `msg.sender`. On the
///      IdentityMD launch `msg.sender` is the ProjectFactory, which pays the supply out (swarm
///      share, pool seed, requester remainder). There is no owner, no mint, no burn-from, no pause,
///      no blacklist and no fee: every transfer moves exactly the amount it says, so the launch
///      flows arrive whole and nothing can grow or freeze a balance after launch.
///
///      The official logo is the profile picture of https://x.com/blox_imd, used exactly as served
///      by X (no regeneration, no edits). Its content-addressed IPFS URI and SHA-256 are recorded on
///      chain as constants so any wallet, explorer or indexer can verify it byte for byte.
contract BloxToken is ERC20, ERC20Permit {
    /// @notice Total supply: 1,000,000,000 BLOX with 18 decimals, in minor units.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Content-addressed URI of the official logo: the unmodified profile picture of the
    ///         X account blox_imd (CIDv0, dag-pb/unixfs, sha2-256, single 56,060-byte chunk).
    string public constant LOGO_URI = "ipfs://QmWJsrdD9smahpdyqjBzDBodJkJJGNznMA2Wrh15R1hhCp";

    /// @notice SHA-256 of the logo file bytes, for verification outside IPFS.
    bytes32 public constant LOGO_SHA256 = 0xc2aeb53e69e10a7a4654a97ce8b26bd0a99a843d024ad6f09f6f7d235ca2eaec;

    /// @notice Where the logo was retrieved from: the X account whose profile picture it is.
    string public constant LOGO_SOURCE = "https://x.com/blox_imd";

    constructor() ERC20("Blox", "BLOX") ERC20Permit("Blox") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice The official token logo as an IPFS URI.
    function logoURI() external pure returns (string memory) {
        return LOGO_URI;
    }
}
