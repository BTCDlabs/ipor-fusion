// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {SPOLUnstakeExecutor} from "../../../contracts/fuses/chains/ethereum/spol/SPOLUnstakeExecutor.sol";
import {ISPOLController, FullNonceDetails} from "../../../contracts/fuses/chains/ethereum/spol/ext/ISPOLController.sol";

/// @dev Stub controller for the positive claim path — vm.mockCall cannot move tokens
contract StubSPOLController {
    address public immutable POL_TOKEN;
    uint256 public payout;

    constructor(address polToken_) {
        POL_TOKEN = polToken_;
    }

    function setPayout(uint256 payout_) external {
        payout = payout_;
    }

    function polToken() external view returns (address) {
        return POL_TOKEN;
    }

    function withdrawPOL() external {
        IERC20(POL_TOKEN).transfer(msg.sender, payout);
    }
}

/// @dev Test contract acts as the PLASMA_VAULT (deploys the executor bound to itself)
contract SPOLUnstakeExecutorTest is Test {
    address private constant SPOL_CONTROLLER = 0xEaadA411F2600570796c341552b9869DA708a28B;
    address private constant POL = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    address private constant SPOL = 0x3B790d651e950497c7723D47B24E6f61534f7969;

    uint256 private constant FORK_BLOCK = 25_580_000;

    SPOLUnstakeExecutor private executor;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);
        executor = new SPOLUnstakeExecutor(address(this));
    }

    function testShouldSetPlasmaVault() external {
        assertEq(executor.PLASMA_VAULT(), address(this), "PLASMA_VAULT should be the deployer-supplied vault");
    }

    function testShouldRevertOnZeroPlasmaVault() external {
        vm.expectRevert(SPOLUnstakeExecutor.SPOLUnstakeExecutorInvalidPlasmaVaultAddress.selector);
        new SPOLUnstakeExecutor(address(0));
    }

    function testShouldRevertUnstakeForUnauthorizedCaller() external {
        vm.prank(address(0xBAD));
        vm.expectRevert(SPOLUnstakeExecutor.SPOLUnstakeExecutorUnauthorizedCaller.selector);
        executor.unstake(SPOL_CONTROLLER, 1e18);
    }

    function testShouldRevertClaimForUnauthorizedCaller() external {
        vm.prank(address(0xBAD));
        vm.expectRevert(SPOLUnstakeExecutor.SPOLUnstakeExecutorUnauthorizedCaller.selector);
        executor.claim(SPOL_CONTROLLER);
    }

    function testShouldRevertSweepForUnauthorizedCaller() external {
        vm.prank(address(0xBAD));
        vm.expectRevert(SPOLUnstakeExecutor.SPOLUnstakeExecutorUnauthorizedCaller.selector);
        executor.sweep(POL);
    }

    function testShouldUnstakeAndAccrueNoncesToExecutor() external {
        // given
        uint256 spolAmount = 100e18;
        deal(SPOL, address(executor), spolAmount);

        // when
        executor.unstake(SPOL_CONTROLLER, spolAmount);

        // then - sellSPOL burns the exact amount, no residue without any sweep
        assertEq(IERC20(SPOL).balanceOf(address(executor)), 0, "Executor should hold no sPOL after unstake");

        FullNonceDetails[] memory nonces = ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(address(executor));
        assertGt(nonces.length, 0, "Nonces should accrue to the executor");
    }

    function testShouldBubbleClaimRevertsUnchanged() external {
        // real controller, empty queue for the executor - NoOpenNonces must bubble, not be caught
        vm.expectRevert(abi.encodeWithSelector(ISPOLController.NoOpenNonces.selector, address(executor)));
        executor.claim(SPOL_CONTROLLER);
    }

    function testShouldClaimDeltaToVaultAndLeaveParkedPolUntouched() external {
        // given - 100 POL parked on the executor (e.g. third-party claim), stub pays 50 more
        uint256 parked = 100e18;
        uint256 claimPayout = 50e18;

        StubSPOLController stub = new StubSPOLController(POL);
        deal(POL, address(executor), parked);
        deal(POL, address(stub), claimPayout);
        stub.setPayout(claimPayout);

        uint256 vaultPolBefore = IERC20(POL).balanceOf(address(this));

        // when
        uint256 polAmount = executor.claim(address(stub));

        // then - exactly the freshly claimed delta is forwarded, parked POL stays for sweep
        assertEq(polAmount, claimPayout, "Claim should return the freshly claimed delta");
        assertEq(
            IERC20(POL).balanceOf(address(this)) - vaultPolBefore,
            claimPayout,
            "Vault should receive exactly the delta"
        );
        assertEq(IERC20(POL).balanceOf(address(executor)), parked, "Parked POL should remain on the executor");
    }

    function testShouldSweepFullBalanceToVault() external {
        // given
        uint256 amount = 123e18;
        deal(POL, address(executor), amount);
        uint256 vaultPolBefore = IERC20(POL).balanceOf(address(this));

        // when
        uint256 swept = executor.sweep(POL);

        // then
        assertEq(swept, amount, "Sweep should return the full balance");
        assertEq(IERC20(POL).balanceOf(address(this)) - vaultPolBefore, amount, "Vault should receive the balance");
        assertEq(IERC20(POL).balanceOf(address(executor)), 0, "Executor should be drained");
    }

    function testShouldSweepZeroBalanceWithoutRevert() external {
        assertEq(executor.sweep(POL), 0, "Sweeping an empty balance should return 0");
    }

    function testShouldPinControllerErrorSelectors() external pure {
        assertEq(ISPOLController.NoOpenNonces.selector, bytes4(0x210f50a4), "NoOpenNonces selector drifted");
        assertEq(ISPOLController.NoNoncesReady.selector, bytes4(0x29b22615), "NoNoncesReady selector drifted");
    }
}
