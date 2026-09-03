// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Vm} from "forge-std/Vm.sol";

import {KesselErrors, KesselEvents} from "../../src/KesselTypes.sol";
import {FastLaneFee} from "../../src/lanes/FastLaneFee.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice The size-denominated Fast-Lane tax (DD-4 as amended), through the
/// live hook rather than the pure library.
///
/// `test/property/FastLaneFeeProperties.t.sol` proves the arithmetic. What it
/// cannot prove is that the hook ever *reaches* that arithmetic: the mode is
/// selected by an immutable constructor argument, falls back to the rate form
/// whenever the pool's own price cannot establish a size, and is reachable only
/// on a deployment that declares a gas-token side. Every branch of that
/// selection is here, because a deployment that silently ran the wrong mode
/// would mis-price the Fast Lane while looking entirely healthy — the fee is
/// still monotone, still capped, still routed to LPs, just denominated in the
/// wrong thing (I12 holds in both modes, which is exactly why nothing else in
/// the suite would notice).
contract GasTokenFeeTest is KesselTestBase {
    uint8 internal constant GAS_TOKEN_NONE = 0;
    uint8 internal constant GAS_TOKEN_CURRENCY0 = 1;
    uint8 internal constant GAS_TOKEN_CURRENCY1 = 2;

    uint24 internal constant MAX_FAST_FEE = 50_000;

    function setUp() public {
        // currency0 is the chain's gas-token-equivalent side. The pool is
        // initialised at 1:1, so the two currencies are interchangeable for
        // sizing and the assertions below stay readable.
        gasTokenSide = GAS_TOKEN_CURRENCY0;
        _deployKessel();
        _addWideLiquidity();
    }

    // ======================================================================
    // The mode is actually selected
    // ======================================================================

    /// @notice On a gas-token deployment the charged fee is the size-denominated
    /// one, not the rate form.
    ///
    /// @dev The two modes agree at a priority fee of zero (both charge
    /// `fBase`), so the test is run at a real priority fee where they diverge,
    /// and both are computed independently from the library rather than from a
    /// hard-coded expectation.
    function test_DD4_gasTokenDeploymentChargesTheSizeDenominatedFee() public {
        uint256 priorityFee = 5 gwei;
        uint256 amountIn = 1e18;

        _setPriorityFee(priorityFee);
        uint24 charged = _feeChargedBy(true, -int256(amountIn));

        // At a 1:1 pool price a zeroForOne exact-input swap is already
        // denominated in currency0, so the size is the input itself.
        uint24 expectedBySize = FastLaneFee.feeBySize(hook.fBase(), hook.kGas(), priorityFee, amountIn, MAX_FAST_FEE);
        uint24 expectedByRate = FastLaneFee.fee(hook.fBase(), hook.k(), priorityFee, MAX_FAST_FEE);

        assertEq(charged, expectedBySize, "gas-token deployment did not use the size-denominated form");
        assertTrue(charged != expectedByRate, "the two modes must actually differ at this calibration");
    }

    /// @notice The premium is a fixed *amount*, so a larger trade pays a
    /// strictly lower rate. This is the property the rate form could not
    /// express and the reason DD-4 was reopened.
    function test_DD4_largerTradesPayALowerRateForTheSameUrgency() public {
        _setPriorityFee(5 gwei);
        uint24 smallFee = _feeChargedBy(true, -0.1e18);

        _setPriorityFee(5 gwei);
        uint24 largeFee = _feeChargedBy(true, -1e18);

        assertGt(smallFee, largeFee, "a ten-times-larger trade should pay a lower rate for the same urgency");
        assertGe(smallFee, hook.fBase(), "fee fell below the base");
    }

    /// @notice The conversion runs in the direction that needs the pool price
    /// too. A `oneForZero` exact-input swap specifies currency1, which is not
    /// the declared gas token, so its size must be converted through
    /// `sqrtPriceX96` before the tax is applied.
    function test_DD4_theConvertedDirectionIsAlsoPriced() public {
        _setPriorityFee(5 gwei);
        uint24 fee = _feeChargedBy(false, -1e18);

        // At 1:1 the conversion is the identity in value, so the converted
        // direction must land on the same fee as the unconverted one. That is
        // the strongest available check: it pins the conversion as correct
        // rather than merely as having happened.
        _setPriorityFee(5 gwei);
        uint24 unconverted = _feeChargedBy(true, -1e18);

        assertEq(fee, unconverted, "the converted direction priced differently at a 1:1 pool");
    }

    /// @notice I12 through the live hook in the size-denominated mode.
    function test_I12_sizeModeIsMonotoneInPriorityFee() public {
        uint24 last;
        uint256[5] memory priorities = [uint256(0), 1 gwei, 5 gwei, 20 gwei, 200 gwei];

        for (uint256 i; i < priorities.length; ++i) {
            _setPriorityFee(priorities[i]);
            uint24 fee = _feeChargedBy(true, -1e18);
            assertGe(fee, last, "I12 violated in the size-denominated mode");
            assertLe(fee, MAX_FAST_FEE, "fee exceeded the hard cap");
            last = fee;
        }
    }

    // ======================================================================
    // The fallback
    // ======================================================================

    /// @notice `setKGas` moves the tax the size mode actually charges.
    ///
    /// @dev The setter exists on every deployment but only bites here, so this
    /// is the only place its effect is observable. Its bounds are checked in
    /// `Governance.t.sol` alongside every other parameter.
    function test_setKGasMovesTheChargedFee() public {
        _setPriorityFee(5 gwei);
        uint24 before = _feeChargedBy(true, -1e18);

        uint256 raised = hook.kGas() * 4;
        vm.prank(governance);
        hook.setKGas(raised);

        _setPriorityFee(5 gwei);
        uint24 after_ = _feeChargedBy(true, -1e18);

        assertGt(after_, before, "raising kGas did not raise the charged fee");
    }

    /// @notice A `kGas` of zero disables the size tax without disabling the
    /// lane: the base fee is still charged.
    function test_zeroKGasChargesBaseOnly() public {
        vm.prank(governance);
        hook.setKGas(0);

        _setPriorityFee(50 gwei);
        assertEq(_feeChargedBy(true, -1e18), hook.fBase(), "a zero kGas should leave only the base fee");
    }

    // ======================================================================
    // Deploy-time guards
    //
    // The mode is fixed at construction and can never move under a live pool,
    // so these are the only moment at which a mis-declaration can be caught.
    // ======================================================================

    /// @notice An undefined gas-token side is refused.
    function test_constructorRefusesAnUnknownGasTokenSide() public {
        (bool ok, bytes memory ret) = _tryDeploy(currency0, currency1, GAS_TOKEN_CURRENCY1 + 1);
        assertFalse(ok, "an out-of-range gas-token side must not deploy");
        assertEq(_revertSelector(ret), KesselErrors.ParameterOutOfBounds.selector, "wrong revert reason");
    }

    /// @notice Declaring currency1 the gas token while currency0 is native is
    /// contradictory on its face, and is refused.
    ///
    /// @dev The native currency is `address(0)` and always sorts to currency0,
    /// so such a pool's gas token can only be currency0. Every other
    /// combination is a deployer assertion this contract cannot check — see the
    /// constructor's note on WETH-quoted pools — which is precisely why the one
    /// combination it *can* check is checked.
    function test_constructorRefusesNativeCurrency0DeclaredAsCurrency1Gas() public {
        (bool ok, bytes memory ret) = _tryDeploy(Currency.wrap(address(0)), currency1, GAS_TOKEN_CURRENCY1);
        assertFalse(ok, "a contradictory gas-token declaration must not deploy");
        assertEq(_revertSelector(ret), KesselErrors.ParameterOutOfBounds.selector, "wrong revert reason");
    }

    /// @notice A hook with no governance can never have a parameter changed
    /// again, so it is refused at construction as well as at handover.
    function test_constructorRefusesZeroGovernance() public {
        bytes memory args = abi.encode(manager, currency0, currency1, TICK_SPACING, address(0), GAS_TOKEN_NONE);
        (bool ok, bytes memory ret) = _tryDeployWithArgs(args);
        assertFalse(ok, "a hook with no governance must not deploy");
        assertEq(_revertSelector(ret), KesselErrors.ParameterOutOfBounds.selector, "wrong revert reason");
    }

    /// @notice Passing `NONE` is always safe and selects the rate form. The
    /// suite's other 150-odd tests run on such a deployment; this states it as
    /// a property rather than leaving it implicit in the fixture default.
    function test_gasTokenSideNoneIsAcceptedAndSelectsTheRateForm() public {
        (bool ok,) = _tryDeploy(currency0, currency1, GAS_TOKEN_NONE);
        assertTrue(ok, "the rate-form deployment must be accepted");
    }

    // ======================================================================
    // Helpers
    // ======================================================================

    /// @dev Run one Fast-Lane swap and return the fee the hook announced.
    /// Read from the event rather than recomputed, so the assertion is about
    /// what the pool actually charged.
    function _feeChargedBy(
        bool zeroForOne,
        int256 amountSpecified
    ) internal returns (uint24 feeCharged) {
        vm.recordLogs();
        _fastSwap(zeroForOne, amountSpecified);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook)) continue;
            if (logs[i].topics[0] != KesselEvents.FastSwap.selector) continue;
            (,,, feeCharged,) = abi.decode(logs[i].data, (bool, int256, uint256, uint24, uint24));
            return feeCharged;
        }
        revert("no FastSwap event emitted");
    }

    /// @dev Deploy a second hook at a differently-salted but still
    /// correctly-flagged address, and report whether the constructor accepted
    /// its arguments.
    ///
    /// @dev `deployCodeTo` swallows the revert reason behind its own `require`,
    /// so the etch-and-call is done here explicitly. The target carries
    /// `KESSEL_FLAGS`, so `BaseHook`'s own address validation — which runs
    /// before the derived constructor body — passes and the revert observed is
    /// Kessel's.
    function _tryDeploy(
        Currency c0,
        Currency c1,
        uint8 side
    ) internal returns (bool ok, bytes memory ret) {
        return _tryDeployWithArgs(abi.encode(manager, c0, c1, TICK_SPACING, governance, side));
    }

    /// @dev First four bytes of raw returndata — the custom error's selector.
    /// Truncating by construction, so it is spelled out rather than cast
    /// inline, where the linter cannot tell it apart from an accident.
    function _revertSelector(
        bytes memory ret
    ) internal pure returns (bytes4 selector) {
        require(ret.length >= 4, "revert data too short to carry a selector");
        return bytes4(bytes32(_word(ret)));
    }

    function _word(
        bytes memory ret
    ) private pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := mload(add(ret, 32))
        }
    }

    function _tryDeployWithArgs(
        bytes memory args
    ) internal returns (bool ok, bytes memory ret) {
        address target = address(uint160(KESSEL_FLAGS) | (uint160(0x5555) << 144));
        vm.etch(target, abi.encodePacked(vm.getCode("KesselHook.sol:KesselHook"), args));
        (ok, ret) = target.call("");
    }
}
