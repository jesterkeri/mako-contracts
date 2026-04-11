# Mako Markets — Contracts

Short-form parimutuel prediction markets on Monad.

Built for **Monad Blitz Lagos** — April 11, 2026.

## What it is

A single Solidity contract (`MakoMarkets.sol`) that lets anyone:

- **Create** a YES/NO prediction market (football fixture, crypto price, or ad-hoc)
- **Bet** native MON on either side until `closeTime`
- **Resolve** the market via an off-chain resolver (football-data.org, CoinGecko, or admin)
- **Claim** winnings — pool is split parimutuel-style, minus 2% protocol fee and 1% creator fee

Zero external dependencies. No OpenZeppelin, no oracles wired in. Pure EVM.

## Payout math

Parimutuel, like horse racing. Your payout is proportional to the ratio of your side to the total pool:

```
totalPool   = totalYes + totalNo
payoutPool  = totalPool * 0.97            # 3% total fees
your_payout = your_bet * payoutPool / winning_side_pool
```

One-sided pools (nobody took the other side) auto-refund all bettors — no fees taken.

## Market types

| Type      | `oracleRef` encoding                      | Resolved by                  |
|-----------|-------------------------------------------|------------------------------|
| FOOTBALL  | `matchId:qType:param` (bytes32 utf-8)     | off-chain cron + football-data.org |
| CRYPTO    | `symbol:direction:strike`                 | off-chain cron + CoinGecko   |
| ADHOC     | `bytes32(0)`                              | market creator / admin       |

## Usage

```bash
forge install
forge build
forge test -vv
```

### Deploy to Monad testnet

```bash
cp .env.example .env   # fill in PRIVATE_KEY and TREASURY
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://testnet-rpc.monad.xyz/ \
  --private-key $PRIVATE_KEY \
  --broadcast -vvv
```

## Test coverage

9 tests covering the full lifecycle, the math, access control, and the most exploitable edge cases:

- Happy path: create → bet → resolve → claim
- Parimutuel math matches spec to 12-decimal precision on a 60/40 split
- Zero-pool auto-refund (the classic parimutuel footgun)
- Double-claim reverts (both `claim` and `claimCreatorFee`)
- Bet after `closeTime` reverts
- Non-resolver cannot resolve
- Treasury accrues exactly 2%
- Creator fee is exactly 1%
- Football markets run the same codepath as crypto

## License

MIT
