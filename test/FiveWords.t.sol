// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Errors, IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FiveWords} from "../src/FiveWords.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {FiveWordsBase} from "./FiveWordsBase.sol";

/// @notice Writing words, ordering images, the round clock and the money.
contract FiveWordsGameTest is FiveWordsBase {
    // ---- writing ----

    function test_theFirstImageOpensAtDeployment() public view {
        assertEq(nft.name(), "fivewords");
        assertEq(nft.symbol(), "FIVE");
        assertEq(nft.MAX_SUPPLY(), 25);
        assertEq(nft.currentImage(), 1);
        assertEq(nft.imageInfo(1).opensAt, deployedAt);
        assertEq(nft.imageInfo(2).opensAt, 0);
        assertEq(nft.amountDue(), SHARE);
        assertEq(nft.totalSupply(), 0);
    }

    function test_aWordMintsItsSlotToTheSenderAndPullsAFifth() public {
        address alice = makeAddr("alice");
        imd.mint(alice, 1 ether);
        vm.startPrank(alice);
        imd.approve(address(nft), SHARE);
        vm.expectEmit(true, true, true, true, address(nft));
        emit FiveWords.WordAdded(1, 1, alice, 1, "quiet", SHARE);
        vm.expectEmit(false, false, false, true, address(nft));
        emit IERC4906.BatchMetadataUpdate(1, 1);
        uint256 tokenId = nft.addWord("quiet");
        vm.stopPrank();

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.totalSupply(), 1);
        assertTrue(nft.hasWord(1, alice));
        assertEq(nft.wordsOf(1)[0], "quiet");
        assertEq(nft.phraseOf(1), "quiet");
        assertEq(nft.imageInfo(1).wordCount, 1);
        assertEq(imd.balanceOf(alice), 1 ether - SHARE);
        assertEq(imd.balanceOf(address(nft)), SHARE);
        assertEq(nft.pot(), SHARE);
        assertEq(imd.allowance(alice, address(nft)), 0);
        // Nothing is ordered before the fifth word.
        assertEq(intake.nonce(), 0);
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Writing));
    }

    function test_wordsAreOneToTwentyLowercaseLetters() public {
        string[12] memory bad = [
            "",
            "abcdefghijklmnopqrstu",
            "Quiet",
            "two words",
            "a1",
            'a"b',
            "a\\b",
            "a\nb",
            unicode"café",
            "a-b",
            "a`",
            "a{"
        ];
        address alice = makeAddr("alice");
        imd.mint(alice, 1 ether);
        vm.startPrank(alice);
        imd.approve(address(nft), 1 ether);
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(FiveWords.BadWord.selector);
            nft.addWord(bad[i]);
        }
        vm.stopPrank();
        assertEq(nft.totalSupply(), 0);

        _add(_user(1, 1), "a");
        _add(_user(1, 2), "abcdefghijklmnopqrst");
        _add(_user(1, 3), "z");
        assertEq(nft.phraseOf(1), "a abcdefghijklmnopqrst z");
    }

    function testFuzz_everyLowercaseWordIsAccepted(uint256 seed, uint8 length) public {
        bytes memory word = _letters(seed, bound(length, 1, 20));
        (uint256 tokenId,) = _add(stranger, string(word));
        assertEq(nft.wordsOf(1)[0], string(word));
        assertEq(nft.ownerOf(tokenId), stranger);
    }

    function testFuzz_aWordWithAnyOtherByteIsRefused(uint256 seed, uint8 length, uint8 position, bytes1 other) public {
        vm.assume(other < 0x61 || other > 0x7a);
        bytes memory word = _letters(seed, bound(length, 1, 20));
        word[bound(position, 0, word.length - 1)] = other;
        vm.prank(stranger);
        vm.expectRevert(FiveWords.BadWord.selector);
        nft.addWord(string(word));
    }

    function testFuzz_aWordLongerThanTwentyLettersIsRefused(uint256 seed, uint8 length) public {
        bytes memory word = _letters(seed, bound(length, 21, 200));
        vm.prank(stranger);
        vm.expectRevert(FiveWords.BadWord.selector);
        nft.addWord(string(word));
    }

    function test_oneWordPerWalletPerImage() public {
        address alice = _user(1, 1);
        _add(alice, "quiet");
        imd.mint(alice, 1 ether);
        vm.startPrank(alice);
        imd.approve(address(nft), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.AlreadyAdded.selector, 1, alice));
        nft.addWord("again");
        vm.stopPrank();

        _addWords(1, 2, 5);
        vm.warp(nft.imageInfo(2).opensAt);
        // The same wallet writes one word of the next image.
        (uint256 tokenId,) = _add(alice, "quiet");
        assertEq(tokenId, 6);
        assertTrue(nft.hasWord(2, alice));
    }

    function test_aTransferMovesTheHolderNotTheWord() public {
        address alice = _user(1, 1);
        address bob = makeAddr("bob");
        _add(alice, "quiet");
        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(nft.ownerOf(1), bob);
        assertTrue(nft.hasWord(1, alice));
        assertFalse(nft.hasWord(1, bob));
        _add(bob, "orange");
        assertEq(nft.balanceOf(bob), 2);
    }

    // ---- ordering ----

    function test_theFifthWordOrdersTheImageAtExactlyThePrice() public {
        _addWords(1, 1, 4);
        assertEq(nft.pot(), 4 * SHARE);
        address fifth = _user(1, 5);
        imd.mint(fifth, SHARE);
        vm.startPrank(fifth);
        imd.approve(address(nft), SHARE);
        vm.expectEmit(false, true, true, true, address(intake));
        emit MockIntake.Requested(
            bytes32(0), address(nft), ACTION, EXPECTED_BODY, address(nft), nft.onResult.selector, address(imd), PRICE
        );
        uint256 tokenId = nft.addWord("clouds");
        vm.stopPrank();

        bytes32 requestId = intake.lastRequestId();
        (address payer, address target, bytes4 selector, bytes4 onFailure, bool pending) = intake.requests(requestId);
        assertEq(payer, address(nft));
        assertEq(target, address(nft));
        assertEq(selector, nft.onResult.selector);
        assertEq(onFailure, nft.onFailure.selector);
        assertTrue(pending);
        assertEq(intake.lastBody(), EXPECTED_BODY);
        assertEq(nft.bodyOf(1), EXPECTED_BODY);

        // The price is spent: nothing held, nothing left approved.
        assertEq(imd.balanceOf(treasury), PRICE);
        assertEq(imd.balanceOf(address(nft)), 0);
        assertEq(imd.balanceOf(fifth), 0);
        assertEq(nft.pot(), 0);
        assertEq(imd.allowance(address(nft), address(intake)), 0);

        assertEq(tokenId, 5);
        assertEq(nft.ownerOf(5), fifth);
        FiveWords.Image memory img = nft.imageInfo(1);
        assertEq(uint8(img.status), uint8(FiveWords.Status.Ordered));
        assertEq(img.wordCount, 5);
        assertEq(img.orders, 1);
        assertEq(img.orderedAt, block.timestamp);
        assertEq(img.requestedAt, block.timestamp);
        assertEq(img.requestId, requestId);
        assertEq(nft.imageOfRequest(requestId), 1);
        assertEq(nft.imagesOrdered(), 1);
        assertEq(nft.currentImage(), 2);
        assertEq(nft.imageInfo(2).opensAt, block.timestamp + 5 hours);
    }

    function test_theCallbackSelectorsAreTheIntakeVersion2Signatures() public view {
        assertEq(nft.onResult.selector, bytes4(keccak256("onResult(bytes32,bytes32,string)")));
        assertEq(nft.onFailure.selector, bytes4(keccak256("onFailure(bytes32,uint8,bytes32,uint16,uint16,bytes)")));
        assertEq(
            intake.requestWithFailure.selector,
            bytes4(keccak256("requestWithFailure(bytes32,bytes,(address,bytes4),bytes4,address,uint256)"))
        );
        assertEq(ACTION, 0x6a6f622e6f70656e406a6f622d31000000000000000000000000000000000000);
    }

    function test_allFiveRoundsThenTheGameEnds() public {
        for (uint256 image = 1; image <= 5; ++image) {
            assertEq(nft.currentImage(), image);
            uint256 opensAt = nft.imageInfo(image).opensAt;
            if (image > 1) {
                assertEq(opensAt, nft.imageInfo(image - 1).orderedAt + 5 hours);
                vm.warp(opensAt - 1);
                vm.prank(_user(image, 1));
                vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOpenYet.selector, image, opensAt));
                nft.addWord("early");
            }
            vm.warp(opensAt + image * 17 minutes);
            bytes32 requestId = _fill(image);
            assertEq(nft.imageOfRequest(requestId), image);
            assertEq(nft.imageInfo(image).orderedAt, block.timestamp);
            assertEq(imd.balanceOf(treasury), image * PRICE);
            assertEq(imd.balanceOf(address(nft)), 0);
            if (image % 2 == 1) assertTrue(_deliver(requestId, RESULT_URI));
        }

        assertEq(nft.currentImage(), 0);
        assertEq(nft.imagesOrdered(), 5);
        assertEq(nft.amountDue(), 0);
        assertEq(nft.totalSupply(), 25);
        for (uint256 image = 1; image <= 5; ++image) {
            for (uint256 slot = 1; slot <= 5; ++slot) {
                uint256 tokenId = (image - 1) * 5 + slot;
                assertEq(nft.ownerOf(tokenId), _user(image, slot));
                (uint256 ofImage, uint256 ofSlot) = nft.slotOf(tokenId);
                assertEq(ofImage, image);
                assertEq(ofSlot, slot);
            }
            assertEq(nft.phraseOf(image), "quiet orange lighthouse above clouds");
        }

        // No sixth image, however long anyone waits.
        vm.warp(block.timestamp + 365 days);
        imd.mint(stranger, 1 ether);
        vm.startPrank(stranger);
        imd.approve(address(nft), 1 ether);
        vm.expectRevert(FiveWords.GameOver.selector);
        nft.addWord("late");
        vm.stopPrank();
        assertEq(imd.balanceOf(stranger), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 26));
        nft.ownerOf(26);
    }

    function test_theNextImageOpensFiveHoursAfterTheOrderWhateverTheResult() public {
        vm.warp(deployedAt + 3 days);
        _addWords(1, 1, 4);
        vm.warp(deployedAt + 9 days);
        bytes32 requestId = _fill1Last();
        uint256 orderedAt = block.timestamp;
        assertEq(nft.imageInfo(2).opensAt, orderedAt + 5 hours);

        // The result arriving early, late or never does not move the clock.
        vm.warp(orderedAt + 1 hours);
        _deliver(requestId, RESULT_URI);
        assertEq(nft.imageInfo(2).opensAt, orderedAt + 5 hours);
        vm.warp(orderedAt + 5 hours - 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOpenYet.selector, 2, orderedAt + 5 hours));
        nft.addWord("soon");
        vm.warp(orderedAt + 5 hours);
        (uint256 tokenId,) = _add(stranger, "now");
        assertEq(tokenId, 6);
    }

    function _fill1Last() private returns (bytes32) {
        _addWords(1, 5, 5);
        return intake.lastRequestId();
    }

    // ---- a failed order rolls the fifth word back ----

    function test_aRefusedOrderRollsTheFifthWordBack() public {
        _addWords(1, 1, 4);
        address fifth = _user(1, 5);
        imd.mint(fifth, SHARE);
        vm.prank(fifth);
        imd.approve(address(nft), SHARE);

        intake.setMode(MockIntake.Mode.Refusing, "");
        vm.prank(fifth);
        vm.expectRevert(MockIntake.Refused.selector);
        nft.addWord("clouds");
        _assertFifthWordNeverHappened(fifth);

        intake.setMode(MockIntake.Mode.NotPulling, "");
        vm.prank(fifth);
        vm.expectRevert(FiveWords.PaymentNotTaken.selector);
        nft.addWord("clouds");
        _assertFifthWordNeverHappened(fifth);

        // The same word goes through once the Intake takes orders again.
        intake.setMode(MockIntake.Mode.Normal, "");
        vm.prank(fifth);
        assertEq(nft.addWord("clouds"), 5);
        assertEq(nft.ownerOf(5), fifth);
        assertEq(imd.balanceOf(treasury), PRICE);
        assertEq(nft.pot(), 0);
    }

    function _assertFifthWordNeverHappened(address fifth) private {
        assertEq(nft.totalSupply(), 4);
        assertEq(nft.balanceOf(fifth), 0);
        assertFalse(nft.hasWord(1, fifth));
        FiveWords.Image memory img = nft.imageInfo(1);
        assertEq(img.wordCount, 4);
        assertEq(uint8(img.status), uint8(FiveWords.Status.Writing));
        assertEq(img.orderedAt, 0);
        assertEq(img.orders, 0);
        assertEq(img.words[4], "");
        assertEq(nft.imagesOrdered(), 0);
        assertEq(nft.imageInfo(2).opensAt, 0);
        assertEq(nft.pot(), 4 * SHARE);
        assertEq(imd.balanceOf(address(nft)), 4 * SHARE);
        assertEq(imd.balanceOf(fifth), SHARE);
        assertEq(imd.allowance(fifth, address(nft)), SHARE);
        assertEq(imd.allowance(address(nft), address(intake)), 0);
        assertEq(imd.balanceOf(treasury), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 5));
        nft.ownerOf(5);
    }

    function test_anIntakeThatUnsoldTheActionMidTransactionRollsBack() public {
        _addWords(1, 1, 4);
        intake.setPrice(ACTION, address(imd), 0);
        vm.prank(_user(1, 5));
        vm.expectRevert(FiveWords.NotSold.selector);
        nft.addWord("clouds");
        vm.expectRevert(FiveWords.NotSold.selector);
        nft.amountDue();
        vm.expectRevert(FiveWords.NotSold.selector);
        nft.retryPrice();
        assertEq(nft.totalSupply(), 4);
    }

    function test_aRequestIdTheIntakeRepeatsIsRefused() public {
        _fill(1);
        vm.warp(nft.imageInfo(2).opensAt);
        _addWords(2, 1, 4);
        intake.setMode(MockIntake.Mode.SameId, "");
        bytes32 repeated = intake.lastRequestId();
        address fifth = _user(2, 5);
        imd.mint(fifth, SHARE);
        vm.startPrank(fifth);
        imd.approve(address(nft), SHARE);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.RequestIdReused.selector, repeated));
        nft.addWord("clouds");
        vm.stopPrank();
        assertEq(nft.imageOfRequest(repeated), 1);
        assertEq(nft.imagesOrdered(), 1);
    }

    // ---- reentrancy ----

    function test_theIntakeCannotReenterWhileAnOrderIsMade() public {
        _addWords(1, 1, 4);
        address fifth = _user(1, 5);
        imd.mint(fifth, SHARE);
        vm.prank(fifth);
        imd.approve(address(nft), SHARE);

        intake.setMode(MockIntake.Mode.Reentering, abi.encodeCall(nft.addWord, ("again")));
        vm.prank(fifth);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        nft.addWord("clouds");

        intake.setMode(MockIntake.Mode.Reentering, abi.encodeCall(nft.retry, (1)));
        vm.prank(fifth);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        nft.addWord("clouds");

        // A result delivered inside the request, before the request id is known here, is refused.
        bytes32 next = keccak256(abi.encode(block.chainid, address(intake), intake.nonce() + 1));
        intake.setMode(MockIntake.Mode.Reentering, abi.encodeCall(nft.onResult, (next, RESULT_HASH, RESULT_URI)));
        vm.prank(fifth);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOutstanding.selector, next));
        nft.addWord("clouds");
        assertEq(nft.totalSupply(), 4);
    }

    // ---- the price ----

    function test_exactlyTheAmountDueIsEnoughAndOneWeiLessIsNot() public {
        address alice = makeAddr("alice");
        imd.mint(alice, 1 ether);
        uint256 due = nft.amountDue();
        vm.startPrank(alice);
        imd.approve(address(nft), due - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(nft), due - 1, due)
        );
        nft.addWord("quiet");
        imd.approve(address(nft), due);
        nft.addWord("quiet");
        vm.stopPrank();
        assertEq(imd.allowance(alice, address(nft)), 0);
        assertEq(imd.balanceOf(alice), 1 ether - due);
    }

    function test_aWalletWithoutTheAmountDueCannotWrite() public {
        vm.startPrank(stranger);
        imd.approve(address(nft), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, SHARE));
        nft.addWord("quiet");
        vm.stopPrank();
        assertEq(nft.totalSupply(), 0);
    }

    function test_aPriceRiseIsMadeUpByTheLaterWords() public {
        _addWords(1, 1, 2);
        intake.setPrice(ACTION, address(imd), 1 ether);
        assertEq(nft.amountDue(), 0.2 ether);
        _addWords(1, 3, 4);
        assertEq(nft.pot(), 0.6 ether);
        // The fifth word pays what is missing to the whole live price.
        assertEq(nft.amountDue(), 0.4 ether);
        (, uint256 paid) = _add(_user(1, 5), "clouds");
        assertEq(paid, 0.4 ether);
        assertEq(imd.balanceOf(treasury), 1 ether);
        assertEq(imd.balanceOf(address(nft)), 0);
        assertEq(nft.pot(), 0);
        assertEq(imd.allowance(address(nft), address(intake)), 0);
    }

    function test_aPriceRiseAfterTheSiteReadItStopsAtTheAllowance() public {
        address alice = makeAddr("alice");
        imd.mint(alice, 1 ether);
        vm.prank(alice);
        imd.approve(address(nft), SHARE);
        intake.setPrice(ACTION, address(imd), 0.75 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(nft), SHARE, 0.15 ether)
        );
        nft.addWord("quiet");
        assertEq(imd.balanceOf(alice), 1 ether);
    }

    function test_aPriceFallLeavesTheSurplusForTheNextImage() public {
        _addWords(1, 1, 4);
        intake.setPrice(ACTION, address(imd), 0.3 ether);
        assertEq(nft.amountDue(), 0);
        // Nothing is due, so nothing is pulled and no allowance is needed.
        vm.prank(stranger);
        nft.addWord("clouds");
        assertEq(imd.balanceOf(treasury), 0.3 ether);
        assertEq(nft.pot(), 0.1 ether);
        assertEq(imd.balanceOf(address(nft)), 0.1 ether);
        assertEq(imd.allowance(address(nft), address(intake)), 0);

        vm.warp(nft.imageInfo(2).opensAt);
        _addWords(2, 1, 4);
        assertEq(nft.pot(), 0.1 ether + 4 * 0.06 ether);
        assertEq(nft.amountDue(), 0);
        _addWords(2, 5, 5);
        assertEq(imd.balanceOf(treasury), 0.6 ether);
        assertEq(nft.pot(), 0.04 ether);
        assertEq(imd.balanceOf(address(nft)), 0.04 ether);
    }

    function test_aPriceThatDoesNotDivideByFiveIsStillPaidInFull() public {
        uint256 price = 0.5 ether + 3;
        intake.setPrice(ACTION, address(imd), price);
        assertEq(nft.amountDue(), SHARE);
        _addWords(1, 1, 4);
        assertEq(nft.amountDue(), SHARE + 3);
        _addWords(1, 5, 5);
        assertEq(imd.balanceOf(treasury), price);
        assertEq(imd.balanceOf(address(nft)), 0);
        assertEq(nft.pot(), 0);
    }

    /// @dev Whatever the price does between words, the Intake is paid exactly the live price at each
    /// order, the contract holds exactly its pot, and nothing stays approved.
    function testFuzz_fundsAreConserved(uint256[10] memory prices) public {
        uint256 paidIn;
        uint256 spent;
        for (uint256 image = 1; image <= 2; ++image) {
            vm.warp(nft.imageInfo(image).opensAt);
            for (uint256 slot = 1; slot <= 5; ++slot) {
                uint256 price = bound(prices[(image - 1) * 5 + slot - 1], 1, 1e27);
                intake.setPrice(ACTION, address(imd), price);
                (, uint256 paid) = _add(_user(image, slot), words[slot - 1]);
                paidIn += paid;
                if (slot == 5) {
                    spent += price;
                    assertEq(imd.balanceOf(treasury), spent);
                }
                assertEq(imd.balanceOf(address(nft)), nft.pot());
                assertEq(imd.allowance(address(nft), address(intake)), 0);
            }
        }
        assertEq(paidIn, spent + nft.pot());
        assertEq(nft.totalSupply(), 10);
    }

    function _letters(uint256 seed, uint256 length) private pure returns (bytes memory word) {
        word = new bytes(length);
        for (uint256 i; i < length; ++i) {
            word[i] = bytes1(uint8(0x61 + uint256(keccak256(abi.encode(seed, i))) % 26));
        }
    }
}
