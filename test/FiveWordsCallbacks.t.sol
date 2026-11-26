// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {FiveWords} from "../src/FiveWords.sol";
import {IIntake} from "../src/IIntake.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {FiveWordsBase} from "./FiveWordsBase.sol";

/// @notice What the Intake calls back, who may call it, what it costs, and ordering again.
contract FiveWordsCallbacksTest is FiveWordsBase {
    // ---- results and failures ----

    function test_aResultIsStoredAndEmitted() public {
        bytes32 requestId = _fill(1);
        vm.expectEmit(true, true, false, true, address(nft));
        emit FiveWords.ImageDelivered(1, requestId, RESULT_HASH, RESULT_URI);
        vm.expectEmit(false, false, false, true, address(nft));
        emit IERC4906.BatchMetadataUpdate(1, 5);
        vm.expectEmit(true, false, false, true, address(intake));
        emit MockIntake.Completed(requestId, 0, RESULT_HASH, RESULT_URI, true);
        assertTrue(_deliver(requestId, RESULT_URI));

        FiveWords.Image memory img = nft.imageInfo(1);
        assertEq(uint8(img.status), uint8(FiveWords.Status.Delivered));
        assertEq(img.resultHash, RESULT_HASH);
        assertEq(img.uri, RESULT_URI);
        assertEq(img.requestId, requestId);
        assertEq(nft.imageURI(1), IMAGE_URI);
        assertFalse(nft.canRetry(1));
    }

    function test_aFailureIsStoredAndEmittedAndNothingIsPaidBack() public {
        bytes32 requestId = _fill(1);
        vm.expectEmit(true, true, false, true, address(nft));
        emit FiveWords.ImageFailed(1, requestId, 2, bytes32("failed"));
        vm.expectEmit(true, false, false, true, address(intake));
        emit MockIntake.Completed(requestId, 2, bytes32(0), "", true);
        assertTrue(_fail(requestId, 2, bytes32("failed")));

        FiveWords.Image memory img = nft.imageInfo(1);
        assertEq(uint8(img.status), uint8(FiveWords.Status.Failed));
        assertEq(img.failureStatus, 2);
        assertEq(img.failureReason, bytes32("failed"));
        assertEq(img.uri, "");
        assertEq(nft.imageURI(1), "");
        assertTrue(nft.canRetry(1));
        // The price stays spent.
        assertEq(imd.balanceOf(treasury), PRICE);
        assertEq(imd.balanceOf(address(nft)), 0);
        for (uint256 slot = 1; slot <= 5; ++slot) {
            assertEq(imd.balanceOf(_user(1, slot)), 0);
        }
    }

    function test_onlyTheIntakeCallsBack() public {
        bytes32 requestId = _fill(1);
        address[3] memory callers = [address(this), writer, _user(1, 1)];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(FiveWords.NotIntake.selector);
            nft.onResult(requestId, RESULT_HASH, RESULT_URI);
            vm.expectRevert(FiveWords.NotIntake.selector);
            nft.onFailure(requestId, 2, bytes32("failed"), 0, 0, "");
            vm.stopPrank();
        }
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Ordered));
    }

    function test_aRequestThisContractNeverMadeIsRefused() public {
        _fill(1);
        bytes32[2] memory unknown = [bytes32("unknown"), bytes32(0)];
        for (uint256 i; i < unknown.length; ++i) {
            vm.startPrank(address(intake));
            vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOutstanding.selector, unknown[i]));
            nft.onResult(unknown[i], RESULT_HASH, RESULT_URI);
            vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOutstanding.selector, unknown[i]));
            nft.onFailure(unknown[i], 1, bytes32("refused"), 0, 0, "");
            vm.stopPrank();
        }
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Ordered));
    }

    function test_aRequestIsSettledOnce() public {
        bytes32 first = _fill(1);
        vm.startPrank(address(intake));
        nft.onResult(first, RESULT_HASH, RESULT_URI);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOutstanding.selector, first));
        nft.onResult(first, keccak256("another"), "ipfs://another/result.json");
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOutstanding.selector, first));
        nft.onFailure(first, 2, bytes32("failed"), 0, 0, "");
        vm.stopPrank();
        assertEq(nft.imageInfo(1).uri, RESULT_URI);
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Delivered));

        vm.warp(nft.imageInfo(2).opensAt);
        bytes32 second = _fill(2);
        vm.startPrank(address(intake));
        nft.onFailure(second, 1, bytes32("body_refused"), 0, 0, "");
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOutstanding.selector, second));
        nft.onFailure(second, 2, bytes32("failed"), 0, 0, "");
        // A failed order is over: its result is not accepted afterwards.
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOutstanding.selector, second));
        nft.onResult(second, RESULT_HASH, RESULT_URI);
        vm.stopPrank();
        assertEq(nft.imageInfo(2).failureReason, bytes32("body_refused"));
        // Each result is bound to its own image.
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Delivered));
        assertEq(uint8(nft.imageInfo(2).status), uint8(FiveWords.Status.Failed));
    }

    function test_someoneElsesRequestNamingThisContractChangesNothing() public {
        bytes32 ours = _fill(1);
        imd.mint(stranger, 2 * PRICE);
        vm.startPrank(stranger);
        imd.approve(address(intake), 2 * PRICE);
        IIntake.Callback memory callback = IIntake.Callback(address(nft), nft.onResult.selector);
        bytes32 theirs1 = intake.requestWithFailure(ACTION, "{}", callback, nft.onFailure.selector, address(imd), PRICE);
        bytes32 theirs2 = intake.requestWithFailure(ACTION, "{}", callback, nft.onFailure.selector, address(imd), PRICE);
        vm.stopPrank();

        // The Intake does call this contract, which refuses: recorded as not delivered.
        assertFalse(_fail(theirs1, 1, bytes32("body_invalid")));
        assertFalse(_deliver(theirs2, "ipfs://theirs/result.json"));
        FiveWords.Image memory img = nft.imageInfo(1);
        assertEq(uint8(img.status), uint8(FiveWords.Status.Ordered));
        assertEq(img.requestId, ours);
        assertEq(img.uri, "");
        assertFalse(nft.canRetry(1));
        assertEq(nft.imageOfRequest(theirs1), 0);
        assertTrue(_deliver(ours, RESULT_URI));
    }

    // ---- the callback gas limit ----

    function test_theLongestResultIsDeliveredWithinTheCallbackGasFromColdStorage() public {
        bytes32 requestId = _fill(1);
        string memory uri = _uriOfLength(nft.MAX_URI_BYTES());
        // Nothing is warm when the writer's transaction arrives.
        vm.cool(address(nft));
        assertTrue(_deliver(requestId, uri));
        assertEq(nft.imageInfo(1).uri, uri);
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Delivered));
    }

    function test_theLongestResultLeavesAMarginUnderTheCallbackGas() public {
        bytes32 requestId = _fill(1);
        string memory uri = _uriOfLength(nft.MAX_URI_BYTES());
        vm.cool(address(nft));
        (bool ok, uint256 used) =
            intake.measure(address(nft), abi.encodeCall(nft.onResult, (requestId, RESULT_HASH, uri)));
        assertTrue(ok);
        assertEq(nft.imageInfo(1).uri, uri);
        assertLt(used, 165_000, "onResult must leave a margin under its 200,000 gas");
    }

    function test_aFailureFitsTheCallbackGasFromColdStorage() public {
        bytes32 requestId = _fill(1);
        vm.cool(address(nft));
        assertTrue(_fail(requestId, 2, bytes32("failed")));
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Failed));
    }

    function test_aFailureLeavesAMarginUnderTheCallbackGas() public {
        bytes32 requestId = _fill(1);
        vm.cool(address(nft));
        (bool ok, uint256 used) = intake.measure(
            address(nft),
            abi.encodeCall(nft.onFailure, (requestId, 1, bytes32("admission_refused"), 7, 9, new bytes(65)))
        );
        assertTrue(ok);
        assertEq(nft.imageInfo(1).failureReason, bytes32("admission_refused"));
        assertLt(used, 60_000);
    }

    function test_aCallbackRunsOutBelowTheLimitWithoutChangingAnything() public {
        bytes32 requestId = _fill(1);
        vm.cool(address(nft));
        vm.prank(address(intake));
        (bool ok,) = address(nft).call{gas: 40_000}(abi.encodeCall(nft.onResult, (requestId, RESULT_HASH, RESULT_URI)));
        assertFalse(ok);
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Ordered));
        // The same result is accepted when it comes with its gas.
        assertTrue(_deliver(requestId, RESULT_URI));
    }

    function test_aResultUriThatCouldNotBeStoredSafelyIsRefused() public {
        bytes32 requestId = _fill(1);
        string[7] memory bad = [
            "",
            _uriOfLength(nft.MAX_URI_BYTES() + 1),
            'ipfs://cid/result.json","image":"x',
            "ipfs://cid\\result.json",
            "ipfs://cid/result .json",
            "ipfs://cid/result.json\n",
            unicode"ipfs://cïd/result.json"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(address(intake));
            vm.expectRevert(FiveWords.BadUri.selector);
            nft.onResult(requestId, RESULT_HASH, bad[i]);
        }
        // Through the Intake the refusal is a result that was not delivered; the order stays open.
        vm.warp(nft.imageInfo(2).opensAt);
        bytes32 second = _fill(2);
        assertFalse(_deliver(second, _uriOfLength(4000)));
        assertEq(uint8(nft.imageInfo(2).status), uint8(FiveWords.Status.Ordered));
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Ordered));
        assertTrue(_deliver(requestId, RESULT_URI));
    }

    // ---- ordering again ----

    function test_anyoneOrdersAFailedImageAgainAtTheFullPrice() public {
        bytes32 first = _fill(1);
        uint256 orderedAt = block.timestamp;
        vm.warp(orderedAt + 1 hours);
        _fail(first, 2, bytes32("failed"));

        vm.warp(orderedAt + 2 hours);
        imd.mint(stranger, PRICE);
        vm.startPrank(stranger);
        imd.approve(address(nft), PRICE);
        bytes32 expectedId = keccak256(abi.encode(block.chainid, address(intake), intake.nonce() + 1));
        // The same phrase, the same callbacks, the whole price.
        vm.expectEmit(true, true, true, true, address(intake));
        emit MockIntake.Requested(
            expectedId, address(nft), ACTION, EXPECTED_BODY, address(nft), nft.onResult.selector, address(imd), PRICE
        );
        vm.expectEmit(true, true, true, true, address(nft));
        emit FiveWords.ImageOrdered(1, expectedId, stranger, PRICE, 2);
        bytes32 second = nft.retry(1);
        vm.stopPrank();

        assertEq(second, expectedId);
        assertTrue(second != first);
        FiveWords.Image memory img = nft.imageInfo(1);
        assertEq(uint8(img.status), uint8(FiveWords.Status.Ordered));
        assertEq(img.orders, 2);
        assertEq(img.requestId, second);
        assertEq(img.requestedAt, orderedAt + 2 hours);
        // The round clock is the first order's.
        assertEq(img.orderedAt, orderedAt);
        assertEq(nft.imageInfo(2).opensAt, orderedAt + 5 hours);
        assertEq(nft.imagesOrdered(), 1);
        // The same slots and holders.
        assertEq(nft.totalSupply(), 5);
        assertEq(nft.phraseOf(1), "quiet orange lighthouse above clouds");
        for (uint256 slot = 1; slot <= 5; ++slot) {
            assertEq(nft.ownerOf(slot), _user(1, slot));
        }
        assertEq(nft.balanceOf(stranger), 0);
        // Paid in full by the sender, spent in full, nothing held or approved.
        assertEq(imd.balanceOf(stranger), 0);
        assertEq(imd.balanceOf(treasury), 2 * PRICE);
        assertEq(imd.balanceOf(address(nft)), 0);
        assertEq(nft.pot(), 0);
        assertEq(imd.allowance(address(nft), address(intake)), 0);
        assertEq(imd.allowance(stranger, address(nft)), 0);

        // Only the new request is outstanding.
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOutstanding.selector, first));
        nft.onResult(first, RESULT_HASH, RESULT_URI);
        assertTrue(_deliver(second, RESULT_URI));
        assertEq(nft.imageURI(1), IMAGE_URI);
        assertEq(nft.imageInfo(1).failureReason, bytes32("failed"));
    }

    function test_orderingAgainLeavesTheOpenRoundAlone() public {
        bytes32 first = _fill(1);
        _fail(first, 1, bytes32("refused"));
        vm.warp(nft.imageInfo(2).opensAt);
        _addWords(2, 1, 2);
        uint256 opensAt = nft.imageInfo(2).opensAt;

        _retry(stranger, 1);
        assertEq(nft.pot(), 2 * SHARE);
        assertEq(imd.balanceOf(address(nft)), 2 * SHARE);
        assertEq(nft.currentImage(), 2);
        assertEq(nft.imageInfo(2).wordCount, 2);
        assertEq(nft.imageInfo(2).opensAt, opensAt);
        assertEq(nft.amountDue(), SHARE);
        _addWords(2, 3, 5);
        assertEq(imd.balanceOf(treasury), 3 * PRICE);
        assertEq(nft.pot(), 0);
    }

    function test_onlyAFailedOrStaleOrderCanBeOrderedAgain() public {
        imd.mint(stranger, 10 * PRICE);
        vm.prank(stranger);
        imd.approve(address(nft), 10 * PRICE);

        // Still being written, not started, or not an image at all.
        _addWords(1, 1, 4);
        uint256[4] memory never = [uint256(1), 2, 0, 6];
        for (uint256 i; i < never.length; ++i) {
            assertFalse(nft.canRetry(never[i]));
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(FiveWords.NotRetryable.selector, never[i]));
            nft.retry(never[i]);
        }
        // Ordered and still in time.
        _addWords(1, 5, 5);
        bytes32 requestId = intake.lastRequestId();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotRetryable.selector, 1));
        nft.retry(1);
        // Delivered.
        _deliver(requestId, RESULT_URI);
        vm.warp(block.timestamp + 30 days);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotRetryable.selector, 1));
        nft.retry(1);
        assertEq(imd.balanceOf(stranger), 10 * PRICE);
        assertEq(imd.balanceOf(treasury), PRICE);
    }

    function test_anOrderWithNoAnswerForADayCanBeOrderedAgain() public {
        bytes32 first = _fill(1);
        uint256 orderedAt = block.timestamp;
        vm.warp(orderedAt + 24 hours - 1);
        assertFalse(nft.canRetry(1));
        vm.warp(orderedAt + 24 hours);
        assertTrue(nft.canRetry(1));
        bytes32 second = _retry(stranger, 1);
        // The wait starts again with the new request.
        assertFalse(nft.canRetry(1));
        assertEq(nft.imageInfo(1).orderedAt, orderedAt);
        assertEq(nft.imageInfo(2).opensAt, orderedAt + 5 hours);

        // The replaced request's late answer, either kind, is refused and changes nothing.
        assertFalse(_fail(first, 2, bytes32("failed")));
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Ordered));
        assertEq(nft.imageInfo(1).requestId, second);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOutstanding.selector, first));
        nft.onResult(first, RESULT_HASH, RESULT_URI);
        assertTrue(_deliver(second, RESULT_URI));
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Delivered));
    }

    function test_orderingAgainPaysTheLivePrice() public {
        bytes32 first = _fill(1);
        _fail(first, 2, bytes32("blocked"));
        intake.setPrice(ACTION, address(imd), 0.8 ether);
        assertEq(nft.retryPrice(), 0.8 ether);

        imd.mint(stranger, 1 ether);
        vm.startPrank(stranger);
        imd.approve(address(nft), 0.8 ether - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(nft), 0.8 ether - 1, 0.8 ether
            )
        );
        nft.retry(1);
        imd.approve(address(nft), 0.8 ether);
        nft.retry(1);
        vm.stopPrank();
        assertEq(imd.balanceOf(stranger), 0.2 ether);
        assertEq(imd.balanceOf(treasury), PRICE + 0.8 ether);
        assertEq(imd.balanceOf(address(nft)), 0);
        assertEq(imd.allowance(address(nft), address(intake)), 0);
    }

    function test_aRefusedReorderRollsBack() public {
        bytes32 first = _fill(1);
        _fail(first, 2, bytes32("failed"));
        imd.mint(stranger, PRICE);
        vm.startPrank(stranger);
        imd.approve(address(nft), PRICE);
        vm.stopPrank();

        intake.setMode(MockIntake.Mode.Refusing, "");
        vm.prank(stranger);
        vm.expectRevert(MockIntake.Refused.selector);
        nft.retry(1);
        intake.setMode(MockIntake.Mode.NotPulling, "");
        vm.prank(stranger);
        vm.expectRevert(FiveWords.PaymentNotTaken.selector);
        nft.retry(1);

        FiveWords.Image memory img = nft.imageInfo(1);
        assertEq(uint8(img.status), uint8(FiveWords.Status.Failed));
        assertEq(img.orders, 1);
        assertEq(img.requestId, first);
        assertEq(imd.balanceOf(stranger), PRICE);
        assertEq(imd.balanceOf(address(nft)), 0);
        assertEq(imd.allowance(address(nft), address(intake)), 0);
    }

    function test_theLastImageCanBeOrderedAgainAfterTheGameEnds() public {
        bytes32 requestId;
        for (uint256 image = 1; image <= 5; ++image) {
            vm.warp(nft.imageInfo(image).opensAt);
            requestId = _fill(image);
        }
        assertEq(nft.currentImage(), 0);
        _fail(requestId, 2, bytes32("failed"));
        bytes32 again = _retry(stranger, 5);
        assertTrue(_deliver(again, RESULT_URI));
        assertEq(nft.imageURI(5), IMAGE_URI);
        assertEq(nft.imagesOrdered(), 5);
        assertEq(imd.balanceOf(treasury), 6 * PRICE);
    }

    // ---- which result URIs are accepted ----

    function testFuzz_aPlainUriOfAnyLengthIsAccepted(uint256 seed, uint8 length) public {
        bytes32 requestId = _fill(1);
        bytes memory uri = _plainBytes(seed, bound(length, 1, 128));
        vm.prank(address(intake));
        nft.onResult(requestId, RESULT_HASH, string(uri));
        assertEq(bytes(nft.imageInfo(1).uri), uri);
    }

    function testFuzz_oneByteDecidesWhetherAUriIsAccepted(uint256 seed, uint8 length, uint8 position, bytes1 other)
        public
    {
        bytes32 requestId = _fill(1);
        bytes memory uri = _plainBytes(seed, bound(length, 1, 128));
        uri[bound(position, 0, uri.length - 1)] = other;
        vm.prank(address(intake));
        if (!_isPlain(other)) vm.expectRevert(FiveWords.BadUri.selector);
        nft.onResult(requestId, RESULT_HASH, string(uri));
        assertEq(
            uint8(nft.imageInfo(1).status),
            uint8(_isPlain(other) ? FiveWords.Status.Delivered : FiveWords.Status.Ordered)
        );
    }

    function testFuzz_anyBytesAreAcceptedOnlyWhenEveryByteIsPlain(bytes memory uri) public {
        bytes32 requestId = _fill(1);
        bool good = uri.length != 0 && uri.length <= 128;
        for (uint256 i; good && i < uri.length; ++i) {
            good = _isPlain(uri[i]);
        }
        vm.prank(address(intake));
        if (!good) vm.expectRevert(FiveWords.BadUri.selector);
        nft.onResult(requestId, RESULT_HASH, string(uri));
    }

    /// @dev All 256 byte values, at the first and the last byte of a URI that ends before, just
    /// after and on a 32-byte boundary.
    function test_everyByteValueIsJudgedAtTheEdgesOfAChunk() public {
        bytes32 requestId = _fill(1);
        uint256 snapshot = vm.snapshotState();
        uint256[4] memory lengths = [uint256(1), 31, 33, 128];
        for (uint256 l; l < lengths.length; ++l) {
            uint256 length = lengths[l];
            for (uint256 edge; edge < (length == 1 ? 1 : 2); ++edge) {
                bytes memory uri = _plainBytes(length, length);
                uint256 position = edge == 0 ? 0 : length - 1;
                for (uint256 value; value < 256; ++value) {
                    uri[position] = bytes1(uint8(value));
                    vm.prank(address(intake));
                    (bool ok,) = address(nft).call(abi.encodeCall(nft.onResult, (requestId, RESULT_HASH, string(uri))));
                    assertEq(ok, _isPlain(bytes1(uint8(value))));
                    if (ok) vm.revertToState(snapshot);
                }
            }
        }
    }

    function _isPlain(bytes1 c) private pure returns (bool) {
        return c >= 0x21 && c <= 0x7e && c != 0x22 && c != 0x5c;
    }

    /// @dev `length` bytes drawn from every plain character.
    function _plainBytes(uint256 seed, uint256 length) private pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            bytes1 c = bytes1(uint8(0x21 + uint256(keccak256(abi.encode(seed, i))) % 94));
            out[i] = _isPlain(c) ? c : bytes1("a");
        }
    }

    function _uriOfLength(uint256 length) private pure returns (string memory) {
        bytes memory uri = new bytes(length);
        bytes memory prefix = "ipfs://";
        for (uint256 i; i < length; ++i) {
            uri[i] = i < prefix.length ? prefix[i] : bytes1("z");
        }
        return string(uri);
    }
}
