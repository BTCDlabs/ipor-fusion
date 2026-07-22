// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SPOLBalanceFuse} from "../../../contracts/fuses/chains/ethereum/spol/SPOLBalanceFuse.sol";
import {ISPOLController, FullNonceDetails} from "../../../contracts/fuses/chains/ethereum/spol/ext/ISPOLController.sol";
import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

contract SPOLBalanceFuseTest is Test {
    address private constant SPOL_CONTROLLER = 0xEaadA411F2600570796c341552b9869DA708a28B;
    address private constant POL = 0x455e53CBB86018Ac2B8092FdCd39d8444aFFC3F6;
    /// @dev Chainlink MATIC/USD aggregator, used as the POL price source
    address private constant CHAINLINK_MATIC_USD = 0x7bAC85A8a13A4BcD8abb3eB7d6b4d632c5a57676;
    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    /// @dev sPOL Controller market id; not registered in IporFusionMarkets (added upstream after the fact)
    uint256 private constant MARKET_ID = 300_001;
    uint256 private constant FORK_BLOCK = 25_580_000;

    PriceOracleMiddleware private priceOracleMiddlewareProxy;
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

        balanceFuse = new SPOLBalanceFuse(MARKET_ID);
        vault = new PlasmaVaultMock(address(0), address(balanceFuse));
        vault.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));
    }

    function testShouldSetupImmutables() external {
        assertEq(balanceFuse.MARKET_ID(), MARKET_ID, "MARKET_ID should match");
        assertEq(balanceFuse.VERSION(), address(balanceFuse), "VERSION should be the fuse address");
    }

    function testShouldRevertWhenMarketIdIsZero() external {
        vm.expectRevert(SPOLBalanceFuse.SPOLBalanceFuseInvalidMarketId.selector);
        new SPOLBalanceFuse(0);
    }

    function testShouldReturnZeroWhenNoSubstrateGranted() external {
        assertEq(vault.balanceOf(), 0, "Balance should be 0 without substrates");
    }

    function testShouldReturnZeroWhenQueueIsEmpty() external {
        _grantControllerSubstrate();

        assertEq(vault.balanceOf(), 0, "Balance should be 0 for an empty unstake queue");
    }

    function testShouldValuePendingNoncesInUsd() external {
        _grantControllerSubstrate();

        FullNonceDetails[] memory nonces = new FullNonceDetails[](3);
        nonces[0] = FullNonceDetails({validatorId: 1, amount: 100e18, validatorNonce: 1, nonce: 1});
        nonces[1] = FullNonceDetails({validatorId: 2, amount: 250e18, validatorNonce: 7, nonce: 2});
        nonces[2] = FullNonceDetails({validatorId: 3, amount: 123456789012345678, validatorNonce: 9, nonce: 3});

        vm.mockCall(
            SPOL_CONTROLLER,
            abi.encodeWithSelector(ISPOLController.getUserOpenNonces.selector, address(vault)),
            abi.encode(nonces)
        );

        uint256 pendingPol = 100e18 + 250e18 + 123456789012345678;
        (uint256 price, ) = priceOracleMiddlewareProxy.getAssetPrice(POL);
        assertGt(price, 0, "POL price should be available on the fork");

        // POL is 18 decimals, middleware price is WAD: usd = pendingPol * price / 1e18
        assertEq(vault.balanceOf(), (pendingPol * price) / 1e18, "Balance should be the priced sum of open nonces");
    }

    function testShouldRevertWhenPolPriceIsZero() external {
        _grantControllerSubstrate();

        FullNonceDetails[] memory nonces = new FullNonceDetails[](1);
        nonces[0] = FullNonceDetails({validatorId: 1, amount: 100e18, validatorNonce: 1, nonce: 1});

        vm.mockCall(
            SPOL_CONTROLLER,
            abi.encodeWithSelector(ISPOLController.getUserOpenNonces.selector, address(vault)),
            abi.encode(nonces)
        );
        vm.mockCall(
            address(priceOracleMiddlewareProxy),
            abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, POL),
            abi.encode(uint256(0), uint256(18))
        );

        vm.expectRevert(abi.encodeWithSelector(SPOLBalanceFuse.SPOLBalanceFusePolPriceIsZero.selector, POL));
        vault.balanceOf();
    }

    function _grantControllerSubstrate() private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(SPOL_CONTROLLER);
        vault.grantMarketSubstrates(MARKET_ID, substrates);
    }
}
