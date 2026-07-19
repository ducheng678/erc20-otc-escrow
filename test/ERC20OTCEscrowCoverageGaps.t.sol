// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20OTCEscrow } from "../src/ERC20OTCEscrow.sol";
import { TestBase } from "./utils/TestBase.sol";

contract ERC20OTCEscrowCoverageGapsTest is TestBase {
    ERC20OTCEscrow internal escrow;

    uint256 internal constant UNKNOWN_OFFER_ID = 777;

    function setUp() public {
        escrow = new ERC20OTCEscrow();
    }

    function testGetOfferRevertsForUnknownOffer() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC20OTCEscrow.OfferNotFound.selector, UNKNOWN_OFFER_ID)
        );
        escrow.getOffer(UNKNOWN_OFFER_ID);
    }

    function testAcceptOfferRevertsForUnknownOffer() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC20OTCEscrow.OfferNotFound.selector, UNKNOWN_OFFER_ID)
        );
        escrow.acceptOffer(UNKNOWN_OFFER_ID);
    }

    function testCancelOfferRevertsForUnknownOffer() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC20OTCEscrow.OfferNotFound.selector, UNKNOWN_OFFER_ID)
        );
        escrow.cancelOffer(UNKNOWN_OFFER_ID);
    }

    function testExpireOfferRevertsForUnknownOffer() public {
        vm.expectRevert(
            abi.encodeWithSelector(ERC20OTCEscrow.OfferNotFound.selector, UNKNOWN_OFFER_ID)
        );
        escrow.expireOffer(UNKNOWN_OFFER_ID);
    }
}
