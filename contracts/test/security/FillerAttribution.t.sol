// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {KesselErrors} from "../../src/KesselTypes.sol";
import {IERC20Like, KesselTestBase} from "../utils/KesselTestBase.sol";

interface IERC20Ops {
    function approve(
        address,
        uint256
    ) external returns (bool);
    function transfer(
        address,
        uint256
    ) external returns (bool);
}

/// @notice SR-9: the external fill is attributed to the caller, and a
/// settlement that does nothing returns the caller's capital.
///
/// @dev The path used to be *deliver-first*: transfer the output currency in,
/// then call `settleWithFill()`, and the hook took `outCurrency.balanceOfSelf()`
/// to be the delivery. Two defects composed into a theft primitive.
///
///  1. `balanceOfSelf()` is unattributed. It is whatever anyone has ever sent
///     this contract, so a filler could satisfy the curve floor out of tokens
///     it never provided and still be paid the batch's whole input.
///  2. `_settleEpochInner` returns silently when the batch cannot be settled —
///     every order screened out, an infeasible pool, an emptied candidate set.
///     `settleWithFill` did not check, so the already-transferred delivery was
///     never banked, never refunded, and stayed on the contract as raw balance.
///
/// Chained: front-run an honest filler with a swap that moves the price until
/// every order in the batch fails its limit; their transaction succeeds and
/// does nothing, stranding their capital; then call `settleWithFill` yourself,
/// delivering nothing, and collect. Neither step touches ERC-6909 custody, so
/// I2 held throughout and no invariant fired.
///
/// The fix declares the amount and pulls it (`transferFrom`, which hands
/// control to the token and not to the filler), and turns a no-op settlement on
/// this path into a revert.
contract FillerAttributionTest is KesselTestBase {
    address internal filler = address(0xF111E7);
    address internal victim = address(0x1C7);

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(address(this), 1_000 ether);
    }

    /// @notice A filler is not paid out of tokens it did not provide.
    ///
    /// @dev The scenario is a stray balance of exactly the curve floor sitting
    /// on the hook. Under the old measurement that alone satisfied the floor
    /// and the caller was paid the batch's entire input for zero capital.
    function test_SR9_aFillerCannotBePaidOutOfStrayBalance() public {
        _slowOrder(alice, true, 1 ether, 1e15, 200);
        _slowOrder(bob, true, 1 ether, 1e15, 200);
        vm.roll(vm.getBlockNumber() + hook.minSettleAge() + 1);

        (bool ok, Currency outCurrency, uint256 floorOut, Currency inCurrency, uint256 payout) = hook.quoteFill();
        assertTrue(ok, "setup: the batch should be fillable");

        // Somebody else's tokens, already sitting on the hook.
        deal(Currency.unwrap(outCurrency), address(hook), floorOut);

        uint256 before = IERC20Like(Currency.unwrap(inCurrency)).balanceOf(filler);

        // The filler holds and approves nothing, and declares the full floor.
        vm.prank(filler);
        vm.expectRevert();
        hook.settleWithFill(floorOut);

        assertEq(
            IERC20Like(Currency.unwrap(inCurrency)).balanceOf(filler) - before,
            0,
            "a filler was paid without providing the delivery"
        );
        assertGt(payout, 0, "setup: the quote should have promised a real payout");
    }

    /// @notice A settlement that cannot run returns the caller's capital
    /// instead of consuming it.
    ///
    /// @dev Every order here carries a floor of 100 currency1 per currency0 on
    /// a pool trading at 1, so the shrinking-set loop drops all of them and the
    /// batch settles to a fill ratio of zero for everyone. That is a legitimate
    /// outcome on the curve paths — the epoch is finished and its orders roll —
    /// but on the filler path it must be a revert, because the caller has
    /// capital committed to a fill that did not happen.
    function test_SR9_aNoOpSettlementDoesNotConsumeTheDelivery() public {
        _slowOrder(alice, true, 1 ether, 100 ether, 200);
        _slowOrder(alice, true, 1 ether, 100 ether, 200);
        vm.roll(vm.getBlockNumber() + hook.minSettleAge() + 1);

        uint256 offer = 5 ether;
        deal(Currency.unwrap(currency1), filler, offer);

        vm.startPrank(filler);
        IERC20Ops(Currency.unwrap(currency1)).approve(address(hook), offer);
        vm.expectRevert(KesselErrors.NothingToSettle.selector);
        hook.settleWithFill(offer);
        vm.stopPrank();

        assertEq(IERC20Like(Currency.unwrap(currency1)).balanceOf(filler), offer, "the filler's capital was consumed");
        assertEq(
            IERC20Like(Currency.unwrap(currency1)).balanceOf(address(hook)), 0, "a delivery was stranded on the hook"
        );
    }

    /// @notice Nothing the filler path does leaves a raw balance behind.
    ///
    /// @dev The pull goes filler -> singleton, so the tokens never rest here at
    /// all. This is what removes the supply of "free capital for the next
    /// caller" that made the chained attack worth running.
    function test_SR9_aSuccessfulFillLeavesNoRawBalance() public {
        uint256 id = _slowOrder(alice, true, 1 ether, 1e15, 200);
        _slowOrder(bob, true, 1 ether, 1e15, 200);
        vm.roll(vm.getBlockNumber() + hook.minSettleAge() + 1);

        (bool ok, Currency outCurrency, uint256 floorOut,,) = hook.quoteFill();
        assertTrue(ok, "setup: the batch should be fillable");

        deal(Currency.unwrap(outCurrency), filler, floorOut);
        vm.startPrank(filler);
        IERC20Ops(Currency.unwrap(outCurrency)).approve(address(hook), floorOut);
        hook.settleWithFill(floorOut);
        vm.stopPrank();

        assertGt(_order(id).owedOut, 0, "the batch did not actually fill");
        assertEq(IERC20Like(Currency.unwrap(currency0)).balanceOf(address(hook)), 0, "raw currency0 left on the hook");
        assertEq(IERC20Like(Currency.unwrap(currency1)).balanceOf(address(hook)), 0, "raw currency1 left on the hook");
    }

    /// @notice Tokens that reach the hook anyway are LP money, and anyone can
    /// send them there.
    ///
    /// @dev A mistaken transfer, or an order that named the hook itself as its
    /// beneficiary, still leaves a raw balance with no owner. `sweepRecapture`
    /// mints it into custody first and then donates it, which is load-bearing:
    /// `_recapture` pays a donation by BURNING ERC-6909, so crediting a raw
    /// balance to `lpClaimable*` without minting it would take the donation out
    /// of the traders' escrow instead (I2).
    function test_SR9_strayBalanceIsSweptToLPsRatherThanLeftForAFiller() public {
        uint256 stray = 3 ether;
        deal(Currency.unwrap(currency1), address(hook), stray);

        (uint256 custodyBefore0, uint256 custodyBefore1) = _custody();
        assertEq(custodyBefore0 + custodyBefore1, 0, "setup: the hook should hold no custody yet");

        hook.sweepRecapture();

        assertEq(IERC20Like(Currency.unwrap(currency1)).balanceOf(address(hook)), 0, "stray balance was not swept");
        // Liquidity is in range, so it was donated outright rather than deferred.
        assertEq(hook.lpClaimable1(), 0, "stray balance should have reached LPs, not been deferred");
        (, uint256 custodyAfter1) = _custody();
        assertEq(custodyAfter1, 0, "the sweep left custody it did not distribute");
    }
}
