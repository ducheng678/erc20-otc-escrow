// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20OTCEscrow } from "../src/ERC20OTCEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { TestBase } from "./utils/TestBase.sol";

contract ERC20OTCEscrowStateMatrixTest is TestBase {
    struct Scenario {
        uint256 sellAmount;
        uint256 buyAmount;
        uint256 expiry;
    }

    struct BalanceSnapshot {
        uint256 makerSell;
        uint256 takerSell;
        uint256 makerBuy;
        uint256 takerBuy;
        uint256 escrowSell;
        uint256 escrowBuy;
    }

    ERC20OTCEscrow internal escrow;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal constant MAKER = address(0xB0B);
    address internal constant TAKER = address(0xA11CE);
    address internal constant OUTSIDER = address(0xBAD);

    function setUp() public {
        escrow = new ERC20OTCEscrow();
        sellToken = new MockERC20("Sell Token", "SELL");
        buyToken = new MockERC20("Buy Token", "BUY");
    }

    function testFuzz_AllNineTerminalActionCombinations(
        uint96 sellAmountSeed,
        uint96 buyAmountSeed,
        uint32 ttlSeed
    ) public {
        Scenario memory scenario = _scenario(sellAmountSeed, buyAmountSeed, ttlSeed);
        uint256[3][3] memory offerIds;

        sellToken.mint(MAKER, scenario.sellAmount * 9);
        buyToken.mint(TAKER, scenario.buyAmount * 3);
        _approve(sellToken, MAKER);
        _approve(buyToken, TAKER);

        for (uint256 terminal = 0; terminal < 3; ++terminal) {
            for (uint256 laterAction = 0; laterAction < 3; ++laterAction) {
                offerIds[terminal][laterAction] = _createOffer(scenario);
            }
        }

        _enterAllTerminalStates(offerIds, scenario.expiry);
        BalanceSnapshot memory balancesBefore = _snapshot();

        for (uint256 terminal = 0; terminal < 3; ++terminal) {
            ERC20OTCEscrow.OfferStatus status = ERC20OTCEscrow.OfferStatus(terminal + 1);

            for (uint256 laterAction = 0; laterAction < 3; ++laterAction) {
                uint256 offerId = offerIds[terminal][laterAction];
                _expectTerminalActionRevert(offerId, status, laterAction);
                assertEq(uint256(escrow.getOffer(offerId).status), uint256(status));
            }
        }

        _assertSnapshot(balancesBefore);
        assertEq(sellToken.balanceOf(MAKER), scenario.sellAmount * 6);
        assertEq(sellToken.balanceOf(TAKER), scenario.sellAmount * 3);
        assertEq(buyToken.balanceOf(MAKER), scenario.buyAmount * 3);
        assertEq(buyToken.balanceOf(TAKER), 0);
        assertEq(sellToken.balanceOf(address(escrow)), 0);
        assertEq(buyToken.balanceOf(address(escrow)), 0);
    }

    function testFuzz_CancelAndExpirePreserveUnrelatedDust(
        uint96 sellAmountSeed,
        uint96 buyAmountSeed,
        uint64 dustSeed,
        uint32 ttlSeed
    ) public {
        Scenario memory scenario = _scenario(sellAmountSeed, buyAmountSeed, ttlSeed);
        uint256 dust = uint256(dustSeed) + 1;
        uint256 makerBalanceBefore = scenario.sellAmount * 2;

        sellToken.mint(MAKER, makerBalanceBefore);
        sellToken.mint(address(escrow), dust);
        _approve(sellToken, MAKER);

        uint256 cancelledOfferId = _createOffer(scenario);
        uint256 expiredOfferId = _createOffer(scenario);

        vm.prank(MAKER);
        escrow.cancelOffer(cancelledOfferId);

        assertEq(
            uint256(escrow.getOffer(cancelledOfferId).status),
            uint256(ERC20OTCEscrow.OfferStatus.Cancelled)
        );
        assertEq(sellToken.balanceOf(MAKER), scenario.sellAmount);
        assertEq(sellToken.balanceOf(address(escrow)), dust + scenario.sellAmount);

        vm.warp(scenario.expiry);
        vm.prank(OUTSIDER);
        escrow.expireOffer(expiredOfferId);

        assertEq(
            uint256(escrow.getOffer(expiredOfferId).status),
            uint256(ERC20OTCEscrow.OfferStatus.Expired)
        );
        assertEq(sellToken.balanceOf(MAKER), makerBalanceBefore);
        assertEq(sellToken.balanceOf(address(escrow)), dust);
    }

    function _enterAllTerminalStates(uint256[3][3] memory offerIds, uint256 expiry) internal {
        for (uint256 laterAction = 0; laterAction < 3; ++laterAction) {
            vm.prank(TAKER);
            escrow.acceptOffer(offerIds[0][laterAction]);

            vm.prank(MAKER);
            escrow.cancelOffer(offerIds[1][laterAction]);
        }

        vm.warp(expiry);
        for (uint256 laterAction = 0; laterAction < 3; ++laterAction) {
            vm.prank(OUTSIDER);
            escrow.expireOffer(offerIds[2][laterAction]);
        }
    }

    function _expectTerminalActionRevert(
        uint256 offerId,
        ERC20OTCEscrow.OfferStatus status,
        uint256 laterAction
    ) internal {
        bytes memory expectedRevert = abi.encodeWithSelector(
            ERC20OTCEscrow.OfferNotOpen.selector, offerId, status
        );

        if (laterAction == 0) {
            vm.prank(TAKER);
            vm.expectRevert(expectedRevert);
            escrow.acceptOffer(offerId);
        } else if (laterAction == 1) {
            vm.prank(MAKER);
            vm.expectRevert(expectedRevert);
            escrow.cancelOffer(offerId);
        } else {
            vm.prank(OUTSIDER);
            vm.expectRevert(expectedRevert);
            escrow.expireOffer(offerId);
        }
    }

    function _createOffer(Scenario memory scenario) internal returns (uint256) {
        ERC20OTCEscrow.CreateOfferParams memory params = ERC20OTCEscrow.CreateOfferParams({
            allowedTaker: address(0),
            sellToken: address(sellToken),
            buyToken: address(buyToken),
            sellAmount: scenario.sellAmount,
            buyAmount: scenario.buyAmount,
            expiry: scenario.expiry
        });

        vm.prank(MAKER);
        return escrow.createOffer(params);
    }

    function _approve(MockERC20 token, address owner) internal {
        vm.prank(owner);
        token.approve(address(escrow), type(uint256).max);
    }

    function _scenario(uint96 sellAmountSeed, uint96 buyAmountSeed, uint32 ttlSeed)
        internal
        view
        returns (Scenario memory scenario)
    {
        scenario.sellAmount = uint256(sellAmountSeed) + 1;
        scenario.buyAmount = uint256(buyAmountSeed) + 1;
        scenario.expiry = block.timestamp + uint256(ttlSeed) % 365 days + 1;
    }

    function _snapshot() internal view returns (BalanceSnapshot memory balances) {
        balances.makerSell = sellToken.balanceOf(MAKER);
        balances.takerSell = sellToken.balanceOf(TAKER);
        balances.makerBuy = buyToken.balanceOf(MAKER);
        balances.takerBuy = buyToken.balanceOf(TAKER);
        balances.escrowSell = sellToken.balanceOf(address(escrow));
        balances.escrowBuy = buyToken.balanceOf(address(escrow));
    }

    function _assertSnapshot(BalanceSnapshot memory expected) internal view {
        assertEq(sellToken.balanceOf(MAKER), expected.makerSell);
        assertEq(sellToken.balanceOf(TAKER), expected.takerSell);
        assertEq(buyToken.balanceOf(MAKER), expected.makerBuy);
        assertEq(buyToken.balanceOf(TAKER), expected.takerBuy);
        assertEq(sellToken.balanceOf(address(escrow)), expected.escrowSell);
        assertEq(buyToken.balanceOf(address(escrow)), expected.escrowBuy);
    }
}
