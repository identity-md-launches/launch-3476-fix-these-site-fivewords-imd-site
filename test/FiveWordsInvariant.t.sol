// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FiveWords} from "../src/FiveWords.sol";
import {IIntake} from "../src/IIntake.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Drives the game in random order: words from many wallets, price moves, results, failures,
/// late answers to replaced requests, retries, stray callbacks, transfers and time. Every input is
/// bounded so that most calls do something; the ones that must be refused are checked inline.
contract FiveWordsHandler is Test {
    bytes32 internal constant ACTION = bytes32("job.open@job-1");
    uint256 internal constant ACTORS = 12;

    FiveWords internal immutable nft;
    MockIntake internal immutable intake;
    MockERC20 internal immutable imd;
    address internal immutable writer;
    address internal immutable treasury;

    address[] public actors;
    uint256 public time;

    // ---- ghosts ----
    /// IMD minted to wallets so they can pay. Every wallet is given exactly what it then pays.
    uint256 public ghostMinted;
    /// IMD the contract pulled from wallets, measured by balance.
    uint256 public ghostPulled;
    /// The price of every order, first or retry, at the moment it was made.
    uint256 public ghostOrdered;
    uint256 public ghostMints;
    mapping(uint256 => uint256) public ghostOrders;
    mapping(uint256 => uint256) public ghostOrderedAt;
    mapping(uint256 => bool) public ghostDelivered;
    mapping(uint256 => string) public ghostUri;
    mapping(uint256 => bytes32) public ghostResultHash;
    mapping(uint256 => mapping(uint256 => string)) public ghostWord;
    mapping(uint256 => mapping(uint256 => address)) public ghostWriter;
    bytes32[] public replaced;
    uint256 public refusedCallbacks;
    uint256 public calls;
    uint256 public gameOverHits;
    uint256 public retries;

    constructor(FiveWords nft_, MockIntake intake_, MockERC20 imd_, address writer_, address treasury_) {
        nft = nft_;
        intake = intake_;
        imd = imd_;
        writer = writer_;
        treasury = treasury_;
        time = block.timestamp;
        for (uint256 i; i < ACTORS; ++i) {
            actors.push(makeAddr(string.concat("actor-", vm.toString(i))));
        }
    }

    modifier step() {
        vm.warp(time);
        ++calls;
        _;
    }

    function _word(uint256 seed) internal pure returns (string memory) {
        uint256 length = 1 + seed % 20;
        bytes memory w = new bytes(length);
        bytes32 r = keccak256(abi.encode(seed));
        for (uint256 i; i < length; ++i) {
            w[i] = bytes1(uint8(0x61 + uint8(r[i]) % 26));
        }
        return string(w);
    }

    function _pay(address who, uint256 amount) internal {
        imd.mint(who, amount);
        ghostMinted += amount;
        vm.prank(who);
        imd.approve(address(nft), amount);
    }

    // ---- what people do ----

    function addWord(uint256 actorSeed, uint256 wordSeed, bool waitForOpen) external step {
        _addWord(actorSeed, wordSeed, waitForOpen);
    }

    /// Writes every word still missing from the open image, waiting for it to open, so that a run
    /// reaches the later rounds and the end of the game.
    function fillImage(uint256 seed) external step {
        uint256 image = nft.currentImage();
        if (image == 0) {
            _addWord(seed, seed, true);
            return;
        }
        uint256 missing = 5 - nft.imageInfo(image).wordCount;
        for (uint256 i; i < missing; ++i) {
            _addWord(uint256(keccak256(abi.encode(seed, i))), seed / (i + 1), true);
        }
    }

    function _addWord(uint256 actorSeed, uint256 wordSeed, bool waitForOpen) internal {
        uint256 image = nft.currentImage();
        address who = actors[actorSeed % ACTORS];
        string memory word = _word(wordSeed);
        if (image == 0) {
            vm.prank(who);
            vm.expectRevert(FiveWords.GameOver.selector);
            nft.addWord(word);
            assertEq(nft.amountDue(), 0, "nothing is due once the game is over");
            ++gameOverHits;
            return;
        }
        FiveWords.Image memory img = nft.imageInfo(image);
        if (block.timestamp < img.opensAt) {
            if (!waitForOpen) {
                vm.prank(who);
                vm.expectRevert(abi.encodeWithSelector(FiveWords.NotOpenYet.selector, image, img.opensAt));
                nft.addWord(word);
                return;
            }
            time = img.opensAt;
            vm.warp(time);
        }
        if (nft.hasWord(image, who)) {
            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(FiveWords.AlreadyAdded.selector, image, who));
            nft.addWord(word);
            // Then a wallet that has not written this image does.
            for (uint256 i; i < ACTORS; ++i) {
                who = actors[(actorSeed % ACTORS + i) % ACTORS];
                if (!nft.hasWord(image, who)) break;
            }
        }

        uint256 slot = uint256(img.wordCount) + 1;
        uint256 price = intake.priceOf(ACTION, address(imd));
        uint256 due = nft.amountDue();
        if (slot < 5) assertEq(due, price / 5, "a word before the fifth costs a fifth of the live price");
        _pay(who, due);

        uint256 ownBefore = imd.balanceOf(address(nft));
        uint256 treasuryBefore = imd.balanceOf(treasury);
        vm.prank(who);
        uint256 tokenId = nft.addWord(word);

        assertEq(tokenId, (image - 1) * 5 + slot, "the token of the slot");
        assertEq(nft.ownerOf(tokenId), who, "minted to the writer");
        assertEq(imd.balanceOf(who), 0, "pulled exactly the amount due");
        assertEq(imd.allowance(who, address(nft)), 0, "the whole approval was used");
        ghostPulled += due;
        ++ghostMints;
        ghostWord[image][slot] = word;
        ghostWriter[image][slot] = who;
        if (slot == 5) {
            assertEq(imd.balanceOf(treasury) - treasuryBefore, price, "the order paid exactly the price");
            assertEq(ownBefore + due - price, imd.balanceOf(address(nft)), "the rest stays");
            ghostOrdered += price;
            ++ghostOrders[image];
            ghostOrderedAt[image] = block.timestamp;
            assertEq(keccak256(intake.lastBody()), keccak256(nft.bodyOf(image)), "the body sent is bodyOf");
        } else {
            assertEq(imd.balanceOf(treasury), treasuryBefore, "nothing leaves before the fifth word");
        }
    }

    function retry(uint256 imageSeed, uint256 actorSeed) external step {
        uint256 image = 1 + imageSeed % 6; // 6 is no image at all
        address who = actors[actorSeed % ACTORS];
        if (!nft.canRetry(image)) {
            vm.prank(who);
            vm.expectRevert(abi.encodeWithSelector(FiveWords.NotRetryable.selector, image));
            nft.retry(image);
            return;
        }
        uint256 price = intake.priceOf(ACTION, address(imd));
        _pay(who, price);
        bytes32 old = nft.imageInfo(image).requestId;
        uint256 potBefore = nft.pot();
        uint256 treasuryBefore = imd.balanceOf(treasury);
        vm.prank(who);
        bytes32 requestId = nft.retry(image);
        assertTrue(requestId != old, "a retry is a new request");
        assertEq(nft.pot(), potBefore, "a retry never spends the pot");
        assertEq(imd.balanceOf(treasury) - treasuryBefore, price, "a retry pays exactly the price");
        assertEq(imd.balanceOf(who), 0);
        ghostPulled += price;
        ghostOrdered += price;
        ++ghostOrders[image];
        replaced.push(old);
        ++retries;
    }

    function setPrice(uint256 seed) external step {
        uint256 price;
        uint256 kind = seed % 4;
        if (kind == 0) price = 1 + seed % 9; // below five wei: the first four words are free
        else if (kind == 1) price = 0.5 ether;
        else price = bound(seed, 1, 3 ether);
        intake.setPrice(ACTION, address(imd), price);
    }

    function warp(uint256 seconds_) external step {
        time += bound(seconds_, 0, 30 hours);
    }

    function transfer(uint256 tokenSeed, uint256 toSeed) external step {
        uint256 supply = nft.totalSupply();
        if (supply == 0) return;
        // Tokens are minted in order, so 1..totalSupply all exist.
        uint256 tokenId = 1 + tokenSeed % supply;
        address from = nft.ownerOf(tokenId);
        address to = actors[toSeed % ACTORS];
        vm.prank(from);
        nft.transferFrom(from, to, tokenId);
    }

    // ---- what the Intake's writer does ----

    function _ordered(uint256 imageSeed) internal view returns (uint256 image, bool found) {
        uint256 n = nft.imagesOrdered();
        if (n == 0) return (0, false);
        for (uint256 i; i < n; ++i) {
            image = 1 + (imageSeed % n + i) % n;
            if (nft.imageInfo(image).status == FiveWords.Status.Ordered) return (image, true);
        }
        return (0, false);
    }

    function deliver(uint256 imageSeed, uint256 cidSeed) external step {
        (uint256 image, bool found) = _ordered(imageSeed);
        if (!found) return;
        bytes32 requestId = nft.imageInfo(image).requestId;
        string memory uri = string.concat("ipfs://bafy", vm.toString(keccak256(abi.encode(cidSeed))), "/result.json");
        bytes32 resultHash = keccak256(bytes(uri));
        vm.prank(writer);
        bool delivered = intake.complete(requestId, 0, resultHash, uri, abi.encode(requestId, resultHash, uri));
        assertTrue(delivered, "the outstanding request's result is taken");
        ghostDelivered[image] = true;
        ghostUri[image] = uri;
        ghostResultHash[image] = resultHash;
    }

    function fail(uint256 imageSeed, bool refused) external step {
        (uint256 image, bool found) = _ordered(imageSeed);
        if (!found) return;
        bytes32 requestId = nft.imageInfo(image).requestId;
        uint8 status = refused ? 1 : 2;
        vm.prank(writer);
        bool delivered = intake.complete(
            requestId,
            status,
            bytes32(0),
            "",
            abi.encode(requestId, status, bytes32("failed"), uint16(0), uint16(0), bytes(""))
        );
        assertTrue(delivered, "the outstanding request's failure is taken");
        assertTrue(nft.canRetry(image));
    }

    /// A late answer to a request a retry replaced: the Intake still delivers it, the contract refuses.
    function lateAnswer(uint256 seed, bool asResult) external step {
        if (replaced.length == 0) return;
        bytes32 requestId = replaced[seed % replaced.length];
        (,,,, bool pending) = intake.requests(requestId);
        if (!pending) return;
        uint256 image = nft.imageOfRequest(requestId);
        FiveWords.Image memory before = nft.imageInfo(image);
        vm.prank(writer);
        bool delivered = asResult
            ? intake.complete(
                requestId,
                0,
                bytes32(seed),
                "ipfs://late/result.json",
                abi.encode(requestId, bytes32(seed), "ipfs://late/result.json")
            )
            : intake.complete(
                requestId, 2, 0, "", abi.encode(requestId, uint8(2), bytes32("failed"), uint16(0), uint16(0), bytes(""))
            );
        assertFalse(delivered, "an answer to a replaced request is refused");
        FiveWords.Image memory afterwards = nft.imageInfo(image);
        assertEq(uint8(afterwards.status), uint8(before.status));
        assertEq(afterwards.requestId, before.requestId);
        assertEq(afterwards.uri, before.uri);
        ++refusedCallbacks;
    }

    /// Anyone but the Intake calling back, with a real request id or a made-up one.
    function strayCallback(uint256 seed, bool asResult) external step {
        address who = seed % 3 == 0 ? writer : actors[seed % ACTORS];
        uint256 n = nft.imagesOrdered();
        bytes32 requestId = n == 0 ? bytes32(seed) : nft.imageInfo(1 + seed % n).requestId;
        vm.prank(who);
        vm.expectRevert(FiveWords.NotIntake.selector);
        if (asResult) nft.onResult(requestId, bytes32(seed), "ipfs://x/result.json");
        else nft.onFailure(requestId, 1, bytes32("x"), 0, 0, "");
        ++refusedCallbacks;
    }

    function actorCount() external pure returns (uint256) {
        return ACTORS;
    }
}

contract FiveWordsInvariantTest is Test {
    bytes32 internal constant ACTION = bytes32("job.open@job-1");

    FiveWords internal nft;
    MockIntake internal intake;
    MockERC20 internal imd;
    FiveWordsHandler internal handler;
    address internal treasury = makeAddr("treasury");
    address internal writer = makeAddr("writer");

    function setUp() public {
        vm.warp(1_800_000_000);
        intake = new MockIntake(treasury, writer);
        imd = new MockERC20();
        intake.setPrice(ACTION, address(imd), 0.5 ether);
        nft = new FiveWords(IIntake(address(intake)), imd, ACTION);
        handler = new FiveWordsHandler(nft, intake, imd, writer, treasury);
        targetContract(address(handler));
    }

    /// How far each run got: visible with -vv.
    function afterInvariant() external {
        emit log_named_uint("images ordered", nft.imagesOrdered());
        emit log_named_uint("retries", handler.retries());
        emit log_named_uint("late answers and stray callbacks refused", handler.refusedCallbacks());
        emit log_named_uint("game over reached", handler.gameOverHits());
    }

    /// What the contract holds is exactly the pot: an order spends exactly the price it holds.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 120
    function invariant_theContractHoldsExactlyThePot() public view {
        assertEq(imd.balanceOf(address(nft)), nft.pot());
    }

    /// Every IMD a wallet paid went to the treasury through an order, or is still in the pot.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 120
    function invariant_everyIMDIsAccountedFor() public view {
        assertEq(handler.ghostPulled(), handler.ghostMinted(), "wallets paid exactly what they were given");
        assertEq(imd.balanceOf(treasury), handler.ghostOrdered(), "the treasury got exactly the orders' prices");
        assertEq(imd.balanceOf(treasury) + imd.balanceOf(address(nft)), handler.ghostPulled(), "conservation");
        assertEq(imd.totalSupply(), handler.ghostMinted());
    }

    /// Nothing is left approved to the Intake after any call.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 120
    function invariant_nothingIsLeftApproved() public view {
        assertEq(imd.allowance(address(nft), address(intake)), 0);
    }

    /// The supply follows the words: five per ordered image plus the open image's, at most 25.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 120
    function invariant_supplyFollowsTheWords() public view {
        uint256 ordered = nft.imagesOrdered();
        uint256 supply = nft.totalSupply();
        assertLe(ordered, 5);
        assertLe(supply, 25);
        assertEq(supply, handler.ghostMints());
        uint256 open = ordered < 5 ? nft.imageInfo(ordered + 1).wordCount : 0;
        assertLt(open, 5);
        assertEq(supply, ordered * 5 + open);
        assertEq(nft.currentImage(), ordered < 5 ? ordered + 1 : 0);
    }

    /// Each image's state, clock, words and request stay what they were written as.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 120
    function invariant_imagesKeepTheirHistory() public view {
        uint256 ordered = nft.imagesOrdered();
        for (uint256 image = 1; image <= 5; ++image) {
            FiveWords.Image memory img = nft.imageInfo(image);
            uint256 actors = handler.actorCount();
            uint256 writers;
            for (uint256 a; a < actors; ++a) {
                if (nft.hasWord(image, handler.actors(a))) ++writers;
            }
            assertEq(writers, img.wordCount, "one word per wallet, one wallet per word");
            for (uint256 slot = 1; slot <= 5; ++slot) {
                if (slot <= img.wordCount) {
                    assertEq(img.words[slot - 1], handler.ghostWord(image, slot), "a word never changes");
                    assertTrue(nft.hasWord(image, handler.ghostWriter(image, slot)));
                } else {
                    assertEq(bytes(img.words[slot - 1]).length, 0);
                }
            }
            if (image <= ordered) {
                assertEq(img.wordCount, 5);
                assertTrue(img.status != FiveWords.Status.Writing, "an ordered image never reopens");
                assertEq(img.orders, handler.ghostOrders(image));
                assertGe(img.orders, 1);
                assertEq(img.orderedAt, handler.ghostOrderedAt(image), "a retry never moves the round clock");
                assertGe(img.requestedAt, img.orderedAt);
                assertEq(nft.imageOfRequest(img.requestId), image, "the outstanding request is bound");
                if (image < 5) assertEq(nft.imageInfo(image + 1).opensAt, uint256(img.orderedAt) + 5 hours);
                assertEq(
                    nft.canRetry(image),
                    img.status == FiveWords.Status.Failed
                        || (img.status == FiveWords.Status.Ordered
                            && block.timestamp >= uint256(img.requestedAt) + 24 hours)
                );
            } else {
                assertTrue(img.status == FiveWords.Status.Writing);
                assertEq(img.orders, 0);
                assertEq(img.orderedAt, 0);
                assertEq(img.requestId, bytes32(0));
                assertFalse(nft.canRetry(image));
                if (image > ordered + 1) {
                    assertEq(img.wordCount, 0);
                    assertEq(img.opensAt, 0, "a later image has no clock yet");
                }
            }
            if (handler.ghostDelivered(image)) {
                assertTrue(img.status == FiveWords.Status.Delivered, "a delivered image stays delivered");
                assertEq(img.uri, handler.ghostUri(image), "a delivered uri never changes");
                assertEq(img.resultHash, handler.ghostResultHash(image));
            } else {
                assertTrue(img.status != FiveWords.Status.Delivered);
                assertEq(bytes(img.uri).length, 0);
            }
        }
        assertFalse(nft.canRetry(0));
        assertFalse(nft.canRetry(6));
    }

    /// Every minted token is owned, and the tokens of the open image's unwritten slots do not exist.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 120
    function invariant_tokensMatchTheirSlots() public view {
        uint256 supply = nft.totalSupply();
        uint256 owned;
        for (uint256 a; a < handler.actorCount(); ++a) {
            owned += nft.balanceOf(handler.actors(a));
        }
        assertEq(owned, supply, "every token is held by a wallet that wrote or received one");
        if (supply > 0) {
            (uint256 image, uint256 slot) = nft.slotOf(supply);
            assertEq((image - 1) * 5 + slot, supply);
        }
    }
}
