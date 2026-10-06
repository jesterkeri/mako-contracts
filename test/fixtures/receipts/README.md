# Captured Monad testnet receipts

`eth_getTransactionReceipt` responses from the pinned public endpoint (`monad_testnet` in foundry.toml), as
forge's `vm.rpc` returns them (its ABI encoding of the JSON object), captured 2026-10-06 so the deploy script's
receipt decoder is tested offline too. Re-capture with `vm.rpc("monad_testnet", "eth_getTransactionReceipt",
'["<hash>"]')` and `console.logBytes`.

- `monad-v4-create-receipt.hex`: `0x820d7d68d9bf1bf54aa15cd33370e8baac6bd7e57b0670509a26f137ced39740`, the CREATE
  of live MakoMarketsV4 `0xbC5A58487D7949dA2B76aC84AfC032fD0aa26195` (status 0x1, block 0x1f17e1e, `to` null).
  It matches `broadcast/DeployV4.s.sol/10143/run-latest.json`.
- `monad-call-receipt.hex`: `0x5d8e177a4206fc7d9acaf0641f04f4c880260cbf11eb7a835a1e5c7c9a1460be`, an ordinary
  call (status 0x1, block 0x415f626, `to` 0x…1000, `contractAddress` null).
