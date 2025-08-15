# Advanced Lending Protocol (Foundry + Chainlink)

A gas-conscious DeFi lending engine with collateralized borrowing, real-time pricing via Chainlink oracles, health-factor based risk controls, and liquidation. Built during a learning sprint inspired by @CyfrinUpdraft.

> ✅ **Status:** Codebase complete & configured for **ANVIL** testing.  
> 🧪 Includes deployment script, helper config, mock price feeds, and a starter test suite.

---

## ✨ Features

- **Collateralized Borrowing** — Deposit approved ERC-20s as collateral; borrow the protocol’s debt token (`LendingToken`).
- **Chainlink Price Feeds** — USD-denominated, normalized to 18 decimals with stale-data and non-positive price checks.
- **Health Factor Guardrails** — Borrowing and redemption gated behind `_healthFactorCheckPoint` (no storage writes), full HF calculation in `_healthFactor`.
- **Liquidation Path** — Third parties can repay undercollateralized debt and seize collateral with a configurable bonus.
- **Gas Optimizations** — Read-only HF simulations before writes; tight error types; `nonReentrant` on state-changing externals.
- **Extensible Collateral Set** — Owner can add new collateral tokens + price feeds post-deploy.

---

## 🧩 Architecture

```
contracts/
├─ LendingProtocolEngine.sol   # Core engine: deposit, borrow, repay, redeem, liquidate, pricing
├─ LendingToken.sol            # ERC20-compatible debt token (mint/burn controlled by engine)
└─ (Mocks used in tests via OZ / local)
```

Key storage:
- `s_collateralDeposited[user][token]` — per-user per-token collateral amounts
- `s_lendTokenMinted[user]` — user debt (amount of LendingToken minted)
- `s_priceFeeds[token]` — token ⇒ Chainlink price feed
- `s_collateralTokens` — list of enabled collateral tokens

---

## 🧠 Risk Math (at a glance)

**Health Factor (HF):**
```
collateralUsd = Σ( amount[token] * priceUsd[token] / 10**decimals[token] )
adj = collateralUsd * LIQUIDATION_THRESHOLD / LIQUIDATION_PRECISION
HF  = (adj * 1e18) / totalDebt
```
- If `totalDebt == 0` ⇒ `HF = uint256.max` (safe)
- Liquidation eligible when `HF < MINIMUM_HEALTH_FACTOR` (set to `1e18`)

**Liquidation seize amount:**
```
collateralToSeize =
    (debtToCover * LIQUIDATION_BONUS * 10**decimals(collateral)) / priceUsd(collateral)
```
Capped by borrower’s actual collateral balance for that token.

**Core params (defaults in code):**
- `PRECISION = 1e18`
- `LIQUIDATION_THRESHOLD = 50`  (interpreted as “50 / 100” ⇒ 50%)  
- `LIQUIDATION_PRECISION = 100`
- `MINIMUM_HEALTH_FACTOR = 1e18`
- `LIQUIDATION_BONUS = 1.1e18`  (i.e., 110%)

> Tip: Tweak `LIQUIDATION_THRESHOLD`/`LIQUIDATION_BONUS` to tune risk appetite.

---

## 🔐 Security Notes (learning project)

- `nonReentrant` on state mutating public/external entry points (`depositCollateral`, `borrow`, `repay`, `redeemCollateral`, `liquidate`).
- Chainlink price data guarded by **stale-data** and **non-positive price** reverts.
- Simulations before writes prevent storing invalid states.
- **Owner-only** collateral/price-feed onboarding.

> **Not production-audited.** Use for education/experiments. Thorough audits and economic reviews are required for mainnet.

---

## 🧪 Testing

- **Unit Tests:** Foundry tests cover constructor checks, price normalization, and basic flows.
- **Mocks:** `MockV3Aggregator` for price feeds (via HelperConfig) and `ERC20Mock` for test tokens.
- **Example test** (constructor mismatch check):
```solidity
vm.expectRevert(
    LendingProtocolEngine
        .LendingProtocolEngine__TokenAddressesAndPriceFeedAddressesShouldBeOfSameLength
        .selector
);
// try to deploy with mismatched arrays ⇒ revert expected
```

Run all tests:
```bash
forge test -vv
```

Gas snapshots:
```bash
forge test --gas-report
```

---

## 🛠️ Scripts & Config (Sepolia)

### Files
- `script/DeployLendingProtocolEngine.s.sol`
  - Deploys `LendingToken`
  - Deploys `LendingProtocolEngine` with arrays of `tokenAddresses` and `priceFeedAddresses`
  - Transfers `LendingToken` ownership to the engine
- `script/HelperConfig.s.sol`
  - Provides active network config (Sepolia): chainlink feeds + token addresses
  - Provides mock setup for local

### Run (Sepolia)
Use a `.env` with your RPC + private key:
```bash
SEPOLIA_RPC_URL=...
PRIVATE_KEY=...
```
Then:
```bash
source .env
forge script script/DeployLendingProtocolEngine.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

> On Sepolia, prefer **well-known token contracts** as collateral (WETH, WBTC test deployments) or deploy your own mock ERC20s and corresponding mock feeds for end-to-end dry runs.

---

## 📦 Contract Surfaces

### `LendingProtocolEngine.sol`
- `depositCollateral(token, amount)`
- `borrow(amount)`
- `repay(amount)`
- `redeemCollateral(token, amount)`
- `liquidate(user, debtToCover, collateralToken)`
- `addNewTokenForCollateralInEngine(token, priceFeed)` (owner only)
- `getUsdPriceOfToken(token)` (view)
- `getHealthFactor(user)` (view)

**Notable internals:**
- `_healthFactor(user)` — reads storage, uses full portfolio
- `_healthFactorCheckPoint(user, simulatedDebt, tokenToSimulate, simulatedCollateral)` — **read-only** simulation to avoid gas-heavy writes mid-check

### `LendingToken.sol`
- ERC20-style debt token; engine is the minter/burner (calls currently commented until you finish the token logic).

---

## 🔧 Development

**Prereqs**
- Foundry (`forge`, `cast`)
- Node (if you rely on scripting helpers)
- Git

**Build**
```bash
forge build
```

**Format & Lint**
```bash
forge fmt
```

**Local Anvil + Mocks**
```bash
anvil
# In another terminal:
forge script script/DeployLendingProtocolEngine.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast
```

---

## 🧵 Design Notes & Trade-offs

- **Read-before-write**: health-factor checkpoint avoids wasted writes/reverts → cheaper failures.
- **Single-collateral liquidation leg**: liquidator chooses `collateralToken`; multi-asset liquidation can be added later.
- **No interest rate model yet**: debt is principal-only for clarity in learning; add IRM later (utilization-based, kinked, etc.).
- **No fee to protocol in liquidation**: bonus goes entirely to liquidator; a protocol fee is easy to add if desired.

---

## 🚀 Roadmap / Ideas

- Interest accrual model (variable + reserve factor)
- Oracle heartbeat circuit-breakers per asset
- Pausable/Guardian roles
- eMode / isolation modes per asset
- Partial liquidations by HF target
- Protocol fee on liquidation & borrow
- More tests: fuzzing, invariant tests, edge-case coverage

---

## 📚 References

- Chainlink Feeds docs (price normalization & staleness patterns)
- OpenZeppelin (ReentrancyGuard, ERC20, mocks)
- Foundry Book (scripting, testing patterns)

---

## 📝 License

MIT — see `LICENSE` if present.

---

## Author

Vinay Vig
