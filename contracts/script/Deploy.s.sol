// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PrincipalVault} from "../src/core/PrincipalVault.sol";
import {LotteryTreasury} from "../src/core/LotteryTreasury.sol";
import {PositionManager} from "../src/core/PositionManager.sol";
import {Wiring} from "../src/periphery/Wiring.sol";
import {Curator} from "../src/periphery/Curator.sol";
import {YieldSweeper} from "../src/periphery/YieldSweeper.sol";
import {StrategyExecutor} from "../src/periphery/StrategyExecutor.sol";

import {IWiring} from "../src/interfaces/IWiring.sol";
import {IMorphoVault} from "../src/interfaces/IMorphoVault.sol";

/// @title Deploy — full Degen Curator deployment
/// @notice Deploys all 7 contracts in dependency order, wires them via the
///         Wiring registry, and renounces deployer permissions in favor of
///         the configured admin / curator / guardian multisigs.
///
/// USAGE (Base Sepolia testnet):
///     forge script script/Deploy.s.sol \
///       --rpc-url $BASE_SEPOLIA_RPC_URL \
///       --broadcast \
///       --verify
///
/// USAGE (Base mainnet):
///     forge script script/Deploy.s.sol \
///       --rpc-url $BASE_RPC_URL \
///       --broadcast --verify \
///       --etherscan-api-key $BASESCAN_API_KEY
///
/// REQUIRED ENV:
///   PRIVATE_KEY            — deployer key (rotated/burned post-deploy)
///   USDC_ADDRESS           — Base USDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
///   MORPHO_USDC_VAULT      — Steakhouse / Gauntlet curated USDC vault on chosen chain
///   PENDLE_ROUTER_V4       — Base Pendle Router: 0x888888888889758F76e7103c6CbF23ABbF58F946
///   ADMIN_MULTISIG         — 3/5 Gnosis Safe (or TimelockController address)
///   CURATOR_MULTISIG       — 2/3 Gnosis Safe
///   GUARDIAN_KEY           — Hot guardian EOA (separate device)
///   KEEPER_ADDRESS         — Initial keeper (Gelato / Chainlink / EOA)
///   FEE_RECIPIENT          — Where curator fees flow (typically curator multisig)
contract Deploy is Script {
    // Configuration loaded from env
    address public USDC;
    address public MORPHO_USDC_VAULT;
    address public PENDLE_ROUTER_V4;
    address public ADMIN_MULTISIG;
    address public CURATOR_MULTISIG;
    address public GUARDIAN;
    address public KEEPER;
    address public FEE_RECIPIENT;

    // Vault parameters (testnet defaults; tune for mainnet)
    uint128 public constant DEPOSIT_CAP = 250_000e6; // $250K starter cap
    uint32 public constant DEPOSITOR_CAP = 500;
    uint128 public constant MIN_DEPOSIT = 100e6; // $100
    uint16 public constant SLIPPAGE_BPS = 300; // 3%
    uint256 public constant TIMELOCK_DELAY = 2 days;

    // Deployed addresses (populated during run)
    Wiring public wiring;
    PrincipalVault public principalVault;
    LotteryTreasury public lotteryTreasury;
    PositionManager public positionManager;
    Curator public curator;
    YieldSweeper public yieldSweeper;
    StrategyExecutor public strategyExecutor;

    function run() public {
        _loadEnv();

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("Deployer:", deployer);
        console.log("Network: ", block.chainid);

        vm.startBroadcast(deployerKey);

        // 1. Wiring (UUPS proxy, deployer = initial admin)
        Wiring wiringImpl = new Wiring();
        ERC1967Proxy wiringProxy = new ERC1967Proxy(
            address(wiringImpl),
            abi.encodeCall(Wiring.initialize, (deployer))
        );
        wiring = Wiring(address(wiringProxy));
        console.log("Wiring (proxy):", address(wiring));
        console.log("Wiring (impl): ", address(wiringImpl));

        // 2. PrincipalVault (immutable)
        principalVault = new PrincipalVault(
            IERC20(USDC),
            IMorphoVault(MORPHO_USDC_VAULT),
            IWiring(address(wiring)),
            DEPOSIT_CAP,
            DEPOSITOR_CAP,
            MIN_DEPOSIT
        );
        console.log("PrincipalVault:  ", address(principalVault));

        // 3. LotteryTreasury (immutable)
        lotteryTreasury = new LotteryTreasury(IERC20(USDC), IWiring(address(wiring)));
        console.log("LotteryTreasury: ", address(lotteryTreasury));

        // 4. PositionManager (immutable)
        positionManager = new PositionManager(IWiring(address(wiring)));
        console.log("PositionManager: ", address(positionManager));

        // 5. Curator (UUPS proxy)
        Curator curatorImpl = new Curator();
        ERC1967Proxy curatorProxy = new ERC1967Proxy(
            address(curatorImpl),
            abi.encodeCall(
                Curator.initialize,
                (
                    IWiring(address(wiring)),
                    TIMELOCK_DELAY,
                    CURATOR_MULTISIG,
                    GUARDIAN,
                    FEE_RECIPIENT
                )
            )
        );
        curator = Curator(address(curatorProxy));
        console.log("Curator (proxy):", address(curator));
        console.log("Curator (impl): ", address(curatorImpl));

        // 6. YieldSweeper (UUPS proxy)
        YieldSweeper ysImpl = new YieldSweeper();
        ERC1967Proxy ysProxy = new ERC1967Proxy(
            address(ysImpl),
            abi.encodeCall(YieldSweeper.initialize, (IWiring(address(wiring)), ADMIN_MULTISIG, KEEPER))
        );
        yieldSweeper = YieldSweeper(address(ysProxy));
        console.log("YieldSweeper (proxy):", address(yieldSweeper));
        console.log("YieldSweeper (impl): ", address(ysImpl));

        // 7. StrategyExecutor (UUPS proxy)
        StrategyExecutor seImpl = new StrategyExecutor();
        ERC1967Proxy seProxy = new ERC1967Proxy(
            address(seImpl),
            abi.encodeCall(
                StrategyExecutor.initialize,
                (
                    IWiring(address(wiring)),
                    PENDLE_ROUTER_V4,
                    IERC20(USDC),
                    ADMIN_MULTISIG,
                    KEEPER,
                    SLIPPAGE_BPS
                )
            )
        );
        strategyExecutor = StrategyExecutor(address(seProxy));
        console.log("StrategyExecutor (proxy):", address(strategyExecutor));
        console.log("StrategyExecutor (impl): ", address(seImpl));

        // 8. Wire everything (one-shot, locks core addresses).
        wiring.setAll(
            address(principalVault),
            address(lotteryTreasury),
            address(positionManager),
            address(strategyExecutor),
            address(yieldSweeper),
            address(curator),
            GUARDIAN
        );

        // 9. Hand admin role to the multisig and renounce deployer's role.
        wiring.grantRole(wiring.DEFAULT_ADMIN_ROLE(), ADMIN_MULTISIG);
        wiring.renounceRole(wiring.DEFAULT_ADMIN_ROLE(), deployer);

        vm.stopBroadcast();

        console.log("");
        console.log("DEPLOYMENT COMPLETE");
        console.log("===================");
        console.log("Deposit cap (USDC):", DEPOSIT_CAP / 1e6);
        console.log("Depositor cap:      ", DEPOSITOR_CAP);
        console.log("Min deposit (USDC): ", MIN_DEPOSIT / 1e6);
        console.log("Timelock delay (s): ", TIMELOCK_DELAY);
        console.log("");
        console.log("Next steps for Sarthak:");
        console.log("  1. Verify all contract addresses on Basescan");
        console.log("  2. Curator multisig: proposeWhitelistMarket(...) for 5-10 Pendle YT markets");
        console.log("  3. Wait 48h timelock; commitWhitelistMarket(...) each");
        console.log("  4. Curator multisig: setWeeklyBasket([...]) with first cycle's picks");
        console.log("  5. Keeper: yieldSweeper.sweep() once first yield accrues");
        console.log("  6. Keeper: strategyExecutor.runWeeklyCycle() (after Pendle SDK integration)");
        console.log("  7. Update frontend env with addresses; deploy to Vercel");
    }

    function _loadEnv() internal {
        USDC = vm.envAddress("USDC_ADDRESS");
        MORPHO_USDC_VAULT = vm.envAddress("MORPHO_USDC_VAULT");
        PENDLE_ROUTER_V4 = vm.envAddress("PENDLE_ROUTER_V4");
        ADMIN_MULTISIG = vm.envAddress("ADMIN_MULTISIG");
        CURATOR_MULTISIG = vm.envAddress("CURATOR_MULTISIG");
        GUARDIAN = vm.envAddress("GUARDIAN_KEY");
        KEEPER = vm.envAddress("KEEPER_ADDRESS");
        FEE_RECIPIENT = vm.envAddress("FEE_RECIPIENT");
    }
}
