# Blox (BLOX)

A fixed-supply ERC-20 custom token for an IdentityMD launch on Ethereum mainnet, whose official
logo is the unmodified profile picture of [@blox_imd](https://x.com/blox_imd).

| Item | Value |
|---|---|
| Solidity contract | `BloxToken` (`src/BloxToken.sol`) |
| Token name / symbol | `Blox` / `BLOX` |
| Decimals | 18 |
| Total supply | 1,000,000,000 BLOX = `1000000000000000000000000000` minor units |
| Minting | once, in the constructor, all of it to `msg.sender` (the ProjectFactory); nothing can mint afterwards |
| Constructor arguments | none |
| Extras | EIP-2612 `permit`; on-chain logo provenance (`logoURI()`, `LOGO_SHA256`, `LOGO_SOURCE`) |
| Compiler | solc 0.8.26, optimizer 200 runs, `bytecode_hash = "none"`, `cbor_metadata = false` |

## Layout

```
foundry.toml, remappings.txt       Foundry configuration (root project; forge build/test run here)
src/BloxToken.sol                  the token
test/BloxToken.t.sol               success and failure tests
assets/logo/blox.jpg               the exact @blox_imd profile picture (56,060 bytes, 400x400 JPEG)
assets/token-metadata.json         token-list style metadata pointing at the logo
lib/forge-std, lib/openzeppelin-contracts
                                   vendored as ordinary files (no submodules); see VENDORED.md in each
```

## Token logo: the @blox_imd profile picture, used as is

The brief requires the existing X profile picture, byte for byte, with no generation, redesign or
replacement. That is what was done:

1. The profile picture of `https://x.com/blox_imd` (X user id `2108499362334826497`, display name
   "Blox") was resolved on 2026-10-13 to X's image host:
   `https://pbs.twimg.com/profile_images/2108499797414236160/QJxnGSNM.jpg` (the original upload;
   X also serves resized variants such as `_400x400`, `_normal`, `_bigger`).
2. The original upload was downloaded unmodified and committed as `assets/logo/blox.jpg`.
   - SHA-256: `c2aeb53e69e10a7a4654a97ce8b26bd0a99a843d024ad6f09f6f7d235ca2eaec`
   - size: 56,060 bytes, 400x400, progressive JPEG
   - (for reference only, not used: the `_400x400` variant hashes to
     `829645b1ecd5a6e0467ca5dd338369b178b119e2a662756cd2aed267388aabc9`, 50,685 bytes)
3. Its IPFS content identifier was computed locally from those bytes, two independent ways
   (a from-scratch dag-pb/unixfs implementation and the `ipfs-only-hash` package), both giving
   `QmWJsrdD9smahpdyqjBzDBodJkJJGNznMA2Wrh15R1hhCp` (CIDv0; CIDv1
   `bafybeidwnezpefbhckt655vgpzbllnnqqeo4t3enirkrbgajb3xx4uwuru`). The CID depends only on the
   file bytes and the default `ipfs add` settings (CIDv0, sha2-256, 256 KiB chunks, one chunk), so
   whoever pins the file gets the same CID.
4. The token records that URI and the SHA-256 on chain (`logoURI()`, `LOGO_URI`, `LOGO_SHA256`,
   `LOGO_SOURCE`), and `assets/token-metadata.json` points at the same file, so any wallet,
   explorer or indexer can verify the logo matches the X profile picture exactly.

No AI image generation, editing or resizing was used, and no logo task was delegated. The "logo
generation stage" is skipped: the logo already exists.

**Limitation to report:** this task has no IPFS pinning credentials, so the file has been
content-addressed but not yet pinned. The URI is already correct; it resolves once someone pins the
committed file (see "Operational responsibilities"). If IdentityMD's listing takes a logo file
directly, use `assets/logo/blox.jpg` unchanged.

## Behaviour and trust assumptions

- **Plain transfers.** Every `transfer`/`transferFrom` moves exactly the amount stated. There is
  no fee, tax, reflection, burn-on-transfer, max-wallet, cooldown or trading switch, so the
  factory's payout to the MerkleDistributor, the single-sided Uniswap v4 seed through the
  PoolManager, claims from the distributor and ordinary buys and sells all arrive whole.
- **No privileged role.** The contract has no owner, admin, minter, pauser, blacklist, freeze,
  seize, `burnFrom` or upgrade path. It is not a proxy and uses no `DELEGATECALL`, `CALLCODE` or
  `SELFDESTRUCT`. Nobody, including the deployer, can move or freeze a holder's balance, and the
  supply cannot grow after construction. Holders may of course send tokens wherever they like.
- **Deployer = factory.** The constructor mints to `msg.sender`, which at launch is the
  IdentityMD ProjectFactory. It never uses `tx.origin`, and it never calls another contract, so it
  deploys on an empty chain. The three exemption arguments (`$factory`, `$poolManager`,
  `$launchNumber`) are not needed because nothing is ever exempted from anything.
- **Permit.** EIP-2612 `permit` (OpenZeppelin `ERC20Permit`) is included for gasless approvals.
  The EIP-712 domain name is `Blox`, version `1`; the domain separator is recomputed if the chain
  id changes, as OpenZeppelin does.
- **Libraries.** All library code is `internal` (OpenZeppelin `ECDSA`, `ShortStrings`,
  `StorageSlot`, `Strings`, `Math`, ...) and is inlined; the bytecode has no link placeholders.

## Deployment parameters (for the launch; recorded here, not acted on)

Decided by the launch and copied by the manifest step; none are open questions:

| Parameter | Value |
|---|---|
| Chain | Ethereum, chain id 1 |
| Launch kind | `custom_token` through `ProjectFactory.launchCustom` |
| `token.contract` | `BloxToken` |
| `token.name` / `token.symbol` / `token.decimals` | `Blox` / `BLOX` / `18` |
| `token.constructorArgs` | `[]` |
| `token.totalSupply` | `1000000000000000000000000000` |
| Application contracts | none |
| `pool.pairedCurrency` | `0x0000000000000000000000000000000000000000` (native ETH) |
| `pool.fee` / `pool.tickSpacing` | `12500` (1.25%) / `60` |
| `pool.initialPrice` | `79228162514264337593543950336` (provenance only; the deployer derives the opening price) |
| `economics.poolBps` | `8800` |
| `economics.initialMarketCapWei` | `10000000000000000000` (10 ETH for the whole supply) |
| `economics.remainderTo` | `0xf2816f3f05fac35577b1930ffd09b531b62628df` |

Resulting distribution of the 1,000,000,000 BLOX the factory receives: 10% to the launch's
MerkleDistributor (swarm), 88% seeds the ETH/BLOX Uniswap v4 pool single-sided, 2% to
`economics.remainderTo`. This repository does not write `launch.json`; the manifest step does.

The launch deploys the bytecode exactly as `forge build` produces it with the pinned
`foundry.toml`, so do not change compiler settings after acceptance.

## After launch

There are no owner-settable values: the contract has no owner and no configuration. Nothing needs
to be called after deployment.

## Operational responsibilities

- **Pin the logo to IPFS** (anyone can; the CID is deterministic and must come out as
  `QmWJsrdD9smahpdyqjBzDBodJkJJGNznMA2Wrh15R1hhCp`, otherwise the file was altered):
  ```
  ipfs add --cid-version 0 assets/logo/blox.jpg
  ```
  or upload the same file through any pinning service and check the reported CID matches. Only
  pin the committed file; never re-encode, resize or regenerate it.
- **Logo distribution.** When registering the token with wallets, explorers or token lists, submit
  `assets/logo/blox.jpg` (or the IPFS URI above) unchanged. If a platform cannot take an existing
  image and insists on generating one, do not: report the limitation instead, as the brief asks.
- **Explorer verification** of the deployed contract (`forge verify-contract` with the pinned
  settings) is the deployer's step after launch, not this task's.
- **Keys and transactions.** Nothing here holds keys, broadcasts or calls the factory; IdentityMD's
  deployer launches the attested source.
- **Security review.** Tests passing is not an audit. The contract is OpenZeppelin v5.4.0
  `ERC20` + `ERC20Permit` with a single constructor mint, which keeps the surface minimal, but an
  independent adversarial review before release remains the launch policy's step.

## Verification

```
forge build
forge test
forge fmt --check
```

The tests use no environment variables, no `ffi`, no filesystem access and no network, and pass in
any order and in parallel. They cover: name/symbol/decimals; the exact supply minted once to
`msg.sender` (not `tx.origin`); the single mint `Transfer` event; on-chain logo provenance;
the swarm share and full factory payout arriving whole; fuzzed conservation of supply for
`transfer` and `transferFrom`; reverts for insufficient balance, zero receiver, missing or exceeded
allowance and zero spender; that none of the usual admin/mint/pause/blacklist/seize/burnFrom
selectors exist or move a balance, from a stranger or from the deployer; absence of
`DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT` in the runtime and the EIP-170 size limit; and `permit`
success, wrong signer, expired deadline and replay.

Tools run for this task: `forge build`, `forge test`, `forge fmt --check`. Slither and Mythril were
not available in this environment and were not run.
