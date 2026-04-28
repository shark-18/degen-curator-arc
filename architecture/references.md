# References

## Prior Art (researched and ruled out as identical)

| Protocol | URL | Mechanism | Why Different |
|---|---|---|---|
| PoolTogether V5 | https://dev.pooltogether.com/protocol/design/ | No-loss prize savings, ERC-4626 over Aave/Compound, yield auctioned via TPDA → random winners by tier (TWAB) | Closest analog. (a) Random winner vs. our pro-rata. (b) Passive yield vs. our convex YT bets. (c) TWAB vs. our position-attribution. |
| PoolTogether V5 GitHub | https://github.com/pooltogether/v5-prize-pool | Reference for prize pool patterns | Borrowing share-index pattern; not borrowing TWAB |
| Pendle Boros | https://docs.pendle.finance/Resources/PendleBoros/ | Margin/orderbook on YU funding rate | LEVERAGED — has liquidation risk. Inverse of our no-leverage spec |
| Spectra Finance | https://research.nansen.ai/articles/spectra-finance-fixed-rate-stablecoin-vaults | Fixed-rate vaults via PT/YT split | No lottery, no convex bet vault. Same primitive (YT) different product |
| MEV Capital Pendle WBTC | https://forum.morpho.org/t/mev-capital-pendle-wbtc-vault-updates/1054 | Curated Morpho vault using Pendle PT as collateral | PT-based, leverage loops, liquidatable |
| Re7 vault curation | https://www.the-edge.xyz/p/re7-the-art-of-vault-curation-and-the-future-of-onchain-asset-management | Leverage loops on Pendle PT | Liquidatable, opposite end of risk spectrum |
| Beefy auto-compounders | (various Pendle LP vaults) | Auto-compounds Pendle LP rewards | LP not YT, no lottery, no principal floor |
| Yearn V3 | https://docs.yearn.fi/ | Modular strategies, can wrap Pendle | YT exposure rare, none currently lottery-distribute |
| Sommelier Cellars | https://whisperui.com/cryptocoins/sommelier-finance | ERC-4626 cellars, off-chain strategist guidance | General-purpose; could implement dCURATOR but doesn't |
| Idle Finance Tranches | https://docs.idle.finance/developers/perpetual-yield-tranches | Senior/Junior risk tranching | Different primitive (tranching vs. convex bet) |
| Notional Leveraged Vaults | https://blog.notional.finance/introducing-leveraged-vaults/ | fCash + leverage + liquidations | Inverse mechanism |
| Premia Finance | (options vaults) | Sell-side option vaults (DOVs) | Sells premium (opposite of buy-side convex) |
| Dolomite Pendle YT | https://docs.dolomite.io/integrations/pendle/pendle-yt | Lend YT as collateral, borrow against | LEVERAGED YT, has liquidation |
| Ribbon/Aevo Theta | (DOV) | Sell covered calls / cash-secured puts | Sells optionality, loses principal in crashes |

**Verdict: dCURATOR's "Morpho-curated principal floor + yield-only sweep + pro-rata convex YT lottery" combination is unshipped as of April 2026.** PoolTogether V5 is the spiritual parent; the differences (convex bets, pro-rata, position-attribution) are material and defensible.

## Pendle Documentation (integration source)

- Pendle YT mechanics: https://docs.pendle.finance/ProtocolMechanics/YieldTokenization/YT/
- Pendle Points Trading: https://pendle.gitbook.io/pendle-academy/ecosystem-and-resources/points-trading
- Pendle Points Support / Symbiotic note: https://pendle.gitbook.io/pendle-academy/ecosystem-and-resources/points-trading/points-support-page
- Pendle AMM mechanics: https://docs.pendle.finance/ProtocolMechanics/LiquidityEngines/AMM
- Pendle PT/YT cheatsheet (post-maturity): https://pendle.gitbook.io/pendle-academy/cheatsheet-for-the-impatient/pt-yt-lp-cheatsheet
- Pendle Router V4 ABI: pendle-finance/pendle-core-v2-public

## Morpho Documentation

- Morpho Blue: https://docs.morpho.org/
- MetaMorpho (curated vaults): https://docs.morpho.org/morpho-vaults/
- Steakhouse USDC vault (mainnet reference): https://app.morpho.org/base/vault/0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183/steakhouse-usdc
- Gauntlet USDC Prime: https://app.morpho.org/base/vault/0xeE8F4eC5672F09119b96Ab6fB59C27E1b7e44b61/gauntlet-usdc-prime

## Security Patterns

- OpenZeppelin ERC4626 inflation defense: https://blog.openzeppelin.com/a-novel-defense-against-erc4626-inflation-attacks
- EIP-4626 inflation attack discussion: https://ethereum-magicians.org/t/address-eip-4626-inflation-attacks-with-virtual-shares-and-assets/12677
- SushiBar / MasterChef accRewardPerShare: https://rareskills.io/post/staking-algorithm
- EIP-1153 transient storage (reentrancy guards): https://eips.ethereum.org/EIPS/eip-1153
- EIP-7201 namespaced storage: https://eips.ethereum.org/EIPS/eip-7201
- EIP-1822 UUPS proxy: https://eips.ethereum.org/EIPS/eip-1822

## Notable Exploits Studied (and our mitigations)

| Exploit | Year | Loss | Mechanism | Our Mitigation |
|---|---|---|---|---|
| Cream Finance USDT vault | 2021 | (small) | First-depositor inflation attack | OZ ERC4626 with `_decimalsOffset = 6` |
| Euler Finance | 2023 | $197M | Donation attack on share price (different mechanic, same family) | Same — virtual shares |
| Mango Markets | 2022 | $117M | Operator-controlled oracle manipulation | We have ZERO oracles. Cannot be Mango'd |
| Cream/Convex read-only reentrancy | 2023 | ~$50K | Curve LP price-per-share read during reentrancy | All `pricePerShare` views read from non-reentrant Morpho calls |
| Inverse Finance | 2022 | $15M | Stale oracle exploit | We have no oracles |
| BonqDAO | 2023 | $120M | Oracle manipulation via low-liquidity pool | We have no oracles |

## Foundry / Tooling

- Foundry: https://getfoundry.sh/
- Solady: https://github.com/Vectorized/solady
- OpenZeppelin Contracts 5.1.0: https://github.com/OpenZeppelin/openzeppelin-contracts/releases/tag/v5.1.0
- Slither: https://github.com/crytic/slither
- 4naly3er: https://github.com/Picodes/4naly3er
- Halmos: https://github.com/a16z/halmos (Phase 2)

## Audit Service Tiers

| Service | Cost | Time | Best For |
|---|---|---|---|
| Slither + 4naly3er + Codex review | Free | 1 hr | Day 5 first pass |
| Spearbit office hours | Free | 30 min | Architectural sanity check |
| Cantina micro-audit | $3-5K | 3-5 days | StrategyExecutor + LotteryTreasury (riskiest 2) |
| Code4rena Lite | $5-10K | 1 week | Post-mainnet, scaled to TVL |
| Trail of Bits / Spearbit / Halmos | $50K+ | 4-8 weeks | Phase 3 cap raise to $10M+ |
| Immunefi bug bounty | $25-50K cap | Continuous | Post-launch, ongoing |

## Backtest

- Notebook: `convex_lottery_backtest.ipynb` (this repo)
- GitHub: https://github.com/shark-18/degen-curator-arc
- Open in Colab: https://colab.research.google.com/github/shark-18/degen-curator-arc/blob/main/convex_lottery_backtest.ipynb
- 1-year window, 48 markets, 4 strategy variants, full fee model
- Winner: V2 (cheap-FDV bottom quartile + 30d momentum) — 877% modeled annualized treasury return
- **Caveat (Research agent finding):** Backtest assumed YT held to maturity captures airdrop value. Points YTs do NOT auto-redeem to USDC at maturity. Re-run needed assuming exit at AMM mark pre-maturity. Conservative re-run estimated at 40-60% of the 877% figure (~350-525% annualized treasury return). User-facing claim should be **"modeled upside, see backtest assumptions"** not a specific %.
