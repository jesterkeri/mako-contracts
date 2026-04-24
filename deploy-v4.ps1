# Deploy MakoMarketsV4 to Monad testnet.
#
# Prerequisites (all in the current PowerShell session):
#   1. bw unlock has been run, and $env:BW_SESSION is set.
#   2. $env:TREASURY     = "0xC8BF886f73E4371CBd8160EEA7683b8Da98190F1"
#   3. $env:USDC_ADDRESS = "0x534b2f3A21130d7a60830c2Df862319e593943A3"
#   4. Current directory is mako-contracts (not required, but the paths assume it).
#
# Usage from mako-contracts directory:
#   .\deploy-v4.ps1

# Make foundry visible to this session if it isn't already.
if (-not (Get-Command forge -ErrorAction SilentlyContinue)) {
    $env:PATH = "$env:PATH;C:\Users\hr\.foundry\bin"
}

# Guardrails so a missing env var produces a clear message instead of a silent failure.
if (-not $env:BW_SESSION)   { Write-Error "BW_SESSION not set. Run 'bw unlock' and paste the session line first."; exit 1 }
if (-not $env:TREASURY)     { Write-Error "TREASURY not set. Run: `$env:TREASURY='0xC8BF886f73E4371CBd8160EEA7683b8Da98190F1'"; exit 1 }
if (-not $env:USDC_ADDRESS) { Write-Error "USDC_ADDRESS not set. Run: `$env:USDC_ADDRESS='0x534b2f3A21130d7a60830c2Df862319e593943A3'"; exit 1 }

Write-Host "Deploying MakoMarketsV4 to Monad testnet..." -ForegroundColor Cyan
Write-Host "  TREASURY     = $env:TREASURY"
Write-Host "  USDC_ADDRESS = $env:USDC_ADDRESS"
Write-Host ""

& node "../mako-markets/scripts/with-bw.mjs" forge script "script/DeployV4.s.sol:DeployV4" --rpc-url monad_testnet --broadcast --legacy
