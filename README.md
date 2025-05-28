# Lendefi Protocol

```
  ═══════════[ Composable Lending Markets ]═══════════

  ██╗     ███████╗███╗   ██╗██████╗ ███████╗███████╗██╗
  ██║     ██╔════╝████╗  ██║██╔══██╗██╔════╝██╔════╝██║
  ██║     █████╗  ██╔██╗ ██║██║  ██║█████╗  █████╗  ██║
  ██║     ██╔══╝  ██║╚██╗██║██║  ██║██╔══╝  ██╔══╝  ██║
  ███████╗███████╗██║ ╚████║██████╔╝███████╗██║     ██║
  ╚══════╝╚══════╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝     ╚═╝

  ═══════════[ Composable Lending Markets ]═══════════
```

## Composable Lending Markets Protocol

## Executive Summary

The Lendefi Protocol represents a next-generation composable lending infrastructure that enables the creation of independent, isolated lending markets for different base assets. Unlike traditional monolithic lending protocols, Lendefi implements a factory-based architecture where each market operates as an autonomous lending pool with its own base asset, liquidity providers, and risk parameters. This design enables unprecedented flexibility, scalability, and risk isolation while maintaining the sophisticated features expected from modern DeFi protocols.

For more information visit [Nebula Labs](https://nebula-labs.xyz).

## Architecture & Design

### Composable Market Architecture

The protocol's revolutionary architecture centers around composable lending markets, each functioning as an independent lending ecosystem:

- **Market Factory Pattern**: The `LendefiMarketFactory` deploys and manages multiple lending markets, each with its own base asset (USDC, DAI, USDT, etc.)
- **Isolated Liquidity Pools**: Each market maintains completely separate liquidity, preventing contagion between different base assets
- **Market-Specific Components**: Every market consists of:
  - **LendefiCore**: Handles collateral management, borrowing logic, and risk parameters
  - **LendefiMarketVault**: ERC-4626 compliant vault managing base asset deposits and yield distribution
  - **Proof of Reserve Feed**: Market-specific PoR integration for transparent asset verification
  - **Isolated Position Vaults**: Individual vault contracts for each user position within the market

### Key Architectural Benefits

1. **Risk Isolation**: Issues in one market cannot affect liquidity or solvency in other markets
2. **Flexible Deployment**: New markets can be created for any ERC-20 asset without affecting existing markets
3. **Customizable Parameters**: Each market can have unique risk parameters, interest models, and collateral requirements
4. **Scalable Infrastructure**: The factory pattern enables unlimited market creation without protocol complexity
5. **Regulatory Compliance**: Market isolation facilitates compliance with jurisdiction-specific requirements

## Core Features

### Multi-Market Ecosystem

- **Independent Markets**: Each base asset (USDC, DAI, USDT, etc.) operates its own lending market
- **Cross-Market Collateral**: Users can use collateral from any whitelisted asset across different markets
- **Market-Specific Yield Tokens**: Each market issues its own ERC-4626 yield-bearing tokens to liquidity providers
- **Unified Collateral Management**: Single asset module manages collateral configurations across all markets

### Advanced Risk Management

The protocol implements a sophisticated multi-tier risk framework that applies across all markets:

- **Four Collateral Tiers**:

  - STABLE: Blue-chip stablecoins (1% liquidation bonus)
  - CROSS_A: Low-risk assets (2% liquidation bonus)
  - CROSS_B: Medium-risk assets (3% liquidation bonus)
  - ISOLATED: High-risk or new assets (4% liquidation bonus)

- **Position Types**:
  - **Cross-Collateral Positions**: Mix up to 20 different assets as collateral
  - **Isolated Positions**: Single-asset collateral for higher-risk assets
  - **Market-Agnostic Collateral**: Use any whitelisted asset as collateral in any market

### Isolated Position Vaults

Every position across all markets utilizes dedicated vault contracts:

- Complete asset segregation per position
- Direct liquidation transfers from vault to liquidator
- Enhanced security through position-level isolation
- Regulatory compliance through technical asset segregation
- Protection from cross-position vulnerabilities

## Market Creation & Management

### Market Factory

The `LendefiMarketFactory` serves as the protocol's deployment hub:

```solidity
// Create a new USD1 lending market
factory.createMarket(
    USD1_ADDRESS,
    "Lendefi USD1 Market",
    "mUSD1"
);
```

Each market deployment includes:

- Upgradeable LendefiCore contract (UUPS proxy)
- ERC-4626 compliant vault for the base asset
- Dedicated Proof of Reserve feed
- Automatic integration with the protocol's asset module

### Market Lifecycle

1. **Deployment**: Admin creates new market via factory
2. **Initialization**: Market components are deployed and linked
3. **Configuration**: Risk parameters and collateral assets are configured
4. **Operation**: Users can supply liquidity, borrow, and manage positions
5. **Upgrades**: Individual markets can be upgraded without affecting others

## Technical Implementation

### Smart Contract Architecture

```
LendefiMarketFactory
├── Creates Markets →
│   ├── LendefiCore (Proxy)
│   │   ├── Position Management
│   │   ├── Collateral Logic
│   │   └── Interest Calculations
│   └── LendefiMarketVault (Proxy)
│       ├── ERC-4626 Vault
│       ├── Liquidity Management
│       └── Flash Loans
├── Asset Module (Shared)
│   ├── Oracle Integration
│   ├── Risk Parameters
│   └── Proof of Reserve
└── Position Vaults
    └── Individual User Vaults
```

### Key Components

1. **LendefiMarketFactory**: Deploys and tracks all lending markets
2. **LendefiCore**: Market-specific lending logic and collateral management
3. **LendefiMarketVault**: ERC-4626 vault handling base asset deposits
4. **Asset Module**: Shared configuration for collateral assets across markets
5. **Position Vaults**: Cloned vault contracts for each user position

## Features Across Markets

### Unified Features

1. Support for up to 3000 collateral assets (shared across all markets)
2. Up to 1000 positions per user per market
3. Up to 20 collateral assets per position
4. Automatic interest compounding
5. Gas-efficient operations
6. Market-specific yield tokens (ERC-4626)
7. Complete upgradeability (per market)
8. DAO governance
9. Unified reward ecosystem
10. Flash loan functionality per market

### Market-Specific Features

- Independent liquidity pools
- Customizable interest rate models
- Market-specific risk parameters
- Separate Proof of Reserve feeds
- Isolated protocol revenue streams

## Security Features

The protocol implements defense-in-depth security across all markets:

- **Access Control**: Role-based permissions with timelock governance
- **Reentrancy Protection**: Guards on all state-modifying functions
- **Pausability**: Emergency pause per market or protocol-wide
- **Oracle Security**: Multi-oracle support with freshness checks
- **Upgradeable Architecture**: UUPS pattern with version tracking
- **Input Validation**: Comprehensive checks and custom errors
- **MEV Protection**: Same-block operation prevention

## Economic Model

### Market-Specific Economics

Each lending market operates with independent economic parameters:

1. **Interest Rates**: Utilization-based with tier adjustments
2. **Protocol Revenue**: Market-specific fee capture
3. **Flash Loans**: Configurable fees per market (default 9 bps)
4. **Liquidation Incentives**: Tier-based bonuses across all markets

### Cross-Market Synergies

- Unified governance token requirements
- Shared collateral configurations
- Consistent risk tiers across markets
- Protocol-wide reward distribution

## Oracle Integration

### Chainlink Price Feeds

- Primary price source for all markets
- Staleness checks (8-hour maximum)
- Volatility monitoring
- Round completion verification

### Proof of Reserve

- Market-specific PoR feeds
- Real-time reserve verification
- Automated TVL tracking
- Circuit breaker integration

### Fallback Mechanisms

- Uniswap V3 TWAP as secondary source
- Multi-oracle median pricing
- Deviation thresholds

## Regulatory Compliance

### Market Isolation Benefits

The composable market architecture facilitates compliance:

- **Asset Segregation**: Complete separation between markets
- **Jurisdictional Flexibility**: Markets can be configured for specific regulatory requirements
- **Audit Trail**: Clear separation of funds and operations per market
- **Bankruptcy Remoteness**: Market isolation prevents cross-contamination

### U.S. GENIUS Act Compliance

The protocol's architecture aligns with emerging regulations:

- Technical asset segregation through isolated vaults
- Proof of Reserve integration for transparency
- Clear custody delineation
- Qualified custodian standards through smart contracts

## Getting Started

### Deploying a New Market

```solidity
// Deploy factory and set implementations
LendefiMarketFactory factory = new LendefiMarketFactory();
factory.initialize(timelock, treasury, assetsModule, govToken, porFeed);
factory.setImplementations(coreImpl, vaultImpl);

// Create markets for different base assets
factory.createMarket(USD1, "Lendefi mUSD1", "mUSD1");
factory.createMarket(DAI, "Lendefi mDAI", "mDAI");
factory.createMarket(USDT, "Lendefi mUSDT", "mUSDT");
```

### Using a Market

```solidity
// Get market information
LendefiCore.Market memory market = factory.getMarketInfo(USD1);

// Interact with specific market
LendefiCore core = LendefiCore(market.core);
LendefiMarketVault vault = LendefiMarketVault(market.baseVault);

// Supply liquidity to USDC market
vault.deposit(amount, recipient);

// Borrow from USDC market using any collateral
core.createPosition(WETH, false); // Cross-collateral position
core.supplyCollateral(WETH, amount, positionId);
core.borrow(positionId, borrowAmount);
```

## Deployed Markets

Track deployed markets and their configurations:

```solidity
// Get all active markets
address[] memory activeMarkets = factory.getAllActiveMarkets();

// Check market details
LendefiCore.Market memory usdcMarket = factory.getMarketInfo(USDC);
```

## Benefits of Composable Architecture

### For Users

- Choose optimal markets for borrowing based on rates
- Isolated risk per market
- Market-specific yield optimization
- Cross-market collateral utilization

### For Liquidity Providers

- Market-specific yield tokens
- Isolated risk exposure
- Choose markets based on risk/reward
- No cross-market contagion

### For Protocol

- Unlimited scalability
- Market-specific optimizations
- Easier regulatory compliance
- Simplified risk management

## Future Developments

The composable architecture enables:

- Specialized markets (RWA, LST-specific, etc.)
- Cross-chain market deployment
- Market-specific strategies
- Advanced inter-market composability
- Automated market management

## Disclaimer

This software is provided as is with a Business Source License 1.1 without warranties of any kind. Some libraries included with this software are licensed under the MIT license, while others require GPL-v3.0. The smart contracts are labeled accordingly.

## Running Tests

This is a Foundry repository. To get more information visit [Foundry](https://github.com/foundry-rs/foundry/blob/master/foundryup/README.md).

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone and setup
git clone https://github.com/nebula-labs-xyz/lendefi-markets.git
cd lendefi-markets

# Configure environment
echo "ALCHEMY_API_KEY=your_api_key_here" >> .env

# Build and test
npm install
npm run build
npm run test
```
