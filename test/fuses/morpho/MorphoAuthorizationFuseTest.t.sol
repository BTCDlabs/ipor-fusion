// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";

import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {MorphoBalanceFuse} from "../../../contracts/fuses/morpho/MorphoBalanceFuse.sol";
import {MorphoAuthorizationFuse, MorphoAuthorizationFuseEnterData, MorphoAuthorizationFuseExitData} from "../../../contracts/fuses/morpho/MorphoAuthorizationFuse.sol";
import {MorphoCollateralFuse, MorphoCollateralFuseEnterData} from "../../../contracts/fuses/morpho/MorphoCollateralFuse.sol";
import {MorphoSupplyFuse, MorphoSupplyFuseEnterData} from "../../../contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {TransientStorageSetInputsFuse, TransientStorageSetInputsFuseEnterData} from "../../../contracts/fuses/transient_storage/TransientStorageSetInputsFuse.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {WstETHPriceFeedEthereum} from "../../../contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol";
import {PlasmaVault, PlasmaVaultInitData, MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {IWETH9} from "./IWETH9.sol";
import {IstETH} from "./IstETH.sol";
import {IWstETH} from "./IWstETH.sol";

contract MorphoAuthorizationFuseTest is Test {
    address private constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant _WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);
    address private constant _DELEGATE = address(778899);
    address private constant _NOT_GRANTED = address(99887766);

    address private constant _MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    bytes32 private constant _MORPHO_MARKET_ID = 0xd0e50cdac92fe2172043f5e0c36532c6369d24947e40968f34a5e8819ca9ec5d;

    /// @dev dedicated market for the authorization substrates, taken from MARKET_ID in .env as at deploy time
    uint256 private _authMarketId;
    uint256 private constant _DEFAULT_AUTH_MARKET_ID = 424244;

    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant _ETH_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;

    address private _morphoSupplyFuse;
    address private _morphoCollateralFuse;
    address private _morphoAuthorizationFuse;
    address private _transientStorageSetInputsFuse;

    event MorphoAuthorizationFuseEnter(address version, address authorized, bool isAuthorized);
    event MorphoAuthorizationFuseExit(address version, address authorized, bool isAuthorized);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20919795);

        _authMarketId = vm.envOr("MARKET_ID", _DEFAULT_AUTH_MARKET_ID);

        _priceOracle = _createPriceOracle();
        address accessManager = _createAccessManager();
        address withdrawManager = address(new WithdrawManager(accessManager));

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "wstETH",
                _WST_ETH,
                _priceOracle,
                _setupFeeConfig(),
                accessManager,
                address(new PlasmaVaultBase()),
                withdrawManager,
                address(0)
            )
        );
        vm.stopPrank();

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            address(_plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );

        _initAccessManager();
        _setupDependenceBalance();

        deal(_USER, 100_000e18);
        vm.startPrank(_USER);
        IWETH9(_W_ETH).deposit{value: 20_000e18}();
        IstETH(_ST_ETH).submit{value: 20_001e18}(address(0));
        ERC20(_ST_ETH).approve(_WST_ETH, 20_000e18);
        IWstETH(_WST_ETH).wrap(20_000e18);

        ERC20(_WST_ETH).approve(_plasmaVault, 10_000e18);
        PlasmaVault(_plasmaVault).deposit(10_000e18, _USER);

        /// @dev only for test purposes
        ERC20(_W_ETH).transfer(_plasmaVault, 10_000e18);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.MORPHO;
        marketIds[1] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);

        _supplyAndCollateralizeMorpho();
    }

    function _createPriceOracle() private returns (address) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_CHAINLINK_REGISTRY);
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        WstETHPriceFeedEthereum wstETHPriceFeed = new WstETHPriceFeedEthereum();

        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);

        assets[0] = _WST_ETH;
        sources[0] = address(wstETHPriceFeed);

        assets[1] = _W_ETH;
        sources[1] = _ETH_USD_CHAINLINK;

        priceOracle.setAssetsPricesSources(assets, sources);

        return address(priceOracle);
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](3);

        bytes32[] memory morphoMarketsId = new bytes32[](1);
        morphoMarketsId[0] = _MORPHO_MARKET_ID;

        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_W_ETH);

        bytes32[] memory authorizedAccounts = new bytes32[](1);
        authorizedAccounts[0] = PlasmaVaultConfigLib.addressToBytes32(_DELEGATE);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.MORPHO, morphoMarketsId);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, tokens);
        marketConfigs_[2] = MarketSubstratesConfig(_authMarketId, authorizedAccounts);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _morphoSupplyFuse = address(new MorphoSupplyFuse(IporFusionMarkets.MORPHO, _MORPHO));
        _morphoCollateralFuse = address(new MorphoCollateralFuse(IporFusionMarkets.MORPHO, _MORPHO));
        _morphoAuthorizationFuse = address(new MorphoAuthorizationFuse(_authMarketId, _MORPHO));
        _transientStorageSetInputsFuse = address(new TransientStorageSetInputsFuse());

        fuses = new address[](4);
        fuses[0] = _morphoSupplyFuse;
        fuses[1] = _morphoCollateralFuse;
        fuses[2] = _morphoAuthorizationFuse;
        fuses[3] = _transientStorageSetInputsFuse;
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        balanceFuses_ = new MarketBalanceFuseConfig[](3);
        balanceFuses_[0] = MarketBalanceFuseConfig(
            IporFusionMarkets.MORPHO,
            address(new MorphoBalanceFuse(IporFusionMarkets.MORPHO, _MORPHO))
        );
        balanceFuses_[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.ERC20_VAULT_BALANCE,
            address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE))
        );
        balanceFuses_[2] = MarketBalanceFuseConfig(_authMarketId, address(new ZeroBalanceFuse(_authMarketId)));
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private returns (address accessManager_) {
        accessManager_ = address(new IporFusionAccessManager(_ATOMIST, 0));
        _accessManager = accessManager_;
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;

        address[] memory whitelist = new address[](1);
        whitelist[0] = _USER;

        address[] memory dao = new address[](1);
        dao[0] = address(this);

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: dao,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: whitelist,
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            updateMarketsBalancesAccounts: initAddress,
            updateRewardsBalanceAccounts: initAddress,
            withdrawManagerRequestFeeManagers: initAddress,
            withdrawManagerWithdrawFeeManagers: initAddress,
            priceOracleMiddlewareManagers: initAddress,
            preHooksManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0x123),
                withdrawManager: address(0x123),
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }

    function _setupDependenceBalance() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.MORPHO;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
        vm.stopPrank();
    }

    /// @dev Gives the vault real Morpho positions: 5_000 wstETH collateral and 5_000 wETH supply
    function _supplyAndCollateralizeMorpho() private {
        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction(
            _morphoCollateralFuse,
            abi.encodeWithSignature(
                "enter((bytes32,uint256))",
                MorphoCollateralFuseEnterData(_MORPHO_MARKET_ID, 5_000e18)
            )
        );
        enterCalls[1] = FuseAction(
            _morphoSupplyFuse,
            abi.encodeWithSignature("enter((bytes32,uint256))", MorphoSupplyFuseEnterData(_MORPHO_MARKET_ID, 5_000e18))
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function _authorize(address account_) private {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            _morphoAuthorizationFuse,
            abi.encodeWithSignature("enter((address))", MorphoAuthorizationFuseEnterData(account_))
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(calls);
        vm.stopPrank();
    }

    function _revoke(address account_) private {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            _morphoAuthorizationFuse,
            abi.encodeWithSignature("exit((address))", MorphoAuthorizationFuseExitData(account_))
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(calls);
        vm.stopPrank();
    }

    function _marketParams() private view returns (MarketParams memory) {
        return IMorpho(_MORPHO).idToMarketParams(Id.wrap(_MORPHO_MARKET_ID));
    }

    // -------------------------------
    // Tests
    // -------------------------------

    function testShouldAuthorizeDelegateOnEnter() external {
        // given
        assertFalse(IMorpho(_MORPHO).isAuthorized(_plasmaVault, _DELEGATE), "delegate should not be authorized yet");

        // when
        vm.expectEmit(false, false, false, true, _plasmaVault);
        emit MorphoAuthorizationFuseEnter(_morphoAuthorizationFuse, _DELEGATE, true);
        _authorize(_DELEGATE);

        // then
        assertTrue(IMorpho(_MORPHO).isAuthorized(_plasmaVault, _DELEGATE), "delegate should be authorized");
    }

    function testShouldRevokeDelegateOnExit() external {
        // given
        _authorize(_DELEGATE);
        assertTrue(IMorpho(_MORPHO).isAuthorized(_plasmaVault, _DELEGATE), "delegate should be authorized");

        // when
        vm.expectEmit(false, false, false, true, _plasmaVault);
        emit MorphoAuthorizationFuseExit(_morphoAuthorizationFuse, _DELEGATE, false);
        _revoke(_DELEGATE);

        // then
        assertFalse(IMorpho(_MORPHO).isAuthorized(_plasmaVault, _DELEGATE), "delegate should not be authorized");
    }

    function testShouldAllowDelegateToMoveSupplyAndDebt() external {
        // given
        _authorize(_DELEGATE);
        MarketParams memory marketParams = _marketParams();

        // when - delegate moves the vault's supply, collateral and debt on its behalf
        vm.startPrank(_DELEGATE);
        IMorpho(_MORPHO).withdraw(marketParams, 1_000e18, 0, _plasmaVault, _DELEGATE);
        IMorpho(_MORPHO).withdrawCollateral(marketParams, 100e18, _plasmaVault, _DELEGATE);
        IMorpho(_MORPHO).borrow(marketParams, 500e18, 0, _plasmaVault, _DELEGATE);
        vm.stopPrank();

        // then
        assertEq(ERC20(_W_ETH).balanceOf(_DELEGATE), 1_500e18, "delegate should hold withdrawn + borrowed wETH");
        assertEq(ERC20(_WST_ETH).balanceOf(_DELEGATE), 100e18, "delegate should hold withdrawn collateral");
    }

    function testShouldBlockDelegateAfterRevoke() external {
        // given
        _authorize(_DELEGATE);
        _revoke(_DELEGATE);
        MarketParams memory marketParams = _marketParams();

        // then
        vm.startPrank(_DELEGATE);
        vm.expectRevert(bytes("unauthorized"));
        IMorpho(_MORPHO).withdraw(marketParams, 1_000e18, 0, _plasmaVault, _DELEGATE);

        vm.expectRevert(bytes("unauthorized"));
        IMorpho(_MORPHO).withdrawCollateral(marketParams, 100e18, _plasmaVault, _DELEGATE);

        vm.expectRevert(bytes("unauthorized"));
        IMorpho(_MORPHO).borrow(marketParams, 500e18, 0, _plasmaVault, _DELEGATE);
        vm.stopPrank();
    }

    function testShouldNotAuthorizeAccountNotGrantedAsSubstrate() external {
        // given
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            _morphoAuthorizationFuse,
            abi.encodeWithSignature("enter((address))", MorphoAuthorizationFuseEnterData(_NOT_GRANTED))
        );

        bytes memory error = abi.encodeWithSignature(
            "MorphoAuthorizationFuseUnsupportedAccount(string,address)",
            "enter",
            _NOT_GRANTED
        );

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(calls);
        vm.stopPrank();
    }

    function testShouldNotRevokeAccountNotGrantedAsSubstrate() external {
        // given
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(
            _morphoAuthorizationFuse,
            abi.encodeWithSignature("exit((address))", MorphoAuthorizationFuseExitData(_NOT_GRANTED))
        );

        bytes memory error = abi.encodeWithSignature(
            "MorphoAuthorizationFuseUnsupportedAccount(string,address)",
            "exit",
            _NOT_GRANTED
        );

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(calls);
        vm.stopPrank();
    }

    function testShouldBeIdempotent() external {
        // when - double enter does not hit Morpho's "already set" revert
        _authorize(_DELEGATE);
        _authorize(_DELEGATE);

        // then
        assertTrue(IMorpho(_MORPHO).isAuthorized(_plasmaVault, _DELEGATE), "delegate should be authorized");

        // when - double exit, and exit after exit, do not revert either
        _revoke(_DELEGATE);
        _revoke(_DELEGATE);

        // then
        assertFalse(IMorpho(_MORPHO).isAuthorized(_plasmaVault, _DELEGATE), "delegate should not be authorized");
    }

    function testShouldExitWithoutPriorEnter() external {
        // when - revoke on a never-authorized account is a safe no-op
        _revoke(_DELEGATE);

        // then
        assertFalse(IMorpho(_MORPHO).isAuthorized(_plasmaVault, _DELEGATE), "delegate should not be authorized");
    }

    function testShouldAuthorizeAndRevokeUsingTransientStorage() external {
        // given
        address[] memory fusesToSet = new address[](1);
        fusesToSet[0] = _morphoAuthorizationFuse;

        bytes32[][] memory inputsByFuse = new bytes32[][](1);
        inputsByFuse[0] = new bytes32[](1);
        inputsByFuse[0][0] = PlasmaVaultConfigLib.addressToBytes32(_DELEGATE);

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction({
            fuse: _transientStorageSetInputsFuse,
            data: abi.encodeWithSignature(
                "enter((address[],bytes32[][]))",
                TransientStorageSetInputsFuseEnterData({fuse: fusesToSet, inputsByFuse: inputsByFuse})
            )
        });
        enterCalls[1] = FuseAction({fuse: _morphoAuthorizationFuse, data: abi.encodeWithSignature("enterTransient()")});

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        // then
        assertTrue(IMorpho(_MORPHO).isAuthorized(_plasmaVault, _DELEGATE), "delegate should be authorized");

        // when - revoke through exitTransient
        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = enterCalls[0];
        exitCalls[1] = FuseAction({fuse: _morphoAuthorizationFuse, data: abi.encodeWithSignature("exitTransient()")});

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        // then
        assertFalse(IMorpho(_MORPHO).isAuthorized(_plasmaVault, _DELEGATE), "delegate should not be authorized");
    }
}
