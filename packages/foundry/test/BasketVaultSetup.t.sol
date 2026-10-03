// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { BasketVault } from "../contracts/BasketVault.sol";
import { MockHtsToken } from "./mocks/MockHtsToken.sol";
import { MockShareToken } from "./mocks/MockHederaSystem.sol";
import { MockPool } from "./mocks/MockSaucerSwap.sol";
import { BasketVaultBase } from "./BasketVaultBase.sol";

contract BasketVaultConstructorTest is BasketVaultBase {
    function _expectBadConfig() internal {
        vm.expectRevert(BasketVault.BadConfig.selector);
    }

    function test_constructor_storesConfigAndWeights() public view {
        assertEq(address(vault.router()), address(router));
        assertEq(address(vault.whbarHelper()), address(helper));
        assertEq(vault.whbar(), WHBAR_ADDR);
        assertEq(address(vault.hbarUsdFeed()), address(feed));
        assertEq(vault.maxOracleAge(), MAX_ORACLE_AGE);
        assertEq(vault.driftBps(), DRIFT_BPS);
        assertEq(vault.slippageBps(), SLIPPAGE_BPS);
        assertEq(vault.scheduledGas(), SCHEDULED_GAS);
        assertEq(vault.guardLeg(), 1);
        assertEq(vault.maxDeviationBps(), GUARD_DEVIATION_BPS);
        assertEq(vault.owner(), owner);
        assertEq(vault.whbarWeightBps(), 4000);

        BasketVault.Leg[] memory legs = vault.legs();
        assertEq(legs.length, 2);
        assertEq(legs[0].token, SAUCE_ADDR);
        assertEq(legs[0].pool, address(saucePool));
        assertEq(legs[0].fee, SAUCE_FEE);
        assertEq(legs[0].weightBps, 3000);
        assertFalse(legs[0].tokenIsToken0, "SAUCE sorts above WHBAR so it is token1");
        assertEq(legs[1].token, USDC_ADDR);
        assertEq(legs[1].fee, USDC_FEE);
        assertTrue(legs[1].tokenIsToken0, "USDC sorts below WHBAR so it is token0");
    }

    function test_constructor_rejectsZeroAddresses() public {
        BasketVault.Config memory c = _config();
        c.router = address(0);
        _expectBadConfig();
        _deployVault(c, _legs());

        c = _config();
        c.whbarHelper = address(0);
        _expectBadConfig();
        _deployVault(c, _legs());

        c = _config();
        c.whbar = address(0);
        _expectBadConfig();
        _deployVault(c, _legs());

        c = _config();
        c.hbarUsdFeed = address(0);
        _expectBadConfig();
        _deployVault(c, _legs());
    }

    function test_constructor_rejectsNoLegs() public {
        _expectBadConfig();
        _deployVault(_config(), new BasketVault.LegConfig[](0));
    }

    function test_constructor_rejectsPoolNotPairedWithWhbar() public {
        // A SAUCE/USDC pool holds the leg token but not WHBAR.
        MockPool wrong = new MockPool(SAUCE_ADDR, USDC_ADDR, 3000);
        BasketVault.LegConfig[] memory legs = _legs();
        legs[0].pool = address(wrong);
        _expectBadConfig();
        _deployVault(_config(), legs);
    }

    function test_constructor_rejectsPoolThatDoesNotHoldTheLegToken() public {
        // WHBAR/SAUCE pool configured for the USDC leg: WHBAR is present, USDC is not.
        BasketVault.LegConfig[] memory legs = _legs();
        legs[1].pool = address(saucePool);
        _expectBadConfig();
        _deployVault(_config(), legs);
    }

    function test_constructor_rejectsWeightsThatLeaveNothingForWhbar() public {
        BasketVault.LegConfig[] memory legs = _legs();
        legs[0].weightBps = 6000; // 6000 + 3000 = 9000, fine
        _deployVault(_config(), legs);

        legs[0].weightBps = 7000; // exactly 10000: WHBAR would get zero
        _expectBadConfig();
        _deployVault(_config(), legs);
    }

    function test_constructor_rejectsWeightsAboveOneHundredPercent() public {
        BasketVault.LegConfig[] memory legs = _legs();
        legs[0].weightBps = 8000;
        _expectBadConfig();
        _deployVault(_config(), legs);
    }

    function test_constructor_acceptsWeightsThatLeaveOneBasisPointForWhbar() public {
        BasketVault.LegConfig[] memory legs = _legs();
        legs[0].weightBps = 6999;
        BasketVault v = _deployVault(_config(), legs);
        assertEq(v.whbarWeightBps(), 1);
    }

    function test_constructor_rejectsZeroWeight() public {
        BasketVault.LegConfig[] memory legs = _legs();
        legs[1].weightBps = 0;
        _expectBadConfig();
        _deployVault(_config(), legs);
    }

    function test_constructor_rejectsScheduledGasBelowThreeMillion() public {
        BasketVault.Config memory c = _config();
        c.scheduledGas = 2_999_999;
        _expectBadConfig();
        _deployVault(c, _legs());

        c.scheduledGas = 3_000_000;
        BasketVault v = _deployVault(c, _legs());
        assertEq(v.scheduledGas(), 3_000_000);
    }

    function test_constructor_rejectsGuardLegOutOfRange() public {
        BasketVault.Config memory c = _config();
        c.guardLeg = 2; // two legs: valid indices are 0 and 1
        _expectBadConfig();
        _deployVault(c, _legs());

        c.guardLeg = 1;
        _deployVault(c, _legs());
    }

    function test_constructor_acceptsNoGuardLeg() public {
        BasketVault.Config memory c = _config();
        c.guardLeg = type(uint256).max;
        BasketVault v = _deployVault(c, _legs());
        assertEq(v.guardLeg(), type(uint256).max);
    }

    function test_constructor_rejectsSlippageAtOrAboveOneHundredPercent() public {
        BasketVault.Config memory c = _config();
        c.slippageBps = 10_000;
        _expectBadConfig();
        _deployVault(c, _legs());

        c.slippageBps = 9_999;
        _deployVault(c, _legs());
    }

    function test_constructor_rejectsDriftZeroOrAboveOneHundredPercent() public {
        BasketVault.Config memory c = _config();
        c.driftBps = 0;
        _expectBadConfig();
        _deployVault(c, _legs());

        c.driftBps = 10_000;
        _expectBadConfig();
        _deployVault(c, _legs());

        c.driftBps = 9_999;
        _deployVault(c, _legs());
    }
}

contract BasketVaultInitializeTest is BasketVaultBase {
    BasketVault internal fresh;

    function setUp() public override {
        super.setUp();
        fresh = _deployVault(_config(), _legs());
        vm.deal(owner, 100e8);
    }

    function test_initialize_associatesEveryTokenAndCreatesShareToken() public {
        assertEq(fresh.shareToken(), address(0));
        assertFalse(whbar.associated(address(fresh)));
        assertFalse(sauce.associated(address(fresh)));
        assertFalse(usdc.associated(address(fresh)));

        vm.recordLogs();
        vm.prank(owner);
        fresh.initialize{ value: INIT_VALUE }("Index", "IDX");

        assertTrue(whbar.associated(address(fresh)));
        assertTrue(sauce.associated(address(fresh)));
        assertTrue(usdc.associated(address(fresh)));

        MockShareToken s = MockShareToken(fresh.shareToken());
        assertTrue(address(s) != address(0));
        assertEq(address(s), hts.lastCreated());
        assertEq(s.name(), "Index");
        assertEq(s.symbol(), "IDX");
        assertEq(s.decimals(), 8);
        assertEq(s.treasury(), address(fresh));
        assertEq(s.totalSupply(), 0);
        assertEq(hts.supplyKeyHolder(address(s)), address(fresh), "the vault holds the supply key");
        assertEq(hts.lastKeyType(), 16);
        assertEq(hts.lastAutoRenewAccount(), address(fresh));
        assertFalse(hts.lastFiniteSupply(), "infinite supply");
        assertEq(hts.lastInitialSupply(), 0);
        assertEq(hts.createCount(), 2, "one for the fixture vault and one for this one");
    }

    function test_initialize_forwardsValueToHtsAndKeepsTheRestAsFuel() public {
        vm.prank(owner);
        fresh.initialize{ value: INIT_VALUE }("Index", "IDX");
        assertEq(hts.lastCreateValue(), INIT_VALUE);
        assertEq(address(fresh).balance, INIT_VALUE - CREATE_FEE, "what HTS does not take stays in the vault");
    }

    function test_initialize_revertsWhenHtsRefusesTheCreationFee() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.HtsCallFailed.selector, int64(9)));
        fresh.initialize{ value: CREATE_FEE - 1 }("Index", "IDX");
        assertEq(fresh.shareToken(), address(0));
    }

    function test_initialize_revertsWhenCreateFails() public {
        hts.setForcedCodes(int64(167), 0, 0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.HtsCallFailed.selector, int64(167)));
        fresh.initialize{ value: INIT_VALUE }("Index", "IDX");
    }

    function test_initialize_toleratesTokensAlreadyAssociated() public {
        vm.prank(address(fresh));
        whbar.associate();
        vm.prank(address(fresh));
        usdc.associate();
        vm.prank(owner);
        fresh.initialize{ value: INIT_VALUE }("Index", "IDX");
        assertTrue(fresh.shareToken() != address(0));
    }

    function test_initialize_revertsWhenAssociationFails() public {
        sauce.setForcedAssociateCode(int64(184));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BasketVault.HtsCallFailed.selector, int64(184)));
        fresh.initialize{ value: INIT_VALUE }("Index", "IDX");
    }

    function test_initialize_cannotRunTwice() public {
        vm.prank(owner);
        fresh.initialize{ value: INIT_VALUE }("Index", "IDX");
        address first = fresh.shareToken();

        vm.prank(owner);
        vm.expectRevert(BasketVault.AlreadyInitialized.selector);
        fresh.initialize{ value: INIT_VALUE }("Other", "OTH");
        assertEq(fresh.shareToken(), first, "the share token is not replaced");
        assertEq(hts.createCount(), 2);
    }

    function test_initialize_onlyOwner() public {
        vm.deal(alice, INIT_VALUE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        fresh.initialize{ value: INIT_VALUE }("Index", "IDX");
        assertEq(fresh.shareToken(), address(0));
    }

    function test_depositAndRedeem_requireInitialization() public {
        vm.prank(alice);
        vm.expectRevert(BasketVault.NotInitialized.selector);
        fresh.deposit{ value: 1e8 }(0);

        vm.prank(alice);
        vm.expectRevert(BasketVault.NotInitialized.selector);
        fresh.redeem(1);
    }
}
