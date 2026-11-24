# Masters of Management

A fully on-chain, turn-based strategy game built on **BNB Smart Chain (BSC)**, where players develop realms, command armies, form alliances and compete for BNB and LOP rewards.

**Play Ravengard:** [kilopi.net/mom/bnb/ravengard](https://kilopi.net/mom/bnb/ravengard/)

## Technology Stack

- **Blockchain:** BNB Smart Chain; Solidity smart contracts executed by the EVM.
- **Smart Contracts:** Solidity **0.8.37** for the game contracts.
- **Frontend:** React 18, Phaser 3 and ethers.js 6.
- **Development:** Hardhat, the Solidity compiler and Remix IDE.
- **Testing:** JavaScript contract tests, Jest and React Testing Library.
- **Wallet Connection:** MetaMask through an EIP-1193 wallet provider.
- **Hosting:** A static web frontend that communicates with smart contracts through RPC endpoints.

## Supported Networks

- **BNB Smart Chain Mainnet** — Chain ID: **56**; native currency: **BNB**.
- **Current game world:** Ravengard.

## Contract Addresses

The following primary contracts belong to the Ravengard deployment on **BNB Smart Chain Mainnet**. Addresses link to BscScan.

| Contract | Purpose | Address |
|---|---|---|
| TheLand | Core realm state and gameplay | [0xFA2f1410571796AE94ad84E3Cb37c2D1349F3071](https://bscscan.com/address/0xFA2f1410571796AE94ad84E3Cb37c2D1349F3071) |
| LOP | Reward token, 6 decimals | [0xCF3D31Dd1BCEd6121d97E98D110f8fc54D993365](https://bscscan.com/address/0xCF3D31Dd1BCEd6121d97E98D110f8fc54D993365) |
| WorldRewards | World-end LOP reward distribution | [0xBA398b404416Ce18E2786EeECe424510c77F7D6b](https://bscscan.com/address/0xBA398b404416Ce18E2786EeECe424510c77F7D6b) |
| Clan | Clan membership, governance and treasury | [0x8A985223298A32657D7f30FC675E61733B76A860](https://bscscan.com/address/0x8A985223298A32657D7f30FC675E61733B76A860) |
| ClanCouncil | Council proposal and voting logic | [0x8Aeec4da36552AD7d9542fe5e0b7314F143b6b1e](https://bscscan.com/address/0x8Aeec4da36552AD7d9542fe5e0b7314F143b6b1e) |
| MarketPlace | Player-to-player item trading | [0x515b4236981CC6A59A051b0ce09dCCc25476f1E2](https://bscscan.com/address/0x515b4236981CC6A59A051b0ce09dCCc25476f1E2) |
| Military | Realm army journeys and battles | [0xcCda9eB115f3b3c56Bf5214ec4a1896c47eA10BE](https://bscscan.com/address/0xcCda9eB115f3b3c56Bf5214ec4a1896c47eA10BE) |
| ClanWar | Clan army journeys and battles | [0x6311629bDf175A5D0Cf730aA2641C1DCD78614aD](https://bscscan.com/address/0x6311629bDf175A5D0Cf730aA2641C1DCD78614aD) |
| Logistics | Resource deliveries and return journeys | [0x4c05248E05502d32c0D590bF36171eAEaF28e70b](https://bscscan.com/address/0x4c05248E05502d32c0D590bF36171eAEaF28e70b) |

## Features

- **On-chain gameplay:** Realm development, production, trading, battles and reward accounting are handled by smart contracts.
- **Realm management:** Construct and upgrade buildings, produce resources, manage storage and develop your realm's economy.
- **Turn-based progression:** One turn regenerates every 10 minutes. Players choose how to spend their accumulated turns.
- **Military strategy:** Forge weapons and armor, train infantry and mounted troops, research improvements and plan attacks using troop matchups.
- **Exploration and scouting:** Expand visibility as your realm develops and scout areas or rival realms to gather intelligence.
- **Player-to-player trading:** Buy and sell resources, equipment and logistics items through the on-chain marketplace.
- **Clans and collective decisions:** Coordinate armies, establish diplomatic relationships and spend Influence to vote, earning Reputation through participation.
- **Relic competition:** Produce relics, defend them and capture relics through successful realm attacks. Captured loot travels home with the army and must be collected.
- **World-end rewards:** Each world lasts 365 days. Eligible relic holdings determine relic BNB rewards, clan Reputation determines shares of remaining clan pools, and troop-training points determine LOP allocations. Wallet withdrawals for game rewards and market proceeds open after world closure.
- **Referral links:** Share a wallet referral link. For an eligible paid land claim with a valid referrer, half of the claim fee goes to the referrer and half to the game treasury.

## Getting Started

1. Open [Ravengard](https://kilopi.net/mom/bnb/ravengard/) and connect MetaMask on BNB Smart Chain.
2. Select a resource bonus and claim a realm while new claims are open. BNB is used for network gas and applicable game fees.
3. Enter your realm, use turns, build your economy and prepare your strategy.
4. Open the in-game **Game Guide** for building costs, troop attributes, diplomacy rules and fee details.
