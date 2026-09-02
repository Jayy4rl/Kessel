// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {FastLaneFee} from "../../src/lanes/FastLaneFee.sol";
import {IERC20Like, KesselTestBase} from "../utils/KesselTestBase.sol";

/// @title DD-5 adversarial economic simulation
///
/// @notice **This is not an invariant test and it must not be read as one.**
/// The invariant suite cannot see the question this file asks, because the
/// question is an economic outcome across two transactions rather than a
/// state-machine violation: every run below leaves I1–I12 intact whether the
/// attack pays or not.
///
/// ## The question
///
/// Can an adversary move the pool price in the settlement block, skew the
/// uniform clearing price, and profit by more than Kessel's priority-fee tax
/// costs them?
///
/// ## What is actually simulated
///
/// The real `KesselHook`, the real `Clearing.solve`, and a real v4 pool — no
/// model of any of them. Each cell runs the attack end to end and measures the
/// attacker's token balances, so there is no modelling error to argue about.
///
/// The attack is the strongest form the design permits:
///
///   tx1  attacker Fast-Lane swap of size `A` at priority fee `p`. Its
///        `afterSwap` settles the pending batch, so the batch clears at the
///        price the attacker just moved the pool to.
///   tx2  attacker unwinds the position.
///
/// Note what the piggyback design (DD-6) forces here: the perturbation and the
/// settlement are **atomic**. The attacker cannot watch the batch clear and
/// then decide whether to keep the position — they commit to `A` before seeing
/// the outcome. Splitting them is not available: a Fast-Lane swap settles a due
/// batch whether or not its sender wants it to.
///
/// ## How "profit" is measured
///
/// `extraction = pnl(attack with a batch pending) - pnl(identical two swaps
/// with no batch pending)`. Differencing against the no-batch control is what
/// isolates value taken *from the batch* from the ordinary round-trip cost of
/// two swaps, and it is why the numbers below are not merely restatements of
/// the fee schedule. P&L is in currency1 units, marking currency0 at the
/// pool's pre-attack spot price.
///
/// `tax` is the Kessel priority-fee tax the attacker paid: the portion of the
/// LP fee above `f_base` on both legs, i.e. what `k` actually charged them.
///
/// A cell is `PROFIT` when `extraction > tax` — the user-facing framing — and
/// `netPnl > 0` is reported alongside, which is the sharper test because it
/// also charges the attacker `f_base` on both legs.
///
/// ## Benchmark
///
/// FM-AMM's zero-arbitrage result assumes *open* arbitrage competition. A
/// sealed batch removes that competition, so the applicable regime is
/// Canidio–Fritsch's malicious-batch-operator bound: extraction of at most half
/// what a CPAMM would lose. `cpamm` below is the operational form of that
/// benchmark — the profit the *same* attacker makes sandwiching the *same* net
/// flow when it is executed as an ordinary Fast-Lane swap instead of a batch.
/// The half-bound is `cpamm / 2`.
///
/// Run with:  forge test --match-path 'test/economic/*' -vv
contract DD5ManipulationTest is KesselTestBase {
    /// @dev Priority fee the attacker bids. Only the product `k * p` enters the
    /// tax, so sweeping `k` at a fixed `p` also sweeps `p` at fixed `k`.
    uint256 internal constant PRIORITY = 1 gwei;

    uint256 internal constant LIQUIDITY = 100 ether;
    int24 internal constant WIDE_LOWER = -60_000;
    int24 internal constant WIDE_UPPER = 60_000;

    address internal attacker = address(0xADDE7);

    struct Cell {
        uint256 batch; // total slow-lane notional across both sides
        uint256 residualBps; // residual after netting, as bps of `batch`
        uint256 k;
        uint256 attackSize;
        /// @dev How much price slack each trader's `minOut` leaves, in bps. This
        /// is the axis that actually bounds the attack: an order is only
        /// eligible while the (skewed) clearing price still meets its limit, so
        /// the attacker's skew has to fit inside whatever slack survives the
        /// batch's own price impact.
        uint256 slackBps;
    }

    struct Outcome {
        int256 pnlWith;
        int256 pnlWithout;
        int256 extraction;
        uint256 tax;
        uint256 residual;
        bool settled;
        /// @dev Gross input the batch actually filled. Zero means the attacker
        /// pushed the price past every order's limit and there was no victim
        /// flow left to sandwich.
        uint256 filled;
    }

    // ==================================================================
    // Fixture
    // ==================================================================

    /// @dev Snapshot of the deployed-and-funded world, taken once and reverted
    /// to for every subsequent cell.
    uint256 private _pristine = type(uint256).max;

    /// @dev A clean pool at a given `k`.
    ///
    /// @dev The sweeps in this file call this twice per cell — once with a
    /// batch pending and once without — so a full redeploy each time costs
    /// `2 * cells` deployments of the manager, routers, currencies, hook and
    /// pool, plus four funded accounts. At 42 cells that is 84 of them, and
    /// `test_DD5_extractionAsShareOfBatchVersusSlack` used to exhaust the
    /// 3e9 `gas_limit` part-way through its last row and die `MemoryOOG` with
    /// six of its seven rows already printed.
    ///
    /// Deploying once and reverting to a snapshot is equivalent — a reverted
    /// snapshot restores contract code, balances and block number alike — and
    /// costs a fraction of it. The snapshot is retaken after each revert
    /// because reverting consumes it, and it is taken *before* `setK` so that
    /// `k` remains a per-cell parameter rather than being baked in.
    function _freshPool(
        uint256 k
    ) internal {
        if (_pristine == type(uint256).max) {
            _deployKessel();
            _addLiquidity(WIDE_LOWER, WIDE_UPPER, int256(LIQUIDITY));
            _fundAndApprove(address(this), 10_000 ether);
            _fundAndApprove(attacker, 10_000 ether);
            _fundAndApprove(alice, 10_000 ether);
            _fundAndApprove(bob, 10_000 ether);
        } else {
            vm.revertToState(_pristine);
        }
        _pristine = vm.snapshotState();

        vm.prank(governance);
        hook.setK(k);
    }

    function _bal(
        address who
    ) internal view returns (uint256 b0, uint256 b1) {
        b0 = IERC20Like(Currency.unwrap(currency0)).balanceOf(who);
        b1 = IERC20Like(Currency.unwrap(currency1)).balanceOf(who);
    }

    /// @dev P&L in currency1 units. The pool starts at 1:1 in every run, so
    /// currency0 is marked at parity — stated explicitly because a P&L that
    /// silently marks at the *post*-attack price would flatter the attacker.
    function _pnl(
        uint256 b0Before,
        uint256 b1Before,
        uint256 b0After,
        uint256 b1After
    ) internal pure returns (int256) {
        return (int256(b0After) - int256(b0Before)) + (int256(b1After) - int256(b1Before));
    }

    /// @dev The two attacker legs. `zeroForOne` first, then the unwind.
    function _sandwichLegs(
        uint256 amount
    ) internal {
        _setPriorityFee(PRIORITY);
        vm.prank(attacker);
        _fastSwapAs(true, -int256(amount));

        _setPriorityFee(PRIORITY);
        vm.prank(attacker);
        _fastSwapAs(false, -int256(amount));
    }

    function _fastSwapAs(
        bool zeroForOne,
        int256 amountSpecified
    ) internal {
        _swapWithData(zeroForOne, amountSpecified, "");
    }

    /// @dev The Kessel tax on the two legs: the LP fee charged above `f_base`.
    function _taxOnLegs(
        uint256 k,
        uint256 amount
    ) internal view returns (uint256) {
        uint24 charged = FastLaneFee.fee(hook.fBase(), k, PRIORITY, 50_000);
        uint256 premium = charged > hook.fBase() ? charged - hook.fBase() : 0;
        return 2 * FullMath.mulDiv(amount, premium, 1_000_000);
    }

    // ==================================================================
    // One cell
    // ==================================================================

    function _runCell(
        Cell memory c
    ) internal returns (Outcome memory o) {
        // ---- run 1: attack against a pending batch ----------------------
        _freshPool(c.k);

        // Split the batch so the residual after netting is `residualBps` of it.
        // `Clearing.solve` reads only the two aggregates `net0`/`net1`, so the
        // number of orders behind them cannot affect the clearing price — see
        // `test_DD5_orderCountDoesNotChangeTheClearingPrice`.
        uint256 side0 = (c.batch * (10_000 + c.residualBps)) / 20_000;
        uint256 side1 = c.batch - side0;

        uint256 id0 = _slowOrder(alice, true, side0, uint128((side0 * (10_000 - c.slackBps)) / 10_000), 64);
        uint256 id1;
        if (side1 > 0) {
            // A `oneForZero` limit is a price CEILING, so its slack goes the
            // other way: accept up to `1 + slack`.
            id1 = _slowOrder(bob, false, side1, uint128((side1 * 10_000) / (10_000 + c.slackBps)), 64);
        }

        vm.roll(vm.getBlockNumber() + 5);

        (uint256 a0, uint256 a1) = _bal(attacker);
        _sandwichLegs(c.attackSize);
        (uint256 b0, uint256 b1) = _bal(attacker);
        o.pnlWith = _pnl(a0, a1, b0, b1);

        (,,,,,, bool settled) = hook.epochs(1);
        o.settled = settled;
        o.residual = side0 > side1 ? side0 - side1 : side1 - side0;
        o.filled = (side0 - _order(id0).amountInRemaining) + (side1 > 0 ? side1 - _order(id1).amountInRemaining : 0);

        // ---- run 2: identical legs, no batch ----------------------------
        _freshPool(c.k);
        (a0, a1) = _bal(attacker);
        _sandwichLegs(c.attackSize);
        (b0, b1) = _bal(attacker);
        o.pnlWithout = _pnl(a0, a1, b0, b1);

        o.extraction = o.pnlWith - o.pnlWithout;
        o.tax = _taxOnLegs(c.k, c.attackSize);
    }

    /// @dev The benchmark: the same attacker sandwiching the same net flow when
    /// it is executed as an ordinary Fast-Lane swap rather than a batch.
    function _runCpammBenchmark(
        uint256 k,
        uint256 residual,
        uint256 attackSize
    ) internal returns (int256 extraction) {
        _freshPool(k);
        (uint256 a0, uint256 a1) = _bal(attacker);

        _setPriorityFee(PRIORITY);
        vm.prank(attacker);
        _fastSwapAs(true, -int256(attackSize));

        // The victim flow, executed immediately and synchronously.
        _setPriorityFee(0);
        vm.prank(alice);
        _fastSwapAs(true, -int256(residual));

        _setPriorityFee(PRIORITY);
        vm.prank(attacker);
        _fastSwapAs(false, -int256(attackSize));

        (uint256 b0, uint256 b1) = _bal(attacker);
        int256 pnlWith = _pnl(a0, a1, b0, b1);

        _freshPool(k);
        (a0, a1) = _bal(attacker);
        _sandwichLegs(attackSize);
        (b0, b1) = _bal(attacker);

        extraction = pnlWith - _pnl(a0, a1, b0, b1);
    }

    // ==================================================================
    // The sweep
    // ==================================================================

    /// @notice The DD-5 table, one `k` per test.
    ///
    /// @dev Split by `k` rather than run as one loop because a single test that
    /// deploys ~250 fresh pools exhausts the EVM memory limit. Each of these
    /// deploys ~50 and is independent of the others.
    function test_DD5_sweep_k0_noTax() public {
        _sweepAtK(0);
    }

    function test_DD5_sweep_k500_default() public {
        _sweepAtK(500);
    }

    function test_DD5_sweep_k5000() public {
        _sweepAtK(5_000);
    }

    function test_DD5_sweep_k100000_governanceMax() public {
        _sweepAtK(100_000);
    }

    function _sweepAtK(
        uint256 k
    ) internal {
        console2.log("");
        console2.log(string.concat("=== DD-5 sweep, k=", _u(k), ", priority=1 gwei, trader slack=50% ==="));
        console2.log("units: 1e12 wei of currency1, marked at the pre-attack spot");

        // Flat index over 3 batch sizes x 4 residual fractions. Written this way
        // rather than as nested loops over array literals because the `optimized`
        // (via-IR) profile cannot fit the latter in the EVM stack.
        for (uint256 i; i < 12; ++i) {
            _sweepOneCell(k, _batchAt(i / 4), _residualBpsAt(i % 4));
        }
    }

    function _batchAt(
        uint256 i
    ) internal pure returns (uint256) {
        if (i == 0) return 1 ether;
        if (i == 1) return 5 ether;
        return 20 ether;
    }

    /// @dev Residual surviving netting, as bps of the batch. 0 = perfect CoW.
    function _residualBpsAt(
        uint256 i
    ) internal pure returns (uint256) {
        if (i == 0) return 0;
        if (i == 1) return 2_000;
        if (i == 2) return 6_000;
        return 10_000;
    }

    /// @dev Split out of `_sweepAtK` to keep the sweep within the EVM stack
    /// limit under the `optimized` (via-IR) profile.
    function _sweepOneCell(
        uint256 k,
        uint256 batch,
        uint256 residualBps
    ) internal {
        uint256 residual = (batch * residualBps) / 10_000;
        uint256[2] memory sizes = [residual + 1e15, 2 * residual + 1e15];

        Outcome memory best;
        uint256 bestA;
        for (uint256 ia; ia < sizes.length; ++ia) {
            Outcome memory o =
                _runCell(Cell({batch: batch, residualBps: residualBps, k: k, attackSize: sizes[ia], slackBps: 5_000}));
            if (ia == 0 || o.pnlWith > best.pnlWith) {
                best = o;
                bestA = sizes[ia];
            }
        }

        _row(batch, residualBps, k, bestA, best);
    }

    function _row(
        uint256 batch,
        uint256 resBps,
        uint256 k,
        uint256 attackSize,
        Outcome memory o
    ) internal pure {
        {
            string memory _line = "batch=";
            _line = string.concat(_line, _u(batch / 1e15));
            _line = string.concat(_line, "e15 resBps=");
            _line = string.concat(_line, _u(resBps));
            _line = string.concat(_line, " k=");
            _line = string.concat(_line, _u(k));
            _line = string.concat(_line, " A=");
            _line = string.concat(_line, _u(attackSize / 1e12));
            _line = string.concat(_line, " ext=");
            _line = string.concat(_line, _i(o.extraction / 1e12));
            _line = string.concat(_line, " tax=");
            _line = string.concat(_line, _u(o.tax / 1e12));
            _line = string.concat(_line, " netPnl=");
            _line = string.concat(_line, _i(o.pnlWith / 1e12));
            _line = string.concat(_line, " => ");
            // Verdict is NET P&L, not `extraction > tax`. The original framing
            // isolated the priority-fee tax because the question then was
            // whether the tax could be made to bind — it cannot, and §3 says
            // why. DD-5's closure is the residual cap, whose binding cost on
            // the attacker is `f_base` on two legs, so a row where extraction
            // exceeds the tax while the attacker still loses money is a row the
            // defence WON. Reporting that as "PROFITABLE" would misstate the
            // result in the direction of false alarm.
            _line = string.concat(_line, o.pnlWith > 0 ? "PROFITABLE" : "not profitable");
            console2.log(_line);
        }
    }

    function _u(
        uint256 v
    ) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _i(
        int256 v
    ) internal pure returns (string memory) {
        return vm.toString(v);
    }

    // ==================================================================
    // Benchmark and supporting facts
    // ==================================================================

    /// @notice Where Kessel sits against the malicious-batch-operator bound.
    function test_DD5_versusTheHalfCpammBound() public {
        uint256[3] memory batches = [uint256(1 ether), 5 ether, 20 ether];

        console2.log("");
        console2.log("=== DD-5 vs the half-CPAMM bound (fully one-sided batch, k=500) ===");
        console2.log("units: 1e12 wei of currency1");

        for (uint256 i; i < batches.length; ++i) {
            uint256 batch = batches[i];
            uint256 attackSize = batch + 1e15;

            Outcome memory o =
                _runCell(Cell({batch: batch, residualBps: 10_000, k: 500, attackSize: attackSize, slackBps: 5_000}));
            int256 cpamm = _runCpammBenchmark(500, batch, attackSize);

            {
                string memory _line = "batch=";
                _line = string.concat(_line, _u(batch / 1e15));
                _line = string.concat(_line, "e15  kessel=");
                _line = string.concat(_line, _i(o.extraction / 1e12));
                _line = string.concat(_line, "  cpamm=");
                _line = string.concat(_line, _i(cpamm / 1e12));
                _line = string.concat(_line, "  half=");
                _line = string.concat(_line, _i(cpamm / 2e12));
                console2.log(_line);
            }
        }
    }

    /// @notice Netting is the primary defence, so its effect is isolated: hold
    /// batch size and `k` fixed and vary only how much survives netting.
    function test_DD5_nettingIsTheDefence() public {
        uint256[5] memory residuals = [uint256(0), 1_000, 2_500, 5_000, 10_000];

        console2.log("");
        console2.log("=== DD-5 netting effect (batch=20e18, k=500) ===");
        for (uint256 i; i < residuals.length; ++i) {
            uint256 residual = (20 ether * residuals[i]) / 10_000;
            Outcome memory o = _runCell(
                Cell({batch: 20 ether, residualBps: residuals[i], k: 500, attackSize: residual + 1e15, slackBps: 5_000})
            );
            {
                string memory _line = "resBps=";
                _line = string.concat(_line, _u(residuals[i]));
                _line = string.concat(_line, "  extraction=");
                _line = string.concat(_line, _i(o.extraction / 1e12));
                _line = string.concat(_line, "  tax=");
                _line = string.concat(_line, _u(o.tax / 1e12));
                console2.log(_line);
            }
        }
    }

    /// @notice `Clearing.solve` takes only the two aggregates `net0`/`net1`, so
    /// the number of orders behind them cannot move the clearing price. Pinned
    /// here because the sweep above uses two orders per cell to stand in for a
    /// batch of any size, and that shorthand has to be earned.
    function test_DD5_orderCountDoesNotChangeTheClearingPrice() public {
        _freshPool(500);
        _slowOrder(alice, true, 8 ether, uint128(4 ether), 64);
        vm.roll(vm.getBlockNumber() + 5);
        _setPriorityFee(0);
        _fastSwap(true, -1e15);
        (, uint160 pTwo,,,,,) = hook.epochs(1);

        _freshPool(500);
        for (uint256 i; i < 16; ++i) {
            _slowOrder(alice, true, 0.5 ether, uint128(0.25 ether), 64);
        }
        vm.roll(vm.getBlockNumber() + 5);
        _setPriorityFee(0);
        _fastSwap(true, -1e15);
        (, uint160 pMany,,,,,) = hook.epochs(1);

        uint256 diff = pTwo > pMany ? pTwo - pMany : pMany - pTwo;
        assertLt(diff * 1e6 / pTwo, 100, "clearing price must not depend on order count");
    }

    /// @notice The axis that actually bounds the attack: trader limit slack.
    ///
    /// @dev The sweep above uses a deliberately permissive 50% limit, which
    /// isolates the mechanism but describes no real trader. In practice an
    /// order is eligible only while the *skewed* clearing price still meets its
    /// limit, so the attacker's skew must fit inside whatever slack survives
    /// the batch's own price impact — and if it does not, the batch drops out
    /// entirely and there is no victim flow left to sandwich. This table is
    /// what the DD-5 recommendation should be read against.
    function test_DD5_limitSlackBoundsTheAttack() public {
        uint256[6] memory slacks = [uint256(10), 25, 50, 100, 500, 5_000];
        // Sized so the batch's own impact is small relative to the pool
        // (~95 ether per side), leaving the slack, not the depth, as the bind.
        uint256 batch = 0.5 ether;

        console2.log("");
        console2.log("=== DD-5 attacker gain vs trader limit slack (batch=0.5e18 one-sided, k=500) ===");
        console2.log("units: 1e12 wei of currency1");

        for (uint256 i; i < slacks.length; ++i) {
            uint256[4] memory sizes = [uint256(0.05 ether), 0.25 ether, 0.5 ether, 2 ether];
            Outcome memory best;
            uint256 bestA;
            for (uint256 j; j < sizes.length; ++j) {
                Outcome memory o = _runCell(
                    Cell({batch: batch, residualBps: 10_000, k: 500, attackSize: sizes[j], slackBps: slacks[i]})
                );
                // The attacker maximises net P&L, not gross extraction: a skew
                // that knocks the batch out of eligibility earns nothing and
                // still costs two legs of fees.
                if (j == 0 || o.pnlWith > best.pnlWith) {
                    best = o;
                    bestA = sizes[j];
                }
            }
            {
                string memory _line = "slack=";
                _line = string.concat(_line, _u(slacks[i]));
                _line = string.concat(_line, "bps  bestA=");
                _line = string.concat(_line, _u(bestA / 1e12));
                _line = string.concat(_line, "  ext=");
                _line = string.concat(_line, _i(best.extraction / 1e12));
                _line = string.concat(_line, "  tax=");
                _line = string.concat(_line, _u(best.tax / 1e12));
                _line = string.concat(_line, "  netPnl=");
                _line = string.concat(_line, _i(best.pnlWith / 1e12));
                _line = string.concat(_line, "  batchFilled=");
                _line = string.concat(_line, _u(best.filled / 1e12));
                console2.log(_line);
            }
        }
    }

    /// @notice The same bound, resolved finely and reported in the unit that
    /// matters: extraction as bps of the batch's own notional.
    ///
    /// @dev The batch is sized so its *own* price impact is small (~20 bps on a
    /// ~95-ether-per-side pool), which is what separates "the attacker knocked
    /// the batch out" from "the batch was never eligible in the first place" —
    /// the two look identical in the coarse table above at slack <= 50 bps.
    function test_DD5_extractionAsShareOfBatchVersusSlack() public {
        uint256[7] memory slacks = [uint256(30), 50, 75, 100, 150, 300, 1_000];
        uint256 batch = 0.2 ether;

        console2.log("");
        console2.log("=== DD-5 extraction as bps of batch notional vs trader slack ===");
        console2.log("batch=0.2e18 one-sided, k=500, priority=1 gwei");

        for (uint256 i; i < slacks.length; ++i) {
            uint256[6] memory sizes = [uint256(0.01 ether), 0.05 ether, 0.1 ether, 0.25 ether, 0.5 ether, 1 ether];
            Outcome memory best;
            uint256 bestA;
            for (uint256 j; j < sizes.length; ++j) {
                Outcome memory o = _runCell(
                    Cell({batch: batch, residualBps: 10_000, k: 500, attackSize: sizes[j], slackBps: slacks[i]})
                );
                if (j == 0 || o.pnlWith > best.pnlWith) {
                    best = o;
                    bestA = sizes[j];
                }
            }

            int256 extBps = (best.extraction * 10_000) / int256(batch);
            {
                string memory _line = "slack=";
                _line = string.concat(_line, _u(slacks[i]));
                _line = string.concat(_line, "bps  bestA=");
                _line = string.concat(_line, _u(bestA / 1e15));
                _line = string.concat(_line, "e15  ext=");
                _line = string.concat(_line, _i(best.extraction / 1e12));
                _line = string.concat(_line, " (");
                _line = string.concat(_line, _i(extBps));
                _line = string.concat(_line, " bps of batch)  tax=");
                _line = string.concat(_line, _u(best.tax / 1e12));
                _line = string.concat(_line, "  netPnl=");
                _line = string.concat(_line, _i(best.pnlWith / 1e12));
                _line = string.concat(_line, "  filled=");
                _line = string.concat(_line, _u(best.filled / 1e15));
                _line = string.concat(_line, "e15");
                console2.log(_line);
            }
        }
    }

    /// @notice Where the attack turns a profit: sweep residual size against a
    /// fixed pool depth (~95 ether per side) and find the crossover.
    ///
    /// @dev This is the single most decision-relevant table in the file. The
    /// binding cost turns out to be `f_base` on the attacker's two legs, not
    /// the `k` tax — at the default `k` the tax is roughly a sixth of the
    /// `f_base` bill — so the crossover is essentially where the sandwich gain
    /// on the residual overtakes `2 * f_base * A`.
    function test_DD5_profitabilityCrossoverInResidualSize() public {
        uint256[7] memory batches = [uint256(0.1 ether), 0.2 ether, 0.5 ether, 1 ether, 2 ether, 5 ether, 20 ether];

        console2.log("");
        console2.log("=== DD-5 profitability crossover (one-sided batch, k=500, slack=50%) ===");
        console2.log("pool depth ~95 ether per side; units 1e12 wei");

        for (uint256 i; i < batches.length; ++i) {
            uint256 batch = batches[i];
            uint256[4] memory sizes = [batch / 4, batch / 2, batch, 2 * batch];
            Outcome memory best;
            uint256 bestA;
            for (uint256 j; j < sizes.length; ++j) {
                Outcome memory o =
                    _runCell(Cell({batch: batch, residualBps: 10_000, k: 500, attackSize: sizes[j], slackBps: 5_000}));
                if (j == 0 || o.pnlWith > best.pnlWith) {
                    best = o;
                    bestA = sizes[j];
                }
            }
            {
                string memory _line = "residual=";
                _line = string.concat(_line, _u(batch / 1e15));
                _line = string.concat(_line, "e15 (");
                _line = string.concat(_line, _u((batch * 10_000) / 95 ether));
                _line = string.concat(_line, " bps of depth)  bestA=");
                _line = string.concat(_line, _u(bestA / 1e15));
                _line = string.concat(_line, "e15  ext=");
                _line = string.concat(_line, _i(best.extraction / 1e12));
                _line = string.concat(_line, "  tax=");
                _line = string.concat(_line, _u(best.tax / 1e12));
                _line = string.concat(_line, "  netPnl=");
                _line = string.concat(_line, _i(best.pnlWith / 1e12));
                _line = string.concat(_line, best.pnlWith > 0 ? "  <== PROFITABLE" : "");
                console2.log(_line);
            }
        }
    }
}
