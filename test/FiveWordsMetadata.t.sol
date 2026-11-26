// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {FiveWords} from "../src/FiveWords.sol";
import {IIntake} from "../src/IIntake.sol";
import {FiveWordsBase} from "./FiveWordsBase.sol";

/// @notice Onchain metadata before and after the image arrives, and the contract as it is deployed.
contract FiveWordsMetadataTest is FiveWordsBase {
    string private constant DESCRIPTION =
        "five strangers write one image prompt, one word each, and the imd swarm draws it. an onchain experiment: the nfts aren't worth anything.";
    string private constant JSON_PREFIX = "data:application/json;base64,";
    string private constant SVG_PREFIX = "data:image/svg+xml;base64,";

    // ---- before the image arrives ----

    function test_aPendingTokenShowsAnSvgOfItsWords() public {
        _addWords(1, 1, 2);
        string memory svg = nft.svgOf(2);
        assertEq(
            svg,
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000"><rect width="1000" height="1000" fill="#fff"/><rect x="20" y="20" width="960" height="960" fill="none" stroke="#000" stroke-width="8"/><g font-family="monospace" font-size="56" fill="#999"><text x="90" y="240">1 quiet</text><text x="90" y="360" fill="#000" font-weight="bold">2 orange</text><text x="90" y="480">3 _</text><text x="90" y="600">4 _</text><text x="90" y="720">5 _</text><text x="90" y="900" font-size="28">fivewords 1/5</text></g></svg>'
        );

        string memory json = string.concat(
            '{"name":"fivewords #2 - orange","description":"',
            DESCRIPTION,
            '","image":"',
            SVG_PREFIX,
            Base64.encode(bytes(svg)),
            '","attributes":[{"trait_type":"image","value":1},{"trait_type":"slot","value":2},{"trait_type":"word","value":"orange"},{"trait_type":"phrase","value":"quiet orange"},{"trait_type":"status","value":"writing"}]}'
        );
        assertEq(nft.tokenURI(2), string.concat(JSON_PREFIX, Base64.encode(bytes(json))));
        // The document is JSON a marketplace can read.
        assertEq(vm.parseJsonString(json, ".name"), "fivewords #2 - orange");
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "orange");
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 2);
    }

    function test_everyTokenOfAnImageShowsThePhraseSoFarWithItsOwnWordInBlack() public {
        _addWords(1, 1, 3);
        string memory first = nft.svgOf(1);
        assertTrue(_contains(first, '<text x="90" y="240" fill="#000" font-weight="bold">1 quiet</text>'));
        assertTrue(_contains(first, '<text x="90" y="480">3 lighthouse</text>'));
        assertTrue(_contains(nft.svgOf(3), '<text x="90" y="480" fill="#000" font-weight="bold">3 lighthouse</text>'));
        assertTrue(_contains(nft.svgOf(3), '<text x="90" y="240">1 quiet</text>'));

        // The longest word still goes in whole.
        vm.warp(deployedAt + 1);
        _add(stranger, "abcdefghijklmnopqrst");
        assertTrue(_contains(nft.svgOf(4), ">4 abcdefghijklmnopqrst</text>"));
        assertTrue(_contains(nft.svgOf(1), ">4 abcdefghijklmnopqrst</text>"));
    }

    function test_anOrderedOrFailedImageKeepsItsSvg() public {
        bytes32 requestId = _fill(1);
        string memory svgUri = string.concat(SVG_PREFIX, Base64.encode(bytes(nft.svgOf(5))));
        assertEq(nft.tokenURI(5), _metadata(5, "clouds", svgUri, 1, 5, "ordered"));
        _fail(requestId, 2, bytes32("failed"));
        assertEq(nft.tokenURI(5), _metadata(5, "clouds", svgUri, 1, 5, "failed"));
        assertTrue(_contains(nft.svgOf(5), "fivewords 1/5"));
    }

    // ---- after ----

    function test_aDeliveredTokenPointsAtTheImagePinnedBesideTheResult() public {
        _fill(1);
        vm.warp(nft.imageInfo(2).opensAt);
        bytes32 requestId = _fill(2);
        _deliver(requestId, RESULT_URI);

        string memory json = _json(8, "lighthouse", IMAGE_URI, 2, 3, "delivered");
        assertEq(nft.tokenURI(8), string.concat(JSON_PREFIX, Base64.encode(bytes(json))));
        assertEq(vm.parseJsonString(json, ".image"), IMAGE_URI);
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), "quiet orange lighthouse above clouds");
        assertEq(vm.parseJsonString(json, ".attributes[4].value"), "delivered");
        assertEq(nft.imageURI(2), IMAGE_URI);
        // The other image is still its words.
        assertEq(nft.imageURI(1), "");
        assertEq(
            nft.tokenURI(3),
            _metadata(3, "lighthouse", string.concat(SVG_PREFIX, Base64.encode(bytes(nft.svgOf(3)))), 1, 3, "ordered")
        );
    }

    function test_theImageIsBesideAResultUriOfAnyShape() public {
        string[5] memory uris = [
            "https://plane.example/intake-results/0xabc",
            "https://plane.example/intake-results/0xabc/",
            "ipfs://cid/notresult.json",
            "result.json",
            "ipfs://cid/sub/result.json"
        ];
        string[5] memory images = [
            "https://plane.example/intake-results/0xabc/artifacts/print.png",
            "https://plane.example/intake-results/0xabc/artifacts/print.png",
            "ipfs://cid/notresult.json/artifacts/print.png",
            "result.json/artifacts/print.png",
            "ipfs://cid/sub/artifacts/print.png"
        ];
        for (uint256 image = 1; image <= 5; ++image) {
            vm.warp(nft.imageInfo(image).opensAt);
            bytes32 requestId = _fill(image);
            assertTrue(_deliver(requestId, uris[image - 1]));
            assertEq(nft.imageURI(image), images[image - 1]);
            assertEq(nft.imageInfo(image).uri, uris[image - 1]);
        }
    }

    // ---- reading ----

    function test_aTokenThatIsNotMintedHasNoMetadata() public {
        _addWords(1, 1, 2);
        uint256[3] memory missing = [uint256(0), 3, 26];
        for (uint256 i; i < missing.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, missing[i]));
            nft.tokenURI(missing[i]);
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, missing[i]));
            nft.svgOf(missing[i]);
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, missing[i]));
            nft.slotOf(missing[i]);
        }
    }

    function test_readingAnImageThatDoesNotExistReverts() public {
        uint256[2] memory missing = [uint256(0), 6];
        for (uint256 i; i < missing.length; ++i) {
            bytes memory err = abi.encodeWithSelector(FiveWords.NoSuchImage.selector, missing[i]);
            vm.expectRevert(err);
            nft.imageInfo(missing[i]);
            vm.expectRevert(err);
            nft.wordsOf(missing[i]);
            vm.expectRevert(err);
            nft.phraseOf(missing[i]);
            vm.expectRevert(err);
            nft.bodyOf(missing[i]);
            vm.expectRevert(err);
            nft.imageURI(missing[i]);
        }
        assertEq(nft.phraseOf(5), "");
    }

    function test_collectionMetadataAndInterfaces() public view {
        assertEq(
            nft.contractURI(),
            string.concat(
                JSON_PREFIX,
                Base64.encode(bytes(string.concat('{"name":"fivewords","description":"', DESCRIPTION, '"}')))
            )
        );
        assertTrue(nft.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(nft.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(nft.supportsInterface(0x5b5e139f)); // ERC-721 metadata
        assertTrue(nft.supportsInterface(0x49064906)); // ERC-4906
        assertFalse(nft.supportsInterface(0xffffffff));
    }

    // ---- the contract as deployed ----

    function test_itDeploysWithTheLaunchParametersWhereNothingElseExists() public {
        address liveIntake = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
        address liveImd = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
        bytes32 liveAction = 0x6a6f622e6f70656e406a6f622d31000000000000000000000000000000000000;
        assertEq(liveIntake.code.length, 0);
        vm.warp(1_900_000_000);
        FiveWords live = new FiveWords(IIntake(liveIntake), IERC20(liveImd), liveAction);
        assertEq(address(live.intake()), liveIntake);
        assertEq(address(live.imd()), liveImd);
        assertEq(live.action(), bytes32("job.open@job-1"));
        assertEq(live.imageInfo(1).opensAt, 1_900_000_000);
        assertEq(live.currentImage(), 1);
    }

    function test_theConstructorRefusesMissingParameters() public {
        vm.expectRevert(FiveWords.ZeroAddress.selector);
        new FiveWords(IIntake(address(0)), imd, ACTION);
        vm.expectRevert(FiveWords.ZeroAddress.selector);
        new FiveWords(IIntake(address(intake)), IERC20(address(0)), ACTION);
        vm.expectRevert(FiveWords.ZeroAction.selector);
        new FiveWords(IIntake(address(intake)), imd, bytes32(0));
    }

    function test_thereIsNoOwnerAndNoWayToTakeIMDOut() public {
        string[6] memory absent = [
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "withdraw()",
            "pause()",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < absent.length; ++i) {
            (bool ok,) = address(nft).call(bytes.concat(bytes4(keccak256(bytes(absent[i]))), bytes32(0)));
            assertFalse(ok, absent[i]);
        }
        // It takes no ETH either.
        vm.deal(address(this), 1 ether);
        (bool sent,) = address(nft).call{value: 1 ether}("");
        assertFalse(sent);
    }

    /// @dev The same scan the launch's protected floor runs: a runtime within EIP-170 with no
    /// DELEGATECALL, CALLCODE or SELFDESTRUCT that execution can reach.
    function test_theRuntimeIsBoundedAndHasNoEscapeOpcodes() public view {
        bytes memory code = address(nft).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }

    function _json(
        uint256 tokenId,
        string memory word,
        string memory picture,
        uint256 image,
        uint256 slot,
        string memory status
    ) private view returns (string memory) {
        return string.concat(
            '{"name":"fivewords #',
            vm.toString(tokenId),
            " - ",
            word,
            '","description":"',
            DESCRIPTION,
            '","image":"',
            picture,
            '","attributes":[{"trait_type":"image","value":',
            vm.toString(image),
            '},{"trait_type":"slot","value":',
            vm.toString(slot),
            '},{"trait_type":"word","value":"',
            word,
            '"},{"trait_type":"phrase","value":"',
            nft.phraseOf(image),
            '"},{"trait_type":"status","value":"',
            status,
            '"}]}'
        );
    }

    function _metadata(
        uint256 tokenId,
        string memory word,
        string memory picture,
        uint256 image,
        uint256 slot,
        string memory status
    ) private view returns (string memory) {
        return string.concat(JSON_PREFIX, Base64.encode(bytes(_json(tokenId, word, picture, image, slot, status))));
    }
}
