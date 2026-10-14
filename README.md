# Mako Market: Contracts

Solidity contracts for [Mako Market](https://makomarket.xyz), a prediction market on Monad. App and services: [jesterkeri/mako-markets](https://github.com/jesterkeri/mako-markets).

## Live on Monad testnet (chain 10143)

| Contract | Source | Address |
|---|---|---|
| Pools (YES/NO parimutuel, USDC) | [`src/MakoMarketsV4.sol`](src/MakoMarketsV4.sol) | [`0xbC5A58487D7949dA2B76aC84AfC032fD0aa26195`](https://testnet.monadvision.com/address/0xbC5A58487D7949dA2B76aC84AfC032fD0aa26195) |
| Rounds (15-minute Up or Down, USDC) | [`src/MakoRoundsV1.sol`](src/MakoRoundsV1.sol) | [`0x9dC0e0b9E8F1905740D8B98E90fe07288dcC2921`](https://testnet.monadvision.com/address/0x9dC0e0b9E8F1905740D8B98E90fe07288dcC2921) |

## What each contract does

- **`MakoMarketsV4`**: anyone opens a YES/NO pool; bets go into one pot and winners split it. The creator earns 2% only when both sides hold real money; a one-sided pool refunds everyone.
- **`MakoRoundsV1`**: rounds scheduled by Mako Market. Entries close when the round starts. Open and close prices are Chainlink Data Streams reports, verified on chain through the Data Streams verifier proxy; a one-sided round, or one with no valid report, refunds everyone.
- **`RoundSettlement`** ([`src/RoundSettlement.sol`](src/RoundSettlement.sol)): the library that checks a Data Streams v3 report against the round's boundary second (feed, schema, timestamps, bid/ask spread, expiry) before it can settle anything.
- **`MakoPrivateMarketsV1`**: invite-only markets; not enabled in the app.
- **`MakoMarkets`**: the original April 2026 contract from Monad Blitz Lagos (native MON), kept for history and superseded by V4.

## Build and test

```bash
forge build
forge test
```

Fork tests against the real Data Streams verifier run when a Monad testnet RPC is configured (`foundry.toml` alias `monad_testnet`); without one they skip.
