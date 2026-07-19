// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20OTCEscrow } from "../src/ERC20OTCEscrow.sol";
import { FeeOnTransferERC20 } from "./mocks/FeeOnTransferERC20.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { ReentrantERC20 } from "./mocks/ReentrantERC20.sol";
import { TestBase } from "./utils/TestBase.sol";

contract ERC20OTCEscrowTest is TestBase {
    ERC20OTCEscrow internal escrow;
    MockERC20 internal weth;
    MockERC20 internal usdc;

    address internal constant MAKER = address(0xB0B);
    address internal constant TAKER = address(0xA11CE);
    address internal constant ALLOWED_TAKER = address(0xCAFE);
    address internal constant OUTSIDER = address(0xBAD);

    uint256 internal constant SELL_AMOUNT = 0.5 ether;
    uint256 internal constant BUY_AMOUNT = 1_000e6;
    uint256 internal expiry;

    function setUp() public {
        escrow = new ERC20OTCEscrow();
        weth = new MockERC20("Wrapped Ether", "WETH");
        usdc = new MockERC20("USD Coin", "USDC");
        expiry = block.timestamp + 7 days;

        weth.mint(MAKER, 10 ether);
        usdc.mint(TAKER, 10_000e6);
        usdc.mint(ALLOWED_TAKER, 10_000e6);

        vm.prank(MAKER);
        weth.approve(address(escrow), type(uint256).max);
        vm.prank(TAKER);
        usdc.approve(address(escrow), type(uint256).max);
        vm.prank(ALLOWED_TAKER);
        usdc.approve(address(escrow), type(uint256).max);
    }

    function testMakerCreatesOfferAndLocksSellToken() public {
        uint256 makerBalanceBefore = weth.balanceOf(MAKER);

        uint256 offerId = _createOffer(_defaultParams());
        ERC20OTCEscrow.Offer memory offer = escrow.getOffer(offerId);

        assertEq(offerId, 1);
        assertEq(offer.maker, MAKER);
        assertEq(offer.allowedTaker, address(0));
        assertEq(offer.sellToken, address(weth));
        assertEq(offer.buyToken, address(usdc));
        assertEq(offer.sellAmount, SELL_AMOUNT);
        assertEq(offer.buyAmount, BUY_AMOUNT);
        assertEq(offer.expiry, expiry);
        assertEq(uint256(offer.status), uint256(ERC20OTCEscrow.OfferStatus.Open));
        assertEq(weth.balanceOf(MAKER), makerBalanceBefore - SELL_AMOUNT);
        assertEq(weth.balanceOf(address(escrow)), SELL_AMOUNT);
    }

    function testTakerAcceptsAndBothAssetsSettleAtomically() public {
        uint256 offerId = _createOffer(_defaultParams());
        uint256 takerWethBefore = weth.balanceOf(TAKER);
        uint256 takerUsdcBefore = usdc.balanceOf(TAKER);
        uint256 makerUsdcBefore = usdc.balanceOf(MAKER);

        vm.prank(TAKER);
        escrow.acceptOffer(offerId);

        ERC20OTCEscrow.Offer memory offer = escrow.getOffer(offerId);
        assertEq(uint256(offer.status), uint256(ERC20OTCEscrow.OfferStatus.Filled));
        assertEq(weth.balanceOf(TAKER), takerWethBefore + SELL_AMOUNT);
        assertEq(usdc.balanceOf(TAKER), takerUsdcBefore - BUY_AMOUNT);
        assertEq(usdc.balanceOf(MAKER), makerUsdcBefore + BUY_AMOUNT);
        assertEq(weth.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(address(escrow)), 0);
    }

    function testNonMakerCannotCancel() public {
        uint256 offerId = _createOffer(_defaultParams());

        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(ERC20OTCEscrow.NotMaker.selector, OUTSIDER, MAKER));
        escrow.cancelOffer(offerId);

        ERC20OTCEscrow.Offer memory offer = escrow.getOffer(offerId);
        assertEq(uint256(offer.status), uint256(ERC20OTCEscrow.OfferStatus.Open));
        assertEq(weth.balanceOf(address(escrow)), SELL_AMOUNT);
    }

    function testMakerCancelsOpenOfferAndGetsRefund() public {
        uint256 makerBalanceBefore = weth.balanceOf(MAKER);
        uint256 offerId = _createOffer(_defaultParams());

        vm.prank(MAKER);
        escrow.cancelOffer(offerId);

        ERC20OTCEscrow.Offer memory offer = escrow.getOffer(offerId);
        assertEq(uint256(offer.status), uint256(ERC20OTCEscrow.OfferStatus.Cancelled));
        assertEq(weth.balanceOf(MAKER), makerBalanceBefore);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function testMakerCannotCancelFilledOffer() public {
        uint256 offerId = _createOffer(_defaultParams());
        vm.prank(TAKER);
        escrow.acceptOffer(offerId);

        vm.prank(MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20OTCEscrow.OfferNotOpen.selector, offerId, ERC20OTCEscrow.OfferStatus.Filled
            )
        );
        escrow.cancelOffer(offerId);
    }

    function testCannotExpireBeforeDeadline() public {
        uint256 offerId = _createOffer(_defaultParams());

        vm.prank(OUTSIDER);
        vm.expectRevert(
            abi.encodeWithSelector(ERC20OTCEscrow.OfferNotExpired.selector, offerId, expiry)
        );
        escrow.expireOffer(offerId);
    }

    function testExpiredOfferRefundsMaker() public {
        uint256 makerBalanceBefore = weth.balanceOf(MAKER);
        uint256 offerId = _createOffer(_defaultParams());
        vm.warp(expiry);

        vm.prank(OUTSIDER);
        escrow.expireOffer(offerId);

        ERC20OTCEscrow.Offer memory offer = escrow.getOffer(offerId);
        assertEq(uint256(offer.status), uint256(ERC20OTCEscrow.OfferStatus.Expired));
        assertEq(weth.balanceOf(MAKER), makerBalanceBefore);
        assertEq(weth.balanceOf(address(escrow)), 0);
    }

    function testCannotAcceptOfferAtDeadline() public {
        uint256 offerId = _createOffer(_defaultParams());
        vm.warp(expiry);

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(ERC20OTCEscrow.OfferAlreadyExpired.selector, offerId, expiry)
        );
        escrow.acceptOffer(offerId);
    }

    function testOfferCannotBeFilledTwice() public {
        uint256 offerId = _createOffer(_defaultParams());
        vm.prank(TAKER);
        escrow.acceptOffer(offerId);

        vm.prank(ALLOWED_TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20OTCEscrow.OfferNotOpen.selector, offerId, ERC20OTCEscrow.OfferStatus.Filled
            )
        );
        escrow.acceptOffer(offerId);
    }

    function testOnlyAllowedTakerCanAcceptRestrictedOffer() public {
        ERC20OTCEscrow.CreateOfferParams memory params = _defaultParams();
        params.allowedTaker = ALLOWED_TAKER;
        uint256 offerId = _createOffer(params);

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(ERC20OTCEscrow.TakerNotAllowed.selector, TAKER, ALLOWED_TAKER)
        );
        escrow.acceptOffer(offerId);

        vm.prank(ALLOWED_TAKER);
        escrow.acceptOffer(offerId);
        assertEq(weth.balanceOf(ALLOWED_TAKER), SELL_AMOUNT);
    }

    function testZeroTokenAddressReverts() public {
        ERC20OTCEscrow.CreateOfferParams memory params = _defaultParams();
        params.sellToken = address(0);

        vm.prank(MAKER);
        vm.expectRevert(ERC20OTCEscrow.ZeroAddress.selector);
        escrow.createOffer(params);
    }

    function testZeroAmountReverts() public {
        ERC20OTCEscrow.CreateOfferParams memory params = _defaultParams();
        params.buyAmount = 0;

        vm.prank(MAKER);
        vm.expectRevert(ERC20OTCEscrow.ZeroAmount.selector);
        escrow.createOffer(params);
    }

    function testIdenticalTokensRevert() public {
        ERC20OTCEscrow.CreateOfferParams memory params = _defaultParams();
        params.buyToken = address(weth);

        vm.prank(MAKER);
        vm.expectRevert(ERC20OTCEscrow.IdenticalTokens.selector);
        escrow.createOffer(params);
    }

    function testNonFutureExpiryReverts() public {
        ERC20OTCEscrow.CreateOfferParams memory params = _defaultParams();
        params.expiry = block.timestamp;

        vm.prank(MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(ERC20OTCEscrow.InvalidExpiry.selector, block.timestamp)
        );
        escrow.createOffer(params);
    }

    function testFeeOnTransferSellTokenIsRejected() public {
        FeeOnTransferERC20 feeToken = new FeeOnTransferERC20();
        feeToken.mint(MAKER, SELL_AMOUNT);

        vm.prank(MAKER);
        feeToken.approve(address(escrow), SELL_AMOUNT);

        ERC20OTCEscrow.CreateOfferParams memory params = _defaultParams();
        params.sellToken = address(feeToken);
        uint256 received = SELL_AMOUNT - SELL_AMOUNT / 100;

        vm.prank(MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20OTCEscrow.UnexpectedTransferAmount.selector,
                address(feeToken),
                SELL_AMOUNT,
                received
            )
        );
        escrow.createOffer(params);

        assertEq(feeToken.balanceOf(MAKER), SELL_AMOUNT);
        assertEq(feeToken.balanceOf(address(escrow)), 0);
    }

    function testNonReentrantBlocksMaliciousTokenCallback() public {
        ReentrantERC20 maliciousBuyToken = new ReentrantERC20();
        maliciousBuyToken.mint(TAKER, BUY_AMOUNT);

        vm.prank(TAKER);
        maliciousBuyToken.approve(address(escrow), BUY_AMOUNT);

        ERC20OTCEscrow.CreateOfferParams memory params = _defaultParams();
        params.buyToken = address(maliciousBuyToken);
        uint256 offerId = _createOffer(params);

        maliciousBuyToken.configureCallback(
            address(escrow),
            abi.encodeWithSelector(ERC20OTCEscrow.acceptOffer.selector, offerId),
            true
        );

        vm.prank(TAKER);
        escrow.acceptOffer(offerId);

        assertFalse(maliciousBuyToken.lastCallbackSuccess());
        assertEq(
            _firstFourBytes(maliciousBuyToken.lastCallbackResult()),
            bytes4(keccak256("ReentrancyGuardReentrantCall()"))
        );
        assertEq(
            uint256(escrow.getOffer(offerId).status), uint256(ERC20OTCEscrow.OfferStatus.Filled)
        );
        assertEq(maliciousBuyToken.balanceOf(MAKER), BUY_AMOUNT);
        assertEq(weth.balanceOf(TAKER), SELL_AMOUNT);
    }

    function _createOffer(ERC20OTCEscrow.CreateOfferParams memory params)
        internal
        returns (uint256)
    {
        vm.prank(MAKER);
        return escrow.createOffer(params);
    }

    function _defaultParams() internal view returns (ERC20OTCEscrow.CreateOfferParams memory) {
        return ERC20OTCEscrow.CreateOfferParams({
            allowedTaker: address(0),
            sellToken: address(weth),
            buyToken: address(usdc),
            sellAmount: SELL_AMOUNT,
            buyAmount: BUY_AMOUNT,
            expiry: expiry
        });
    }

    function _firstFourBytes(bytes memory data) internal pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(data, 32))
        }
    }
}
