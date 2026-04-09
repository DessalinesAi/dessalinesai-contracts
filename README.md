# Dessalines AI Protocol

**Haiti's first trustless rotating savings protocol on Base.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Network: Base](https://img.shields.io/badge/Network-Base-0052FF)](https://base.org)
[![Token: $DESSAI](https://img.shields.io/badge/Token-%24DESSAI-D21034)](https://app.virtuals.io/virtuals/15911)
[![Audit: Pending](https://img.shields.io/badge/Audit-Pending-orange)](/)

---

## What is Dessalines AI?

The *eso* is a centuries-old rotating savings tradition in Haitian culture. A group of trusted people each contribute a fixed amount every month. One person receives the full pot. The cycle continues until everyone has received their payout. No banks. No fees. Just community.

**The problem:** the traditional eso depends entirely on a human coordinator. When that coordinator disappears — and sometimes they do — there is no contract, no recourse, and no protection. Meanwhile, 3.2 million Haitians in the United States are almost entirely excluded from modern DeFi wealth-building tools.

**Dessalines AI replaces the coordinator with a smart contract.**

---

## Protocol Overview

```
User -> EsoPoolFactory.createPool()
          └─ deploys EsoPool (one contract per savings circle)
               └─ EsoPool.settleRound()
                    ├─ 1% protocol fee -> DessaiStaking (to stakers)
                    └─ Net payout -> round recipient
```

| Contract | Purpose |
|---|---|
| `EsoPool.sol` | Holds USDC, enforces rounds, pays recipients automatically |
| `EsoPoolFactory.sol` | Deploys and tracks all pools; admin entry point |
| `DessaiStaking.sol` | Distributes 100% of protocol fees to $DESSAI stakers |
| `ReputationRegistry.sol` | On-chain trust scores for pool access gating |

---

## Token

**$DESSAI** — utility and revenue-sharing token.

- Network: Base (Ethereum L2)
- - Contract: `0xb56b5269c03421765c28aa61037536ea5690741c`
  - - Total supply: 1,000,000,000 (fixed)
    - - Protocol fees: 100% distributed to stakers
      - - Trading tax: 0%
       
        - **Trade:** [Virtuals](https://app.virtuals.io/virtuals/15911) · [Uniswap](https://app.uniswap.org/explore/tokens/base/0xB56B5269C03421765c28AA61037536Ea5690741c) · [DexScreener](https://dexscreener.com/base/0x2ec65817e3d99dd5ee25a5fa32e8bea5f8ea6abd) · [CoinGecko](https://www.coingecko.com/en/coins/dessalinesai-by-virtuals)
       
        - ---

        ## Staking Tiers

        | Tier | DESSAI Staked | Benefit |
        |---|---|---|
        | 1 | Any amount | Weekly share of 100% of protocol fees |
        | 2 | 500+ | Join mid-tier pools without USDC collateral |
        | 3 | 2,000+ | Reduced pool fee (1% to 0.5%) |
        | 4 | 5,000+ | Governance rights |
        | 5 | 10,000+ | Biznis Eso pool access |

        ---

        ## Development

        ```bash
        # Install Foundry
        curl -L https://foundry.paradigm.xyz | bash && foundryup

        # Install deps
        forge install OpenZeppelin/openzeppelin-contracts

        # Build
        forge build

        # Test
        forge test -vvv

        # Deploy to Base Sepolia testnet
        forge script script/Deploy.s.sol --rpc-url https://sepolia.base.org --broadcast --verify
        ```

        ---

        ## Security

        **These contracts have not yet been audited. Do not use with real funds until an audit is complete.**

        Targeting Halborn or Certik for audit prior to mainnet launch.

        ---

        ## Roadmap

        | Phase | Timeline | Milestone |
        |---|---|---|
        | 1 — Foundation | Months 1-3 | Contracts audited, Base Sepolia testnet live, AI agent integrated |
        | 2 — Launch | Months 4-9 | Base mainnet, 100 beta users, first live Eso pools, $DESSAI staking live |
        | 3 — Scale | Months 10-18 | 500+ pools, $500K USDC in protocol, staking APR demonstrable |
        | 4 — Expand | 18 months+ | Caribbean and African diaspora expansion |

        ---

        ## Community

        - Website: [dessalinesai.io](https://dessalinesai.io)
        - - Telegram (Haitian Creole): [Bitcoin Kripto Ayisyen](https://t.me/bitcoinkriptoayisyen)
          - - Investor inquiries: invest@dessalinesai.io
           
            - Read the whitepaper: https://dessalinesai.io/whitepaper.html
           
            - ---

            ## License

            MIT

            ---

            *Named after Jean-Jacques Dessalines — Haiti's founding father. The fight for Haitian financial sovereignty continues, on-chain.*
