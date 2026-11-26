// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIntake} from "../../src/IIntake.sol";

/// @notice A local stand-in that keeps the live Intake's rules as a client sees them: it reverts on
/// an action it does not sell, below the price and on an empty body; records the payer, the target
/// and both selectors; pulls exactly `amount` and forwards it to the treasury; and only its writer
/// completes a request, calling the target once with `selector ++ args` under 200,000 gas in a try.
contract MockIntake is IIntake {
    enum Mode {
        Normal,
        Refusing, // every request reverts
        NotPulling, // takes the request but leaves the payment and the allowance
        SameId, // returns the previous request id again
        Reentering // calls `reenterData` on the caller before returning
    }

    struct Request {
        address payer;
        address target;
        bytes4 selector;
        bytes4 onFailure;
        bool pending;
    }

    error ActionNotSold(bytes32 action, address asset);
    error ShortPayment(uint256 amount, uint256 price);
    error EmptyBody();
    error BodyTooLong();
    error Refused();
    error NotWriter();
    error NotPending(bytes32 requestId);
    error OutOfGas();

    event Requested(
        bytes32 indexed requestId,
        address indexed payer,
        bytes32 indexed action,
        bytes body,
        address callbackTarget,
        bytes4 callbackSelector,
        address asset,
        uint256 amount
    );
    event Completed(bytes32 indexed requestId, uint8 status, bytes32 resultHash, string uri, bool delivered);

    uint256 public constant CALLBACK_GAS = 200_000;

    address public immutable treasury;
    address public immutable writer;
    Mode public mode;
    bytes public reenterData;
    uint256 public nonce;
    bytes32 public lastRequestId;
    bytes public lastBody;
    mapping(bytes32 action => mapping(address asset => uint256)) public prices;
    mapping(bytes32 requestId => Request) public requests;

    constructor(address treasury_, address writer_) {
        treasury = treasury_;
        writer = writer_;
    }

    function setPrice(bytes32 action, address asset, uint256 price) external {
        prices[action][asset] = price;
    }

    function setMode(Mode mode_, bytes calldata reenterData_) external {
        mode = mode_;
        reenterData = reenterData_;
    }

    function priceOf(bytes32 action, address asset) external view returns (uint256) {
        return prices[action][asset];
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 requestId) {
        if (mode == Mode.Refusing) revert Refused();
        uint256 price = prices[action][asset];
        if (price == 0) revert ActionNotSold(action, asset);
        if (amount < price) revert ShortPayment(amount, price);
        if (body.length == 0) revert EmptyBody();
        if (body.length > 16 * 1024) revert BodyTooLong();

        requestId = mode == Mode.SameId ? lastRequestId : keccak256(abi.encode(block.chainid, address(this), ++nonce));
        requests[requestId] = Request(msg.sender, callback.target, callback.selector, onFailure, true);
        lastRequestId = requestId;
        lastBody = body;
        if (mode != Mode.NotPulling) require(IERC20(asset).transferFrom(msg.sender, treasury, amount), "pull failed");
        emit Requested(requestId, msg.sender, action, body, callback.target, callback.selector, asset, amount);

        if (mode == Mode.Reentering) {
            (bool ok, bytes memory returned) = msg.sender.call(reenterData);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(returned, 0x20), mload(returned))
                }
            }
        }
    }

    /// @notice The writer's completion. Status 0 calls the result selector, any other the failure
    /// selector, with `args` as the plane encodes them.
    function complete(bytes32 requestId, uint8 status, bytes32 resultHash, string calldata uri, bytes calldata args)
        external
        returns (bool delivered)
    {
        if (msg.sender != writer) revert NotWriter();
        Request storage r = requests[requestId];
        if (!r.pending) revert NotPending(requestId);
        r.pending = false;
        bytes4 selector = status == 0 ? r.selector : r.onFailure;
        if (r.target != address(0) && selector != bytes4(0)) {
            // Running short must revert, never skip the callback.
            if (gasleft() < CALLBACK_GAS * 64 / 63 + 10_000) revert OutOfGas();
            (delivered,) = r.target.call{gas: CALLBACK_GAS}(bytes.concat(selector, args));
        }
        emit Completed(requestId, status, resultHash, uri, delivered);
    }

    /// @notice Test hook: calls `target` as this Intake, under the callback gas limit, and reports
    /// what the call used. A nested call, so the figure is the same however the test is run.
    function measure(address target, bytes calldata data) external returns (bool ok, uint256 used) {
        uint256 before = gasleft();
        (ok,) = target.call{gas: CALLBACK_GAS}(data);
        used = before - gasleft();
    }
}
