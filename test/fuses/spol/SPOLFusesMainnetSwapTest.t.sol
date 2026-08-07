// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {
    SPOLUnstakeFuseEnterData,
    SPOLUnstakeFuseSweepData
} from "../../../contracts/fuses/chains/ethereum/spol/SPOLUnstakeFuse.sol";
import {ISPOLController, FullNonceDetails} from "../../../contracts/fuses/chains/ethereum/spol/ext/ISPOLController.sol";
import {ReadSPOLUnstakeExecutor} from "../../../contracts/readers/ReadSPOLUnstakeExecutor.sol";

interface IStakeManagerEpoch {
    function epoch() external view returns (uint256);
    function withdrawalDelay() external view returns (uint256);
}

/// @title SPOLFusesMainnetSwapTest
/// @notice Integration test over the DEPLOYED mainnet contracts: the live POL Prime
///         Plasma Vault, the DEPLOYED v3 fuse generation (same MARKET_ID 424243), and the
///         deployed ReadSPOLUnstakeExecutor lens. setUp SIMULATES THE GOVERNANCE FUSE SWAP
///         when the forked chain has not done it yet — each of the four owner txs is keyed
///         on its own on-chain predicate, so the test keeps passing unchanged after the real
///         governance session lands.
/// @dev The scenarios pin the executor security model end-to-end through the REAL vault's
///      execute() path: third-party withdrawPOL(executor) leaves totalAssets EXACTLY
///      invariant (the POL parks on the executor, counted by the balance fuse), and the
///      sweep — the vault's recovery action — lands it as vault idle without ever counting
///      it twice.
contract SPOLFusesMainnetSwapTest is Test {
    /// @dev Live POL Prime instance (deployed 2026-07-27) and its role holders.
    address private constant PLASMA_VAULT = 0x5F304564Bd957A28C4A4472DeD30C91ffeb05fB4;
    address private constant ACCESS_MANAGER = 0xB91564bc211a87f60329aCDdde145c14A636D53d;
    address private constant ATOMIST = 0xFBD5D6f37E9aaa1BF243A93899866646fFfA45d2;
    address private constant ALPHA = 0xc67e243D4E63bFBeBEd81B18380d70530A66A323;

    /// @dev v3 generation, deployed 2026-08-06 (blocks 25_697_985..987).
    address private constant UNSTAKE_FUSE_V3 = 0x1faffa606D0674728Cf20763b94F99A1156C61cc;
    address private constant BALANCE_FUSE_V2 = 0x2170717E80999f8D2F8168282c419bB1D8Bc7faa;
    address private constant READ_EXECUTOR = 0x830Fcaf08fA48D9270355Ddc836A4CCf20900916;
    /// @dev Previous generation the live vault ran before the swap.
    address private constant PREV_UNSTAKE_FUSE = 0xF7379E4D945B2CAA89630d4F81a7A3863629Fd02;
    address private constant PREV_BALANCE_FUSE = 0x69A206f638019e3a419CF3408991df9E87538949;

    address private constant SPOL_CONTROLLER = 0xEaadA411F2600570796c341552b9869DA708a28B;
    address private constant POL = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    address private constant SPOL = 0x3B790d651e950497c7723D47B24E6f61534f7969;
    /// @dev Polygon StakeManagerProxy on Ethereum — epoch()/withdrawalDelay() drive maturity.
    address private constant STAKE_MANAGER = 0x5e3Ef299fDDf15eAa0432E6e66473ace8c13D908;

    /// @dev SAME AS MAINNET: constructor parameter of both deployed v3 fuses.
    uint256 private constant MARKET_ID = 424_243;
    /// @dev Must postdate the v3 deploys (25_697_987); matches the Go fork-suite pin.
    uint256 private constant FORK_BLOCK = 25_698_100;

    PlasmaVault private vault;
    PlasmaVaultGovernance private governance;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);
        vault = PlasmaVault(PLASMA_VAULT);
        governance = PlasmaVaultGovernance(PLASMA_VAULT);
        _simulateFuseSwapIfNeeded();
        _ensureAlphaCanUpdateBalances();
    }

    /// @dev The mainnet migration, exactly: four owner txs, each skipped when the forked
    ///      chain already has it. removeBalanceFuse is contract-guarded (reverts
    ///      BalanceFuseNotReadyToRemove unless the market's live balance is ~zero), so the
    ///      "swap while empty" precondition is enforced on-chain here exactly as it will be
    ///      in the real governance session.
    function _simulateFuseSwapIfNeeded() private {
        if (!governance.isBalanceFuseSupported(MARKET_ID, BALANCE_FUSE_V2)) {
            if (governance.isBalanceFuseSupported(MARKET_ID, PREV_BALANCE_FUSE)) {
                vm.prank(ATOMIST);
                governance.removeBalanceFuse(MARKET_ID, PREV_BALANCE_FUSE);
            }
            vm.prank(ATOMIST);
            governance.addBalanceFuse(MARKET_ID, BALANCE_FUSE_V2);
        }
        if (!governance.isFuseSupported(UNSTAKE_FUSE_V3)) {
            address[] memory toAdd = new address[](1);
            toAdd[0] = UNSTAKE_FUSE_V3;
            vm.prank(ATOMIST);
            governance.addFuses(toAdd);
        }
        if (governance.isFuseSupported(PREV_UNSTAKE_FUSE)) {
            address[] memory toRemove = new address[](1);
            toRemove[0] = PREV_UNSTAKE_FUSE;
            vm.prank(ATOMIST);
            governance.removeFuses(toRemove);
        }
    }

    /// @dev updateMarketsBalances needs UPDATE_MARKETS_BALANCES_ROLE; grant it to the alpha
    ///      when the live chain has not yet (idempotent — same pending governance action the
    ///      Go fork fixture backfills).
    function _ensureAlphaCanUpdateBalances() private {
        IporFusionAccessManager accessManager = IporFusionAccessManager(ACCESS_MANAGER);
        (bool isMember,) = accessManager.hasRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, ALPHA);
        if (!isMember) {
            vm.prank(ATOMIST);
            accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, ALPHA, 0);
        }
    }

    function testShouldConvergeLiveVaultOntoV3Generation() external view {
        assertTrue(governance.isFuseSupported(UNSTAKE_FUSE_V3), "v3 unstake fuse must be registered");
        assertFalse(governance.isFuseSupported(PREV_UNSTAKE_FUSE), "previous unstake fuse must be removed");
        assertTrue(
            governance.isBalanceFuseSupported(MARKET_ID, BALANCE_FUSE_V2), "v2 balance fuse must back market 424243"
        );
        assertFalse(
            governance.isBalanceFuseSupported(MARKET_ID, PREV_BALANCE_FUSE), "previous balance fuse must be gone"
        );
    }

    function testShouldKeepDeployedVaultTotalAssetsInvariantUnderThirdPartyClaim() external {
        // given — a real sell through the deployed vault's execute() path.
        uint256 spolAmount = 500e18;
        deal(SPOL, PLASMA_VAULT, spolAmount);
        _executeEnter(spolAmount, 1_754_000_000);

        address executor = new ReadSPOLUnstakeExecutor().getSPOLUnstakeExecutorAddress(PLASMA_VAULT);
        assertNotEq(executor, address(0), "first v3 enter must deploy the executor");
        assertEq(
            ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(PLASMA_VAULT).length,
            0,
            "no nonce may ever be keyed to the vault"
        );
        FullNonceDetails[] memory nonces = ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(executor);
        assertEq(nonces.length, 1, "the executor owns the unbond queue");
        uint256 queuedPol = nonces[0].amount;

        _bumpEpochPastWithdrawalDelay();

        uint256[] memory markets = new uint256[](1);
        markets[0] = MARKET_ID;
        vm.prank(ALPHA);
        uint256 assetsBefore = vault.updateMarketsBalances(markets);

        // when — a STRANGER claims the vault's matured batch (permissionless).
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        ISPOLController(SPOL_CONTROLLER).withdrawPOL(executor);

        // then — the POL parked on the executor, valued by the balance fuse:
        // totalAssets EXACTLY invariant, nothing extractable, PPS untouched.
        assertEq(IERC20(POL).balanceOf(executor), queuedPol, "claimed POL must park on the executor");
        vm.prank(ALPHA);
        uint256 assetsAfterClaim = vault.updateMarketsBalances(markets);
        assertEq(assetsAfterClaim, assetsBefore, "totalAssets must be EXACTLY invariant under a third-party claim");

        // and — the sweep (the vault's recovery action) lands it as idle, once.
        uint256 vaultPolBefore = IERC20(POL).balanceOf(PLASMA_VAULT);
        _executeSweep(POL, 1_754_000_001);
        assertEq(
            IERC20(POL).balanceOf(PLASMA_VAULT) - vaultPolBefore,
            queuedPol,
            "the sweep must forward the full parked balance to the vault"
        );
        assertEq(IERC20(POL).balanceOf(executor), 0, "the executor must be drained");
        vm.prank(ALPHA);
        uint256 assetsAfterSweep = vault.updateMarketsBalances(markets);
        assertApproxEqAbs(
            assetsAfterSweep,
            assetsBefore,
            1e6,
            "the sweep converts market value to idle without double counting (price-conversion wei only)"
        );
    }

    function testShouldSweepDonationOnDeployedVaultCountingItOnce() external {
        // given — the executor exists (one small sell) and a stranger donates POL to it.
        deal(SPOL, PLASMA_VAULT, 100e18);
        _executeEnter(100e18, 1_754_000_000);
        address executor = new ReadSPOLUnstakeExecutor().getSPOLUnstakeExecutorAddress(PLASMA_VAULT);
        uint256 openNoncesBefore = ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(executor).length;

        uint256 donation = 50e18;
        deal(POL, executor, donation);

        // Donations never close nonces — the cooking batch must be untouched.
        assertEq(
            ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(executor).length,
            openNoncesBefore,
            "a donation must not move the unbond queue"
        );

        uint256[] memory markets = new uint256[](1);
        markets[0] = MARKET_ID;
        vm.prank(ALPHA);
        uint256 assetsWithParkedGift = vault.updateMarketsBalances(markets);

        // when — the sweep collects the gift.
        uint256 vaultPolBefore = IERC20(POL).balanceOf(PLASMA_VAULT);
        _executeSweep(POL, 1); // sentinel stamp: the gift admits nobody
        assertEq(IERC20(POL).balanceOf(PLASMA_VAULT) - vaultPolBefore, donation, "the gift lands as vault idle");

        // then — counted exactly once: parked it was market value, swept it is
        // idle; totalAssets must not gain it a second time.
        vm.prank(ALPHA);
        uint256 assetsAfterSweep = vault.updateMarketsBalances(markets);
        assertApproxEqAbs(
            assetsAfterSweep,
            assetsWithParkedGift,
            1e6,
            "sweeping the gift must not change totalAssets (already counted while parked)"
        );
    }

    function _executeEnter(uint256 spolAmount_, uint256 timestamp_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: UNSTAKE_FUSE_V3,
            data: abi.encodeWithSignature(
                "enter((address,uint256,uint256,uint256))",
                SPOLUnstakeFuseEnterData({
                    controller: SPOL_CONTROLLER, spolAmount: spolAmount_, minPolAmountOut: 0, timestamp: timestamp_
                })
            )
        });
        vm.prank(ALPHA);
        vault.execute(actions);
    }

    function _executeSweep(address token_, uint256 timestamp_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: UNSTAKE_FUSE_V3,
            data: abi.encodeWithSignature(
                "sweep((address,uint256))", SPOLUnstakeFuseSweepData({token: token_, timestamp: timestamp_})
            )
        });
        vm.prank(ALPHA);
        vault.execute(actions);
    }

    /// @dev Epochs advance with Polygon checkpoints, not wall time: find the proxy storage
    ///      slot holding epoch() by probing, then set it past the withdrawal delay — the
    ///      same lever the Go fork suite uses (anvil_setStorageAt).
    function _bumpEpochPastWithdrawalDelay() private {
        uint256 epochBefore = IStakeManagerEpoch(STAKE_MANAGER).epoch();
        uint256 target = epochBefore + IStakeManagerEpoch(STAKE_MANAGER).withdrawalDelay() + 1;
        for (uint256 slot = 0; slot < 200; slot++) {
            bytes32 original = vm.load(STAKE_MANAGER, bytes32(slot));
            if (uint256(original) != epochBefore) {
                continue;
            }
            vm.store(STAKE_MANAGER, bytes32(slot), bytes32(target));
            if (IStakeManagerEpoch(STAKE_MANAGER).epoch() == target) {
                return;
            }
            vm.store(STAKE_MANAGER, bytes32(slot), original);
        }
        revert("StakeManager epoch slot not found in the first 200 slots");
    }
}
