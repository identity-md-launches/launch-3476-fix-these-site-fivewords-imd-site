// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {FiveWords} from "../src/FiveWords.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {FiveWordsBase} from "./FiveWordsBase.sol";

/// @dev A contract wallet that does several things in one transaction, as a bot could.
contract OneTransaction {
    FiveWords internal immutable nft;
    IERC20 internal immutable imd;

    constructor(FiveWords nft_, IERC20 imd_) {
        nft = nft_;
        imd = imd_;
    }

    function twoWords(string calldata a, string calldata b) external {
        imd.approve(address(nft), type(uint256).max);
        nft.addWord(a);
        nft.addWord(b);
    }

    /// Writes the fifth word, then at once tries to order the same image again.
    function fifthThenRetry(string calldata word, uint256 image) external {
        imd.approve(address(nft), type(uint256).max);
        nft.addWord(word);
        nft.retry(image);
    }

    /// Writes the fifth word, then at once tries the first word of the next image.
    function fifthThenNext(string calldata word, string calldata next) external {
        imd.approve(address(nft), type(uint256).max);
        nft.addWord(word);
        nft.addWord(next);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @notice Edges the other suites leave: exact clock boundaries, a retry's own clock, payment that is
/// missing or unsold at retry, several actions in one transaction, and prices at their extremes.
contract FiveWordsEdgesTest is FiveWordsBase {
    // ---- the round clock, to the second ----

    function test_theNextImageOpensExactlyFiveHoursAfterTheOrderAndNotASecondBefore() public {
        _fill(1);
        uint256 orderedAt = nft.imageInfo(1).orderedAt;
        assertEq(orderedAt, block.timestamp);
        assertEq(nft.imageInfo(2).opensAt, orderedAt + 5 hours);

        address user = _user(2, 1);
        imd.mint(user, SHARE);
        vm.prank(user);
        imd.approve(address(nft), SHARE);

        vm.warp(orderedAt + 5 hours - 1);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOpenYet.selector, 2, orderedAt + 5 hours));
        nft.addWord("early");

        vm.warp(orderedAt + 5 hours);
        vm.prank(user);
        assertEq(nft.addWord("early"), 6);
    }

    function test_aLateFifthWordStartsTheNextClockFromItsOwnTime() public {
        // Image 2 opens at +5h but its words come a day later: image 3 opens 5h after image 2's order.
        _fill(1);
        vm.warp(block.timestamp + 29 hours);
        _fill(2);
        assertEq(nft.imageInfo(3).opensAt, block.timestamp + 5 hours);
        assertEq(nft.imageInfo(2).orderedAt, block.timestamp);
    }

    // ---- the stale-order clock ----

    function test_anOrderBecomesRetryableExactlyADayAfterItWasRequested() public {
        _fill(1);
        uint256 requestedAt = nft.imageInfo(1).requestedAt;
        vm.warp(requestedAt + 24 hours - 1);
        assertFalse(nft.canRetry(1));
        address payer = makeAddr("payer");
        imd.mint(payer, PRICE);
        vm.startPrank(payer);
        imd.approve(address(nft), PRICE);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotRetryable.selector, 1));
        nft.retry(1);
        vm.stopPrank();

        vm.warp(requestedAt + 24 hours);
        assertTrue(nft.canRetry(1));
        vm.prank(payer);
        nft.retry(1);
        assertEq(nft.imageInfo(1).orders, 2);
    }

    function test_aRetryRestartsTheStaleClockButNotTheRoundClock() public {
        bytes32 first = _fill(1);
        uint256 orderedAt = nft.imageInfo(1).orderedAt;
        uint256 opens2 = nft.imageInfo(2).opensAt;

        vm.warp(block.timestamp + 24 hours);
        bytes32 second = _retry(stranger, 1);
        uint256 retriedAt = block.timestamp;
        assertEq(nft.imageInfo(1).requestedAt, retriedAt);
        assertFalse(nft.canRetry(1), "a fresh retry is not stale at once");

        vm.warp(retriedAt + 24 hours - 1);
        assertFalse(nft.canRetry(1));
        vm.warp(retriedAt + 24 hours);
        bytes32 third = _retry(stranger, 1);

        FiveWords.Image memory img = nft.imageInfo(1);
        assertEq(img.orders, 3);
        assertEq(img.orderedAt, orderedAt);
        assertEq(nft.imageInfo(2).opensAt, opens2);
        assertEq(img.requestId, third);
        // Every request stays bound to image 1, but only the last is answered.
        assertEq(nft.imageOfRequest(first), 1);
        assertEq(nft.imageOfRequest(second), 1);
        assertFalse(_deliver(first, RESULT_URI));
        assertFalse(_fail(second, 2, bytes32("failed")));
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Ordered));
        assertTrue(_deliver(third, RESULT_URI));
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Delivered));
        assertEq(imd.balanceOf(treasury), 3 * PRICE);
        assertEq(imd.balanceOf(address(nft)), 0);
    }

    function test_aDeliveredImageIsNeverRetryableHoweverLongItWaits() public {
        bytes32 requestId = _fill(1);
        assertTrue(_deliver(requestId, RESULT_URI));
        vm.warp(block.timestamp + 365 days);
        assertFalse(nft.canRetry(1));
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotRetryable.selector, 1));
        nft.retry(1);
    }

    // ---- what a retry needs ----

    function test_aRetryWithoutTheFullPriceApprovedChangesNothing() public {
        bytes32 requestId = _fill(1);
        _fail(requestId, 1, bytes32("body_refused"));
        address payer = makeAddr("payer");
        imd.mint(payer, PRICE);
        vm.startPrank(payer);
        imd.approve(address(nft), PRICE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(nft), PRICE - 1, PRICE)
        );
        nft.retry(1);
        vm.stopPrank();

        FiveWords.Image memory img = nft.imageInfo(1);
        assertEq(uint8(img.status), uint8(FiveWords.Status.Failed));
        assertEq(img.orders, 1);
        assertEq(img.requestId, requestId);
        assertEq(imd.balanceOf(payer), PRICE);
        assertEq(imd.balanceOf(treasury), PRICE);
    }

    function test_aRetryOfAnActionNoLongerSoldChangesNothing() public {
        bytes32 requestId = _fill(1);
        _fail(requestId, 2, bytes32("failed"));
        intake.setPrice(ACTION, address(imd), 0);
        vm.prank(stranger);
        vm.expectRevert(FiveWords.NotSold.selector);
        nft.retry(1);
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Failed));
        assertTrue(nft.canRetry(1));
    }

    function test_aRetryDoesNotSpendThePot() public {
        // A price fall leaves a surplus in the pot; a retry is still paid in full by its sender.
        _addWords(1, 1, 4);
        intake.setPrice(ACTION, address(imd), 0.3 ether);
        bytes32 requestId = _fill1Fifth();
        assertEq(nft.pot(), 0.1 ether);
        _fail(requestId, 2, bytes32("failed"));

        address payer = makeAddr("payer");
        imd.mint(payer, 0.3 ether - 1);
        vm.startPrank(payer);
        imd.approve(address(nft), 0.3 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, payer, 0.3 ether - 1, 0.3 ether)
        );
        nft.retry(1);
        vm.stopPrank();
        assertEq(nft.pot(), 0.1 ether);
        assertEq(imd.balanceOf(address(nft)), 0.1 ether);
    }

    function _fill1Fifth() private returns (bytes32) {
        _add(_user(1, 5), "clouds");
        return intake.lastRequestId();
    }

    // ---- one transaction, several actions ----

    function test_aContractWalletCannotWriteTwoWordsInOneTransaction() public {
        OneTransaction bot = new OneTransaction(nft, imd);
        imd.mint(address(bot), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.AlreadyAdded.selector, 1, address(bot)));
        bot.twoWords("one", "two");
        assertEq(nft.totalSupply(), 0);
        assertEq(imd.balanceOf(address(bot)), 1 ether);
    }

    function test_theFifthWordCannotBeRetriedInTheSameTransaction() public {
        _addWords(1, 1, 4);
        OneTransaction bot = new OneTransaction(nft, imd);
        imd.mint(address(bot), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotRetryable.selector, 1));
        bot.fifthThenRetry("clouds", 1);
        // The whole transaction rolled back, the fifth word with it.
        assertEq(nft.imageInfo(1).wordCount, 4);
        assertEq(nft.imagesOrdered(), 0);
        assertEq(imd.balanceOf(treasury), 0);
    }

    function test_theNextImageDoesNotOpenInTheTransactionThatOrderedThePrevious() public {
        _addWords(1, 1, 4);
        OneTransaction bot = new OneTransaction(nft, imd);
        imd.mint(address(bot), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOpenYet.selector, 2, block.timestamp + 5 hours));
        bot.fifthThenNext("clouds", "next");
        assertEq(nft.imagesOrdered(), 0);
    }

    function test_theSameWalletWritesOncePerImageInEveryImage() public {
        address user = makeAddr("regular");
        for (uint256 image = 1; image <= 5; ++image) {
            _add(user, "same");
            assertTrue(nft.hasWord(image, user));
            for (uint256 slot = 2; slot <= 5; ++slot) {
                _add(_user(image, slot), words[slot - 1]);
            }
            if (image < 5) vm.warp(nft.imageInfo(image + 1).opensAt);
        }
        assertEq(nft.balanceOf(user), 5);
        for (uint256 image = 1; image <= 5; ++image) {
            assertEq(nft.ownerOf((image - 1) * 5 + 1), user);
        }
    }

    // ---- prices at their extremes ----

    function test_aPriceBelowFiveWeiMakesTheFirstFourWordsFreeAndTheFifthPaysItAll() public {
        intake.setPrice(ACTION, address(imd), 4);
        vm.recordLogs();
        for (uint256 slot = 1; slot <= 4; ++slot) {
            assertEq(nft.amountDue(), 0);
            (, uint256 paid) = _add(_user(1, slot), words[slot - 1]);
            assertEq(paid, 0);
        }
        // No IMD moved for the free words.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].emitter != address(imd) || logs[i].topics[0] != IERC20.Transfer.selector
                    || logs[i].topics[1] == bytes32(0)
            );
        }
        assertEq(nft.amountDue(), 4);
        (, uint256 fifth) = _add(_user(1, 5), words[4]);
        assertEq(fifth, 4);
        assertEq(imd.balanceOf(treasury), 4);
        assertEq(nft.pot(), 0);
    }

    function test_aOneWeiPriceIsOrdered() public {
        intake.setPrice(ACTION, address(imd), 1);
        bytes32 requestId = _fill(1);
        assertEq(imd.balanceOf(treasury), 1);
        (address payer,,,, bool pending) = intake.requests(requestId);
        assertEq(payer, address(nft));
        assertTrue(pending);
    }

    function test_aHugePriceIsPaidInFullWithoutOverflow() public {
        uint256 price = 1e40 + 3;
        intake.setPrice(ACTION, address(imd), price);
        _fill(1);
        assertEq(imd.balanceOf(treasury), price);
        assertEq(nft.pot(), 0);
        assertEq(imd.balanceOf(address(nft)), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_whatAWordPullsIsAlwaysAmountDue(uint256[5] memory prices) public {
        uint256 pulledTotal;
        for (uint256 slot = 1; slot <= 5; ++slot) {
            uint256 price = bound(prices[slot - 1], 1, 1e30);
            intake.setPrice(ACTION, address(imd), price);
            uint256 due = nft.amountDue();
            if (slot < 5) assertEq(due, price / 5);
            uint256 potBefore = nft.pot();
            (, uint256 paid) = _add(_user(1, slot), words[slot - 1]);
            assertEq(paid, due);
            assertEq(imd.balanceOf(_user(1, slot)), 0, "pulled exactly what amountDue said");
            pulledTotal += paid;
            if (slot == 5) {
                assertEq(imd.balanceOf(treasury), price, "the order is the live price");
                assertEq(nft.pot(), potBefore + paid - price);
                assertEq(paid, price > potBefore ? price - potBefore : 0);
            }
        }
        assertEq(pulledTotal, imd.balanceOf(treasury) + imd.balanceOf(address(nft)));
        assertEq(imd.balanceOf(address(nft)), nft.pot());
        assertEq(imd.allowance(address(nft), address(intake)), 0);
    }

    // ---- the Intake's other refusals reach the fifth word atomically ----

    function test_anIntakeThatRepeatsAnIdAcrossImagesIsRefusedAndRollsBack() public {
        _fill(1);
        vm.warp(nft.imageInfo(2).opensAt);
        _addWords(2, 1, 4);
        intake.setMode(MockIntake.Mode.SameId, "");
        address fifth = _user(2, 5);
        imd.mint(fifth, SHARE);
        vm.startPrank(fifth);
        imd.approve(address(nft), SHARE);
        bytes32 repeated = intake.lastRequestId();
        vm.expectRevert(abi.encodeWithSelector(FiveWords.RequestIdReused.selector, repeated));
        nft.addWord("clouds");
        vm.stopPrank();
        assertEq(nft.imagesOrdered(), 1);
        assertEq(nft.imageOfRequest(repeated), 1);
        assertEq(imd.balanceOf(fifth), SHARE);
    }
}
