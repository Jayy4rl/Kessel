// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KesselTestBase} from "../utils/KesselTestBase.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Phase 0 scaffold verification.
///
/// These are characterization tests against upstream Uniswap v4, not tests of
/// Kessel logic (there is none yet). They serve two purposes:
///
///  1. Prove the toolchain end-to-end -- remappings, solc 0.8.26, cancun, and
///     the v4-core test helpers all work.
///  2. Pin the v4 facts the architecture depends on, as executable assertions.
///     Each one corresponds to a claim made in the reconnaissance pass. If a
///     future v4 upgrade changes any of them, this suite fails loudly instead
///     of the assumption rotting silently inside a design document.
contract ScaffoldTest is KesselTestBase {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    function setUp() public {
        _deployHooklessPool();
    }

    // -----------------------------------------------------------------------
    // Toolchain
    // -----------------------------------------------------------------------

    function test_managerDeploys() public view {
        assertTrue(address(manager) != address(0), "manager not deployed");
    }

    function test_poolInitializes() public view {
        (uint160 sqrtPriceX96,,, uint24 lpFee) = manager.getSlot0(poolId);

        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "pool not initialized at 1:1");
        assertEq(uint256(lpFee), uint256(STATIC_FEE), "unexpected lp fee");
    }

    // -----------------------------------------------------------------------
    // Hook address validity (PRD §8.1, §8.2)
    //
    // v4 encodes permissions in the hook's address and validates the shape at
    // pool initialization. Two rules constrain Kessel directly.
    // -----------------------------------------------------------------------

    /// @dev A dynamic-fee pool REQUIRES a hook. PRD §8.1 mandates a dynamic-fee
    /// pool, so Kessel's pool can never exist without the hook attached -- the
    /// two are deployed as a unit.
    function test_dynamicFeePoolRequiresAHook() public {
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, address(0)));
        initPool(currency0, currency1, IHooks(address(0)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, SQRT_PRICE_1_1);
    }

    /// @dev `beforeSwapReturnDelta` is only valid alongside `beforeSwap`. Kessel
    /// needs both, so this rule is satisfied by construction -- but it is a hard
    /// constraint on any bitmap DD-8 might produce, so pin it.
    function test_returnsDeltaFlagRequiresItsActionFlag() public {
        address deltaOnly = address(uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));

        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, deltaOnly));
        initPool(currency0, currency1, IHooks(deltaOnly), STATIC_FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }

    /// @dev The known-required flag combination produces a valid hook address
    /// shape for a dynamic-fee pool. This is a precondition for Phase 6 address
    /// mining; it does not assert the bitmap is final (DD-8 is open).
    function test_knownRequiredFlagsFormAValidDynamicFeeHook() public {
        address hookAddr = address(uint160(KNOWN_REQUIRED_FLAGS));

        (, PoolId id) = initPool(
            currency0, currency1, IHooks(hookAddr), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, SQRT_PRICE_1_1
        );

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1, "dynamic-fee pool with Kessel's flags failed to initialize");
    }

    // -----------------------------------------------------------------------
    // Fee constants (PRD §4.1, §8.3)
    // -----------------------------------------------------------------------

    function test_feeFlagsMatchSpec() public pure {
        assertEq(uint256(LPFeeLibrary.DYNAMIC_FEE_FLAG), 0x800000, "DYNAMIC_FEE_FLAG drifted");
        assertEq(uint256(LPFeeLibrary.OVERRIDE_FEE_FLAG), 0x400000, "OVERRIDE_FEE_FLAG drifted");
        assertEq(uint256(LPFeeLibrary.MAX_LP_FEE), 1_000_000, "MAX_LP_FEE drifted");
    }

    /// @dev The Fast-Lane fee is returned as `fee | OVERRIDE_FEE_FLAG`. Confirm
    /// the round-trip the fee module will rely on.
    function test_overrideFlagRoundTrip() public pure {
        uint24 fee = 3000;
        uint24 tagged = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        assertTrue(tagged.isOverride(), "override flag not detected");
        assertEq(uint256(tagged.removeOverrideFlag()), uint256(fee), "fee did not survive round-trip");
    }

    // -----------------------------------------------------------------------
    // Hook permission bits (PRD §8.1, §8.2)
    //
    // The permission bitmap is encoded in the hook's address and is immutable
    // once mined, so these bit positions are load-bearing for DD-8.
    // -----------------------------------------------------------------------

    function test_hookPermissionBits() public pure {
        assertEq(uint256(Hooks.BEFORE_SWAP_FLAG), 1 << 7, "BEFORE_SWAP_FLAG moved");
        assertEq(uint256(Hooks.AFTER_SWAP_FLAG), 1 << 6, "AFTER_SWAP_FLAG moved");
        assertEq(uint256(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG), 1 << 3, "BEFORE_SWAP_RETURNS_DELTA_FLAG moved");
        assertEq(uint256(Hooks.ALL_HOOK_MASK), (1 << 14) - 1, "hook permission count changed");
    }

    // -----------------------------------------------------------------------
    // donate() empty-range behaviour (PRD §6.2)
    //
    // Recon finding: `donate()` reverts when there is no *active* liquidity.
    // PRD §6.2 therefore requires a fallback so a Fast-Lane swap never reverts
    // merely because the premium had nowhere to go. This test pins the
    // behaviour that makes the fallback mandatory.
    // -----------------------------------------------------------------------

    function test_donateRevertsWithNoActiveLiquidity() public {
        assertEq(manager.getLiquidity(poolId), 0, "expected an empty pool");

        vm.expectRevert(Pool.NoLiquidityToReceiveFees.selector);
        donateRouter.donate(key, 1e18, 1e18, ZERO_BYTES);
    }

    // -----------------------------------------------------------------------
    // Priority fee readability (PRD §2.3, §4.1)
    //
    // `tx.gasprice - block.basefee` is the only sanctioned urgency signal.
    // DD-2 is unresolved, so this asserts only that the arithmetic is readable
    // and behaves as expected under a controlled fixture -- NOT that any
    // particular chain orders on it (that is assumption A3, a fork test).
    // -----------------------------------------------------------------------

    function test_priorityFeeIsReadable() public {
        vm.fee(1 gwei);
        vm.txGasPrice(3 gwei);

        assertEq(tx.gasprice - block.basefee, 2 gwei, "priority fee arithmetic unexpected");
    }

    /// @dev `vm.fee` caps the base fee at 2^64, so bound both inputs to a range
    /// far wider than any realistic gas market but within the cheatcode limit.
    function testFuzz_priorityFeeNeverUnderflows(
        uint256 baseFee,
        uint256 tip
    ) public {
        baseFee = bound(baseFee, 0, 10_000 gwei);
        tip = bound(tip, 0, 10_000 gwei);

        vm.fee(baseFee);
        // A transaction's gas price is never below the block's base fee.
        vm.txGasPrice(baseFee + tip);

        assertEq(tx.gasprice - block.basefee, tip, "priority fee mismatch");
    }
}
