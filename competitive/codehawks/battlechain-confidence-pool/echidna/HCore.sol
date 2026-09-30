// SPDX-License-Identifier:MIT

pragma solidity 0.8.26;

import {EchidnaSetup} from "./EchidnaSetup.sol";
import {PoolStates} from "../../src/libraries/PoolStates.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev echidna test/echidna/HCore.sol --contract HCore --config test/echidna/HCore.yaml

contract HCore is EchidnaSetup {
    /// @dev Pre-call snapshot for `h_stake`'s post-conditions.
    struct PreStakeSnapshot {
        uint256 poolBalance;
        uint256 userEligibleStake;
        uint256 userSumStakeTime;
        uint256 userSumStakeTimeSq;
        uint256 totalEligibleStake;
        uint256 globalSumStakeTime;
        uint256 globalSumStakeTimeSq;
        uint32 riskWindowStart;
    }

    /// @dev Pre-call snapshot for exact-claim post-conditions.
    struct PreClaimSnapshot {
        uint256 actorBalance;
        uint256 poolBalance;
        uint256 userEligibleStake;
        uint256 claimedBonus;
        uint256 totalEligibleStake;
        uint256 expectedBonusShare;
    }

    // SOL-1 · Phase-indexed solvency (the king invariants): stakeToken.balanceOf(pool) >= L(phase).
    //   UNRESOLVED          -> L = totalEligibleStake + totalBonus
    //   SURVIVED / EXPIRED  -> L = totalEligibleStake
    //                          + (riskWindowStart != 0 && totalEligibleStake != 0
    //                               ? snapshotTotalBonus - claimedBonus : 0)
    //   CORRUPTED good-faith, t <= deadline -> L = bountyEntitlement - bountyClaimed
    //   CORRUPTED otherwise  -> L = 0 (conservation, SOL-2, takes over)

    // Cumulative minted tokens (stake + bonus + donations) stays <= 1e27.
    //   SOL-1 does not need this, but ACC-2  squares userSumStakeTime:
    // (1e27 * 2^32)^2 ~ 2^243 < 2^256. Enforcing the cap from the first run
    // keeps today's corpus valid for every later property.
    uint256 internal constant INFLOW_CAP = 1e27;
    uint256 internal constant PER_CALL_CAP = 1e24;
    uint256 internal mintedTotal;
    /// @dev First nonzero corruptedClaimDeadline ever observed. COR-2's anchor: the pool
    ///      pins the deadline to the FIRST good-faith flag, so it must never move again.
    uint32 internal ghostFirstCorruptedDeadline;

    /*//////////////////////////////////////////////////////////////
                               LAT GHOSTS
    //////////////////////////////////////////////////////////////*/
    //  first-observation pins for one-way state. Each pins the first value it
    // sees; every later observation must equal it. Fresh per sequence (Echidna redeploys).
    uint32 internal ghostRiskWindowStart;
    uint32 internal ghostRiskWindowEnd;
    bool internal ghostScopeLocked;
    bool internal ghostExpiryLocked;
    uint32 internal ghostExpiryAtLock;
    bool internal ghostResolved;
    bool internal ghostClaimsStarted;
    PoolStates.Outcome internal ghostFinalOutcome;
    bool internal ghostFinalGoodFaith;
    address internal ghostFinalAttacker;
    uint32 internal ghostFinalFlaggedAt;
    uint256 internal ghostFinalSnapStaked;
    uint256 internal ghostFinalSnapBonus;
    uint256 internal ghostFinalSnapSumT;
    uint256 internal ghostFinalSnapSumTSq;
    bool[3] internal ghostHasClaimed; // indexed like `actors`

    /*//////////////////////////////////////////////////////////////
                               ACL FIXTURES
    //////////////////////////////////////////////////////////////*/
    // recovery-rotation candidates: inert addresses (never stake, never named attacker) that
    // are ALL watched by SOL-2, so a moving recoveryAddress can never open the closed ledger.
    address internal constant RECOVERY_ALT1 = address(0xBEE2);
    address internal constant RECOVERY_ALT2 = address(0xBEE3);

    // pre-terminal walk ceiling; terminal transitions go through `h_registryFinalize`.
    uint8 internal constant MAX_REGISTRY_ORDINAL = uint8(IAttackRegistry.ContractState.PROMOTION_REQUESTED);

    /// @notice Handlers — the only doors into the system. Reverts inside the pool are
    // legitimate outcomes (paused, deposits gated, withdraw latched); Echidna
    // treats them as dead-end txs, not failures. Only assert() fails a run.

    //INVARIANT: a successful stake(a) by u increases eligibleStake[u], totalEligibleStake, and the pool balance by exactly the received amount (== a for our token), and increases the four sum aggregates by exactly received·e / received·e² with e = max(now, riskWindowStart);
    function h_stake(uint256 actorSeed, uint256 rawAmount) external {
        // Preconditions
        address actor = _actor(actorSeed);
        uint256 amount = _between(rawAmount, birth.minStake, PER_CALL_CAP);
        if (mintedTotal + amount > INFLOW_CAP) return;
        mintedTotal += amount;
        stakeToken.mint(actor, amount);

        PreStakeSnapshot memory pre = PreStakeSnapshot({
            poolBalance: stakeToken.balanceOf(address(pool)),
            userEligibleStake: pool.eligibleStake(actor),
            userSumStakeTime: pool.userSumStakeTime(actor),
            userSumStakeTimeSq: pool.userSumStakeTimeSq(actor),
            totalEligibleStake: pool.totalEligibleStake(),
            globalSumStakeTime: pool.sumStakeTime(),
            globalSumStakeTimeSq: pool.sumStakeTimeSq(),
            riskWindowStart: pool.riskWindowStart()
        });

        // Action
        VM.prank(actor);
        pool.stake(amount);

        // Read AFTER the call: this call may itself have sealed the window.
        uint256 riskWindowStartAfter = pool.riskWindowStart();
        uint256 effectiveEntry = block.timestamp < riskWindowStartAfter ? riskWindowStartAfter : block.timestamp; // defensive; start <= now in-phase

        // Expected per-user base: the lazy clamp may have fired on pre-existing sums.
        uint256 clampedUserSumStakeTime = pre.userSumStakeTime;
        uint256 clampedUserSumStakeTimeSq = pre.userSumStakeTimeSq;
        if (riskWindowStartAfter != 0 && clampedUserSumStakeTime < pre.userEligibleStake * riskWindowStartAfter) {
            clampedUserSumStakeTime = pre.userEligibleStake * riskWindowStartAfter;
            clampedUserSumStakeTimeSq = pre.userEligibleStake * riskWindowStartAfter * riskWindowStartAfter;
        }

        // Post-conditions — money and principal move by exactly `amount` (standard mock token).
        assert(stakeToken.balanceOf(address(pool)) == pre.poolBalance + amount);
        assert(pool.eligibleStake(actor) == pre.userEligibleStake + amount);
        assert(pool.totalEligibleStake() == pre.totalEligibleStake + amount);

        // per-user k=2 sums: clamped base + the new tranche at effectiveEntry.
        assert(pool.userSumStakeTime(actor) == clampedUserSumStakeTime + amount * effectiveEntry);
        assert(pool.userSumStakeTimeSq(actor) == clampedUserSumStakeTimeSq + amount * effectiveEntry * effectiveEntry);

        // Postconditions — globals: eager reset iff the window opened INSIDE this
        // call (0 -> start), rebuilt from the PRE-call stake total, then the tranche lands.
        if (pre.riskWindowStart == 0 && riskWindowStartAfter != 0) {
            assert(pool.sumStakeTime() == pre.totalEligibleStake * riskWindowStartAfter + amount * effectiveEntry);
            assert(
                pool.sumStakeTimeSq()
                    == pre.totalEligibleStake * riskWindowStartAfter * riskWindowStartAfter + amount * effectiveEntry
                        * effectiveEntry
            );
        } else {
            assert(pool.sumStakeTime() == pre.globalSumStakeTime + amount * effectiveEntry);
            assert(pool.sumStakeTimeSq() == pre.globalSumStakeTimeSq + amount * effectiveEntry * effectiveEntry);
        }
    }

    // Full exit for a rotating actor. Legitimately reverts once `riskWindowStart != 0`
    function h_withdraw(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        VM.prank(actor);
        pool.withdraw();
    }

    // Permissionless bonus top-up (no claim rights attached)
    function h_contributeBonus(uint256 actorSeed, uint256 rawAmount) external {
        address actor = _actor(actorSeed);
        uint256 amount = _between(rawAmount, 1, PER_CALL_CAP);
        if (mintedTotal + amount > INFLOW_CAP) return;
        mintedTotal += amount;
        stakeToken.mint(actor, amount);
        VM.prank(actor);
        pool.contributeBonus(amount);
    }

    /// @notice Direct transfer into the pool with NO contract call — the
    ///         adversarial surface sweeps must handle. Only raises the balance,
    ///         so it can pad SOL-1's left side but never mask a deficit.
    function h_donate(uint256 rawAmount) external {
        uint256 amount = _between(rawAmount, 1, PER_CALL_CAP);
        if (mintedTotal + amount > INFLOW_CAP) return;
        mintedTotal += amount;
        stakeToken.mint(address(pool), amount);
    }

    /// @notice Eager observation. Reverts RiskWindowNotReached while the
    ///         registry is pre-risk — expected noise, not a failure.
    function h_poke() external {
        pool.pokeRiskWindow();
    }

    /// @notice Lawful registry driver: monotone walk NEW_DEPLOYMENT(1) ->
    ///         ATTACK_REQUESTED(2) -> UNDER_ATTACK(3) -> PROMOTION_REQUESTED(4),
    ///         possibly several ordinals per call so the pool can MISS observing
    ///         intermediate states (that unobserved fast path is first-class
    ///         behavior). Phase gate: never reaches a terminal state, so
    ///         outcome stays UNRESOLVED throughout phase 1.
    function h_advanceRegistry(uint256 rawSteps) external {
        uint8 cur = uint8(attackRegistry.getAgreementState(address(agreement)));
        if (cur >= MAX_REGISTRY_ORDINAL) return;
        uint256 stepsAhead = _between(rawSteps, 1, MAX_REGISTRY_ORDINAL - cur);
        attackRegistry.setAgreementState(IAttackRegistry.ContractState(cur + stepsAhead));
    }

    /// @notice Time driver, phase 2: cap moves past `expiry` so claimExpired, the
    ///         MODERATOR_CORRUPTED_GRACE backstop (expiry + 180d), and post-deadline
    ///         sweeps (good-faith flag + 180d) are reachable. expiry + 400 days covers
    ///         grace + claim-window with slack; expiry freezes at the first stake, so
    ///         time — and every T² magnitude — stays bounded.
    function h_warp(uint256 rawDelta) external {
        uint256 cap = uint256(pool.expiry()) + 400 days;
        if (block.timestamp >= cap) return;
        uint256 delta = _between(rawDelta, 1 hours, 90 days);
        uint256 target = block.timestamp + delta;
        if (target > cap) target = cap;
        VM.warp(target);
        VM.roll(block.number + 1 + delta / 12);
    }

    // Owner levers (harness == pool owner). Reverts on wrong pause state or a
    // locked expiry are the contract enforcing LAT-3/ACL — expected.
    function h_pause() external {
        pool.pause();
    }

    function h_unpause() external {
        pool.unpause();
    }

    /// @notice Sponsor moves the deadline — legal only until the first stake.
    function h_setExpiry(uint256 raw) external {
        uint256 newExpiry = _between(raw, block.timestamp + 30 days, block.timestamp + 400 days);
        pool.setExpiry(newExpiry);
    }

    /*//////////////////////////////////////////////////////////////
                PHASE 2: TERMINALITY, RESOLUTION, CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lawful terminal transition: CORRUPTED from either active-risk state (breach
    ///         lands mid-attack or during promotion review), PRODUCTION only from
    ///         PROMOTION_REQUESTED (promotion granted). One-way; no-op elsewhere. Reaching
    ///         CORRUPTED while the pool never observed active risk (riskWindowStart == 0)
    ///         is a first-class target state — it drives claimExpired's EXPIRED fallback
    ///         and the "no observable risk" bonus rules.

    function h_registryFinalize(uint256 rawChoice) external {
        IAttackRegistry.ContractState currentState = attackRegistry.getAgreementState(address(agreement));
        if (rawChoice % 2 == 0) {
            if (
                currentState != IAttackRegistry.ContractState.UNDER_ATTACK
                    && currentState != IAttackRegistry.ContractState.PROMOTION_REQUESTED
            ) return;
            attackRegistry.setAgreementState(IAttackRegistry.ContractState.CORRUPTED);
        } else {
            if (currentState != IAttackRegistry.ContractState.PROMOTION_REQUESTED) return;
            attackRegistry.setAgreementState(IAttackRegistry.ContractState.PRODUCTION);
        }
    }

    /// @notice Moderator lever (mock is permissionless). All lawful flag shapes, including
    ///         re-flags; unlawful shapes revert in the pool (dead-end). Mode 3 names a
    ///         STAKING actor as good-faith attacker — the overlap case the bounty/claim
    ///         paths must not double-pay. On success, asserts the resolution capture:
    ///         snapshots == pre-call live accumulators (no eager-reset caveat — flags
    ///         require a terminal registry state, which never opens the window), T pinned
    ///         to riskWindowEnd, and the CORRUPTED pot bookkeeping shaped exactly.
    function h_flagOutcome(uint256 raw) external {
        uint256 preTotalEligible = pool.totalEligibleStake();
        uint256 preTotalBonus = pool.totalBonus();
        uint256 preSumT = pool.sumStakeTime();
        uint256 preSumTSq = pool.sumStakeTimeSq();

        uint256 mode = raw % 4;
        if (mode == 0) defaultOutcomeModerator.flagSurvived(address(pool));
        else if (mode == 1) defaultOutcomeModerator.flagCorruptedBadFaith(address(pool));
        else if (mode == 2) defaultOutcomeModerator.flagCorruptedGoodFaith(address(pool), attackerActor);
        else defaultOutcomeModerator.flagCorruptedGoodFaith(address(pool), _actor(raw / 4));

        // Reached only on a successful flag.
        assert(pool.snapshotTotalStaked() == preTotalEligible);
        assert(pool.snapshotTotalBonus() == preTotalBonus);
        assert(pool.snapshotSumStakeTime() == preSumT);
        assert(pool.snapshotSumStakeTimeSq() == preSumTSq);
        assert(pool.outcomeFlaggedAt() == pool.riskWindowEnd());

        if (pool.outcome() == PoolStates.Outcome.CORRUPTED) {
            assert(pool.corruptedReserve() == preTotalEligible + preTotalBonus);
            if (pool.goodFaith()) {
                assert(pool.bountyEntitlement() == preTotalEligible + preTotalBonus);
                uint32 d = pool.corruptedClaimDeadline();
                assert(d != 0);
                if (ghostFirstCorruptedDeadline == 0) ghostFirstCorruptedDeadline = d;
            } else {
                assert(pool.bountyEntitlement() == 0);
                assert(pool.corruptedClaimDeadline() == 0);
            }
        } else {
            assert(pool.corruptedReserve() == 0);
            assert(pool.bountyEntitlement() == 0);
        }
    }

    /// INVARIANT: a successful claimSurvived(u) pays exactly eligibleStake[u] + bonusShare(u),
    /// with bonusShare re-derived independently in _expectedBonusShare.
    function h_claimSurvived(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        PreClaimSnapshot memory pre = _snapClaim(actor);
        VM.prank(actor);
        pool.claimSurvived();
        _assertExactPayout(actor, pre);
    }

    /// @notice Two personalities. Pre-call outcome EXPIRED: a frozen-snapshot claim — same
    ///         exact-payout instrument as claimSurvived. Pre-call UNRESOLVED: the RESOLVING
    ///         call — the snapshot is captured inside it, so instead of payout exactness we
    ///         assert the capture itself: snapshots equal the pre-call live accumulators
    ///         (modulo the eager reset if this very call opened the window), the outcome went
    ///         terminal, and mechanical resolution latched finality (claimsStarted).
    function h_claimExpired(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        PoolStates.Outcome preOutcome = pool.outcome();

        if (preOutcome == PoolStates.Outcome.EXPIRED) {
            PreClaimSnapshot memory pre = _snapClaim(actor);
            VM.prank(actor);
            pool.claimExpired();
            _assertExactPayout(actor, pre);
            return;
        }

        // Resolving call (preOutcome UNRESOLVED, or a dead-end revert for SURVIVED/CORRUPTED).
        uint256 preTotalEligible = pool.totalEligibleStake();
        uint256 preTotalBonus = pool.totalBonus();
        uint256 preSumT = pool.sumStakeTime();
        uint256 preSumTSq = pool.sumStakeTimeSq();
        uint256 preStart = pool.riskWindowStart();
        uint256 preActorBalance = stakeToken.balanceOf(actor);

        VM.prank(actor);
        pool.claimExpired();

        PoolStates.Outcome outcomeAfter = pool.outcome();
        assert(outcomeAfter != PoolStates.Outcome.UNRESOLVED);
        assert(pool.claimsStarted()); // all three mechanical branches latch finality

        // Snapshot capture: totals verbatim; k=2 sums verbatim UNLESS this call opened the
        // window (first observation at/past expiry), where the eager reset rebuilt them
        // from the pre-call stake total first.
        assert(pool.snapshotTotalStaked() == preTotalEligible);
        assert(pool.snapshotTotalBonus() == preTotalBonus);

        uint256 startAfter = pool.riskWindowStart();
        if (preStart == 0 && startAfter != 0) {
            assert(pool.snapshotSumStakeTime() == preTotalEligible * startAfter);
            assert(pool.snapshotSumStakeTimeSq() == preTotalEligible * startAfter * startAfter);
        } else {
            assert(pool.snapshotSumStakeTime() == preSumT);
            assert(pool.snapshotSumStakeTimeSq() == preSumTSq);
        }

        if (outcomeAfter == PoolStates.Outcome.CORRUPTED) {
            // Auto-CORRUPTED backstop: pays the caller nothing; whole pot earmarked for recovery.
            assert(stakeToken.balanceOf(actor) == preActorBalance);
            assert(pool.corruptedReserve() == preTotalEligible + preTotalBonus);
            assert(pool.bountyEntitlement() == 0);
        }
    }

    /// @notice Permissionless sweep to recoveryAddress. Must-succeed instrument: when the
    ///         sweep is lawful (CORRUPTED, bounty settled or bad-faith, nonzero balance) a
    ///         revert is a FAILURE — a panic in the sweep math cannot hide as a dead-end.
    ///         On success: full balance to recovery, reserve decremented with the clamp,
    ///         bad-faith closes the bounty, finality latched.
    function h_claimCorrupted(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        bool goodFaith = pool.goodFaith();
        bool mustSucceed = pool.outcome() == PoolStates.Outcome.CORRUPTED
            && !(goodFaith && pool.bountyClaimed() < pool.bountyEntitlement())
            && stakeToken.balanceOf(address(pool)) > 0;

        address rec = pool.recoveryAddress(); // sweep destination, captured live
        uint256 prePoolBal = stakeToken.balanceOf(address(pool));
        uint256 preRecoveryBal = stakeToken.balanceOf(rec);
        uint256 preReserve = pool.corruptedReserve();

        VM.prank(actor);
        try pool.claimCorrupted() {
            assert(mustSucceed);
            assert(stakeToken.balanceOf(address(pool)) == 0);
            assert(stakeToken.balanceOf(rec) == preRecoveryBal + prePoolBal);
            assert(pool.corruptedReserve() == (prePoolBal <= preReserve ? preReserve - prePoolBal : 0));
            assert(pool.claimsStarted());
            if (!goodFaith) assert(pool.bountyClaimed() == pool.bountyEntitlement());
        } catch {
            assert(!mustSucceed);
        }
    }

    /// @notice Pranks whatever address the pool currently names as attacker. Must-succeed:
    ///         a lawful bounty claim (good-faith CORRUPTED, entitlement outstanding, within
    ///         deadline) may never revert — this is the instrument aimed at the unclamped
    ///         `corruptedReserve -= payout`. On success pays exactly min(remaining, balance).
    function h_claimAttackerBounty() external {
        address att = pool.attacker();
        if (att == address(0)) return;

        uint256 ent = pool.bountyEntitlement();
        uint256 preClaimed = pool.bountyClaimed();
        uint256 prePoolBal = stakeToken.balanceOf(address(pool));
        uint256 preAttBal = stakeToken.balanceOf(att);
        uint256 remaining = ent > preClaimed ? ent - preClaimed : 0;
        uint256 expectedPayout = remaining <= prePoolBal ? remaining : prePoolBal;

        bool mustSucceed = pool.outcome() == PoolStates.Outcome.CORRUPTED && pool.goodFaith() && preClaimed < ent
            && block.timestamp <= pool.corruptedClaimDeadline();

        VM.prank(att);
        try pool.claimAttackerBounty() {
            assert(mustSucceed);
            assert(stakeToken.balanceOf(att) == preAttBal + expectedPayout);
            assert(stakeToken.balanceOf(address(pool)) == prePoolBal - expectedPayout);
            assert(pool.bountyClaimed() == preClaimed + expectedPayout);
        } catch {
            assert(!mustSucceed);
        }
    }

    /// @notice Post-deadline recovery of an unclaimed good-faith bounty. Must-succeed +
    ///         exact: full balance to recovery, reserve zeroed, bounty closed, finality latched.
    function h_sweepUnclaimedCorrupted() external {
        bool mustSucceed = pool.outcome() == PoolStates.Outcome.CORRUPTED && pool.goodFaith()
            && block.timestamp > pool.corruptedClaimDeadline() && stakeToken.balanceOf(address(pool)) > 0;

        address rec = pool.recoveryAddress(); // sweep destination, captured live
        uint256 prePoolBal = stakeToken.balanceOf(address(pool));
        uint256 preRecoveryBal = stakeToken.balanceOf(rec);

        try pool.sweepUnclaimedCorrupted() {
            assert(mustSucceed);
            assert(stakeToken.balanceOf(address(pool)) == 0);
            assert(stakeToken.balanceOf(rec) == preRecoveryBal + prePoolBal);
            assert(pool.corruptedReserve() == 0);
            assert(pool.bountyClaimed() == pool.bountyEntitlement());
            assert(pool.claimsStarted());
        } catch {
            assert(!mustSucceed);
        }
    }

    /// @notice Excess sweep on SURVIVED/EXPIRED. Mirrors the pool's reserved computation,
    ///         asserts the exact sweep amount, the totalBonus decrement rule (only when the
    ///         pot is unreserved — no window or no stakers left — and clamped), and that the
    ///         sweep does NOT latch claimsStarted (the documented anti-grief decision: a
    ///         1-wei donation must not let a stranger close the moderator's re-flag window).
    function h_sweepUnclaimedBonus() external {
        PoolStates.Outcome o = pool.outcome();
        address rec = pool.recoveryAddress(); // sweep destination, captured live
        uint256 prePoolBal = stakeToken.balanceOf(address(pool));
        uint256 preRecoveryBal = stakeToken.balanceOf(rec);
        uint256 preTotalBonus = pool.totalBonus();
        uint256 preTotalEligible = pool.totalEligibleStake();
        bool preClaimsStarted = pool.claimsStarted();
        uint256 start = pool.riskWindowStart();

        uint256 reserved;
        if (preTotalEligible != 0) {
            reserved = preTotalEligible;
            if (start != 0) {
                uint256 snapB = pool.snapshotTotalBonus();
                uint256 clB = pool.claimedBonus();
                assert(clB <= snapB);
                reserved += snapB - clB;
            }
        }
        uint256 expectedSweep = prePoolBal > reserved ? prePoolBal - reserved : 0;
        bool mustSucceed = (o == PoolStates.Outcome.SURVIVED || o == PoolStates.Outcome.EXPIRED) && expectedSweep > 0;

        try pool.sweepUnclaimedBonus() {
            assert(mustSucceed);
            assert(stakeToken.balanceOf(address(pool)) == prePoolBal - expectedSweep);
            assert(stakeToken.balanceOf(rec) == preRecoveryBal + expectedSweep);
            if (preTotalEligible == 0 || start == 0) {
                uint256 drop = expectedSweep <= preTotalBonus ? expectedSweep : preTotalBonus;
                assert(pool.totalBonus() == preTotalBonus - drop);
            } else {
                assert(pool.totalBonus() == preTotalBonus);
            }
            assert(pool.claimsStarted() == preClaimsStarted);
        } catch {
            assert(!mustSucceed);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        PHASE 2: ACL / OWNER LEVERS
    //////////////////////////////////////////////////////////////*/

    /// @notice recoveryAddress rotation (owner path, harness == owner). Unlocked and mutable
    ///         in EVERY phase by design — the point of this handler is to prove that a moving
    ///         sweep target never breaks SOL-1/SOL-2: every candidate is a watched wallet, so
    ///         wherever a later sweep lands it stays counted. Also asserts the two guards the
    ///         function does have: zero-address rejected, and the update actually takes.
    function h_setRecoveryAddress(uint256 seed) external {
        // zero is the only value the setter rejects — must always revert.
        try pool.setRecoveryAddress(address(0)) {
            assert(false);
        } catch {}

        address newRec = _recoveryCandidate(seed);
        pool.setRecoveryAddress(newRec);
        assert(pool.recoveryAddress() == newRec);
    }

    /// @notice setPoolScope (owner path). Behavioral check on the scopeLocked latch: a call
    ///         that STARTS locked can never succeed, and any success leaves scope still
    ///         unlocked (the observe inside didn't seal it this call). Exercises _replaceScope
    ///         with the one in-agreement account, so the only variable under test is the lock.
    function h_setPoolScope() external {
        bool lockedBefore = pool.scopeLocked();
        try pool.setPoolScope(_scope()) {
            assert(!lockedBefore); // started locked ⇒ must have reverted
            assert(!pool.scopeLocked()); // success ⇒ observe didn't lock it either
        } catch {
            // lawful: already locked, or the observe inside just sealed it. Nothing to assert.
        }
    }

    /// @notice Ownable2Step round-trip, self-contained so the harness ends every call as owner
    ///         (other owner-levers keep working). Asserts the two-step semantics at each edge:
    ///         transfer only ARMS (owner unchanged, pendingOwner set); accept by the pending
    ///         address moves ownership and clears the pending slot. EVM atomicity guarantees a
    ///         mid-sequence revert rolls ownership back to the harness.
    function h_ownershipRoundTrip(uint256 seed) external {
        address a = _actor(seed);
        address me = address(this);
        if (a == me) return; // defensive; actors are never the harness

        pool.transferOwnership(a);
        assert(pool.owner() == me); // arm only — owner unchanged until accept
        assert(pool.pendingOwner() == a);

        VM.prank(a);
        pool.acceptOwnership();
        assert(pool.owner() == a);
        assert(pool.pendingOwner() == address(0));

        VM.prank(a);
        pool.transferOwnership(me);
        pool.acceptOwnership(); // un-pranked ⇒ msg.sender == harness == me
        assert(pool.owner() == me);
        assert(pool.pendingOwner() == address(0));
    }

    /// @notice ACL negative: a rotating actor (never the owner) hitting any owner-gated lever
    ///         must ALWAYS revert. All arguments are read/built BEFORE the prank so the prank
    ///         lands on the gated call itself, not on an argument-evaluation read.
    function h_ownerGateNegative(uint256 seed) external {
        address actor = _actor(seed);
        uint256 which = seed % 5;
        uint256 curExpiry = uint256(pool.expiry());
        address[] memory scope_ = _scope();

        VM.prank(actor);
        if (which == 0) {
            try pool.setRecoveryAddress(recovery) {
                assert(false);
            } catch {}
        } else if (which == 1) {
            try pool.setExpiry(curExpiry) {
                assert(false);
            } catch {}
        } else if (which == 2) {
            try pool.setPoolScope(scope_) {
                assert(false);
            } catch {}
        } else if (which == 3) {
            try pool.pause() {
                assert(false);
            } catch {}
        } else {
            try pool.unpause() {
                assert(false);
            } catch {}
        }
    }

    /*//////////////////////////////////////////////////////////////
                               PROPERTIES

      The SOL / ACC / DST / COR tags in the names are this audit's own
      invariant IDs, kept only so Echidna's per-property output maps back
      to the plan. Each claim is fully stated in its NatSpec, so nothing
      here needs the plan to be understood:
        SOL = Solvency       — the pool can always pay what it owes
        ACC = Accounting     — per-operation ledger math is exact
        DST = Distribution   — bonus-payout math (phase 2)
        COR = Corrupted-path — bounty / sweep math (phase 2)
        COR = Corrupted-path — bounty / sweep math (phase 2)
        ACL = Access-control — owner-lever authorization, config-lock behavior, immutability
    //////////////////////////////////////////////////////////////*/

    /// @notice SOL-1 — the pool is always solvent: it holds at least what it currently owes.
    ///         Asserts  stakeToken.balanceOf(pool) >= _liability(), where _liability() is the
    ///         total the pool could be forced to pay out right now given its lifecycle phase
    ///         (staked principal, owed bonus, or an attacker bounty — defined at _liability()).
    ///         A failure means some staker, claimant, or attacker could not be paid in full —
    ///         the definition of an insolvent pool.
    ///
    ///         `>=`, not `==`, is deliberate: donations and dust can leave the pool holding
    ///         MORE than it owes (that surplus is swept later), and a surplus must never be
    ///         read as a shortfall. Checking that inflow is exactly accounted for is a
    ///         separate invariant (SOL-2), not this one.
    ///
    ///         Not `view`: in Echidna's assertion mode this runs as an ordinary tx inside call
    ///         sequences, so a violation shrinks to a minimal reproducing sequence ending here.
    function property_SOL1_poolStaysSolvent() external {
        uint256 poolBalance = stakeToken.balanceOf(address(pool));
        assert(poolBalance >= _liability());
    }

    /// @notice SOL-2 — token conservation: no stake token is ever created from nowhere or lost.
    ///         Asserts  _watchedTokenBalance() == mintedTotal, exactly.
    ///           • mintedTotal — this harness's running count of every token it has minted into
    ///             existence (through the stake, bonus, and donate handlers). Minting is the
    ///             ONLY way tokens enter the system, so this is the total supply that should exist.
    ///           • _watchedTokenBalance() — the sum of balances over the only wallets a token can
    ///            lawfully occupy in any phase: the pool, the three staking actors, the recovery wallet
    ///            and the named attacker.
    ///         Exact equality is the whole point. A surplus over mintedTotal means tokens appeared
    ///         without a mint; a deficit means tokens leaked to an address we deliberately do NOT
    ///         watch — the recovery wallet, an attacker, or an owner role. Pre-resolution no lawful
    ///         path sends tokens there, so any such movement is a bug, and this is what catches it.
    ///         (SOL-1 only bounds the pool alone, and only from below; SOL-2 audits the whole ledger.)
    function property_SOL2_tokensAreConserved() external {
        assert(_watchedTokenBalance() == mintedTotal);
    }

    /// @notice ACC-2 — the time-weighted (k=2) accounting sums stay within the range that real
    ///         deposits can produce, and therefore can never overflow when the payout math
    ///         squares them later.
    ///
    ///         The pool weights each deposit by its entry time to the SECOND power. Per staker it
    ///         keeps  userSumStakeTime[u] = Σ amountᵢ·tᵢ  and  userSumStakeTimeSq[u] = Σ amountᵢ·tᵢ²,
    ///         plus the same two totals globally (sumStakeTime / sumStakeTimeSq). Every entry time
    ///         tᵢ is ≤ the pool's own deadline `expiry`, and total staked principal is ≤ the tokens
    ///         actually minted (`mintedTotal`). Those two facts bound every sum:
    ///             Σ amount·t   ≤ (Σ amount)·expiry
    ///             Σ amount·t²  ≤ (Σ amount)·expiry²
    ///         Asserted globally and per actor, so a deposit recorded with a time outside the pool's
    ///         lifetime, or a weight with no matching principal, fails here and names the wallet.
    ///
    ///         Final assert is the overflow headroom: the largest value the phase-2 payout formula
    ///         forms is  expiry²·totalStaked + sumStakeTimeSq, and this proves it fits in uint256 —
    ///         the reason inflow is capped at INFLOW_CAP.
    function property_ACC2_k2SumsStayBounded() external {
        // Phase-2 gate: claims DELETE per-user sums and decrement `totalEligibleStake` without
        // touching the global k=2 sums (unlike withdraw, which subtracts both sides). Post-
        // resolution the live globals are dead storage — the snapshots took over at flag
        // time — so the relations below are UNRESOLVED-only by construction. DST rungs
        // own the post-resolution math.
        if (pool.outcome() != PoolStates.Outcome.UNRESOLVED) return;
        // `expiry` is a hard ceiling on every recorded entry time: staking closes at `expiry`, and
        // `riskWindowStart` is capped at expiry, so `max(now,riskWindowStart) <= expiry`. It also
        // freezes on the first stake, so it bounds every tᵢ already in the sums.
        uint256 maxEntryTime = pool.expiry();
        uint256 totalStaked = pool.totalEligibleStake();

        // 1. Nothing is weighted that wasn't actually staked from minted supply.
        assert(totalStaked <= mintedTotal);

        // 2.Global k=2 sums correspond to entry times within the pool's lifetime
        assert(pool.sumStakeTime() <= totalStaked * maxEntryTime);
        assert(pool.sumStakeTimeSq() <= totalStaked * maxEntryTime * maxEntryTime);

        // 3. Same per actor - pins any drift to one wallet for a readable counterexample
        for (uint256 i; i < actors.length; i++) {
            address u = actors[i];
            uint256 staked = pool.eligibleStake(u);
            assert(pool.userSumStakeTime(u) <= staked * maxEntryTime);
            assert(pool.userSumStakeTimeSq(u) <= staked * maxEntryTime * maxEntryTime);
        }

        // 4. Overflow headroom for the phase-2 payout math: expiry²·totalStaked + sumStakeTimeSq
        //      must fit in uint256. Checked by division/subtraction so the check itself cannot overflow
        uint256 maxEntryTimeSq = maxEntryTime * maxEntryTime;
        if (maxEntryTimeSq != 0) {
            assert(totalStaked <= type(uint256).max / maxEntryTimeSq);
        }
        assert(pool.sumStakeTimeSq() <= type(uint256).max - maxEntryTimeSq * totalStaked);
    }

    /// @notice ACC-3 — global/per-user ledger consistency: the two global k=2 aggregates are,
    ///         at every moment, exactly the sum of the per-user sums — once each user is read
    ///         the way the pool itself will read them (post-clamp).
    ///
    ///         Why not plain Σ: when the risk window opens, the pool eagerly rebuilds the
    ///         globals as totalEligibleStake·start (and ·start²) but leaves per-user sums stale
    ///         until each user's next operation lazily clamps them (_clampUserSums). So raw
    ///         per-user storage lags the globals BY DESIGN. The invariant that must hold is
    ///             sumStakeTime   == Σ_u clamp(userSumStakeTime[u])
    ///             sumStakeTimeSq == Σ_u clamp(userSumStakeTimeSq[u])
    ///         with clamp() mirroring the pool's own rule byte-for-byte: if a user's linear sum
    ///         is below eligibleStake·start, both sums read as eligibleStake·start / ·start².
    ///         Pre-window (start == 0) clamp is the identity and this is the plain sum.
    ///
    ///         Exact equality, both directions: surplus in the globals is phantom weight that
    ///         dilutes every honest staker's phase-2 bonus share; deficit inflates it. Either
    ///         way the distribution denominator (snapshotted from these globals at resolution)
    ///         stops describing deposits that actually exist. Trips if any path mutates user
    ///         sums without the identical delta on the globals, if some window-opening path
    ///         (stake / contributeBonus / poke) misses the eager reset, or if the clamp
    ///         predicate ever drifts from the sums it rewrites.
    function property_ACC3_globalMatchClampedUserSums() external {
        if (pool.outcome() != PoolStates.Outcome.UNRESOLVED) return;

        uint256 start = pool.riskWindowStart();
        uint256 sumLinear;
        uint256 sumSq;

        for (uint256 i; i < actors.length; i++) {
            address u = actors[i];
            uint256 staked = pool.eligibleStake(u);
            uint256 uLinear = pool.userSumStakeTime(u);
            uint256 uSq = pool.userSumStakeTimeSq(u);

            // Mirror _clampUserSums exactly — same strict `<`, same overwrite pair.
            if (start != 0 && staked != 0 && uLinear < staked * start) {
                uLinear = staked * start;
                uSq = staked * start * start;
            }
            sumLinear += uLinear;
            sumSq += uSq;
        }
        assert(pool.sumStakeTime() == sumLinear);
        assert(pool.sumStakeTimeSq() == sumSq);
    }

    /// @notice DST-1 — the pool never pays out more bonus than the pot it froze at
    ///         resolution: claimedBonus <= snapshotTotalBonus, always, in every phase.
    ///         Redundant with the forward-guard inside _liability BY DESIGN: this one is a
    ///         named, standalone shrink target that fails even in sequences where SOL-1
    ///         isn't scheduled.
    function property_DST1_paidBonusNeverExceedsPot() external {
        assert(pool.claimedBonus() <= pool.snapshotTotalBonus());
    }

    /// @notice DST-2 — full distribution conserves the pot to within integer dust. Once a
    ///         SURVIVED/EXPIRED pool with an observed risk window has paid out every staker
    ///         (totalEligibleStake == 0), the undistributed remainder is at most
    ///         actors.length − 1 wei. Why: each claim floors once (mulDiv), and the claim
    ///         numerators sum EXACTLY to the frozen denominator (ACC-3 at snapshot + frozen
    ///         clamps + frozen T), so each claimer loses < 1 wei to rounding — nothing else.
    ///         A larger remainder means shares were computed against the wrong denominator,
    ///         someone's weight was dropped, or distribution double-counted — the exact class
    ///         of bug the k=2 split-brain design could plausibly produce. Trusts no formula:
    ///         pure conservation.
    function property_DST2_fullDistributionLeavesOnlyDust() external {
        PoolStates.Outcome o = pool.outcome();
        if (o != PoolStates.Outcome.SURVIVED && o != PoolStates.Outcome.EXPIRED) return;
        if (pool.riskWindowStart() == 0) return; // no-bonus rule: pot is sweepable, not owed
        if (pool.snapshotTotalStaked() == 0) return; // no stakers existed at resolution
        if (pool.totalEligibleStake() != 0) return; // not everyone has claimed yet
        assert(pool.snapshotTotalBonus() - pool.claimedBonus() <= actors.length - 1);
    }

    /// @notice DST-3 — the "no observable risk → no bonus" rule holds through money movement:
    ///         while riskWindowStart == 0, not one wei of bonus is ever paid to a staker
    ///         (claimedBonus stays 0). The pot's only lawful exit in that world is
    ///         sweepUnclaimedBonus → recoveryAddress. Total: no outcome gate needed —
    ///         pre-resolution claimedBonus is trivially 0, post-resolution start is frozen.
    function property_DST3_noRiskWindowBonus() external {
        if (pool.riskWindowStart() != 0) return;
        assert(pool.claimedBonus() == 0);
    }

    /// @notice COR-1 — the attacker is never paid more than their entitlement:
    ///         bountyClaimed <= bountyEntitlement, always, in every phase. Standalone twin
    ///         of the _liability forward-guard, same rationale as DST-1: a named shrink
    ///         target independent of SOL-1's scheduling.
    function property_COR1_bountyNeverExceedsEntitlement() external {
        assert(pool.bountyClaimed() <= pool.bountyEntitlement());
    }

    /// @notice COR-2 — the attacker-claim deadline is never extendable. The pool anchors it
    ///         to the FIRST good-faith CORRUPTED flag; re-flagging out of and back into
    ///         good-faith must reuse that anchor, or the moderator could mint a fresh
    ///         180-day window at will. Ghost-based: the first nonzero deadline ever observed
    ///         is pinned, and every later nonzero deadline must equal it exactly (zero is
    ///         lawful — a re-flag to bad-faith/SURVIVED clears it).
    function property_COR2_deadlineNeverExtends() external {
        uint32 d = pool.corruptedClaimDeadline();
        if (d == 0) return;
        if (ghostFirstCorruptedDeadline == 0) ghostFirstCorruptedDeadline = d;
        assert(d == ghostFirstCorruptedDeadline);
    }

    /// @notice LAT-1 — the risk-window markers are write-once and ordered. Once
    ///         riskWindowStart (or riskWindowEnd) is nonzero it never changes and never
    ///         returns to zero — withdraw's permanent disable, the clamp floor, and the
    ///         bonus bound T all assume exactly this. When both are set, start <= end:
    ///         the accrual interval is never inverted (both observations are wall-clock
    ///         ordered and share the expiry cap).
    function property_LAT1_riskMarkersOneWayAndOrdered() external {
        uint32 s = pool.riskWindowStart();
        uint32 e = pool.riskWindowEnd();

        if (ghostRiskWindowStart == 0) ghostRiskWindowStart = s;
        else assert(s == ghostRiskWindowStart);

        if (ghostRiskWindowEnd == 0) ghostRiskWindowEnd = e;
        else assert(e == ghostRiskWindowEnd);

        if (s != 0 && e != 0) assert(s <= e);
    }

    /// @notice LAT-2 — the config locks are one-way, and a locked expiry is frozen.
    ///         scopeLocked never clears once the registry leaves pre-attack staging;
    ///         expiryLocked never clears once the first stake lands, and from that moment
    ///         `expiry` itself must never move again — it is the ceiling ACC-2 trusts, the
    ///         cap on both risk markers, and the EXPIRED path's T. A post-lock expiry
    ///         change would silently re-scale every time weight in the pool.
    function property_LAT2_locksOneWayExpiryFrozen() external {
        bool sl = pool.scopeLocked();
        if (ghostScopeLocked) assert(sl);
        else ghostScopeLocked = sl;

        bool el = pool.expiryLocked();
        if (ghostExpiryLocked) {
            assert(el);
            assert(pool.expiry() == ghostExpiryAtLock);
        } else if (el) {
            ghostExpiryLocked = true;
            ghostExpiryAtLock = pool.expiry();
        }
    }

    /// @notice LAT-3 — resolution finality, two rungs. (1) Outcome never returns to
    ///         UNRESOLVED once resolved (re-flags may move between terminal outcomes, never
    ///         back). (2) Once claimsStarted latches — someone acted on the outcome — the
    ///         ENTIRE resolution record freezes: outcome, goodFaith, attacker,
    ///         outcomeFlaggedAt, and all four snapshots. This is the "value-movement
    ///         finality" the re-flag window's safety argument rests on: nothing a claimant
    ///         relied on can be rewritten after the first claim.
    function property_LAT3_outcomeFinalOnceClaimsStart() external {
        if (pool.outcome() != PoolStates.Outcome.UNRESOLVED) ghostResolved = true;
        if (ghostResolved) assert(pool.outcome() != PoolStates.Outcome.UNRESOLVED);

        if (!ghostClaimsStarted) {
            if (pool.claimsStarted()) {
                ghostClaimsStarted = true;
                ghostFinalOutcome = pool.outcome();
                ghostFinalGoodFaith = pool.goodFaith();
                ghostFinalAttacker = pool.attacker();
                ghostFinalFlaggedAt = pool.outcomeFlaggedAt();
                ghostFinalSnapStaked = pool.snapshotTotalStaked();
                ghostFinalSnapBonus = pool.snapshotTotalBonus();
                ghostFinalSnapSumT = pool.snapshotSumStakeTime();
                ghostFinalSnapSumTSq = pool.snapshotSumStakeTimeSq();
            }
            return;
        }
        assert(pool.claimsStarted()); // the latch itself is one-way
        assert(pool.outcome() == ghostFinalOutcome);
        assert(pool.goodFaith() == ghostFinalGoodFaith);
        assert(pool.attacker() == ghostFinalAttacker);
        assert(pool.outcomeFlaggedAt() == ghostFinalFlaggedAt);
        assert(pool.snapshotTotalStaked() == ghostFinalSnapStaked);
        assert(pool.snapshotTotalBonus() == ghostFinalSnapBonus);
        assert(pool.snapshotSumStakeTime() == ghostFinalSnapSumT);
        assert(pool.snapshotSumStakeTimeSq() == ghostFinalSnapSumTSq);
    }

    /// @notice LAT-4 — a claim is forever: hasClaimed never clears, and a claimed actor
    ///         never regains principal (stake is blocked post-resolution and the claim
    ///         deleted their position, so eligibleStake must stay zero for good). Trips on
    ///         any path that would let a claimed staker re-enter and double-draw.
    function property_LAT4_claimIsForever() external {
        for (uint256 i; i < actors.length; i++) {
            bool hc = pool.hasClaimed(actors[i]);
            if (ghostHasClaimed[i]) {
                assert(hc);
                assert(pool.eligibleStake(actors[i]) == 0);
            } else {
                ghostHasClaimed[i] = hc;
            }
        }
    }

    /// @notice ACL-1 — ownership is never permanently lost or left dangling: at rest the
    ///         harness is always the owner and there is no half-open transfer. Every handler
    ///         that touches ownership completes its two-step within one call, so a sequence
    ///         that stranded ownership with an actor — or left a pendingOwner set — trips here.
    function property_ACL1_ownershipReturnsToHarness() external {
        assert(pool.owner() == address(this));
        assert(pool.pendingOwner() == address(0));
    }

    /// @notice ACL-2 — the five setter-less config fields never drift. Recomputes the birth
    ///         hash (frozen at construction) from live pool state: stakeToken, outcomeModerator,
    ///         safeHarborRegistry, agreement, minStake. None has a setter, so a match proves no
    ///         path — re-init, storage collision, delegatecall mishap — ever rewrote them.
    function property_ACL2_immutableConfigNeverDrifts() external {
        bytes32 h = keccak256(
            abi.encode(
                ImmutableConfig({
                    stakeToken: address(pool.stakeToken()),
                    moderator: pool.outcomeModerator(),
                    registry: address(pool.safeHarborRegistry()),
                    agreement: pool.agreement(),
                    minStake: pool.minStake()
                })
            )
        );
        assert(h == birthHash);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev The pool's current liabilities — what it owes right now — as a function of its
    ///      lifecycle phase. This is the right-hand side of SOL-1's solvency check.
    ///        UNRESOLVED (pool still live) -> everything staked plus every bonus contributed:
    ///                                        totalEligibleStake + totalBonus
    ///        SURVIVED / EXPIRED           -> principal still owed to stakers who haven't claimed,
    ///                                        plus the bonus they haven't withdrawn yet
    ///                                        (snapshotTotalBonus - claimedBonus) — counted only
    ///                                        while a risk window opened and stakers remain
    ///        CORRUPTED, good-faith, before the claim deadline
    ///                                     -> the attacker's still-unclaimed bounty
    ///                                        (bountyEntitlement - bountyClaimed)
    ///        CORRUPTED, otherwise         -> 0 — the whole pool is swept to the recovery wallet,
    ///                                        so nothing is "owed" in the solvency sense; SOL-2's
    ///                                        conservation check governs the funds from here.
    ///      The two subtractions are guarded by explicit asserts (paidBonus <= snapBonus and
    ///      paid <= entitlement). If bookkeeping ever let the amount paid exceed the amount owed,
    ///      that is a genuine payout-accounting bug; the assert reports it as a clean, located
    ///      failure here rather than letting it surface as a silent arithmetic underflow panic
    ///      deep in the pool. Only the UNRESOLVED branch is reachable in phase 1.
    function _liability() internal view returns (uint256 L) {
        PoolStates.Outcome outcome = pool.outcome();

        if (outcome == PoolStates.Outcome.UNRESOLVED) {
            return pool.totalEligibleStake() + pool.totalBonus();
        }
        if (outcome == PoolStates.Outcome.SURVIVED || outcome == PoolStates.Outcome.EXPIRED) {
            L = pool.totalEligibleStake();
            uint256 snapBonus = pool.snapshotTotalBonus();
            uint256 paidBonus = pool.claimedBonus();
            assert(paidBonus <= snapBonus); // guard: bonus paid can never exceed bonus snapshotted
            if (pool.riskWindowStart() != 0 && L != 0) {
                L += snapBonus - paidBonus;
            }
            return L;
        }

        // CORRUPTED
        uint256 entitlement = pool.bountyEntitlement();
        uint256 paid = pool.bountyClaimed();
        assert(paid <= entitlement); // guard: bounty paid can never exceed bounty entitlement
        if (pool.goodFaith() && block.timestamp <= pool.corruptedClaimDeadline()) {
            return entitlement - paid;
        }
        return 0;
    }

    /// @dev Independent re-derivation of the pool's _bonusShare from public state: same
    ///      clamp rule, same k=2 expansion, same mulDiv, same fallbacks. Asserting claims
    ///      against it catches the pool using WRONG INPUTS (stale/unclamped sums, live
    ///      totals where snapshots belong, a shifted T) or paying an amount other than
    ///      what its own formula produces.
    function _expectedBonusShare(address u, uint256 userEligible) internal view returns (uint256) {
        uint256 snapBonus = pool.snapshotTotalBonus();
        if (snapBonus == 0) return 0;
        uint256 start = pool.riskWindowStart();
        if (start == 0) return 0; // no observable risk no bonus
        uint256 T = pool.outcomeFlaggedAt();

        // Clamp mirror - what `_clampUserSums` will make of u before the pool computes.
        uint256 uT = pool.userSumStakeTime(u);
        uint256 uTSq = pool.userSumStakeTimeSq(u);
        if (userEligible != 0 && uT < userEligible * start) {
            uT = userEligible * start;
            uTSq = userEligible * start * start;
        }
        uint256 userPlus = T * T * userEligible + uTSq;
        uint256 userMinus = 2 * T * uT;
        uint256 userScore = userPlus > userMinus ? userPlus - userMinus : 0;

        uint256 plus = T * T * pool.snapshotTotalStaked() + pool.snapshotSumStakeTimeSq();
        uint256 minus = 2 * T * pool.snapshotSumStakeTime();
        uint256 globalScore = plus > minus ? plus - minus : 0;

        if (globalScore == 0) {
            uint256 snapStaked = pool.snapshotTotalStaked();
            if (snapStaked == 0) return 0;
            return Math.mulDiv(userEligible, snapBonus, snapStaked);
        }
        return Math.mulDiv(userScore, snapBonus, globalScore);
    }

    /// @dev Sum of stakeToken balances over the CLOSED set of wallets a token can lawfully
    ///      occupy across the pool's whole life — SOL-2's left-hand side:
    ///        • the pool itself (custody while UNRESOLVED / awaiting claims)
    ///        • the three staking actors (withdrawals, principal + bonus claims)
    ///        • the recovery wallet (claimCorrupted + both sweeps)      — phase 2 sink
    ///        • the named attacker wallet (claimAttackerBounty)         — phase 2 sink
    ///      Still intentionally omits owner / sponsor / moderator / factory / strangers: no
    ///      lawful path in ANY phase funds them, so a single wei landing there makes this sum
    ///      fall short of mintedTotal and SOL-2 trips. Mode-3 flags name a staking actor as
    ///      attacker — already watched, so the set stays closed.
    function _watchedTokenBalance() internal view returns (uint256 watchedBalance) {
        watchedBalance = stakeToken.balanceOf(address(pool));
        for (uint256 i; i < actors.length; i++) {
            watchedBalance += stakeToken.balanceOf(actors[i]);
        }
        watchedBalance += stakeToken.balanceOf(recovery);
        watchedBalance += stakeToken.balanceOf(attackerActor);
        watchedBalance += stakeToken.balanceOf(RECOVERY_ALT1); // ACL: recovery-rotation targets
        watchedBalance += stakeToken.balanceOf(RECOVERY_ALT2); //      stay inside the closed set
    }

    function _snapClaim(address actor) internal view returns (PreClaimSnapshot memory s) {
        s.actorBalance = stakeToken.balanceOf(actor);
        s.poolBalance = stakeToken.balanceOf(address(pool));
        s.userEligibleStake = pool.eligibleStake(actor);
        s.claimedBonus = pool.claimedBonus();
        s.totalEligibleStake = pool.totalEligibleStake();
        s.expectedBonusShare = _expectedBonusShare(actor, s.userEligibleStake);
    }

    /// @dev Post-conditions for a successful claim against a FROZEN snapshot: payout is
    ///      exactly principal + the mirrored bonus share, both balances move by exactly
    ///      that, claimedBonus advances by exactly the share, and the user is zeroed.
    function _assertExactPayout(address actor, PreClaimSnapshot memory s) internal view {
        uint256 payout = s.userEligibleStake + s.expectedBonusShare;
        assert(stakeToken.balanceOf(actor) == s.actorBalance + payout);
        assert(stakeToken.balanceOf(address(pool)) == s.poolBalance - payout);
        assert(pool.claimedBonus() == s.claimedBonus + s.expectedBonusShare);
        assert(pool.totalEligibleStake() == s.totalEligibleStake - s.userEligibleStake);
        assert(pool.eligibleStake(actor) == 0);
        assert(pool.userSumStakeTime(actor) == 0);
        assert(pool.userSumStakeTimeSq(actor) == 0);
        // claimExpired soft-succeeds for a stakeless caller WITHOUT setting hasClaimed.
        if (s.userEligibleStake != 0) assert(pool.hasClaimed(actor));
    }

    function _recoveryCandidate(uint256 seed) internal view returns (address) {
        uint256 k = seed % 3;
        if (k == 0) return recovery;
        if (k == 1) return RECOVERY_ALT1;
        return RECOVERY_ALT2;
    }
}
