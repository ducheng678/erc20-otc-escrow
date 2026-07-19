// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20OTCEscrow } from "../src/ERC20OTCEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { TestBase } from "./utils/TestBase.sol";

interface VmFuzz {
    function assume(bool condition) external;
}

contract ERC20OTCEscrowFuzzTest is TestBase {
    struct Scenario {
        uint256 sellAmount;
        uint256 buyAmount;
        uint256 expiry;
        uint256 sellDust;
        uint256 buyDust;
    }

    struct BalanceSnapshot {
        uint256 makerSell;
        uint256 takerSell;
        uint256 makerBuy;
        uint256 takerBuy;
        uint256 escrowSell;
        uint256 escrowBuy;
    }

    VmFuzz internal constant vmFuzz =
        VmFuzz(address(uint160(uint256(keccak256("hevm cheat code")))));

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

    function testFuzz_CreateOfferLocksExactTermsAndIdsAreMonotonic(
        uint96 sellAmountSeed,
        uint96 buyAmountSeed,
        uint32 ttlSeed,
        address allowedTaker
    ) public {
        Scenario memory scenario = _scenario(sellAmountSeed, buyAmountSeed, ttlSeed);

        sellToken.mint(MAKER, scenario.sellAmount * 2);
        _approve(sellToken, MAKER, type(uint256).max);

        uint256 firstOfferId = _createOffer(MAKER, allowedTaker, scenario);
        uint256 secondOfferId = _createOffer(MAKER, allowedTaker, scenario);
        ERC20OTCEscrow.Offer memory offer = escrow.getOffer(secondOfferId);

        assertEq(firstOfferId, 1);
        assertEq(secondOfferId, firstOfferId + 1);
        assertEq(offer.maker, MAKER);
        assertEq(offer.allowedTaker, allowedTaker);
        assertEq(offer.sellToken, address(sellToken));
        assertEq(offer.buyToken, address(buyToken));
        assertEq(offer.sellAmount, scenario.sellAmount);
        assertEq(offer.buyAmount, scenario.buyAmount);
        assertEq(offer.expiry, scenario.expiry);
        assertEq(uint256(offer.status), uint256(ERC20OTCEscrow.OfferStatus.Open));
        assertEq(sellToken.balanceOf(MAKER), 0);
        assertEq(sellToken.balanceOf(address(escrow)), scenario.sellAmount * 2);
    }

    function testFuzz_AcceptOfferConservesAssetsWithPreexistingDust(
        address maker,
        address taker,
        uint96 sellAmountSeed,
        uint96 buyAmountSeed,
        uint64 sellDustSeed,
        uint64 buyDustSeed,
        uint32 ttlSeed
    ) public {
        _assumeActor(maker);
        _assumeActor(taker);
        vmFuzz.assume(maker != taker);

        Scenario memory scenario = _scenario(sellAmountSeed, buyAmountSeed, ttlSeed);
        scenario.sellDust = uint256(sellDustSeed);
        scenario.buyDust = uint256(buyDustSeed);

        sellToken.mint(maker, scenario.sellAmount);
        buyToken.mint(taker, scenario.buyAmount);
        sellToken.mint(address(escrow), scenario.sellDust);
        buyToken.mint(address(escrow), scenario.buyDust);
        _approve(sellToken, maker, type(uint256).max);
        _approve(buyToken, taker, type(uint256).max);

        BalanceSnapshot memory balancesBefore = _snapshot(maker, taker);
        uint256 offerId = _createOffer(maker, taker, scenario);

        vm.prank(taker);
        escrow.acceptOffer(offerId);

        assertEq(
            uint256(escrow.getOffer(offerId).status), uint256(ERC20OTCEscrow.OfferStatus.Filled)
        );
        assertEq(sellToken.balanceOf(maker), balancesBefore.makerSell - scenario.sellAmount);
        assertEq(sellToken.balanceOf(taker), balancesBefore.takerSell + scenario.sellAmount);
        assertEq(buyToken.balanceOf(taker), balancesBefore.takerBuy - scenario.buyAmount);
        assertEq(buyToken.balanceOf(maker), balancesBefore.makerBuy + scenario.buyAmount);
        assertEq(sellToken.balanceOf(address(escrow)), balancesBefore.escrowSell);
        assertEq(buyToken.balanceOf(address(escrow)), balancesBefore.escrowBuy);
        assertEq(sellToken.totalSupply(), scenario.sellAmount + scenario.sellDust);
        assertEq(buyToken.totalSupply(), scenario.buyAmount + scenario.buyDust);
    }

    function testFuzz_RestrictedOfferRejectsOtherTakerThenAllowsDesignatedTaker(
        address maker,
        address allowedTaker,
        address otherTaker,
        uint96 sellAmountSeed,
        uint96 buyAmountSeed,
        uint32 ttlSeed
    ) public {
        _assumeActor(maker);
        _assumeActor(allowedTaker);
        _assumeActor(otherTaker);
        vmFuzz.assume(maker != allowedTaker);
        vmFuzz.assume(maker != otherTaker);
        vmFuzz.assume(allowedTaker != otherTaker);

        Scenario memory scenario = _scenario(sellAmountSeed, buyAmountSeed, ttlSeed);

        sellToken.mint(maker, scenario.sellAmount);
        buyToken.mint(allowedTaker, scenario.buyAmount);
        buyToken.mint(otherTaker, scenario.buyAmount);
        _approve(sellToken, maker, type(uint256).max);
        _approve(buyToken, allowedTaker, type(uint256).max);
        _approve(buyToken, otherTaker, type(uint256).max);

        uint256 offerId = _createOffer(maker, allowedTaker, scenario);
        BalanceSnapshot memory balancesBefore = _snapshot(maker, otherTaker);
        uint256 allowanceBefore = buyToken.allowance(otherTaker, address(escrow));

        vm.prank(otherTaker);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20OTCEscrow.TakerNotAllowed.selector, otherTaker, allowedTaker
            )
        );
        escrow.acceptOffer(offerId);

        assertEq(uint256(escrow.getOffer(offerId).status), uint256(ERC20OTCEscrow.OfferStatus.Open));
        _assertSnapshot(maker, otherTaker, balancesBefore);
        assertEq(buyToken.allowance(otherTaker, address(escrow)), allowanceBefore);

        vm.prank(allowedTaker);
        escrow.acceptOffer(offerId);

        assertEq(
            uint256(escrow.getOffer(offerId).status), uint256(ERC20OTCEscrow.OfferStatus.Filled)
        );
        assertEq(sellToken.balanceOf(allowedTaker), scenario.sellAmount);
        assertEq(buyToken.balanceOf(maker), scenario.buyAmount);
        assertEq(sellToken.balanceOf(address(escrow)), 0);
        assertEq(buyToken.balanceOf(address(escrow)), 0);
    }

    function testFuzz_ExpiryBoundaryIsExact(
        uint96 sellAmountSeed,
        uint96 buyAmountSeed,
        uint32 ttlSeed
    ) public {
        Scenario memory scenario = _scenario(sellAmountSeed, buyAmountSeed, ttlSeed);

        sellToken.mint(MAKER, scenario.sellAmount * 3);
        buyToken.mint(TAKER, scenario.buyAmount);
        _approve(sellToken, MAKER, type(uint256).max);
        _approve(buyToken, TAKER, type(uint256).max);

        uint256 filledOfferId = _createOffer(MAKER, address(0), scenario);
        uint256 cancelledOfferId = _createOffer(MAKER, address(0), scenario);
        uint256 expiredOfferId = _createOffer(MAKER, address(0), scenario);

        vm.warp(scenario.expiry - 1);

        vm.prank(OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20OTCEscrow.OfferNotExpired.selector, expiredOfferId, scenario.expiry
            )
        );
        escrow.expireOffer(expiredOfferId);

        vm.prank(TAKER);
        escrow.acceptOffer(filledOfferId);

        vm.prank(MAKER);
        escrow.cancelOffer(cancelledOfferId);

        vm.warp(scenario.expiry);

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20OTCEscrow.OfferAlreadyExpired.selector, expiredOfferId, scenario.expiry
            )
        );
        escrow.acceptOffer(expiredOfferId);

        vm.prank(MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20OTCEscrow.OfferAlreadyExpired.selector, expiredOfferId, scenario.expiry
            )
        );
        escrow.cancelOffer(expiredOfferId);

        vm.prank(OUTSIDER);
        escrow.expireOffer(expiredOfferId);

        assertEq(
            uint256(escrow.getOffer(filledOfferId).status),
            uint256(ERC20OTCEscrow.OfferStatus.Filled)
        );
        assertEq(
            uint256(escrow.getOffer(cancelledOfferId).status),
            uint256(ERC20OTCEscrow.OfferStatus.Cancelled)
        );
        assertEq(
            uint256(escrow.getOffer(expiredOfferId).status),
            uint256(ERC20OTCEscrow.OfferStatus.Expired)
        );
        assertEq(sellToken.balanceOf(MAKER), scenario.sellAmount * 2);
        assertEq(sellToken.balanceOf(TAKER), scenario.sellAmount);
        assertEq(sellToken.balanceOf(address(escrow)), 0);
        assertEq(buyToken.balanceOf(MAKER), scenario.buyAmount);
        assertEq(buyToken.balanceOf(TAKER), 0);
        assertEq(buyToken.balanceOf(address(escrow)), 0);
    }

    function testFuzz_TerminalStateRejectsEveryLaterAction(
        uint8 terminalSeed,
        uint8 laterActionSeed,
        uint96 sellAmountSeed,
        uint96 buyAmountSeed,
        uint32 ttlSeed
    ) public {
        uint8 terminal = terminalSeed % 3;
        uint8 laterAction = laterActionSeed % 3;
        Scenario memory scenario = _scenario(sellAmountSeed, buyAmountSeed, ttlSeed);

        sellToken.mint(MAKER, scenario.sellAmount);
        buyToken.mint(TAKER, scenario.buyAmount);
        _approve(sellToken, MAKER, type(uint256).max);
        _approve(buyToken, TAKER, type(uint256).max);

        uint256 offerId = _createOffer(MAKER, address(0), scenario);
        ERC20OTCEscrow.OfferStatus expectedStatus;

        if (terminal == 0) {
            vm.prank(TAKER);
            escrow.acceptOffer(offerId);
            expectedStatus = ERC20OTCEscrow.OfferStatus.Filled;
        } else if (terminal == 1) {
            vm.prank(MAKER);
            escrow.cancelOffer(offerId);
            expectedStatus = ERC20OTCEscrow.OfferStatus.Cancelled;
        } else {
            vm.warp(scenario.expiry);
            vm.prank(OUTSIDER);
            escrow.expireOffer(offerId);
            expectedStatus = ERC20OTCEscrow.OfferStatus.Expired;
        }

        BalanceSnapshot memory balancesBefore = _snapshot(MAKER, TAKER);
        bytes memory expectedRevert =
            abi.encodeWithSelector(ERC20OTCEscrow.OfferNotOpen.selector, offerId, expectedStatus);

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

        assertEq(uint256(escrow.getOffer(offerId).status), uint256(expectedStatus));
        _assertSnapshot(MAKER, TAKER, balancesBefore);
    }

    function testFuzz_FailedBuyTransferRollsBackAtomically(
        uint8 failureModeSeed,
        uint96 sellAmountSeed,
        uint96 buyAmountSeed,
        uint64 sellDustSeed,
        uint64 buyDustSeed,
        uint32 ttlSeed
    ) public {
        uint8 failureMode = failureModeSeed % 2;
        Scenario memory scenario = _scenario(sellAmountSeed, buyAmountSeed, ttlSeed);
        scenario.sellDust = uint256(sellDustSeed);
        scenario.buyDust = uint256(buyDustSeed);
        uint256 availableBuyAmount = scenario.buyAmount - 1;

        sellToken.mint(MAKER, scenario.sellAmount);
        sellToken.mint(address(escrow), scenario.sellDust);
        buyToken.mint(address(escrow), scenario.buyDust);
        _approve(sellToken, MAKER, type(uint256).max);

        if (failureMode == 0) {
            buyToken.mint(TAKER, availableBuyAmount);
            _approve(buyToken, TAKER, scenario.buyAmount);
        } else {
            buyToken.mint(TAKER, scenario.buyAmount);
            _approve(buyToken, TAKER, availableBuyAmount);
        }

        uint256 offerId = _createOffer(MAKER, address(0), scenario);
        BalanceSnapshot memory balancesBefore = _snapshot(MAKER, TAKER);
        uint256 allowanceBefore = buyToken.allowance(TAKER, address(escrow));

        vm.prank(TAKER);
        if (failureMode == 0) {
            vm.expectRevert(
                abi.encodeWithSignature(
                    "ERC20InsufficientBalance(address,uint256,uint256)",
                    TAKER,
                    availableBuyAmount,
                    scenario.buyAmount
                )
            );
        } else {
            vm.expectRevert(
                abi.encodeWithSignature(
                    "ERC20InsufficientAllowance(address,uint256,uint256)",
                    address(escrow),
                    availableBuyAmount,
                    scenario.buyAmount
                )
            );
        }
        escrow.acceptOffer(offerId);

        assertEq(uint256(escrow.getOffer(offerId).status), uint256(ERC20OTCEscrow.OfferStatus.Open));
        _assertSnapshot(MAKER, TAKER, balancesBefore);
        assertEq(buyToken.allowance(TAKER, address(escrow)), allowanceBefore);
        assertEq(balancesBefore.escrowSell, scenario.sellDust + scenario.sellAmount);
    }

    function _createOffer(address maker, address allowedTaker, Scenario memory scenario)
        internal
        returns (uint256)
    {
        ERC20OTCEscrow.CreateOfferParams memory params = ERC20OTCEscrow.CreateOfferParams({
            allowedTaker: allowedTaker,
            sellToken: address(sellToken),
            buyToken: address(buyToken),
            sellAmount: scenario.sellAmount,
            buyAmount: scenario.buyAmount,
            expiry: scenario.expiry
        });

        vm.prank(maker);
        return escrow.createOffer(params);
    }

    function _approve(MockERC20 token, address owner, uint256 amount) internal {
        vm.prank(owner);
        token.approve(address(escrow), amount);
    }

    function _assumeActor(address actor) internal {
        vmFuzz.assume(actor != address(0));
        vmFuzz.assume(actor != address(this));
        vmFuzz.assume(actor != address(escrow));
        vmFuzz.assume(actor != address(sellToken));
        vmFuzz.assume(actor != address(buyToken));
        vmFuzz.assume(actor != address(vmFuzz));
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

    function _snapshot(address maker, address taker)
        internal
        view
        returns (BalanceSnapshot memory balances)
    {
        balances.makerSell = sellToken.balanceOf(maker);
        balances.takerSell = sellToken.balanceOf(taker);
        balances.makerBuy = buyToken.balanceOf(maker);
        balances.takerBuy = buyToken.balanceOf(taker);
        balances.escrowSell = sellToken.balanceOf(address(escrow));
        balances.escrowBuy = buyToken.balanceOf(address(escrow));
    }

    function _assertSnapshot(address maker, address taker, BalanceSnapshot memory expected)
        internal
        view
    {
        assertEq(sellToken.balanceOf(maker), expected.makerSell);
        assertEq(sellToken.balanceOf(taker), expected.takerSell);
        assertEq(buyToken.balanceOf(maker), expected.makerBuy);
        assertEq(buyToken.balanceOf(taker), expected.takerBuy);
        assertEq(sellToken.balanceOf(address(escrow)), expected.escrowSell);
        assertEq(buyToken.balanceOf(address(escrow)), expected.escrowBuy);
    }
}
