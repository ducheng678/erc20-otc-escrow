// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ERC20 OTC Escrow
/// @notice Fixed-price escrow for atomic swaps between two ERC-20 tokens.
/// @dev The contract is intended for standard ERC-20 tokens. Rebasing and
/// fee-on-transfer tokens are not supported.
contract ERC20OTCEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum OfferStatus {
        Open,
        Filled,
        Cancelled,
        Expired
    }

    struct Offer {
        address maker;
        address allowedTaker;
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        uint256 expiry;
        OfferStatus status;
    }

    /// @dev A struct input keeps offer creation readable and demonstrates calldata usage.
    struct CreateOfferParams {
        address allowedTaker;
        address sellToken;
        address buyToken;
        uint256 sellAmount;
        uint256 buyAmount;
        uint256 expiry;
    }

    error ZeroAddress();
    error ZeroAmount();
    error IdenticalTokens();
    error InvalidExpiry(uint256 expiry);
    error OfferNotFound(uint256 offerId);
    error OfferNotOpen(uint256 offerId, OfferStatus currentStatus);
    error NotMaker(address caller, address maker);
    error TakerNotAllowed(address caller, address allowedTaker);
    error OfferAlreadyExpired(uint256 offerId, uint256 expiry);
    error OfferNotExpired(uint256 offerId, uint256 expiry);
    error UnexpectedTransferAmount(address token, uint256 expected, uint256 received);

    event OfferCreated(
        uint256 indexed offerId,
        address indexed maker,
        address indexed allowedTaker,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 expiry
    );
    event OfferFilled(uint256 indexed offerId, address indexed maker, address indexed taker);
    event OfferCancelled(uint256 indexed offerId, address indexed maker);
    event OfferExpired(uint256 indexed offerId, address indexed maker);

    uint256 private _nextOfferId = 1;
    mapping(uint256 offerId => Offer offer) private _offers;

    /// @notice Creates an offer and escrows the maker's sell token.
    /// @param params The fixed offer terms.
    /// @return offerId The new monotonically increasing offer identifier.
    function createOffer(CreateOfferParams calldata params)
        external
        nonReentrant
        returns (uint256 offerId)
    {
        if (params.sellToken == address(0) || params.buyToken == address(0)) {
            revert ZeroAddress();
        }
        if (params.sellAmount == 0 || params.buyAmount == 0) {
            revert ZeroAmount();
        }
        if (params.sellToken == params.buyToken) {
            revert IdenticalTokens();
        }
        if (params.expiry <= block.timestamp) {
            revert InvalidExpiry(params.expiry);
        }

        offerId = _nextOfferId++;
        _offers[offerId] = Offer({
            maker: msg.sender,
            allowedTaker: params.allowedTaker,
            sellToken: params.sellToken,
            buyToken: params.buyToken,
            sellAmount: params.sellAmount,
            buyAmount: params.buyAmount,
            expiry: params.expiry,
            status: OfferStatus.Open
        });

        emit OfferCreated(
            offerId,
            msg.sender,
            params.allowedTaker,
            params.sellToken,
            params.buyToken,
            params.sellAmount,
            params.buyAmount,
            params.expiry
        );

        _pullExact(IERC20(params.sellToken), msg.sender, params.sellAmount);
    }

    /// @notice Accepts an open offer and atomically settles both token legs.
    /// @param offerId The offer to fill.
    function acceptOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = _getOpenOffer(offerId);

        if (block.timestamp >= offer.expiry) {
            revert OfferAlreadyExpired(offerId, offer.expiry);
        }
        if (offer.allowedTaker != address(0) && msg.sender != offer.allowedTaker) {
            revert TakerNotAllowed(msg.sender, offer.allowedTaker);
        }

        // Effects precede all token interactions. A failed transfer reverts the whole transaction.
        offer.status = OfferStatus.Filled;
        emit OfferFilled(offerId, offer.maker, msg.sender);

        _pullExact(IERC20(offer.buyToken), msg.sender, offer.buyAmount);
        IERC20(offer.buyToken).safeTransfer(offer.maker, offer.buyAmount);
        IERC20(offer.sellToken).safeTransfer(msg.sender, offer.sellAmount);
    }

    /// @notice Cancels an open, unexpired offer. Only the maker may call this.
    /// @param offerId The offer to cancel.
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = _getOpenOffer(offerId);

        if (msg.sender != offer.maker) {
            revert NotMaker(msg.sender, offer.maker);
        }
        if (block.timestamp >= offer.expiry) {
            revert OfferAlreadyExpired(offerId, offer.expiry);
        }

        offer.status = OfferStatus.Cancelled;
        emit OfferCancelled(offerId, offer.maker);

        IERC20(offer.sellToken).safeTransfer(offer.maker, offer.sellAmount);
    }

    /// @notice Marks an elapsed offer as expired and refunds its escrow to the maker.
    /// @dev Anyone may trigger expiry so the refund does not depend on the maker being online.
    /// @param offerId The offer to expire.
    function expireOffer(uint256 offerId) external nonReentrant {
        Offer storage offer = _getOpenOffer(offerId);

        if (block.timestamp < offer.expiry) {
            revert OfferNotExpired(offerId, offer.expiry);
        }

        offer.status = OfferStatus.Expired;
        emit OfferExpired(offerId, offer.maker);

        IERC20(offer.sellToken).safeTransfer(offer.maker, offer.sellAmount);
    }

    /// @notice Returns a copy of an existing offer.
    function getOffer(uint256 offerId) external view returns (Offer memory offer) {
        offer = _offers[offerId];
        if (offer.maker == address(0)) {
            revert OfferNotFound(offerId);
        }
    }

    function _getOpenOffer(uint256 offerId) internal view returns (Offer storage offer) {
        offer = _offers[offerId];
        if (offer.maker == address(0)) {
            revert OfferNotFound(offerId);
        }
        if (offer.status != OfferStatus.Open) {
            revert OfferNotOpen(offerId, offer.status);
        }
    }

    function _pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 received = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;

        if (received != amount) {
            revert UnexpectedTransferAmount(address(token), amount, received);
        }
    }
}
