# Arcter programs

On-chain code for Arcter, a self-custodial exchange for tokenized stocks on Solana. Six Anchor programs cooperate so that one wallet signature can price, check and settle a trade.

**Status:** a test deployment has been live since 7 November 2026. No audit has taken place, and every token in it is a mock with no value. Production addresses will be published separately at launch.

## Test deployment

| Program | Address | Explorer |
| --- | --- | --- |
| `arcter-config` | `2N5AqtBmZyUYbNufeMPcSuKWFYBxRzwuQ1HFPxCj7ajk` | [Solscan](https://solscan.io/account/2N5AqtBmZyUYbNufeMPcSuKWFYBxRzwuQ1HFPxCj7ajk?cluster=devnet) |
| `arcter-access` | `AjD7rqA8Ep3E7VDeCBjnqCdTkDPDgAdNUCjETMKjGxUB` | [Solscan](https://solscan.io/account/AjD7rqA8Ep3E7VDeCBjnqCdTkDPDgAdNUCjETMKjGxUB?cluster=devnet) |
| `arcter-oracle` | `FDHgEUKWuHe9FeBvcGa8dCa9KcMNpuijEFdbdjsTyGcJ` | [Solscan](https://solscan.io/account/FDHgEUKWuHe9FeBvcGa8dCa9KcMNpuijEFdbdjsTyGcJ?cluster=devnet) |
| `arcter-vault` | `Gkz6QizHjtNvMVmaTSuTnEfjrM4W83mF15PVq5j1CoY5` | [Solscan](https://solscan.io/account/Gkz6QizHjtNvMVmaTSuTnEfjrM4W83mF15PVq5j1CoY5?cluster=devnet) |
| `arcter-rfq` | `BKBsrCf2vdcfn9CzkEhfFcmAXqjPUszg7kCpx4fXBgjs` | [Solscan](https://solscan.io/account/BKBsrCf2vdcfn9CzkEhfFcmAXqjPUszg7kCpx4fXBgjs?cluster=devnet) |
| `arcter-router` | `4k5xDqZX8ry422znZoafGrA5WQVW5R9pJ4hYooU1ESXH` | [Solscan](https://solscan.io/account/4k5xDqZX8ry422znZoafGrA5WQVW5R9pJ4hYooU1ESXH?cluster=devnet) |

| Item | Address |
| --- | --- |
| Admin and upgrade authority | `5dRnCdPcHy3nha75zxoHrrzsKeQVuhMzJQBrb3sjXaCa` |
| Mock USDC mint | `6EcRnTthZbABGCc5GvZjPgNbDXNjALmakoGchUE1zCWi` |
| Treasury USDC account | `6ywEdxhNryJh7bBdZ6P1ej4dQFEtB6zsGgofv37apB7n` |

| Market | Tier | Mock mint | Market account | Feed |
| --- | --- | --- | --- | --- |
| NVDAx | A | `DJFo5WioMXHyuUwcsdmibkfrp8VhWDA3V3yrsR97oLaq` | `FjGTAZ99fFtsU69KopHngHWpxJUioTgzirP8WGqedJqq` | `Cp9XPsJr4QLDPoA7Crwz12dcju7nA2JYUxp3mYcf3tA9` |
| SPYx | A | `GoVfEj3ZJnJ93HL8YZUeVohSbtb4WDNmAszzkUqZH6ET` | `HMDUjK4iEkpEShUu8PWD5kYfVfrJLitb9h8uguyWXFgH` | `AP7jTCkMGWGJdkURybTKcFxdWFaQmPQt6cdEbjSXFwyn` |
| AAPLx | A | `AoVC7DmMcWUtsS9MY2WtdPureMwVZZ1ERJGZ5nkYHHXs` | `9MTudP6ttBxHA6GSGskTXnuroQfcJXsxuGcj35T8XX4c` | `CGNkftUaRAU8egVBvHY5pbKUCX4yq9tADVi86VxbFCCh` |
| TSLAx | B | `BXUKiZrZ7TMC1KyrhGge1ZXKezZjp4rhmUnwDxdu6idB` | `9UBjCy8FzWoQnEGSEiqMc3Dk3cTJiz3iynZeshwmei1s` | `AP2UEP4GnsmhdJzkhAa7E59JUqDzYpYP9bi1RPCrE3C3` |
| PLTRx | C | `7w4esdaQDPAiSQqo6VQfAt6KttrqqR9bos3DRrhSuvjR` | `GMmCHwrDdnkhAPU6RyxJARh355qd1Rb9K6WzudW64ySf` | `Cu7pkLwTiuP2deuZYssgBfsrXtqKk8mXAmtyvcvevBCL` |

The same data is in [`deployments/devnet.json`](deployments/devnet.json). A buy and sell of 1,000 USDC settled through the router after deployment, and each deployed binary matches the local build byte for byte.

Markets need the keeper. Without `yarn keeper`, the heartbeat lapses and every market halts within about an hour. Withdrawals stay open.

## Recent changes

- **Settlement moved to USDC.** Accounts, arguments and IDLs now use `usdc` names. In the test deployment this is a mock mint, unrelated to Circle.
- **Slim binaries.** Deployed programs omit Anchor's on-chain IDL instructions and instruction name logs, to reduce rent. Clients load IDLs from `target/idl/`.
- **New Anchor codebase.** Six Rust programs replace the earlier contracts.

## How a trade flows

```
                   Wallet signs one transaction
                               |
                      +--------v--------+
                      |  arcter-router  |  expiry, pause, market access
                      +---+---------+---+
                          |         |
                 +--------v---+ +---v---------+
                 | arcter-    | | arcter-rfq  |  signed maker quotes
                 | vault      | | prefunded   |
                 | reserves,  | | inventory   |
                 | shares     | +---+---------+
                 +---+----+---+     |
                     |    |         |
        reads Feed   |    |  reads Attestation
                     |    +----------------+
              +------v-------+      +------v-------+
              | arcter-oracle|      | arcter-access|
              +--------------+      +--------------+

      arcter-config: settings, treasury, pause, restart window
```

| Program | Job |
| --- | --- |
| `arcter-config` | Fees, regime multipliers, guardian, treasury, the delayed change queue and the restart window |
| `arcter-access` | Approved issuers and one Attestation per wallet (`TRADER`, `LP`, `MAKER`, `RELAYER`) |
| `arcter-oracle` | One Feed per asset: price, cross-check, session and derived regime |
| `arcter-vault` | Markets, reserves, share mints, deposits, withdrawals and vault fills |
| `arcter-rfq` | Maker registration, prefunded inventory and ed25519 quote settlement |
| `arcter-router` | The one trading entry point, covering `swap_exact_in` and `swap_with_quote` |

The vault and maker programs accept fills only from the router's PDA, so nobody can skip its checks.

## Accounts

| Account | Program | Seeds |
| --- | --- | --- |
| Config | `arcter-config` | `"config"` |
| Treasury | `arcter-config` | `"treasury"` |
| Queued change | `arcter-config` | `"change", id` |
| Issuer | `arcter-access` | `"issuer", key` |
| Attestation | `arcter-access` | `"attestation", wallet` |
| Feed | `arcter-oracle` | `"feed", asset_mint` |
| Market | `arcter-vault` | `"market", asset_mint` |
| Reserve | `arcter-vault` | `"reserve", market, mint` |
| Share mint | `arcter-vault` | `"shares", market` |
| Maker | `arcter-rfq` | `"maker", owner` |
| Inventory | `arcter-rfq` | `"inventory", owner, mint` |
| Quote record | `arcter-rfq` | `"quote", owner, quote_id` |
| Router authority | `arcter-router` | `"router"` |

## Pricing

All quote arithmetic lives in [`programs/arcter-vault/src/math.rs`](programs/arcter-vault/src/math.rs). It reads no accounts, so a client can reproduce any fill from public inputs.

```
half_spread = base_half_spread x regime_multiplier
skew        = max_skew x (asset_share - 50%) / inventory_band, capped at +/- max_skew
ask         = mid x (1 + max(0, half_spread - skew))
bid         = mid x (1 - max(0, half_spread + skew))
```

The fee is a separate line, and a share of the captured spread goes to the treasury. Every fill also checks the oracle band, the clip, the daily cap, the inventory band and the reserves.

| Regime | Spread | Clip |
| --- | --- | --- |
| `OPEN` | x1.0 | x1.0 |
| `EXTENDED` | x1.5 | x0.75 |
| `CLOSED` | x3.0 | x0.5 |
| `HALTED` | No quotes | None |

A market halts on any of these: a stale price, sources that disagree, a move above 25%, a paused feed, the global pause, or the hour after a suspected restart. Trades derive the regime themselves, so a late keeper cannot produce a cheap quote.

Withdrawals read no oracle and check no permission. Pauses, halts and retirement leave them open.

## Build and test

You need Rust, the [Agave CLI](https://docs.anza.xyz/cli/install) 2.3.13 and Anchor 0.32.1. `Cargo.lock` pins several crates, because the SBF compiler cannot parse their newest releases. Keep it committed.

```bash
anchor build                          # programs and IDLs
cargo test -p arcter-vault --lib      # pricing math
cd tests && cargo test                # end-to-end suite, needs anchor build first
```

The end-to-end suite runs the compiled programs in LiteSVM. Besides normal trading it attacks the system: calling the vault without the router, replaying quotes, forging or altering signatures, and spoofing Ed25519 offsets.

## Deploy a test environment

Build the slim binaries first. They drop Anchor's on-chain IDL instructions and instruction name logs, which cuts rent by about 16%, and the end-to-end suite passes against them.

```bash
for program in config access oracle vault rfq router; do
  cargo build-sbf --manifest-path programs/arcter-$program/Cargo.toml --features no-idl,no-log-ix-name
done
```

Program keypairs are in `target/deploy/` and are ignored by git. Back them up: while they stay in place, the commands below upgrade the existing programs. The test deployment used 7.18 SOL for the six programs and about 0.07 SOL for setup and first trades, nearly all of it rent.

```bash
yarn install
export ANCHOR_WALLET=~/.config/solana/arcter-devnet.json
solana airdrop 5 --url devnet --keypair $ANCHOR_WALLET    # repeat, or use faucet.solana.com

for program in config access oracle vault rfq router; do
  solana program deploy target/deploy/arcter_$program.so \
    --program-id target/deploy/arcter_$program-keypair.json \
    --url devnet --keypair $ANCHOR_WALLET --max-sign-attempts 30
done

yarn bootstrap   # first deployment only: mock mints, settings, feeds, five markets, seed liquidity
yarn keeper      # keep this running: heartbeats and test prices
yarn smoke       # buy and sell through the router
```

`yarn bootstrap` writes `deployments/devnet.json`, which is what a client needs. Without a running keeper, markets halt on stale prices, which is the intended behavior.

## Test stand-ins

These choices keep the test environment simple. Each must change before any real value is involved.

| Area | In testing | Before launch |
| --- | --- | --- |
| Prices | A publisher wallet posts test prices | Verify Chainlink Data Streams and Pyth reports on-chain |
| Tokens | Mock USDC and mock equity mints, unrelated to Circle or any issuer | Real issuer mints, after confirming each one's extensions |
| Transfer hooks | Refused at listing | Resolve hook accounts in every token movement |
| Admin | One keypair | Squads multisig with a time lock |
| Direct admin calls | `update_market` applies at once | Reached only through that multisig and its delay |
| Initialization | First caller becomes admin | Restrict to the upgrade authority |

Run `yarn bootstrap` straight after deploying, because `initialize` is open to the first caller. Then confirm the admin in `deployments/devnet.json`.

Two-asset trades are two `swap_exact_in` calls in one transaction, through USDC. Solana makes them atomic, so a failed second leg unwinds the first. Those transactions need an address lookup table to fit the size limit.

## Layout

```
programs/    the six Anchor programs
tests/       end-to-end suite (its own Cargo workspace)
scripts/     bootstrap, keeper and smoke test
deployments/ per-cluster address records
```
