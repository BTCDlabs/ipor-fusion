// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SPOLUnstakeFuse, SPOLUnstakeFuseEnterData, SPOLUnstakeFuseExitData, SPOLUnstakeFuseSweepData, SPOLUnstakeFuseUnsupportedController, SPOLUnstakeFuseInsufficientPolOut, SPOLUnstakeFuseExecutorNotDeployed} from "../../../contracts/fuses/chains/ethereum/spol/SPOLUnstakeFuse.sol";
import {SPOLUnstakeExecutor} from "../../../contracts/fuses/chains/ethereum/spol/SPOLUnstakeExecutor.sol";
import {SPOLBalanceFuse} from "../../../contracts/fuses/chains/ethereum/spol/SPOLBalanceFuse.sol";
import {ISPOLController, FullNonceDetails} from "../../../contracts/fuses/chains/ethereum/spol/ext/ISPOLController.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

contract SPOLUnstakeFuseTest is Test {
    address private constant SPOL_CONTROLLER = 0xEaadA411F2600570796c341552b9869DA708a28B;
    address private constant POL = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    address private constant SPOL = 0x3B790d651e950497c7723D47B24E6f61534f7969;
    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    /// @dev Chainlink MATIC/USD aggregator, used as the POL price source
    address private constant CHAINLINK_MATIC_USD = 0x7bAC85A8a13A4BcD8abb3eB7d6b4d632c5a57676;
    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    /// @dev sPOL Controller market id — SAME AS MAINNET (constructor param of the deployed
    /// v3 fuses 0x1faffa60/0x2170717E; not an IporFusionMarkets constant)
    uint256 private constant MARKET_ID = 424_243;
    uint256 private constant FORK_BLOCK = 25_580_000;

    /// @dev cast index-erc7201 "io.ipor.spolUnstake.Executor"
    bytes32 private constant EXECUTOR_SLOT = 0xa56afc2a6b08675c3b996ba4937d309d4c4219c04c5fbdd338969f8501e0d200;

    event SPOLUnstakeFuseEnter(
        address version,
        address controller,
        uint256 spolAmount,
        uint256 polAmount,
        uint256 timestamp
    );
    event SPOLUnstakeFuseExit(address version, address controller, uint256 polAmount, uint256 timestamp);
    event SPOLUnstakeFuseSweep(address version, address token, uint256 amount, uint256 timestamp);
    event SPOLUnstakeFuseExecutorCreated(address version, address executor);

    PriceOracleMiddleware private priceOracleMiddlewareProxy;
    SPOLUnstakeFuse private unstakeFuse;
    SPOLBalanceFuse private balanceFuse;
    PlasmaVaultMock private vault;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(CHAINLINK_FEED_REGISTRY);
        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        address[] memory assets = new address[](1);
        assets[0] = POL;
        address[] memory sources = new address[](1);
        sources[0] = CHAINLINK_MATIC_USD;
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        unstakeFuse = new SPOLUnstakeFuse(MARKET_ID);
        balanceFuse = new SPOLBalanceFuse(MARKET_ID);
        vault = new PlasmaVaultMock(address(unstakeFuse), address(balanceFuse));
        vault.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));
    }

    function testShouldUnstakeViaExecutorAndTrackPendingPolInBalanceFuse() external {
        // given
        _grantControllerSubstrate();
        uint256 spolAmount = 500e18;
        deal(SPOL, address(vault), spolAmount);

        uint256 expectedPol = ISPOLController(SPOL_CONTROLLER).convertSPOLtoPOL(spolAmount);
        assertGt(expectedPol, 0, "Rate should be available on the fork");
        assertEq(vault.balanceOf(), 0, "Balance fuse should report 0 before unstake");

        uint256 operationTimestamp = 1_753_000_000;

        // when
        vm.expectEmit(true, true, true, true, address(vault));
        emit SPOLUnstakeFuseEnter(address(unstakeFuse), SPOL_CONTROLLER, spolAmount, expectedPol, operationTimestamp);
        _enter(
            SPOLUnstakeFuseEnterData({
                controller: SPOL_CONTROLLER,
                spolAmount: spolAmount,
                minPolAmountOut: expectedPol,
                timestamp: operationTimestamp
            })
        );

        // then
        address executor = _executor();
        assertTrue(executor != address(0), "Executor should be deployed");

        assertEq(IERC20(SPOL).balanceOf(address(vault)), 0, "Vault sPOL should be burned");
        assertEq(IERC20(SPOL).balanceOf(executor), 0, "Executor should hold no sPOL (exact burn, no sweep)");
        assertEq(IERC20(POL).balanceOf(executor), 0, "Executor should hold no POL after enter");

        assertEq(
            ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(address(vault)).length,
            0,
            "No nonces should accrue to the vault"
        );

        FullNonceDetails[] memory nonces = ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(executor);
        assertGt(nonces.length, 0, "Unstake nonces should accrue to the executor");

        uint256 pendingPol;
        for (uint256 i; i < nonces.length; ++i) {
            pendingPol += nonces[i].amount;
        }
        assertApproxEqAbs(pendingPol, expectedPol, nonces.length, "Queued POL should match the conversion rate");

        (uint256 price, ) = priceOracleMiddlewareProxy.getAssetPrice(POL);
        assertEq(vault.balanceOf(), (pendingPol * price) / 1e18, "Balance fuse should value the executor's queue");
    }

    function testShouldLazyDeployExecutorWithStableAddress() external {
        // given
        _grantControllerSubstrate();
        deal(SPOL, address(vault), 200e18);

        assertEq(_executor(), address(0), "Executor slot should be empty before first enter");

        // when - first enter deploys and emits ExecutorCreated once
        vm.recordLogs();
        _enter(
            SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: 100e18, minPolAmountOut: 0, timestamp: 0})
        );
        address executorAfterFirst = _executor();
        assertEq(
            _countExecutorCreatedLogs(vm.getRecordedLogs()),
            1,
            "First enter should emit ExecutorCreated exactly once"
        );

        // second enter reuses the executor, no new event
        vm.recordLogs();
        _enter(
            SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: 100e18, minPolAmountOut: 0, timestamp: 0})
        );

        // then
        assertTrue(executorAfterFirst != address(0), "Executor should be deployed on first enter");
        assertEq(_executor(), executorAfterFirst, "Executor address should be stable across enters");
        assertEq(_countExecutorCreatedLogs(vm.getRecordedLogs()), 0, "Second enter should not emit ExecutorCreated");
        assertEq(
            SPOLUnstakeExecutor(executorAfterFirst).PLASMA_VAULT(),
            address(vault),
            "Executor should be bound to the vault"
        );
    }

    function testShouldKeepVaultBalanceInvariantUnderThirdPartyClaim() external {
        // given - a real unstake with pending nonces on the executor
        _grantControllerSubstrate();
        deal(SPOL, address(vault), 500e18);
        _enter(
            SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: 500e18, minPolAmountOut: 0, timestamp: 0})
        );

        address executor = _executor();
        uint256 balanceBefore = vault.balanceOf();
        assertGt(balanceBefore, 0, "Pending queue should be valued before the third-party claim");

        FullNonceDetails[] memory nonces = ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(executor);
        uint256 pendingPol;
        for (uint256 i; i < nonces.length; ++i) {
            pendingPol += nonces[i].amount;
        }

        // when - simulate a permissionless third-party withdrawPOL(executor): queue closes, POL lands on executor
        vm.mockCall(
            SPOL_CONTROLLER,
            abi.encodeWithSelector(ISPOLController.getUserOpenNonces.selector, executor),
            abi.encode(new FullNonceDetails[](0))
        );
        deal(POL, executor, pendingPol);

        // then - the market balance is EXACTLY unchanged (pending value == executor wallet value)
        assertEq(vault.balanceOf(), balanceBefore, "totalAssets must be invariant under third-party claims");
    }

    function testShouldSweepThirdPartyClaimedPolToVault() external {
        // given - post-third-party-claim state: empty queue, POL parked on the executor
        _grantControllerSubstrate();
        deal(SPOL, address(vault), 500e18);
        _enter(
            SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: 500e18, minPolAmountOut: 0, timestamp: 0})
        );

        address executor = _executor();
        FullNonceDetails[] memory nonces = ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(executor);
        uint256 pendingPol;
        for (uint256 i; i < nonces.length; ++i) {
            pendingPol += nonces[i].amount;
        }
        vm.mockCall(
            SPOL_CONTROLLER,
            abi.encodeWithSelector(ISPOLController.getUserOpenNonces.selector, executor),
            abi.encode(new FullNonceDetails[](0))
        );
        deal(POL, executor, pendingPol);

        // when
        vm.expectEmit(true, true, true, true, address(vault));
        emit SPOLUnstakeFuseSweep(address(unstakeFuse), POL, pendingPol, block.timestamp);
        _sweep(SPOLUnstakeFuseSweepData({token: POL, timestamp: 0}));

        // then
        assertEq(IERC20(POL).balanceOf(executor), 0, "Executor should be drained");
        assertEq(IERC20(POL).balanceOf(address(vault)), pendingPol, "Vault should receive the parked POL");
        assertEq(vault.balanceOf(), 0, "Market balance should drop to 0 after the sweep");
    }

    function testShouldSweepSpolDonationAndArbitraryToken() external {
        // given - executor exists
        _grantControllerSubstrate();
        deal(SPOL, address(vault), 100e18);
        _enter(
            SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: 100e18, minPolAmountOut: 0, timestamp: 0})
        );
        address executor = _executor();

        deal(SPOL, executor, 7e18);
        deal(DAI, executor, 11e18);

        // when / then - sPOL donation flushed
        _sweep(SPOLUnstakeFuseSweepData({token: SPOL, timestamp: 0}));
        assertEq(IERC20(SPOL).balanceOf(executor), 0, "Executor sPOL should be swept");
        assertEq(IERC20(SPOL).balanceOf(address(vault)), 7e18, "Vault should receive donated sPOL");

        // arbitrary token flushed
        _sweep(SPOLUnstakeFuseSweepData({token: DAI, timestamp: 0}));
        assertEq(IERC20(DAI).balanceOf(executor), 0, "Executor DAI should be swept");
        assertEq(IERC20(DAI).balanceOf(address(vault)), 11e18, "Vault should receive the arbitrary token");

        // zero-balance sweep emits amount 0 and does not revert
        vm.expectEmit(true, true, true, true, address(vault));
        emit SPOLUnstakeFuseSweep(address(unstakeFuse), DAI, 0, block.timestamp);
        _sweep(SPOLUnstakeFuseSweepData({token: DAI, timestamp: 0}));
    }

    function testShouldCapUnstakeAtVaultSpolBalance() external {
        // given
        _grantControllerSubstrate();
        uint256 spolBalance = 100e18;
        deal(SPOL, address(vault), spolBalance);

        uint256 expectedPol = ISPOLController(SPOL_CONTROLLER).convertSPOLtoPOL(spolBalance);

        // when - timestamp 0 falls back to block.timestamp in the event
        vm.expectEmit(true, true, true, true, address(vault));
        emit SPOLUnstakeFuseEnter(address(unstakeFuse), SPOL_CONTROLLER, spolBalance, expectedPol, block.timestamp);
        _enter(
            SPOLUnstakeFuseEnterData({
                controller: SPOL_CONTROLLER,
                spolAmount: 500e18,
                minPolAmountOut: 0,
                timestamp: 0
            })
        );

        // then
        assertEq(IERC20(SPOL).balanceOf(address(vault)), 0, "Full sPOL balance should be burned");

        FullNonceDetails[] memory nonces = ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(_executor());
        uint256 pendingPol;
        for (uint256 i; i < nonces.length; ++i) {
            pendingPol += nonces[i].amount;
        }
        assertApproxEqAbs(pendingPol, expectedPol, nonces.length + 1, "Queued POL should reflect the capped amount");
    }

    function testShouldDoNothingWhenAmountIsZero() external {
        // given
        _grantControllerSubstrate();

        // when
        _enter(SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: 0, minPolAmountOut: 0, timestamp: 0}));

        // then - no nonces and, importantly, no executor deployment
        assertEq(
            ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(address(vault)).length,
            0,
            "No nonces should be created"
        );
        assertEq(_executor(), address(0), "No-op enter should not deploy the executor");
    }

    function testShouldRevertWhenControllerNotGranted() external {
        vm.expectRevert(abi.encodeWithSelector(SPOLUnstakeFuseUnsupportedController.selector, SPOL_CONTROLLER));
        _enter(
            SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: 100e18, minPolAmountOut: 0, timestamp: 0})
        );
    }

    function testShouldRevertWhenPolOutBelowMinimum() external {
        // given
        _grantControllerSubstrate();
        uint256 spolAmount = 100e18;
        deal(SPOL, address(vault), spolAmount);

        uint256 expectedPol = ISPOLController(SPOL_CONTROLLER).convertSPOLtoPOL(spolAmount);

        // when / then - guard fires before the executor is deployed
        vm.expectRevert(
            abi.encodeWithSelector(SPOLUnstakeFuseInsufficientPolOut.selector, expectedPol, expectedPol + 1)
        );
        _enter(
            SPOLUnstakeFuseEnterData({
                controller: SPOL_CONTROLLER,
                spolAmount: spolAmount,
                minPolAmountOut: expectedPol + 1,
                timestamp: 0
            })
        );
        assertEq(_executor(), address(0), "Failing rate guard should not deploy the executor");
    }

    function testShouldRevertExitWhenControllerNotGranted() external {
        vm.expectRevert(abi.encodeWithSelector(SPOLUnstakeFuseUnsupportedController.selector, SPOL_CONTROLLER));
        _exit(SPOLUnstakeFuseExitData({controller: SPOL_CONTROLLER, timestamp: 0}));
    }

    function testShouldRevertExitWhenExecutorNotDeployed() external {
        _grantControllerSubstrate();

        vm.expectRevert(SPOLUnstakeFuseExecutorNotDeployed.selector);
        _exit(SPOLUnstakeFuseExitData({controller: SPOL_CONTROLLER, timestamp: 0}));
    }

    function testShouldRevertSweepWhenExecutorNotDeployed() external {
        vm.expectRevert(SPOLUnstakeFuseExecutorNotDeployed.selector);
        _sweep(SPOLUnstakeFuseSweepData({token: POL, timestamp: 0}));
    }

    function testShouldRevertExitWhenQueueIsEmpty() external {
        // given - executor force-deployed with an empty queue
        _grantControllerSubstrate();
        address executor = address(new SPOLUnstakeExecutor(address(vault)));
        vm.store(address(vault), EXECUTOR_SLOT, bytes32(uint256(uint160(executor))));

        // when / then - fail-loud: the controller's NoOpenNonces(executor) bubbles through the fuse
        vm.expectRevert(abi.encodeWithSelector(ISPOLController.NoOpenNonces.selector, executor));
        _exit(SPOLUnstakeFuseExitData({controller: SPOL_CONTROLLER, timestamp: 0}));
    }

    function testShouldRevertExitWhenNoNonceMaturedYet() external {
        // given
        _grantControllerSubstrate();
        deal(SPOL, address(vault), 100e18);
        _enter(
            SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: 100e18, minPolAmountOut: 0, timestamp: 0})
        );

        // when / then - the ~80 checkpoint cooldown cannot be warped on a fork
        vm.expectRevert(abi.encodeWithSelector(ISPOLController.NoNoncesReady.selector, _executor()));
        _exit(SPOLUnstakeFuseExitData({controller: SPOL_CONTROLLER, timestamp: 0}));
    }

    function _enter(SPOLUnstakeFuseEnterData memory data) private {
        vault.execute(address(unstakeFuse), abi.encodeWithSignature("enter((address,uint256,uint256,uint256))", data));
    }

    function _exit(SPOLUnstakeFuseExitData memory data) private {
        vault.execute(address(unstakeFuse), abi.encodeWithSignature("exit((address,uint256))", data));
    }

    function _sweep(SPOLUnstakeFuseSweepData memory data) private {
        vault.execute(address(unstakeFuse), abi.encodeWithSignature("sweep((address,uint256))", data));
    }

    function _executor() private view returns (address) {
        return address(uint160(uint256(vm.load(address(vault), EXECUTOR_SLOT))));
    }

    function _countExecutorCreatedLogs(Vm.Log[] memory logs) private pure returns (uint256 count) {
        bytes32 topic = keccak256("SPOLUnstakeFuseExecutorCreated(address,address)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) {
                ++count;
            }
        }
    }

    function _grantControllerSubstrate() private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(SPOL_CONTROLLER);
        vault.grantMarketSubstrates(MARKET_ID, substrates);
    }
}
