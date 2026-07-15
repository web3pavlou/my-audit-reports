// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockAttackRegistry} from "../mocks/MockAttackRegistry.sol";
import {MockSafeHarborRegistry} from "../mocks/MockSafeHarborRegistry.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeOnTransferERC20} from "../mocks/MockFeeOnTransferERC20.sol";
import {MockAgreement} from "../mocks/MockAgreement.sol";
import {MockConfidencePoolModerator} from "../../src/mocks/MockConfidencePoolModerator.sol";

import {ConfidencePool} from "../../src/ConfidencePool.sol";
import {ConfidencePoolFactory} from "../../src/ConfidencePoolFactory.sol";
import {IAttackRegistry} from "@battlechain/interface/IAttackRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title EchidnaSetup
/// @notice Base harness: deploys mocks + the UUPS factory, creates ONE pool, wires actors.
///         Role reality: the harness (address(this)) is factory owner, pool owner/sponsor,
///         and agreement owner. Outcome flagging is permissionless via the moderator mock.
///         Stakers rotate through the fuzzer's default senders via prank.
contract EchidnaSetup {
    // ── pool #1 config at birth ─────────────────────────────────────────
    // Immutable subset only: these five have no setter, so "hash never drifts"
    // is a legal future property. Mutable levers (expiry, recovery, owner) are
    // kept as loose baseline fields below — their properties are mutation
    // RULES (LAT-3 / ACL-2 / Ownable2Step), not immutability.
    struct ImmutableConfig {
        address stakeToken;
        address moderator;
        address registry;
        address agreement;
        uint256 minStake;
    }

    // ── actors ──────────────────────────────────────────────────────────
    address[3] internal actors = [address(0x10000), address(0x20000), address(0x30000)];
    address internal recovery = address(0xBEEF); // CORRUPTED sweep destination (passive)
    address internal attackerActor = address(0xA77); // named in good-faith CORRUPTED flags

    address internal constant SCOPE_ACCOUNT = address(0xC0FFEE); // in-scope BattleChain account
    uint256 internal constant ONE = 1e18;

    ImmutableConfig internal birth; // filled once in _setup
    bytes32 internal birthHash; // keccak256(abi.encode(birth))

    // mutable-lever baselines (NOT covered by birthHash)
    uint256 internal snapExpiry; // sponsor-mutable until first stake (LAT-3 baseline)
    address internal snapRecovery; // owner-mutable at all times (ACL-2 baseline)
    address internal snapOwner; // Ownable2Step baseline

    Vm internal constant VM = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // ── system under test + mocks ───────────────────────────────────────
    MockAttackRegistry internal attackRegistry;
    MockSafeHarborRegistry internal safeHarborRegistry;
    MockERC20 internal stakeToken; // canonical allowlisted stake token — never de-listed
    MockFeeOnTransferERC20 internal feeToken; // phase 2: separate fee-on-transfer harness
    MockAgreement internal agreement;
    MockConfidencePoolModerator internal defaultOutcomeModerator;
    ConfidencePoolFactory internal factory;
    ConfidencePool internal pool; // pool #1 — the pinned audit target

    // ── carousels: owner-lever handlers rotate among pre-wired VALID targets ──
    // Arbitrary addresses would create hollow clones / dead registries — noise, not findings.
    MockConfidencePoolModerator[2] internal moderatorCarousel;
    MockSafeHarborRegistry[2] internal registryCarousel;
    address[2] internal implCarousel;
    MockERC20 internal otherToken; // allowlist-toggled by handlers
    MockERC20 internal bannedToken; // NEVER allowlisted — oracle for the negative handler

    constructor() {
        _setup();
    }

    function _setup() internal virtual {
        VM.warp(1_780_000_000); // BASE_TIMESTAMP rationale: uint32 casts, T²·stake magnitudes
        VM.roll(23_000_000); // realistic block number, same idea

        // registry stack + wiring (pool is dead without setAttackRegistry)
        attackRegistry = new MockAttackRegistry();
        safeHarborRegistry = new MockSafeHarborRegistry();
        safeHarborRegistry.setAttackRegistry(address(attackRegistry));
        attackRegistry.setAgreementState(IAttackRegistry.ContractState.NEW_DEPLOYMENT);

        stakeToken = new MockERC20();
        agreement = new MockAgreement(address(this)); // owner() == harness → createPool passes
        agreement.setContractInScope(SCOPE_ACCOUNT, true);
        safeHarborRegistry.setAgreementValid(address(agreement), true);

        defaultOutcomeModerator = new MockConfidencePoolModerator(); // permissionless flagging

        // implementations: pool impl for clones, factory impl behind the ERC1967 proxy
        ConfidencePool poolImpl = new ConfidencePool();
        ConfidencePoolFactory factoryImpl = new ConfidencePoolFactory();
        factory = ConfidencePoolFactory(
            address(
                new ERC1967Proxy(
                    address(factoryImpl),
                    abi.encodeCall(
                        ConfidencePoolFactory.initialize,
                        (address(safeHarborRegistry), address(poolImpl), address(defaultOutcomeModerator))
                    )
                )
            )
        );
        factory.setStakeTokenAllowed(address(stakeToken), true); // harness == factory owner

        // pool #1; harness == pool owner (msg.sender of createPool)
        pool = ConfidencePool(
            factory.createPool(
                address(agreement), address(stakeToken), block.timestamp + 365 days, ONE, recovery, _scope()
            )
        );

        // carousels for the owner-lever handlers
        moderatorCarousel[0] = defaultOutcomeModerator;
        moderatorCarousel[1] = new MockConfidencePoolModerator();

        registryCarousel[0] = safeHarborRegistry;
        registryCarousel[1] = new MockSafeHarborRegistry();
        registryCarousel[1].setAttackRegistry(address(attackRegistry)); // fully wired, or future createPool dies
        registryCarousel[1].setAgreementValid(address(agreement), true);

        implCarousel[0] = address(poolImpl);
        implCarousel[1] = address(new ConfidencePool());

        otherToken = new MockERC20();
        bannedToken = new MockERC20();

        // birth certificate: immutable subset → struct + hash; mutable levers → loose baselines
        ImmutableConfig memory b = ImmutableConfig({
            stakeToken: address(pool.stakeToken()),
            moderator: pool.outcomeModerator(),
            registry: address(pool.safeHarborRegistry()),
            agreement: pool.agreement(),
            minStake: pool.minStake()
        });
        birth = b;
        birthHash = keccak256(abi.encode(b));

        snapExpiry = pool.expiry();
        snapRecovery = pool.recoveryAddress();
        snapOwner = pool.owner();

        // stakers: one-time infinite approvals; handlers mint on demand
        for (uint256 i; i < actors.length; ++i) {
            VM.prank(actors[i]);
            stakeToken.approve(address(pool), type(uint256).max);
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────
    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _between(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        return lo + (x % (hi - lo + 1));
    }

    function _scope() internal pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = SCOPE_ACCOUNT;
    }
}
