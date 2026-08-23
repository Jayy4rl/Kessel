// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

/// @notice Shared fixture for Kessel tests.
///
/// Builds on v4-core's `Deployers`, adding only what is specific to Kessel: the
/// tick spacing used across the suite and the permission bits the hook is known
/// to require.
///
/// Kessel's real pool is dynamic-fee (PRD §8.1, so the Fast Lane can set its fee
/// per swap from `beforeSwap`). That fixture cannot exist yet: v4 rejects a
/// dynamic-fee pool with no hook, and there is no hook until Phase 1. The
/// Phase 0 fixture is therefore a hookless static-fee pool.
///
/// No hook is wired up here. A hook's address encodes its permission bitmap,
/// and that bitmap depends on DD-8, which is unresolved. Phase 2 adds a
/// `deployHookToFlaggedAddress` helper once there is a hook to deploy.
abstract contract KesselTestBase is Deployers {
    /// @dev Tick spacing used for every Kessel test pool; matches the value
    /// `Deployers` picks for dynamic-fee pools.
    int24 internal constant TICK_SPACING = 60;

    /// @dev Placeholder static fee for fixtures that do not need a dynamic-fee
    /// pool. 0.30%, in hundredths of a bip.
    uint24 internal constant STATIC_FEE = 3000;

    /// @dev The permission bits Kessel is currently known to require: lane
    /// routing and fee override need `beforeSwap`, and Slow-Lane async intake
    /// needs `beforeSwapReturnDelta`.
    ///
    /// `afterSwap` is deliberately absent -- DD-8 is unresolved. Do not treat
    /// this constant as the final bitmap; it is the known-required subset, and
    /// the address must not be mined until DD-8 is decided (PRD §8.1).
    uint160 internal constant KNOWN_REQUIRED_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    /// @dev Id of the pool created by `_deployHooklessPool`.
    PoolId internal poolId;

    /// @notice Deploy the manager and routers, mint and approve two currencies,
    /// and initialize a hookless static-fee pool. Phase 0 baseline.
    ///
    /// @dev This pool is deliberately NOT dynamic-fee. v4 rejects a dynamic-fee
    /// pool whose hook is `address(0)` (see `Hooks.isValidHookAddress`), which
    /// makes sense -- with no hook, nothing could ever set the fee. Kessel's
    /// real pool is dynamic-fee with the hook attached; that fixture arrives in
    /// Phase 1, once there is a hook to attach.
    function _deployHooklessPool() internal {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), STATIC_FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }
}
