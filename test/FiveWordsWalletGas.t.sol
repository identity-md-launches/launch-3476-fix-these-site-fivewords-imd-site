// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FiveWords} from "../src/FiveWords.sol";
import {FiveWordsBase} from "./FiveWordsBase.sol";
import {WalletGas} from "./properties/WalletGas.sol";

/// @notice Every call a person, a bot or the Intake's writer sends does the same at the gas a wallet
/// estimates as with gas to spare.
/// @dev `FiveWords` itself never reads `gasleft()` and catches no failed call, but the fifth word and
/// `retry` call the Intake with all-but-1/64 of what is left, and the writer's `complete` calls the
/// callback under a fixed 200,000 inside a try. At the estimated limit each must still mint, order and
/// store, or revert, never succeed with that work skipped.
contract FiveWordsWalletGasTest is FiveWordsBase, WalletGas {
    function _fund(address user, uint256 amount) private {
        imd.mint(user, amount);
        vm.prank(user);
        imd.approve(address(nft), amount);
    }

    function test_theFirstWordMintsAtAWalletsGas() public {
        address user = _user(1, 1);
        _fund(user, nft.amountDue());
        assertSameAtWalletGas(user, address(nft), abi.encodeCall(FiveWords.addWord, ("quiet")));
    }

    function test_aMiddleWordMintsAtAWalletsGas() public {
        _addWords(1, 1, 3);
        address user = _user(1, 4);
        _fund(user, nft.amountDue());
        assertSameAtWalletGas(user, address(nft), abi.encodeCall(FiveWords.addWord, ("lighthouse")));
    }

    function test_aLongMiddleWordMintsAtAWalletsGas() public {
        _addWords(1, 1, 2);
        address user = _user(1, 3);
        _fund(user, nft.amountDue());
        assertSameAtWalletGas(user, address(nft), abi.encodeCall(FiveWords.addWord, ("abcdefghijklmnopqrst")));
    }

    function test_theFifthWordMintsAndOrdersAtAWalletsGas() public {
        _addWords(1, 1, 4);
        address user = _user(1, 5);
        _fund(user, nft.amountDue());
        assertSameAtWalletGas(user, address(nft), abi.encodeCall(FiveWords.addWord, ("clouds")));
    }

    function test_theLastImagesFifthWordOrdersAtAWalletsGas() public {
        for (uint256 image = 1; image <= 4; ++image) {
            _fill(image);
            vm.warp(nft.imageInfo(image + 1).opensAt);
        }
        _addWords(5, 1, 4);
        address user = _user(5, 5);
        _fund(user, nft.amountDue());
        assertSameAtWalletGas(user, address(nft), abi.encodeCall(FiveWords.addWord, ("abcdefghijklmnopqrst")));
    }

    function test_aFreeFifthWordStillOrdersAtAWalletsGas() public {
        // A price fall leaves the pot above the price: the fifth word pulls nothing and still orders.
        _addWords(1, 1, 4);
        intake.setPrice(ACTION, address(imd), 0.3 ether);
        assertEq(nft.amountDue(), 0);
        address user = _user(1, 5);
        assertSameAtWalletGas(user, address(nft), abi.encodeCall(FiveWords.addWord, ("clouds")));
    }

    function test_retryingAFailedImageOrdersAtAWalletsGas() public {
        bytes32 requestId = _fill(1);
        _fail(requestId, 2, bytes32("failed"));
        address payer = makeAddr("payer");
        _fund(payer, nft.retryPrice());
        assertSameAtWalletGas(payer, address(nft), abi.encodeCall(FiveWords.retry, (1)));
    }

    function test_retryingAStaleImageOrdersAtAWalletsGas() public {
        _fill(1);
        vm.warp(block.timestamp + nft.RETRY_AFTER());
        address payer = makeAddr("payer");
        _fund(payer, nft.retryPrice());
        assertSameAtWalletGas(payer, address(nft), abi.encodeCall(FiveWords.retry, (1)));
    }

    /// The writer's `complete` stands in for the live Intake's: it calls `onResult` under 200,000 in a
    /// try. At the writer's estimated gas the result must still be delivered.
    function test_aResultIsDeliveredAtTheWritersGas() public {
        bytes32 requestId = _fill(1);
        string memory uri = _longestUri();
        bytes memory data =
            abi.encodeCall(intake.complete, (requestId, 0, RESULT_HASH, uri, abi.encode(requestId, RESULT_HASH, uri)));
        assertSameAtWalletGas(writer, address(intake), data);
        // And it really is delivered there, not merely the same as a run that also skipped.
        vm.prank(writer);
        (bool ok, bytes memory returned) = address(intake).call(data);
        assertTrue(ok);
        assertTrue(abi.decode(returned, (bool)));
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Delivered));
    }

    function test_aFailureIsRecordedAtTheWritersGas() public {
        bytes32 requestId = _fill(1);
        bytes memory data = abi.encodeCall(
            intake.complete,
            (
                requestId,
                1,
                bytes32(0),
                "",
                abi.encode(requestId, uint8(1), bytes32("body_refused"), uint16(0), uint16(0), bytes(""))
            )
        );
        assertSameAtWalletGas(writer, address(intake), data);
        vm.prank(writer);
        (bool ok, bytes memory returned) = address(intake).call(data);
        assertTrue(ok);
        assertTrue(abi.decode(returned, (bool)));
        assertEq(uint8(nft.imageInfo(1).status), uint8(FiveWords.Status.Failed));
    }

    function _longestUri() private view returns (string memory) {
        bytes memory u = new bytes(nft.MAX_URI_BYTES());
        bytes memory tail = bytes("/result.json");
        for (uint256 i; i < u.length; ++i) {
            u[i] = "a";
        }
        for (uint256 i; i < tail.length; ++i) {
            u[u.length - tail.length + i] = tail[i];
        }
        return string(u);
    }
}
