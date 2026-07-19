// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20OTCEscrow } from "../../src/ERC20OTCEscrow.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { TestBase } from "../utils/TestBase.sol";
import { ERC20OTCEscrowHandler } from "./handlers/ERC20OTCEscrowHandler.sol";

/// @dev Minimal local equivalent of forge-std's StdInvariant targeting helpers.
abstract contract InvariantTargeting {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    struct FuzzArtifactSelector {
        string artifact;
        bytes4[] selectors;
    }

    struct FuzzInterface {
        address addr;
        string[] artifacts;
    }

    address[] private _excludedContracts;
    address[] private _excludedSenders;
    address[] private _targetedContracts;
    address[] private _targetedSenders;
    string[] private _excludedArtifacts;
    string[] private _targetedArtifacts;
    FuzzArtifactSelector[] private _targetedArtifactSelectors;
    FuzzSelector[] private _excludedSelectors;
    FuzzSelector[] private _targetedSelectors;
    FuzzInterface[] private _targetedInterfaces;

    function targetContract(address newTargetedContract) internal {
        _targetedContracts.push(newTargetedContract);
    }

    function targetSelector(FuzzSelector memory newTargetedSelector) internal {
        _targetedSelectors.push(newTargetedSelector);
    }

    function excludeArtifacts() public view returns (string[] memory) {
        return _excludedArtifacts;
    }

    function excludeContracts() public view returns (address[] memory) {
        return _excludedContracts;
    }

    function excludeSelectors() public view returns (FuzzSelector[] memory) {
        return _excludedSelectors;
    }

    function excludeSenders() public view returns (address[] memory) {
        return _excludedSenders;
    }

    function targetArtifacts() public view returns (string[] memory) {
        return _targetedArtifacts;
    }

    function targetArtifactSelectors() public view returns (FuzzArtifactSelector[] memory) {
        return _targetedArtifactSelectors;
    }

    function targetContracts() public view returns (address[] memory) {
        return _targetedContracts;
    }

    function targetSelectors() public view returns (FuzzSelector[] memory) {
        return _targetedSelectors;
    }

    function targetSenders() public view returns (address[] memory) {
        return _targetedSenders;
    }

    function targetInterfaces() public view returns (FuzzInterface[] memory) {
        return _targetedInterfaces;
    }
}

contract ERC20OTCEscrowInvariantTest is TestBase, InvariantTargeting {
    ERC20OTCEscrow internal escrow;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;
    ERC20OTCEscrowHandler internal handler;
    uint256 internal seededTimestamp;

    function setUp() public {
        escrow = new ERC20OTCEscrow();
        sellToken = new MockERC20("Sell Token", "SELL");
        buyToken = new MockERC20("Buy Token", "BUY");
        handler = new ERC20OTCEscrowHandler(escrow, sellToken, buyToken);
        handler.initializeAndSeed();
        seededTimestamp = block.timestamp;

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = ERC20OTCEscrowHandler.createOfferAction.selector;
        selectors[1] = ERC20OTCEscrowHandler.acceptOfferAction.selector;
        selectors[2] = ERC20OTCEscrowHandler.cancelOfferAction.selector;
        selectors[3] = ERC20OTCEscrowHandler.expireOfferAction.selector;
        selectors[4] = ERC20OTCEscrowHandler.advanceTimeAction.selector;
        selectors[5] = ERC20OTCEscrowHandler.donateDustAction.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariant_StateAndAccountingRemainConsistent() public view {
        _assertHandlerHealth();
        _assertEscrowAccounting();
        _assertOfferLedger();
        _assertActorAccounting();
    }

    /// @dev Forge invokes this after the randomized campaign, so seeded coverage
    /// cannot make the run appear healthy if no random action made progress.
    function afterInvariant() public view {
        bool randomProgress = handler.offerCount() > 7 || handler.successfulFills() > 3
            || handler.successfulCancels() > 1 || handler.successfulExpiries() > 1
            || handler.restrictedRejects() > 1 || handler.terminalRejects() > 1
            || handler.sellDust() > 7 || handler.buyDust() > 11 || block.timestamp > seededTimestamp;
        assertFalse(!randomProgress);
    }

    function _assertHandlerHealth() internal view {
        assertFalse(handler.ghostViolation());
        assertEq(handler.unexpectedReverts(), 0);
        assertFalse(!handler.initialized());
        assertFalse(handler.successfulCreates() == 0);
        assertFalse(handler.successfulFills() == 0);
        assertFalse(handler.successfulCancels() == 0);
        assertFalse(handler.successfulExpiries() == 0);
        assertFalse(handler.restrictedRejects() == 0);
        assertFalse(handler.terminalRejects() == 0);
        assertFalse(handler.selfFills() == 0);
    }

    function _assertEscrowAccounting() internal view {
        assertEq(
            sellToken.balanceOf(address(escrow)), handler.openSellLiability() + handler.sellDust()
        );
        assertEq(buyToken.balanceOf(address(escrow)), handler.buyDust());
        assertEq(
            handler.totalEscrowed(),
            handler.openSellLiability() + handler.filledReleased() + handler.cancelledRefunded()
                + handler.expiredRefunded()
        );
    }

    function _assertOfferLedger() internal view {
        uint256 count = handler.offerCount();
        assertFalse(count == 0);

        uint256 openAmount;
        uint256 filledAmount;
        uint256 cancelledAmount;
        uint256 expiredAmount;

        for (uint256 i = 0; i < count; ++i) {
            ERC20OTCEscrowHandler.ShadowOffer memory shadow = handler.shadowOffer(i);
            ERC20OTCEscrow.Offer memory offer = escrow.getOffer(i + 1);

            assertEq(offer.maker, shadow.maker);
            assertEq(offer.allowedTaker, shadow.allowedTaker);
            assertEq(offer.sellToken, address(sellToken));
            assertEq(offer.buyToken, address(buyToken));
            assertEq(offer.sellAmount, shadow.sellAmount);
            assertEq(offer.buyAmount, shadow.buyAmount);
            assertEq(offer.expiry, shadow.expiry);
            assertEq(uint256(offer.status), uint256(shadow.status));

            if (shadow.status == ERC20OTCEscrow.OfferStatus.Open) {
                assertEq(uint256(shadow.terminalTransitions), 0);
                openAmount += shadow.sellAmount;
            } else {
                assertEq(uint256(shadow.terminalTransitions), 1);
                if (shadow.status == ERC20OTCEscrow.OfferStatus.Filled) {
                    filledAmount += shadow.sellAmount;
                } else if (shadow.status == ERC20OTCEscrow.OfferStatus.Cancelled) {
                    cancelledAmount += shadow.sellAmount;
                } else {
                    expiredAmount += shadow.sellAmount;
                }
            }
        }

        assertEq(openAmount, handler.openSellLiability());
        assertEq(filledAmount, handler.filledReleased());
        assertEq(cancelledAmount, handler.cancelledRefunded());
        assertEq(expiredAmount, handler.expiredRefunded());
        assertEq(
            openAmount + filledAmount + cancelledAmount + expiredAmount, handler.totalEscrowed()
        );
    }

    function _assertActorAccounting() internal view {
        uint256 knownSellBalance = sellToken.balanceOf(address(escrow));
        uint256 knownBuyBalance = buyToken.balanceOf(address(escrow));

        for (uint256 i = 0; i < 4; ++i) {
            address actor_ = handler.actor(i);
            uint256 actualSellBalance = sellToken.balanceOf(actor_);
            uint256 actualBuyBalance = buyToken.balanceOf(actor_);

            assertEq(actualSellBalance, handler.ghostSellBalance(i));
            assertEq(actualBuyBalance, handler.ghostBuyBalance(i));
            knownSellBalance += actualSellBalance;
            knownBuyBalance += actualBuyBalance;
        }

        assertEq(sellToken.totalSupply(), handler.totalMintedSell());
        assertEq(buyToken.totalSupply(), handler.totalMintedBuy());
        assertEq(knownSellBalance, sellToken.totalSupply());
        assertEq(knownBuyBalance, buyToken.totalSupply());
    }
}
