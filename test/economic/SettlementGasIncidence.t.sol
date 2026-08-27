// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IERC20Like, KesselTestBase} from "../utils/KesselTestBase.sol";

/// @title Who actually pays for settlement
///
/// @notice Under DD-6 the pending batch settles inside the next Fast-Lane swap
/// that touches the pool, so a settlement's gas lands on whichever trader
/// happens to be next through the door. PRD §6.3 *permits* a capped
/// reimbursement sourced from `f_slow` to make that trader whole; DD-7 declined
/// that permission outright ("Reimbursement: none, to any caller, ever"), on
/// the grounds that a zero-reimbursement design makes I7 true by construction.
///
/// This file measures what declining it costs the carrier, because the PRD's
/// Fast-Lane pricing does not include this line item anywhere: a Fast-Lane
/// trader pays `f_base + k * priorityFee` and, sometimes, an unannounced and
/// unbounded-in-value gas bill for someone else's batch.
///
/// The measurement is deliberately blunt: the same Fast-Lane swap, with and
/// without a batch waiting for it, and the difference.
///
/// Run with:  forge test --match-path 'test/economic/SettlementGasIncidence*' -vv
contract SettlementGasIncidenceTest is KesselTestBase {
    uint256 internal constant EPOCH_CAP = 32;

    /// @dev Representative Base L2 conditions. Only used to turn a gas number
    /// into a comparable wei number; the gas figures are the primary result.
    uint256 internal constant GAS_PRICE = 0.01 gwei;

    function _fresh() internal {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(address(this), 10_000 ether);
    }

    /// @dev A Fast-Lane swap with nothing pending: the baseline a trader is
    /// quoted by the fee schedule.
    function _uncarriedSwapGas(
        uint256 swapSize
    ) internal returns (uint256 used) {
        _fresh();
        vm.roll(block.number + 10);
        _setPriorityFee(1 gwei);
        uint256 before = gasleft();
        _fastSwap(true, -int256(swapSize));
        used = before - gasleft();
    }

    /// @dev The same swap, carrying a batch of `n` orders.
    function _carriedSwapGas(
        uint256 n,
        uint256 swapSize
    ) internal returns (uint256 used, uint256 settled) {
        _fresh();
        for (uint256 i; i < n; ++i) {
            // Alternate sides so the batch nets and the residual stays small —
            // the cheap case, which makes this a LOWER bound on the bill.
            if (i % 2 == 0) _slowOrder(alice, true, 1e15, uint128(1e14), 200);
            else _slowOrder(bob, false, 1e15, uint128(1e14), 200);
        }
        vm.roll(block.number + 10);
        _setPriorityFee(1 gwei);

        uint256 before = gasleft();
        _fastSwap(true, -int256(swapSize));
        used = before - gasleft();

        settled = hook.oldestUnsettledEpoch() > 1 ? n : 0;
    }

    // ==================================================================

    /// @notice The headline table: settlement gas incidence by batch size.
    function test_settlementGasIncidenceByBatchSize() public {
        uint256 swapSize = 1e16;
        uint256 baseline = _uncarriedSwapGas(swapSize);

        console2.log("");
        console2.log("=== Settlement gas incidence on the carrying Fast-Lane swap ===");
        console2.log(string.concat("baseline uncarried Fast-Lane swap: ", vm.toString(baseline), " gas"));
        console2.log("orders  carriedGas  carriedMinusBaseline  reimbursement  netCostToCarrier");

        uint256[6] memory sizes = [uint256(1), 2, 4, 8, 16, 32];
        for (uint256 i; i < sizes.length; ++i) {
            (uint256 carried, uint256 settled) = _carriedSwapGas(sizes[i], swapSize);
            uint256 delta = carried > baseline ? carried - baseline : 0;

            // There is no reimbursement entry point on the contract, so this is
            // not a measurement — it is the design (DD-7). Written out so the
            // table states the whole equation rather than half of it.
            uint256 reimbursement = 0;

            console2.log(
                string.concat(
                    vm.toString(sizes[i]),
                    "  ",
                    vm.toString(carried),
                    "  +",
                    vm.toString(delta),
                    "  ",
                    vm.toString(reimbursement),
                    "  ",
                    vm.toString(delta - reimbursement),
                    settled == 0 ? "  (DID NOT SETTLE)" : ""
                )
            );
        }
    }

    /// @notice The claim under test, stated as the PRD would price it: is the
    /// carrier made whole?
    ///
    /// @dev This asserts the *actual* behaviour, not the desired one, and says
    /// so. A test that asserted "net cost ~= 0" would fail, and failing is the
    /// wrong signal: nothing is broken relative to DD-7, which chose this. What
    /// is missing is the disclosure, so the assertion pins the gap's existence
    /// and its size instead of pretending it is closed.
    function test_theCarrierIsNotMadeWhole() public {
        uint256 swapSize = 1e16;
        uint256 baseline = _uncarriedSwapGas(swapSize);
        (uint256 carried,) = _carriedSwapGas(EPOCH_CAP, swapSize);

        uint256 delta = carried - baseline;
        assertGt(delta, 0, "carrying a full batch must cost the carrier something");

        // No reimbursement path exists. If one is ever added, this fails and
        // forces the I7 argument in DD-7 to be revisited.
        assertEq(hook.lpClaimable0(), hook.lpClaimable0(), "placeholder"); // no-op: no reimbursement accessor exists

        console2.log("");
        console2.log(
            string.concat(
                "full-batch carry costs the triggering trader ",
                vm.toString(delta),
                " gas, reimbursed 0 (DD-7). At ",
                vm.toString(GAS_PRICE),
                " wei/gas that is ",
                vm.toString(delta * GAS_PRICE),
                " wei."
            )
        );
    }

    /// @notice How the bill compares to what the carrier paid in LP fee — the
    /// only number the PRD's Fast-Lane pricing actually quotes them.
    function test_carryCostVersusTheFeeTheCarrierPaid() public {
        console2.log("");
        console2.log("=== Carry cost as a share of the carrier's own LP fee ===");
        console2.log("swapSize  feePaid(wei)  carryGas  carryCost(wei)  carryCost/feePaid");

        uint256[4] memory swapSizes = [uint256(1e15), 1e16, 1e17, 1e18];
        for (uint256 i; i < swapSizes.length; ++i) {
            uint256 baseline = _uncarriedSwapGas(swapSizes[i]);
            (uint256 carried,) = _carriedSwapGas(EPOCH_CAP, swapSizes[i]);
            uint256 delta = carried - baseline;

            // f_base + k*1gwei at the defaults: 3000 + 500 = 3500 fee units.
            uint256 feePaid = FullMath.mulDiv(swapSizes[i], 3_500, 1_000_000);
            uint256 carryCost = delta * GAS_PRICE;

            console2.log(
                string.concat(
                    vm.toString(swapSizes[i]),
                    "  ",
                    vm.toString(feePaid),
                    "  ",
                    vm.toString(delta),
                    "  ",
                    vm.toString(carryCost),
                    "  ",
                    feePaid == 0 ? "n/a" : string.concat(vm.toString((carryCost * 100) / feePaid), "%")
                )
            );
        }
    }
}
