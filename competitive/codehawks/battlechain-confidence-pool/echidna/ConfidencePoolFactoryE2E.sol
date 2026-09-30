// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ConfidencePool} from "../../src/ConfidencePool.sol";
import {EchidnaSetup} from "./EchidnaSetup.sol";
import {IConfidencePoolFactory} from "../../src/interfaces/IConfidencePoolFactory.sol";

contract ConfidencePoolFactoryE2E is EchidnaSetup {
    event logBytes(string msg, bytes err);

    bytes4 internal constant ENFORCED_PAUSE = bytes4(keccak256("EnforcedPause()"));

    function createPool_happyPath(uint256 expirySeed, uint256 minStakeSeed) public {
        // Preconditions: clamp into the valid envelope — every call should land

        uint256 expiry = _between(expirySeed, block.timestamp + 30 days, type(uint32).max);
        uint256 minStake = _between(minStakeSeed, 1, 1_000_000e18);

        // Snapshot ALL factory-state expectations BEFORE the action — the moderator
        // rotation handler runs interleaved, so the setup constant is stale by design.
        address expectedModerator = factory.defaultOutcomeModerator();
        uint256 countBefore = factory.poolCountByAgreement(address(agreement));
        bytes32 salt = keccak256(abi.encode(address(agreement), countBefore));
        address predicted = Clones.predictDeterministicAddress(factory.poolImplementation(), salt, address(factory));

        // Action — harness == agreement.owner(), the authorized creator
        address created =
            factory.createPool(address(agreement), address(stakeToken), expiry, minStake, recovery, _scope());

        // Postconditions — deltas, not absolutes
        assert(created == predicted); // P2 determinism
        assert(factory.poolCountByAgreement(address(agreement)) == countBefore + 1); // P2 exact +1
        assert(factory.getPoolsByAgreement(address(agreement))[countBefore] == created);
        assert(ConfidencePool(created).owner() == address(this)); // P1 initialized, atomic
        assert(ConfidencePool(created).outcomeModerator() == expectedModerator); // current default, not setup constant
        // Config mirror — every createPool argument lands verbatim in pool storage
        assert(address(ConfidencePool(created).stakeToken()) == address(stakeToken));
        assert(ConfidencePool(created).minStake() == minStake);
        assert(ConfidencePool(created).expiry() == expiry);
        assert(ConfidencePool(created).recoveryAddress() == recovery);
        assert(ConfidencePool(created).agreement() == address(agreement));
    }

    function createPool_expiryTooSoon_reverts(uint256 expirySeed) public {
        uint256 expiry = _between(expirySeed, block.timestamp, block.timestamp + 30 days - 1);
        try factory.createPool(address(agreement), address(stakeToken), expiry, ONE, recovery, _scope()) returns (
            address
        ) {
            assert(false); // ExpiryTooSoon gate broken
        } catch (bytes memory err) {
            // stronger oracle: it must revert for the RIGHT reason
            assert(err.length >= 4 && bytes4(err) == IConfidencePoolFactory.ExpiryTooSoon.selector);
            emit logBytes("errored with:", err);
        }
    }

    function setDefaultOutcomeModerator_rotates(uint256 seed) public {
        address next = address(moderatorCarousel[seed % moderatorCarousel.length]);
        factory.setDefaultOutcomeModerator(next);
        assert(factory.defaultOutcomeModerator() == next); // setter mirrors
        assert(pool.outcomeModerator() == birth.moderator); // P4: pool #1 untouched
    }

    function setSafeHarborRegistry_rotates(uint256 seed) public {
        address next = address(registryCarousel[seed % registryCarousel.length]);
        factory.setSafeHarborRegistry(next);
        assert(address(factory.safeHarborRegistry()) == next);
        assert(address(pool.safeHarborRegistry()) == birth.registry); // P4
    }

    function setPoolImplementation_rotates(uint256 seed) public {
        address next = implCarousel[seed % implCarousel.length];
        factory.setPoolImplementation(next);
        assert(factory.poolImplementation() == next);
        // pool #1's logic is baked into its clone bytecode — behavior probed by the standing property
    }

    function setStakeTokenAllowed_toggles(bool allowed) public {
        factory.setStakeTokenAllowed(address(otherToken), allowed);
        assert(factory.allowedStakeToken(address(otherToken)) == allowed);
        assert(factory.allowedStakeToken(address(stakeToken))); // canonical token never disturbed
    }

    // paired in one call so the factory is never left paused for other handlers
    function pauseUnpause_gateRoundtrip() public {
        factory.pause();
        try factory.createPool(
            address(agreement), address(stakeToken), block.timestamp + 31 days, ONE, recovery, _scope()
        ) returns (
            address
        ) {
            assert(false); // pause gate broken
        } catch (bytes memory err) {
            assert(err.length >= 4 && bytes4(err) == ENFORCED_PAUSE);
        }
        factory.unpause();
        assert(!factory.paused());
    }

    // ── negative: never-allowlisted token ──────────────────────────────────

    function createPool_stakeTokenNotAllowed_reverts(uint256 expirySeed) public {
        uint256 expiry = _between(expirySeed, block.timestamp + 30 days, type(uint32).max);
        try factory.createPool(address(agreement), address(bannedToken), expiry, ONE, recovery, _scope()) returns (
            address
        ) {
            assert(false);
        } catch (bytes memory err) {
            assert(err.length >= 4 && bytes4(err) == IConfidencePoolFactory.StakeTokenNotAllowed.selector);
        }
    }

    // ── P4: the standing isolation property — runs interleaved with everything ──
    // Mutable-lever fields (recovery, expiry, owner) are asserted against their
    // baselines here LEGALLY: no handler in THIS harness touches pool #1 directly,
    // so any drift means a factory action reached into a live pool — the finding.

    function pool1ConfigIsolation() public {
        assert(address(pool.stakeToken()) == birth.stakeToken);
        assert(pool.outcomeModerator() == birth.moderator);
        assert(address(pool.safeHarborRegistry()) == birth.registry);
        assert(pool.recoveryAddress() == snapRecovery);
        assert(pool.agreement() == birth.agreement);
        assert(pool.minStake() == birth.minStake);
        assert(pool.expiry() == snapExpiry);
        assert(pool.owner() == snapOwner);
    }
}
