# Selcier protocol

Smart contracts that let a private company put its share classes on Robinhood Chain. Product guides live at [docs.selcier.xyz](https://docs.selcier.xyz); this file covers the source.

## At a glance

| | |
| --- | --- |
| Target chain | Robinhood Chain, which is built on Arbitrum and settles to Ethereum. Deployed. |
| Build stack | Foundry with Solidity 0.8.26, via-IR and the Cancun EVM |
| Libraries | OpenZeppelin Contracts 5.2.0 and forge-std 1.9.7, managed by Soldeer |
| Test suite | 74 unit and integration tests |

Each company gets one deployment, and each share class inside it becomes a Selcier Share Token. Rules travel with the token, so a transfer that breaks them cannot settle. Raising capital, Liquidity Windows, signed quotes, payouts, voting and document anchoring all sit in that same deployment. Activity is recorded through events, which makes the history of a company publicly checkable, and nothing that identifies a person goes on-chain.

## Source map

```
src/
  core/         SelcierFactory, SelcierShareToken, IssuerTimelock
  identity/     IdentityRegistry, TrustedVerifiers
  compliance/   RuleEngine
    rules/      BaseModule and the eight rule modules
  markets/      OfferingVault, LiquidityWindow, RFQSettlement, PoolGate
  shareholder/  DistributionVault, Governance, DisclosureRegistry, ValuationOracle
  api/          interfaces for integrators
  shared/       Roles, ReasonCodes, Topics, Clock
  testing/      MockStablecoin, a mintable stablecoin for testnets
script/         Deploy.s.sol, Seed.s.sol
test/           Base.t.sol plus one suite for each area
deployments/    per-chain addresses, written by Deploy.s.sol
```

Each file is named after the main contract it holds.

## What gets deployed

Everything starts at `SelcierFactory`. It holds no role on what it creates.

```
SelcierFactory, owned by Selcier
 └── one set per company
      ├── IssuerTimelock        delayed M-of-N execution, DEFAULT_ADMIN across the set
      ├── TrustedVerifiers      maps identity providers to the claim topics they may sign
      ├── IdentityRegistry      links wallets to identities and stores signed claims, no personal data
      ├── OfferingVault         escrowed primary raises with pro-rata allocation, minting at close, refunds
      ├── LiquidityWindow       single-price batch auctions and fixed-price tenders, ROFR priority included
      ├── RFQSettlement         atomic settlement of EIP-712 quotes between eligible holders
      ├── DistributionVault     record-block payouts that each holder claims
      ├── Governance            cross-class snapshot voting with checkpointed delegation
      ├── DisclosureRegistry    SHA-256 document fingerprints
      └── one set per share class
           ├── SelcierShareToken   ERC-20 behind a UUPS proxy, with ERC-3643 methods and an ERC-8056 multiplier
           ├── RuleEngine ──► cloned rule modules, a separate set for each class
           ├── ValuationOracle     Reference Valuation behind a Chainlink AggregatorV3 interface
           └── PoolGate            added only for classes trading in permissioned AMM pools
```

Modules and company-level contracts are EIP-1167 clones of shared implementations. Tokens use ERC1967 proxies instead, because a company may need to upgrade: that goes through its own timelock and waits seven days.

## Transfer checks

The answer to `canTransfer(from, to, amount)` comes from three stages, and evaluation ends at the first failure.

| Stage | Tests | Possible codes |
| --- | --- | --- |
| Token | Paused state, wallets in recovery or with freezes, unlocked balance | `TOKEN_PAUSED`, `FROZEN`, `INSUFFICIENT_UNLOCKED_BALANCE` |
| Identity | Registered identity with live `IDENTITY_VERIFIED` and `SCREENED` claims for every non-agent party | `SENDER_NOT_VERIFIED`, `RECIPIENT_NOT_VERIFIED`, `CLAIM_EXPIRED` |
| Modules | Each enabled module, in the company's chosen order | The reason code of the first module to fail |

`transfer`, `transferFrom` and `mint` use the same logic and revert with `TransferNotAllowed(reasonCode)` on failure. Codes are left-aligned `bytes32` strings defined in `src/shared/ReasonCodes.sol`.

Agents are exempt on their own side of a transfer, for both identity checks and the sender or recipient half of each module. The company's `LiquidityWindow` always counts as one, as does any contract with a valid `VENUE` claim for that token, such as an approved pool. In practice this means rules bind the buyer and seller, while the escrow between them is left alone.

## Module reference

| Id | Contract | `abi.encode` configuration | Failure code |
| --- | --- | --- | --- |
| `REGION` | `RegionModule` | `(uint8 mode, bytes2[] regions)`. Mode 0 allows the list, mode 1 blocks it | `REGION_BLOCKED` |
| `ELIGIBILITY` | `EligibilityModule` | `(uint8 minimumTier, bool exemptEmployees)` | `NOT_ELIGIBLE` |
| `HOLDING_PERIOD` | `HoldingPeriodModule` | `(uint32 period, bytes32[] sources, uint32[] periods, address[] operators, bytes32[] operatorSources)` | `HOLDING_PERIOD_ACTIVE` |
| `HOLDER_CAP` | `HolderCapModule` | `(uint32 maxHolders)` | `HOLDER_CAP_REACHED` |
| `TRANSFER_WINDOW` | `TransferWindowModule` | `(Window[] windows, bool allowDuringLiquidityWindows, address liquidityWindow)` | `WINDOW_CLOSED` |
| `ROFR` | `ROFRModule` | `(address holder, uint32 noticePeriod, address[] exemptVenues)` | `ROFR_PENDING` |
| `MAX_OWNERSHIP` | `MaxOwnershipModule` | `(uint16 maxBps, bool applyToMints, address[] exemptIdentities)` | `MAX_OWNERSHIP_EXCEEDED` |
| `EMPLOYEE_VESTING` | `EmployeeVestingModule` | `(uint8 action, bytes payload)`. The registrar adds grants with `addGrants` | `UNVESTED` |

Enable identity-counting modules before the first mint. Holder caps, ownership caps and vesting all track balances per identity, and they can't reconstruct history. Holding periods work differently: they follow per-wallet lots, spending the oldest first.

## Permissions

| Role | Assigned to | Allows |
| --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | `IssuerTimelock` | Module changes, upgrades, verifier changes, fee and agent settings, role grants |
| `ISSUER_ADMIN` | Company multi-sig | Offerings, windows, distributions, proposals, multiplier scheduling, document anchoring, valuation publishing |
| `REGISTRAR` | Company registrar | Minting, burning, freezing, executing recoveries, adding vesting grants |
| `OPERATOR` | Selcier's per-company relayer | Identity registration, co-approval of recoveries |
| `PAUSER` | Issuer admin and registrar | Instant pause and unpause |
| `MINTER` | `OfferingVault` | Minting at offering close |

Delays are floors: a company may raise any of them but can't go lower.

| Operation | Shortest allowed wait |
| --- | --- |
| `upgradeToAndCall` on the token | 7 days |
| Adding, removing or configuring a module | 24 hours |
| Any other timelocked call | 48 hours |
| Scheduling a multiplier change on the token | 48 hours |
| Wallet recovery, approved by two of issuer, registrar and operator | 72 hours by default, 48 at the least |

## Block numbers on Arbitrum

`block.number` on an Arbitrum chain tracks L1, so it advances far too slowly for snapshots. `src/shared/Clock.sol` reads the L2 number from the ArbSys precompile for record blocks and vote snapshots. Where that precompile doesn't exist, as in local tests, it uses `block.number`.

## Working locally

```sh
forge soldeer install        # downloads libraries into dependencies/
forge build
forge test
forge test -vvv --match-path test/LiquidityWindow.t.sol
```

The test `test_DocumentedAuctionExample` in `test/LiquidityWindow.t.sol` runs the auction walkthrough from the docs, which stops the docs and the contract from drifting apart.

## Live deployment

Source code for every address below is verified as an exact match on [Sourcify](https://repo.sourcify.dev/46630/0x268DB2f7BFB5C86003C5dfE3C34A8166A4ff5E76).

| Contract | Address |
| --- | --- |
| `SelcierFactory` | [`0x268DB2f7BFB5C86003C5dfE3C34A8166A4ff5E76`](https://explorer.testnet.chain.robinhood.com/address/0x268DB2f7BFB5C86003C5dfE3C34A8166A4ff5E76) |
| Test stablecoin (`MockStablecoin`) | [`0xBa70900daD421071785286329E7E7b653D7c47a5`](https://explorer.testnet.chain.robinhood.com/address/0xBa70900daD421071785286329E7E7b653D7c47a5) |

### Shared implementations

Company contracts and modules are clones of these, and share tokens are proxies pointing at `SelcierShareToken`.

| Contract | Address |
| --- | --- |
| `SelcierShareToken` | [`0x66d211e48757f96d12d0c4cf18d805526c3df5a6`](https://explorer.testnet.chain.robinhood.com/address/0x66d211e48757f96d12d0c4cf18d805526c3df5a6) |
| `RuleEngine` | [`0x209d5b3ba4b232f6244b41a1627f3d9b6ffa0baa`](https://explorer.testnet.chain.robinhood.com/address/0x209d5b3ba4b232f6244b41a1627f3d9b6ffa0baa) |
| `ValuationOracle` | [`0x3b722135c40619f58ec699ec85d3359beede621f`](https://explorer.testnet.chain.robinhood.com/address/0x3b722135c40619f58ec699ec85d3359beede621f) |
| `PoolGate` | [`0x707b459308062058e8a36d2dc860e4c470cdcaf0`](https://explorer.testnet.chain.robinhood.com/address/0x707b459308062058e8a36d2dc860e4c470cdcaf0) |
| `IssuerTimelock` | [`0x09041ec3c6bf02e0990004161d10f6d3e2544fc2`](https://explorer.testnet.chain.robinhood.com/address/0x09041ec3c6bf02e0990004161d10f6d3e2544fc2) |
| `TrustedVerifiers` | [`0x50f0e6a415bc40cf60b5fe2727b81c9225bb4566`](https://explorer.testnet.chain.robinhood.com/address/0x50f0e6a415bc40cf60b5fe2727b81c9225bb4566) |
| `IdentityRegistry` | [`0x02bbf4b94d35ab8d4eef72a241c3ee550a2f201c`](https://explorer.testnet.chain.robinhood.com/address/0x02bbf4b94d35ab8d4eef72a241c3ee550a2f201c) |
| `OfferingVault` | [`0xf091a0a308e7a419569294f9f54c1f82e0f83688`](https://explorer.testnet.chain.robinhood.com/address/0xf091a0a308e7a419569294f9f54c1f82e0f83688) |
| `LiquidityWindow` | [`0xf9cbf8306a705973f76a5b3dbf83477db9b6cc10`](https://explorer.testnet.chain.robinhood.com/address/0xf9cbf8306a705973f76a5b3dbf83477db9b6cc10) |
| `RFQSettlement` | [`0xa8596c438ecdd908409d97dc52be8ea1282fd9c8`](https://explorer.testnet.chain.robinhood.com/address/0xa8596c438ecdd908409d97dc52be8ea1282fd9c8) |
| `DistributionVault` | [`0x5c0ca86e4e2c8ad60c1a4618821595d1a2cc4d62`](https://explorer.testnet.chain.robinhood.com/address/0x5c0ca86e4e2c8ad60c1a4618821595d1a2cc4d62) |
| `Governance` | [`0x36caed33a05ddeb846e50d259652b0ed708c9c77`](https://explorer.testnet.chain.robinhood.com/address/0x36caed33a05ddeb846e50d259652b0ed708c9c77) |
| `DisclosureRegistry` | [`0x045ee11411b1d2b1796aa2ca11f3ad23f8ed1c03`](https://explorer.testnet.chain.robinhood.com/address/0x045ee11411b1d2b1796aa2ca11f3ad23f8ed1c03) |
| `RegionModule` | [`0x8f211e2ce157b188d2ca204f9be63161f3b32f81`](https://explorer.testnet.chain.robinhood.com/address/0x8f211e2ce157b188d2ca204f9be63161f3b32f81) |
| `EligibilityModule` | [`0x8133d7e4eeb5c958e3ff0207bece3512dd528784`](https://explorer.testnet.chain.robinhood.com/address/0x8133d7e4eeb5c958e3ff0207bece3512dd528784) |
| `HoldingPeriodModule` | [`0xcf51f83a8ab488ae0d1a48e32af02b89b3ad0508`](https://explorer.testnet.chain.robinhood.com/address/0xcf51f83a8ab488ae0d1a48e32af02b89b3ad0508) |
| `HolderCapModule` | [`0x324b7d23799cc6ce9b5a1cfe060dd6884ac954e6`](https://explorer.testnet.chain.robinhood.com/address/0x324b7d23799cc6ce9b5a1cfe060dd6884ac954e6) |
| `TransferWindowModule` | [`0xe2d82b3e82ad4094dcfcd2500e6b6c4544c8fab0`](https://explorer.testnet.chain.robinhood.com/address/0xe2d82b3e82ad4094dcfcd2500e6b6c4544c8fab0) |
| `ROFRModule` | [`0x3e6f1050a7efc4cb5ef934d52f21d11cd9d9bf62`](https://explorer.testnet.chain.robinhood.com/address/0x3e6f1050a7efc4cb5ef934d52f21d11cd9d9bf62) |
| `MaxOwnershipModule` | [`0xf46c85e6eda8a94c0a335196896099ceb2f86156`](https://explorer.testnet.chain.robinhood.com/address/0xf46c85e6eda8a94c0a335196896099ceb2f86156) |
| `EmployeeVestingModule` | [`0x12f8075c63e6eaade05afcce1ef3d90e0ccbfb9f`](https://explorer.testnet.chain.robinhood.com/address/0x12f8075c63e6eaade05afcce1ef3d90e0ccbfb9f) |


A run deploys all implementations and the factory, registers the eight modules, sets the default verifier, then records addresses in `deployments/<chain id>.json`. The latest testnet run consumed 40.6M gas.

Set `DEPLOY_DEMO=false` to skip the sample issuer. Otherwise the script also creates **Larkway Labs**, a fictional company in which the deployer holds every role:

* `COMMON` blocks sanctioned regions, asks for tier 1 eligibility with an employee exemption, allows up to 2,000 holders, and locks offering allocations for 90 days.
* `SERIES_B` asks for tier 2 and stops any single holder passing 25% through transfers.
* The deployer is verified with 1,000,000 Common and 250,000 Series B shares, and a Series B offering at 25 USDG per share runs for 30 days.

Leaving `USDG` empty makes the script deploy a 6-decimal stablecoin with open minting. That token exists for testing, and the script won't deploy it on mainnet.
## Testnet deployment (Robinhood Chain 46630)

| Contract | Address |
|---|---|
| SelcierFactory | `0x8a3D4e7FC28c1948ab9A00E8886D150B73822b6e` |
| IdentityRegistry | `0x2e04cF46BbEF9e5f8b7f6A4C15C9A3D9e2bAe5c` |
| TrustedVerifiers | `0xaF5C9e8D12B7c3E64f1A2b5d0C8eF3A7B9D4E6c` |

> Addresses may change between redeployments. Use `GET /v1/contracts` for the canonical list.
