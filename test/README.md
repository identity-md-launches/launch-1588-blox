# Blox test coverage

Run from the repository root:

```sh
forge build
forge test
python3 test/verify_logo.py
```

The original `BloxToken.t.sol` suite is retained. Added coverage:

| File | Properties |
| --- | --- |
| `BloxTokenBehavior.t.sol` | Exact constructor log; zero, one wei, full supply and maximum integer inputs; self-transfers; finite/infinite approval spending; replacement and revocation; owner/spender isolation; failed transfer rollback; round trips and split transfers. |
| `BloxTokenPermit.t.sol` | Independently encoded signing domain; deadline boundary; relaying and actual spending; zero/max allowances; nonce isolation; replay after spending; altered signed fields; future nonces; different deployments and chains; malformed and malleable signatures; failed permits preserve existing allowance and nonce. |
| `BloxTokenInvariant.t.sol` | Random sequences of 15 actions across the deploying contract and four signers. An independent ledger checks each balance, all 25 allowance pairs and each nonce after every action, alongside fixed supply and aggregate conservation. |
| `verify_logo.py` | Offline verification of the existing JPEG digest, metadata and both IPFS CIDs. Python standard library only. |

The new stateless fuzz suites use 1,000 runs. The invariant campaign uses 256 runs of
128 calls, with unexpected reverts treated as failures. These settings are inline in
the Solidity test files. Failure actions expect the specific rejection and leave the
model untouched; they exercise overdraws, unapproved spending, zero recipients,
expired/replayed permits, and unavailable privileged functions. A deterministic
sequence additionally checks that positive transfers and spending are reachable.

The handler distributes the constructor supply using actual transfers. It does not
mint test tokens, overwrite contract storage, or copy token state into its model.
Actors can send to themselves and spend their own approvals. Approvals and permits
are independent actions, so later spending observes earlier revocations and partial
consumption. Time changes use `vm.warp`; there are no real-time waits.

All submitted checks work offline and use the already vendored dependencies. They
do not set environment variables, use forks or FFI, broadcast transactions, or
change deployment configuration. The supplied protected factory/Uniswap harness
was read as an acceptance reference; this repository has no factory or PoolManager
implementation to execute that integration locally. The tests cover the delivered
token's behavior and do not claim to verify a live launch or actual pool swaps.

## Logo verification limits

On 2026-10-13, the original image at the metadata's `pbs.twimg.com` URL returned
56,060 bytes identical to `assets/logo/blox.jpg`, with SHA-256
`c2aeb53e69e10a7a4654a97ce8b26bd0a99a843d024ad6f09f6f7d235ca2eaec`.
No image was generated, edited, resized, or replaced.

The X profile-page request returned HTTP 403 and the profile syndication endpoint
returned HTTP 429. Matching the image URL does **not** independently prove that the
account still selects that image as its current profile picture. The offline asset
checks establish byte integrity and metadata consistency, not current X account
state or IPFS pinning/availability. The implementation already documents that
pinning remains an operational step.
