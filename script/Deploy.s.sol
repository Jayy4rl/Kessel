// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";

import {KesselHook} from "../src/KesselHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BatchSolver} from "../src/settle/BatchSolver.sol";

/// @notice Deployment is TWO phases, and they cannot be merged.
///
/// `KesselHook` links `BatchSolver`, so the library's address is embedded in
/// the hook's creation bytecode. The hook's own address is CREATE2-mined over
/// that same creation bytecode, because v4 encodes the permission bitmap in the
/// low 14 bits of a hook's address. So the library must be deployed, and its
/// address fixed at compile time, *before* the hook address can be mined.
///
///   forge script script/Deploy.s.sol:DeployBatchSolver \
///     --rpc-url $RPC --broadcast
///
/// then paste the printed line into `foundry.toml`, recompile, and:
///
///   forge script script/Deploy.s.sol:DeployKessel \
///     --rpc-url $RPC --broadcast
///
/// Both phases must run under `FOUNDRY_PROFILE=optimized`. That is not a
/// preference: under the dev profile the hook compiles to roughly 28KB and
/// exceeds EIP-170's 24,576-byte limit, so the deployment simply fails. The
/// test suite cannot catch that, because it places runtime bytecode with
/// `vm.etch`, which bypasses the limit.

/// @notice Phase 1. Deploy the linked library.
contract DeployBatchSolver is Script {
    function run() external returns (address solver) {
        // A library cannot be `new`-ed, so it is deployed from its creation
        // code directly. `forge create src/settle/BatchSolver.sol:BatchSolver`
        // is an equivalent one-liner if you would rather not run a script.
        bytes memory code = type(BatchSolver).creationCode;

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        assembly ("memory-safe") {
            solver := create(0, add(code, 0x20), mload(code))
        }
        vm.stopBroadcast();

        require(solver != address(0), "BatchSolver deployment failed");

        console2.log("BatchSolver deployed at", solver);
        console2.log("");
        console2.log("Add this to foundry.toml under [profile.optimized], then recompile:");
        console2.log("");
        console2.log('  libraries = ["src/settle/BatchSolver.sol:BatchSolver:%s"]', solver);
    }
}

/// @notice Phase 2. Mine the hook address, deploy, initialize the pool, and set
/// the parameters that ship disabled.
contract DeployKessel is Script {
    /// @dev Canonical deterministic CREATE2 factory. `forge script` routes
    /// salted `new` through it, so the mined address must be computed against
    /// it and not against the EOA.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev The frozen permission bitmap. Changing this changes the hook's
    /// address, so it is written out literally here rather than read from the
    /// contract: if `getHookPermissions()` ever drifts from this, the assertion
    /// at the end of `run` fails loudly instead of deploying to a wrong address.
    uint160 internal constant KESSEL_FLAGS =
        uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);

    function run() external returns (KesselHook hook) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address currency0 = vm.envAddress("CURRENCY0");
        address currency1 = vm.envAddress("CURRENCY1");
        int24 tickSpacing = int24(vm.envInt("TICK_SPACING"));
        address governance = vm.envAddress("GOVERNANCE");
        uint8 gasTokenSide = uint8(vm.envUint("GAS_TOKEN_SIDE"));
        uint160 startSqrtPriceX96 = uint160(vm.envUint("START_SQRT_PRICE_X96"));

        // v4 requires sorted currencies, and the hook's own pool binding is
        // derived from the key. Getting this backwards produces a hook bound to
        // a pool that will never exist.
        require(currency0 < currency1, "CURRENCY0 must sort below CURRENCY1");
        require(governance != address(0), "GOVERNANCE must not be the zero address");
        require(gasTokenSide <= 2, "GAS_TOKEN_SIDE must be 0 (neither), 1 or 2");
        require(startSqrtPriceX96 != 0, "START_SQRT_PRICE_X96 must be set");

        bytes memory args = abi.encode(
            poolManager, Currency.wrap(currency0), Currency.wrap(currency1), tickSpacing, governance, gasTokenSide
        );

        _assertSolverDeployed();

        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, KESSEL_FLAGS, type(KesselHook).creationCode, args);

        console2.log("mined hook address", expected);
        console2.log("salt", uint256(salt));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        hook = new KesselHook{salt: salt}(
            poolManager, Currency.wrap(currency0), Currency.wrap(currency1), tickSpacing, governance, gasTokenSide
        );
        require(address(hook) == expected, "mined address did not match deployment");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(key, startSqrtPriceX96);

        _setLiveParameters(hook, governance);

        vm.stopBroadcast();

        _report(hook, governance);
    }

    /// @dev Confirm phase 1 actually ran.
    ///
    /// The library address is embedded in the hook's creation bytecode, and the
    /// hook's address is mined over that bytecode — so a different library
    /// address means a different hook address. Pinning it in `foundry.toml` is
    /// what makes the mined address reproducible; this check confirms the
    /// address you pinned is real.
    ///
    /// Deliberately not a scan for the `__$...$__` placeholder: forge
    /// substitutes an address before the bytecode ever reaches this script, so
    /// by the time Solidity can see it there is nothing left to detect. The
    /// only meaningful check is against the chain.
    function _assertSolverDeployed() internal view {
        address solver = vm.envAddress("BATCH_SOLVER");
        require(
            solver.code.length > 0,
            "BATCH_SOLVER has no code. Run DeployBatchSolver, then set both BATCH_SOLVER and "
            "libraries = [\"src/settle/BatchSolver.sol:BatchSolver:0x...\"] in foundry.toml, and recompile."
        );
    }

    /// @dev Both of these ship at a no-op default, because neither has a
    /// unit-independent value: they are denominated in each currency's own
    /// token units, and a floor meaningful on an 18-decimal pool is nonsense on
    /// a 6-decimal one. Left unset, the dust-spam floor and the warehoused-
    /// exposure cap are simply inactive.
    ///
    /// Skipped when the deployer is not governance, since the setters are
    /// `onlyGovernance` and would revert. Set them from the governance account
    /// afterwards in that case; the deployment is still valid without them.
    function _setLiveParameters(
        KesselHook hook_,
        address governance
    ) internal {
        if (governance != vm.addr(vm.envUint("PRIVATE_KEY"))) {
            console2.log("NOTE: deployer is not governance; skipping parameter setup.");
            return;
        }

        uint128 minOrder0 = uint128(vm.envOr("MIN_ORDER_SIZE0", uint256(0)));
        uint128 minOrder1 = uint128(vm.envOr("MIN_ORDER_SIZE1", uint256(0)));
        uint128 maxWarehouse0 = uint128(vm.envOr("MAX_WAREHOUSE0", uint256(type(uint128).max)));
        uint128 maxWarehouse1 = uint128(vm.envOr("MAX_WAREHOUSE1", uint256(type(uint128).max)));

        if (minOrder0 != 0 || minOrder1 != 0) hook_.setMinOrderSize(minOrder0, minOrder1);
        if (maxWarehouse0 != type(uint128).max || maxWarehouse1 != type(uint128).max) {
            hook_.setWarehouseCaps(maxWarehouse0, maxWarehouse1);
        }
    }

    function _report(
        KesselHook hook_,
        address governance
    ) internal view {
        console2.log("");
        console2.log("=== Kessel deployed ===");
        console2.log("hook        ", address(hook_));
        console2.log("governance  ", governance);
        console2.log("f_base      ", hook_.fBase());
        console2.log("f_slow      ", hook_.fSlow());
        console2.log("k           ", hook_.k());
        console2.log("minSettleAge", hook_.minSettleAge());
        console2.log("maxDelay    ", hook_.maxDelay());
        console2.log("");

        if (hook_.minOrderSize0() == 0 && hook_.minOrderSize1() == 0) {
            console2.log("WARNING: minOrderSize is 0 on both sides -- the dust-spam floor is INACTIVE.");
        }
        if (hook_.maxWarehouse0() == type(uint128).max && hook_.maxWarehouse1() == type(uint128).max) {
            console2.log("WARNING: maxWarehouse is unbounded -- the warehoused-exposure cap is INACTIVE.");
        }
    }
}

/// @notice Phase 0, testnets only. Two ERC-20s to build a pool from.
///
/// @dev A first deployment needs a pair, and on a testnet there is rarely one
/// worth using. These are plain mintable mocks: they are NOT a product, and
/// nothing about them should be reused on mainnet, where you supply real token
/// addresses instead.
///
/// The pair is sorted before being reported, because v4 requires
/// `currency0 < currency1` and the hook derives its immutable pool binding from
/// that key — getting the order wrong produces a hook bound to a pool that will
/// never exist.
contract DeployTestTokens is Script {
    function run() external returns (address token0, address token1) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        MockERC20 a = new MockERC20("Kessel Test A", "KTA", 18);
        MockERC20 b = new MockERC20("Kessel Test B", "KTB", 18);
        a.mint(deployer, 1_000_000 ether);
        b.mint(deployer, 1_000_000 ether);
        vm.stopBroadcast();

        (token0, token1) =
            address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));

        console2.log("minted 1,000,000 of each to", deployer);
        console2.log("");
        console2.log("CURRENCY0=%s", token0);
        console2.log("CURRENCY1=%s", token1);
    }
}
