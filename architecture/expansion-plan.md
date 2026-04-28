# Expansion Plan — Phase 2, 3, 4

Cores (`PrincipalVault`, `LotteryTreasury`, `PositionManager`) are immutable forever. Every expansion either deploys new periphery contracts or adds new periphery contracts that compose with existing cores. Storage layout for periphery uses EIP-7201 namespaces — new versions get new namespaces.

## Phase 2 — Hardening (Weeks 2-4 post-launch)

### F2.1 — Automated Keeper Bot
- **Lives in:** New off-chain service (Gelato or self-hosted Node)
- **Interface:** Calls existing `YieldSweeper.sweep()` and `StrategyExecutor.runWeeklyCycle()`
- **Storage changes:** None
- **Migration:** Existing manual cycle continues to work; keeper takes over on a setting flip
- **Complexity:** S (1-2 days)

### F2.2 — Position-Attribution Merkle Distributor
- **Lives in:** New `RewardsDistributor.sol` periphery contract
- **What it solves:** xSUSHI-style "deposit just before settlement, claim, withdraw" front-run
- **Implementation:** Off-chain indexer computes per-cycle Merkle root of (user, claimable). User claims via Merkle proof. Posted on-chain by curator after cycle close.
- **Storage changes:** New namespace `dcurator.storage.v1.RewardsDistributor`
- **Migration:** Replaces direct `LotteryTreasury.claim()` flow; existing claims grandfathered for 30 days
- **Complexity:** M (3-5 days)
- **Note:** This is the v1 trade-off — v1 ships with simple sushibar-style claim that has a small front-run window; v2 closes it via Merkle.

### F2.3 — SBT Round Receipts
- **Lives in:** New `CycleNFT.sol` (ERC-721, soulbound)
- **What it does:** At end of each cycle, mints commemorative NFT to all depositors who held during that cycle. Unique tokenId per (cycleId, user). Visible on-chain badge for "I was in the round when X printed."
- **Storage changes:** Standalone, reads from PrincipalVault events
- **Migration:** Retroactive — can mint SBTs for cycles 1-N from indexed events
- **Complexity:** S (1-2 days)

### F2.4 — Enhanced Off-Chain Indexer
- **Lives in:** Subgraph (TheGraph hosted) + custom Node service
- **What it does:** Powers the dashboard with real-time cycle history, edge metrics, position outcomes
- **No on-chain changes**
- **Complexity:** M (3-5 days)

### F2.5 — Cantina Audit Findings
- Implement any findings from the $5K micro-audit
- **Complexity:** Variable

### F2.6 — Immunefi Bug Bounty
- $25K-$50K cap (scaled to TVL)
- No code changes, operational
- **Complexity:** S (1 day setup)

## Phase 3 — Growth (Weeks 5-12)

### F3.1 — Polymarket Integration
- **Lives in:** New `PolymarketStrategyExecutor.sol` (parallel to existing Pendle StrategyExecutor)
- **What it does:** Adds Polymarket conditional tokens (ERC-1155) as a second convex source. Treasury deploys 70% Pendle / 20% Polymarket / 10% reserve per the original spec.
- **Storage changes:** None on cores. New periphery namespace.
- **Migration:** Curator whitelists Polymarket markets in addition to Pendle markets. New StrategyExecutor wired via `Wiring.setStrategyExecutor()` (or runs alongside via `Wiring.addStrategyExecutor()` after Wiring upgrade)
- **Complexity:** L (1-2 weeks; Polymarket UMA settlement is the wrinkle)

### F3.2 — Deep OTM Options Layer
- **Lives in:** New `OptionsStrategyExecutor.sol`
- **Venue:** Lyra v2 (Derive) on Optimism — bridges treasury USDC to OP, executes there
- **What it does:** 10% of treasury into deep OTM mid-cap calls (SOL/INJ/SUI/etc.) ahead of catalysts
- **Cross-chain complexity:** Use LayerZero or CCTP for treasury bridging
- **Migration:** Bigger lift; defer to Phase 3 mid-late
- **Complexity:** L (2-3 weeks)

### F3.3 — Multi-Curator Support
- **Lives in:** Modified `Curator.sol` (UUPS upgrade) → `MultiCurator.sol`
- **What it does:** Whitelisted set of curators; users pick which curator's vault to deposit into. Each curator has independent basket selection. Performance leaderboard.
- **Storage changes:** New struct in same namespace; storage upgrade-compatible via `__gap`
- **Migration:** Existing users migrate or stay with default curator
- **Complexity:** L (1-2 weeks)

### F3.4 — Cap Raise to $10M
- Requires fresh audit pass
- No code changes, governance + multisig action
- **Complexity:** S (1 day) + audit timeline

### F3.5 — Boosted Yield via Morpho Rewards
- **What it does:** Some Morpho USDC vaults pay reward tokens (e.g., MORPHO). Forward those to LotteryTreasury as bonus budget.
- **Lives in:** New `RewardsForwarder.sol` periphery
- **Complexity:** S (1-2 days)

## Phase 4 — Scale (Months 4+)

### F4.1 — Multi-Chain Deployment
- Same codebase, deploy to Arbitrum + Mainnet
- Per-chain treasury (no cross-chain treasury complexity)
- Per-chain curator multisig
- **Complexity:** M per chain (deploy + audit + monitor)

### F4.2 — ETH-Denominated Vault Variant
- **Lives in:** New deployment of all 7 contracts with `asset = WETH` and Pendle ETH PT/YT markets
- **Why:** Many Pendle markets are ETH-denominated; ETH-native users prefer no-conversion exposure
- **Complexity:** M (mostly redeploy + new whitelist)

### F4.3 — Institutional Wrapper
- **Lives in:** New `InstitutionalWrapper.sol` proxy on top of dCURATOR
- **What it does:** KYC gating, whitelist of approved institutional addresses, custom fee tier
- **No core changes**
- **Complexity:** L (compliance work dominates)

### F4.4 — Token Launch (if narrative warrants)
- Pure governance token, no fee switch in core
- Used for: curator selection voting, parameter governance, community treasury
- **Lives in:** New `Governance.sol` + ERC-20 token
- **Complexity:** L (governance design + distribution mechanics)

### F4.5 — Cross-Chain Lottery Aggregation
- Distant future: bridge winnings across chains for unified payout
- **Complexity:** XL (months)

---

## Migration Principles (apply to every expansion)

1. **No expansion modifies core contracts.** PrincipalVault, LotteryTreasury, PositionManager are read-only after deploy.
2. **Periphery upgrades use UUPS + 48h timelock + EIP-7201 storage.** Storage compatibility verified via `forge inspect storage`.
3. **Replacement-via-Wiring** preferred over UUPS upgrade for clean strategy swaps. Deploy new periphery contract, call `Wiring.setStrategyExecutor(newAddr)`. Old contract abandoned but immutable.
4. **Parallel deployment** preferred over replacement when possible. Multiple StrategyExecutors can run simultaneously (Pendle + Polymarket + Options) with a router that splits treasury allocations.
5. **Existing users untouched** by every migration. Their shares, principal, and pending claims survive any periphery change.
6. **Cap raises require fresh audit pass.** No exceptions.

## Decision Matrix: When to Build Each Phase

| Trigger | Action |
|---|---|
| TVL hits $1M cap with waitlist | Cap raise to $10M (Phase 3) |
| First cycle hits 5x payout | Phase 2 narrative push, SBT receipts |
| Second cycle goes to zero | Phase 2 communication + transparency dashboard |
| Cantina audit clean + 30 days clean operation | Lift training wheels, automate keeper |
| 1000 depositor cap hit fast (< 7 days) | Investigate sybil; consider lifting cap to 5K |
| Pendle cuts a major market | Activate emergency procedure runbook |
| Major airdrop hits → big payout | Phase 2 SBT mint + viral push |
| Competitor copycat appears | Phase 3 differentiation features (multi-curator, options layer) |

## What Will NEVER Be Built (firm commitments)

- ❌ Leverage of any kind on user principal
- ❌ Liquidatable positions
- ❌ Borrow facilities against deposits
- ❌ Custom oracle dependencies (we are oracle-free; that's a feature, not a bug)
- ❌ Permissioned curator with no recourse
- ❌ Closed-source contracts
- ❌ Off-chain custody of any user funds at any layer
