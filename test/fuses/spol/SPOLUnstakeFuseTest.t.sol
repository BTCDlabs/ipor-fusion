// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SPOLUnstakeFuse, SPOLUnstakeFuseEnterData, SPOLUnstakeFuseExitData, SPOLUnstakeFuseUnsupportedController, SPOLUnstakeFuseInsufficientPolOut} from "../../../contracts/fuses/chains/ethereum/spol/SPOLUnstakeFuse.sol";
import {SPOLBalanceFuse} from "../../../contracts/fuses/chains/ethereum/spol/SPOLBalanceFuse.sol";
import {ISPOLController, FullNonceDetails} from "../../../contracts/fuses/chains/ethereum/spol/ext/ISPOLController.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

contract SPOLUnstakeFuseTest is Test {
    address private constant SPOL_CONTROLLER = 0xEaadA411F2600570796c341552b9869DA708a28B;
    address private constant POL = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    address private constant SPOL = 0x3B790d651e950497c7723D47B24E6f61534f7969;
    /// @dev Chainlink MATIC/USD aggregator, used as the POL price source
    address private constant CHAINLINK_MATIC_USD = 0x7bAC85A8a13A4BcD8abb3eB7d6b4d632c5a57676;
    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    /// @dev sPOL Controller market id; not registered in IporFusionMarkets (added upstream after the fact)
    uint256 private constant MARKET_ID = 300_001;
    uint256 private constant FORK_BLOCK = 25_580_000;

    /// @dev sPOLController errors surfaced through exit()
    error NoOpenNonces(address user);
    error NoNoncesReady(address user);

    event SPOLUnstakeFuseEnter(address version, address controller, uint256 spolAmount, uint256 polAmount);

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

    function testShouldUnstakeAndTrackPendingPolInBalanceFuse() external {
        // given
        _grantControllerSubstrate();
        uint256 spolAmount = 500e18;
        deal(SPOL, address(vault), spolAmount);

        uint256 expectedPol = ISPOLController(SPOL_CONTROLLER).convertSPOLtoPOL(spolAmount);
        assertGt(expectedPol, 0, "Rate should be available on the fork");
        assertEq(vault.balanceOf(), 0, "Balance fuse should report 0 before unstake");

        // when
        vm.expectEmit(true, true, true, true, address(vault));
        emit SPOLUnstakeFuseEnter(address(unstakeFuse), SPOL_CONTROLLER, spolAmount, expectedPol);
        _enter(
            SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: spolAmount, minPolAmountOut: expectedPol})
        );

        // then
        assertEq(IERC20(SPOL).balanceOf(address(vault)), 0, "sPOL should be burned");

        FullNonceDetails[] memory nonces = ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(address(vault));
        assertGt(nonces.length, 0, "Unstake nonces should accrue to the vault");

        uint256 pendingPol;
        for (uint256 i; i < nonces.length; ++i) {
            pendingPol += nonces[i].amount;
        }
        assertApproxEqAbs(pendingPol, expectedPol, nonces.length, "Queued POL should match the conversion rate");

        (uint256 price, ) = priceOracleMiddlewareProxy.getAssetPrice(POL);
        assertEq(vault.balanceOf(), (pendingPol * price) / 1e18, "Balance fuse should value the pending POL");
    }

    function testShouldCapUnstakeAtVaultSpolBalance() external {
        // given
        _grantControllerSubstrate();
        uint256 spolBalance = 100e18;
        deal(SPOL, address(vault), spolBalance);

        uint256 expectedPol = ISPOLController(SPOL_CONTROLLER).convertSPOLtoPOL(spolBalance);

        // when
        _enter(SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: 500e18, minPolAmountOut: 0}));

        // then
        assertEq(IERC20(SPOL).balanceOf(address(vault)), 0, "Full sPOL balance should be burned");

        FullNonceDetails[] memory nonces = ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(address(vault));
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
        _enter(SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: 0, minPolAmountOut: 0}));

        // then
        assertEq(
            ISPOLController(SPOL_CONTROLLER).getUserOpenNonces(address(vault)).length,
            0,
            "No nonces should be created"
        );
    }

    function testShouldRevertWhenControllerNotGranted() external {
        vm.expectRevert(abi.encodeWithSelector(SPOLUnstakeFuseUnsupportedController.selector, SPOL_CONTROLLER));
        _enter(SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: 100e18, minPolAmountOut: 0}));
    }

    function testShouldRevertWhenPolOutBelowMinimum() external {
        // given
        _grantControllerSubstrate();
        uint256 spolAmount = 100e18;
        deal(SPOL, address(vault), spolAmount);

        uint256 expectedPol = ISPOLController(SPOL_CONTROLLER).convertSPOLtoPOL(spolAmount);

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(SPOLUnstakeFuseInsufficientPolOut.selector, expectedPol, expectedPol + 1)
        );
        _enter(
            SPOLUnstakeFuseEnterData({
                controller: SPOL_CONTROLLER,
                spolAmount: spolAmount,
                minPolAmountOut: expectedPol + 1
            })
        );
    }

    function testShouldRevertExitWhenControllerNotGranted() external {
        vm.expectRevert(abi.encodeWithSelector(SPOLUnstakeFuseUnsupportedController.selector, SPOL_CONTROLLER));
        _exit(SPOLUnstakeFuseExitData({controller: SPOL_CONTROLLER}));
    }

    function testShouldRevertExitWhenQueueIsEmpty() external {
        // given
        _grantControllerSubstrate();

        // when / then
        vm.expectRevert(abi.encodeWithSelector(NoOpenNonces.selector, address(vault)));
        _exit(SPOLUnstakeFuseExitData({controller: SPOL_CONTROLLER}));
    }

    function testShouldRevertExitWhenNoNonceMaturedYet() external {
        // given
        _grantControllerSubstrate();
        uint256 spolAmount = 100e18;
        deal(SPOL, address(vault), spolAmount);

        _enter(SPOLUnstakeFuseEnterData({controller: SPOL_CONTROLLER, spolAmount: spolAmount, minPolAmountOut: 0}));

        // when / then - the ~80 checkpoint cooldown cannot be warped on a fork
        vm.expectRevert(abi.encodeWithSelector(NoNoncesReady.selector, address(vault)));
        _exit(SPOLUnstakeFuseExitData({controller: SPOL_CONTROLLER}));
    }

    function _enter(SPOLUnstakeFuseEnterData memory data) private {
        vault.execute(address(unstakeFuse), abi.encodeWithSignature("enter((address,uint256,uint256))", data));
    }

    function _exit(SPOLUnstakeFuseExitData memory data) private {
        vault.execute(address(unstakeFuse), abi.encodeWithSignature("exit((address))", data));
    }

    function _grantControllerSubstrate() private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(SPOL_CONTROLLER);
        vault.grantMarketSubstrates(MARKET_ID, substrates);
    }
}
