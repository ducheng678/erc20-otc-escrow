// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20OTCEscrow } from "../src/ERC20OTCEscrow.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { TestBase } from "./utils/TestBase.sol";

contract ERC20OTCEscrowAtomicRollbackTest is TestBase {
    struct Scenario {
        uint256 sellAmount;
        uint256 buyAmount;
        uint256 expiry;
        uint256 sellDust;
        uint256 buyDust;
    }

    ERC20OTCEscrow internal escrow;
    MockERC20 internal sellToken;
    MockERC20 internal buyToken;

    address internal constant MAKER = address(0xB0B);
    address internal constant LOW_BALANCE_TAKER = address(0xA11CE);
    address internal constant LOW_ALLOWANCE_TAKER = address(0xCAFE);

    function setUp() public {
        escrow = new ERC20OTCEscrow();
        sellToken = new MockERC20("Sell Token", "SELL");
        buyToken = new MockERC20("Buy Token", "BUY");
    }

    function testFuzz_BothFailedBuyTransferModesRollBackAtomically(
        uint96 sellAmountSeed,
        uint96 buyAmountSeed,
        uint64 sellDustSeed,
        uint64 buyDustSeed,
        uint32 ttlSeed
    ) public {
        Scenario memory scenario = _scenario(
            sellAmountSeed, buyAmountSeed, sellDustSeed, buyDustSeed, ttlSeed
        );
        uint256 availableBuyAmount = scenario.buyAmount - 1;

        sellToken.mint(MAKER, scenario.sellAmount * 2);
        sellToken.mint(address(escrow), scenario.sellDust);
        buyToken.mint(address(escrow), scenario.buyDust);
        buyToken.mint(LOW_BALANCE_TAKER, availableBuyAmount);
        buyToken.mint(LOW_ALLOWANCE_TAKER, scenario.buyAmount);

        _approve(sellToken, MAKER, type(uint256).max);
        _approve(buyToken, LOW_BALANCE_TAKER, scenario.buyAmount);
        _approve(buyToken, LOW_ALLOWANCE_TAKER, availableBuyAmount);

        uint256 lowBalanceOfferId = _createOffer(scenario);
        uint256 lowAllowanceOfferId = _createOffer(scenario);

        vm.prank(LOW_BALANCE_TAKER);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)",
                LOW_BALANCE_TAKER,
                availableBuyAmount,
                scenario.buyAmount
            )
        );
        escrow.acceptOffer(lowBalanceOfferId);

        vm.prank(LOW_ALLOWANCE_TAKER);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)",
                address(escrow),
                availableBuyAmount,
                scenario.buyAmount
            )
        );
        escrow.acceptOffer(lowAllowanceOfferId);

        assertEq(
            uint256(escrow.getOffer(lowBalanceOfferId).status),
            uint256(ERC20OTCEscrow.OfferStatus.Open)
        );
        assertEq(
            uint256(escrow.getOffer(lowAllowanceOfferId).status),
            uint256(ERC20OTCEscrow.OfferStatus.Open)
        );
        assertEq(sellToken.balanceOf(MAKER), 0);
        assertEq(sellToken.balanceOf(LOW_BALANCE_TAKER), 0);
        assertEq(sellToken.balanceOf(LOW_ALLOWANCE_TAKER), 0);
        assertEq(buyToken.balanceOf(MAKER), 0);
        assertEq(buyToken.balanceOf(LOW_BALANCE_TAKER), availableBuyAmount);
        assertEq(buyToken.balanceOf(LOW_ALLOWANCE_TAKER), scenario.buyAmount);
        assertEq(buyToken.allowance(LOW_BALANCE_TAKER, address(escrow)), scenario.buyAmount);
        assertEq(buyToken.allowance(LOW_ALLOWANCE_TAKER, address(escrow)), availableBuyAmount);
        assertEq(sellToken.balanceOf(address(escrow)), scenario.sellDust + scenario.sellAmount * 2);
        assertEq(buyToken.balanceOf(address(escrow)), scenario.buyDust);
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

    function _approve(MockERC20 token, address owner, uint256 amount) internal {
        vm.prank(owner);
        token.approve(address(escrow), amount);
    }

    function _scenario(
        uint96 sellAmountSeed,
        uint96 buyAmountSeed,
        uint64 sellDustSeed,
        uint64 buyDustSeed,
        uint32 ttlSeed
    ) internal view returns (Scenario memory scenario) {
        scenario.sellAmount = uint256(sellAmountSeed) + 1;
        scenario.buyAmount = uint256(buyAmountSeed) + 1;
        scenario.expiry = block.timestamp + uint256(ttlSeed) % 365 days + 1;
        scenario.sellDust = uint256(sellDustSeed);
        scenario.buyDust = uint256(buyDustSeed);
    }
}
