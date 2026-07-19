// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20OTCEscrow } from "../../../src/ERC20OTCEscrow.sol";
import { MockERC20 } from "../../mocks/MockERC20.sol";

interface VmHandler {
    function prank(address msgSender) external;
    function warp(uint256 newTimestamp) external;
}

contract ERC20OTCEscrowHandler {
    struct ShadowOffer {
        address maker;
        address allowedTaker;
        uint8 makerIndex;
        uint256 sellAmount;
        uint256 buyAmount;
        uint256 expiry;
        ERC20OTCEscrow.OfferStatus status;
        uint8 terminalTransitions;
    }

    VmHandler internal constant vm =
        VmHandler(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant ACTOR_COUNT = 4;
    uint256 internal constant INITIAL_BALANCE = 1e30;
    uint256 internal constant MAX_AMOUNT = 1e21;
    uint256 internal constant MAX_OFFERS = 32;

    ERC20OTCEscrow public immutable escrow;
    MockERC20 public immutable sellToken;
    MockERC20 public immutable buyToken;

    address[4] internal _actors;
    uint256[4] internal _ghostSellBalances;
    uint256[4] internal _ghostBuyBalances;
    ShadowOffer[] internal _shadowOffers;

    bool public initialized;
    bool public ghostViolation;
    uint256 public unexpectedReverts;

    uint256 public openSellLiability;
    uint256 public sellDust;
    uint256 public buyDust;
    uint256 public totalEscrowed;
    uint256 public filledReleased;
    uint256 public cancelledRefunded;
    uint256 public expiredRefunded;
    uint256 public totalMintedSell;
    uint256 public totalMintedBuy;

    uint256 public successfulCreates;
    uint256 public successfulFills;
    uint256 public successfulCancels;
    uint256 public successfulExpiries;
    uint256 public restrictedRejects;
    uint256 public terminalRejects;
    uint256 public selfFills;

    constructor(ERC20OTCEscrow escrow_, MockERC20 sellToken_, MockERC20 buyToken_) {
        escrow = escrow_;
        sellToken = sellToken_;
        buyToken = buyToken_;

        _actors[0] = address(0x1001);
        _actors[1] = address(0x1002);
        _actors[2] = address(0x1003);
        _actors[3] = address(0x1004);
    }

    function initializeAndSeed() external {
        if (initialized) return;
        initialized = true;

        for (uint256 i = 0; i < ACTOR_COUNT; ++i) {
            address actor_ = _actors[i];
            sellToken.mint(actor_, INITIAL_BALANCE);
            buyToken.mint(actor_, INITIAL_BALANCE);
            _ghostSellBalances[i] = INITIAL_BALANCE;
            _ghostBuyBalances[i] = INITIAL_BALANCE;

            vm.prank(actor_);
            sellToken.approve(address(escrow), type(uint256).max);
            vm.prank(actor_);
            buyToken.approve(address(escrow), type(uint256).max);
        }

        totalMintedSell = INITIAL_BALANCE * ACTOR_COUNT;
        totalMintedBuy = INITIAL_BALANCE * ACTOR_COUNT;
        _donateDust(7, 11);

        uint256 now_ = block.timestamp;

        uint256 filledOfferId = _createOffer(0, address(0), 101, 211, now_ + 30 days);
        if (filledOfferId != 0) _attemptAccept(filledOfferId, 1);

        uint256 restrictedOfferId = _createOffer(0, _actors[2], 102, 212, now_ + 30 days);
        if (restrictedOfferId != 0) {
            _attemptAccept(restrictedOfferId, 1);
            _attemptAccept(restrictedOfferId, 2);
        }

        uint256 cancelledOfferId = _createOffer(1, address(0), 103, 213, now_ + 30 days);
        if (cancelledOfferId != 0) _attemptCancel(cancelledOfferId, 1);

        uint256 expiredOfferId = _createOffer(2, address(0), 104, 214, now_ + 1);
        vm.warp(now_ + 1);
        if (expiredOfferId != 0) _attemptExpire(expiredOfferId, 3);

        if (filledOfferId != 0) _attemptAccept(filledOfferId, 1);

        uint256 selfFillOfferId = _createOffer(3, address(0), 105, 215, block.timestamp + 30 days);
        if (selfFillOfferId != 0) _attemptAccept(selfFillOfferId, 3);

        _createOffer(0, address(0), 106, 216, block.timestamp + 30 days);
        _createOffer(1, _actors[2], 107, 217, block.timestamp + 30 days);
    }

    function createOfferAction(
        uint256 makerSeed,
        uint96 sellAmountSeed,
        uint96 buyAmountSeed,
        uint32 ttlSeed,
        bool restricted,
        uint256 allowedTakerSeed
    ) external {
        if (_shadowOffers.length >= MAX_OFFERS) return;

        uint8 makerIndex = uint8(makerSeed % ACTOR_COUNT);
        address allowedTaker = restricted ? _actors[allowedTakerSeed % ACTOR_COUNT] : address(0);
        uint256 sellAmount = uint256(sellAmountSeed) % MAX_AMOUNT + 1;
        uint256 buyAmount = uint256(buyAmountSeed) % MAX_AMOUNT + 1;
        uint256 expiry = block.timestamp + uint256(ttlSeed) % 30 days + 1;

        _createOffer(makerIndex, allowedTaker, sellAmount, buyAmount, expiry);
    }

    function acceptOfferAction(uint256 offerSeed, uint256 callerSeed) external {
        if (_shadowOffers.length == 0) return;
        uint256 offerId = offerSeed % _shadowOffers.length + 1;
        _attemptAccept(offerId, uint8(callerSeed % ACTOR_COUNT));
    }

    function cancelOfferAction(uint256 offerSeed, uint256 callerSeed) external {
        if (_shadowOffers.length == 0) return;
        uint256 offerId = offerSeed % _shadowOffers.length + 1;
        _attemptCancel(offerId, uint8(callerSeed % ACTOR_COUNT));
    }

    function expireOfferAction(uint256 offerSeed, uint256 callerSeed) external {
        if (_shadowOffers.length == 0) return;
        uint256 offerId = offerSeed % _shadowOffers.length + 1;
        _attemptExpire(offerId, uint8(callerSeed % ACTOR_COUNT));
    }

    function advanceTimeAction(uint32 deltaSeed) external {
        uint256 delta = uint256(deltaSeed) % 3 days + 1;
        vm.warp(block.timestamp + delta);
    }

    function donateDustAction(uint64 sellDustSeed, uint64 buyDustSeed) external {
        _donateDust(uint256(sellDustSeed) + 1, uint256(buyDustSeed) + 1);
    }

    function offerCount() external view returns (uint256) {
        return _shadowOffers.length;
    }

    function shadowOffer(uint256 index) external view returns (ShadowOffer memory) {
        return _shadowOffers[index];
    }

    function actor(uint256 index) external view returns (address) {
        return _actors[index];
    }

    function ghostSellBalance(uint256 index) external view returns (uint256) {
        return _ghostSellBalances[index];
    }

    function ghostBuyBalance(uint256 index) external view returns (uint256) {
        return _ghostBuyBalances[index];
    }

    function _createOffer(
        uint8 makerIndex,
        address allowedTaker,
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 expiry
    ) internal returns (uint256 offerId) {
        if (_shadowOffers.length >= MAX_OFFERS) return 0;

        ERC20OTCEscrow.CreateOfferParams memory params = ERC20OTCEscrow.CreateOfferParams({
            allowedTaker: allowedTaker,
            sellToken: address(sellToken),
            buyToken: address(buyToken),
            sellAmount: sellAmount,
            buyAmount: buyAmount,
            expiry: expiry
        });

        vm.prank(_actors[makerIndex]);
        (bool success, bytes memory result) = address(escrow)
            .call(abi.encodeWithSelector(ERC20OTCEscrow.createOffer.selector, params));

        if (!success || result.length < 32) {
            ghostViolation = true;
            ++unexpectedReverts;
            return 0;
        }

        offerId = abi.decode(result, (uint256));
        if (offerId != _shadowOffers.length + 1) {
            ghostViolation = true;
            return 0;
        }

        _shadowOffers.push(
            ShadowOffer({
                maker: _actors[makerIndex],
                allowedTaker: allowedTaker,
                makerIndex: makerIndex,
                sellAmount: sellAmount,
                buyAmount: buyAmount,
                expiry: expiry,
                status: ERC20OTCEscrow.OfferStatus.Open,
                terminalTransitions: 0
            })
        );

        _ghostSellBalances[makerIndex] -= sellAmount;
        openSellLiability += sellAmount;
        totalEscrowed += sellAmount;
        ++successfulCreates;
    }

    function _attemptAccept(uint256 offerId, uint8 callerIndex) internal {
        ShadowOffer storage shadow = _shadowOffers[offerId - 1];
        address caller = _actors[callerIndex];
        bool shouldSucceed;
        bytes4 expectedError;

        if (shadow.status != ERC20OTCEscrow.OfferStatus.Open) {
            expectedError = ERC20OTCEscrow.OfferNotOpen.selector;
        } else if (block.timestamp >= shadow.expiry) {
            expectedError = ERC20OTCEscrow.OfferAlreadyExpired.selector;
        } else if (shadow.allowedTaker != address(0) && caller != shadow.allowedTaker) {
            expectedError = ERC20OTCEscrow.TakerNotAllowed.selector;
        } else {
            shouldSucceed = true;
        }

        vm.prank(caller);
        (bool success, bytes memory result) = address(escrow)
            .call(abi.encodeWithSelector(ERC20OTCEscrow.acceptOffer.selector, offerId));

        if (!shouldSucceed) {
            _recordExpectedFailure(success, result, expectedError);
            return;
        }
        if (!success) {
            ghostViolation = true;
            ++unexpectedReverts;
            return;
        }

        shadow.status = ERC20OTCEscrow.OfferStatus.Filled;
        ++shadow.terminalTransitions;
        openSellLiability -= shadow.sellAmount;
        filledReleased += shadow.sellAmount;
        _ghostBuyBalances[callerIndex] -= shadow.buyAmount;
        _ghostBuyBalances[shadow.makerIndex] += shadow.buyAmount;
        _ghostSellBalances[callerIndex] += shadow.sellAmount;
        ++successfulFills;
        if (callerIndex == shadow.makerIndex) ++selfFills;
    }

    function _attemptCancel(uint256 offerId, uint8 callerIndex) internal {
        ShadowOffer storage shadow = _shadowOffers[offerId - 1];
        address caller = _actors[callerIndex];
        bool shouldSucceed;
        bytes4 expectedError;

        if (shadow.status != ERC20OTCEscrow.OfferStatus.Open) {
            expectedError = ERC20OTCEscrow.OfferNotOpen.selector;
        } else if (caller != shadow.maker) {
            expectedError = ERC20OTCEscrow.NotMaker.selector;
        } else if (block.timestamp >= shadow.expiry) {
            expectedError = ERC20OTCEscrow.OfferAlreadyExpired.selector;
        } else {
            shouldSucceed = true;
        }

        vm.prank(caller);
        (bool success, bytes memory result) = address(escrow)
            .call(abi.encodeWithSelector(ERC20OTCEscrow.cancelOffer.selector, offerId));

        if (!shouldSucceed) {
            _recordExpectedFailure(success, result, expectedError);
            return;
        }
        if (!success) {
            ghostViolation = true;
            ++unexpectedReverts;
            return;
        }

        shadow.status = ERC20OTCEscrow.OfferStatus.Cancelled;
        ++shadow.terminalTransitions;
        openSellLiability -= shadow.sellAmount;
        cancelledRefunded += shadow.sellAmount;
        _ghostSellBalances[shadow.makerIndex] += shadow.sellAmount;
        ++successfulCancels;
    }

    function _attemptExpire(uint256 offerId, uint8 callerIndex) internal {
        ShadowOffer storage shadow = _shadowOffers[offerId - 1];
        bool shouldSucceed;
        bytes4 expectedError;

        if (shadow.status != ERC20OTCEscrow.OfferStatus.Open) {
            expectedError = ERC20OTCEscrow.OfferNotOpen.selector;
        } else if (block.timestamp < shadow.expiry) {
            expectedError = ERC20OTCEscrow.OfferNotExpired.selector;
        } else {
            shouldSucceed = true;
        }

        vm.prank(_actors[callerIndex]);
        (bool success, bytes memory result) = address(escrow)
            .call(abi.encodeWithSelector(ERC20OTCEscrow.expireOffer.selector, offerId));

        if (!shouldSucceed) {
            _recordExpectedFailure(success, result, expectedError);
            return;
        }
        if (!success) {
            ghostViolation = true;
            ++unexpectedReverts;
            return;
        }

        shadow.status = ERC20OTCEscrow.OfferStatus.Expired;
        ++shadow.terminalTransitions;
        openSellLiability -= shadow.sellAmount;
        expiredRefunded += shadow.sellAmount;
        _ghostSellBalances[shadow.makerIndex] += shadow.sellAmount;
        ++successfulExpiries;
    }

    function _donateDust(uint256 sellAmount, uint256 buyAmount) internal {
        sellToken.mint(address(escrow), sellAmount);
        buyToken.mint(address(escrow), buyAmount);
        sellDust += sellAmount;
        buyDust += buyAmount;
        totalMintedSell += sellAmount;
        totalMintedBuy += buyAmount;
    }

    function _recordExpectedFailure(bool success, bytes memory result, bytes4 expectedError)
        internal
    {
        if (success || _firstFourBytes(result) != expectedError) {
            ghostViolation = true;
            return;
        }

        if (expectedError == ERC20OTCEscrow.TakerNotAllowed.selector) {
            ++restrictedRejects;
        } else if (expectedError == ERC20OTCEscrow.OfferNotOpen.selector) {
            ++terminalRejects;
        }
    }

    function _firstFourBytes(bytes memory data) internal pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(data, 32))
        }
    }
}
