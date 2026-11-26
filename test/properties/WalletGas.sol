// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

/// @notice Checks that a call does its work at the gas a wallet sends.
/// @dev A wallet sends about what `eth_estimateGas` returns: the lowest gas limit at which the call
///      does not revert. Some add a margin and some add nothing. A function that checks `gasleft()`,
///      forwards a fixed amount of gas or catches a failed call can succeed at that limit with its
///      work skipped, and then a wallet cannot make it work. This runs the same search and compares
///      what the call returns and emits at that limit with what it returns and emits with gas to
///      spare.
abstract contract WalletGas is Test {
    /// @dev The most gas one transaction may carry on Ethereum (EIP-7825).
    uint256 internal constant GAS_TO_SPARE = 16_777_216;

    struct Outcome {
        bool ok;
        bytes returned;
        bytes32 events;
    }

    /// @notice Fails the test unless `from` calling `target` with `data` does the same at a
    ///         wallet's gas as with gas to spare. Nothing is left changed.
    function assertSameAtWalletGas(address from, address target, bytes memory data) internal {
        assertSameAtWalletGas(from, target, 0, data);
    }

    /// @notice The same for a call that sends `value`. Fund `from` first.
    function assertSameAtWalletGas(address from, address target, uint256 value, bytes memory data) internal {
        (Outcome memory spare, Outcome memory wallet) = _both(from, target, value, data);
        assertTrue(spare.ok, "the call reverts with gas to spare");
        assertTrue(wallet.ok, "the call reverts at a wallet's gas");
        assertEq(wallet.returned, spare.returned, "at a wallet's gas the call returns something else");
        assertEq(wallet.events, spare.events, "at a wallet's gas the call emits different events");
    }

    /// @notice Whether the call does the same at a wallet's gas, for a test that expects it not to.
    function sameAtWalletGas(address from, address target, bytes memory data) internal returns (bool) {
        (Outcome memory spare, Outcome memory wallet) = _both(from, target, 0, data);
        return spare.ok && wallet.ok && keccak256(wallet.returned) == keccak256(spare.returned)
            && wallet.events == spare.events;
    }

    function _both(address from, address target, uint256 value, bytes memory data)
        private
        returns (Outcome memory spare, Outcome memory wallet)
    {
        uint256 start = vm.snapshotState();
        spare = _callWith(from, target, value, data, GAS_TO_SPARE);
        if (spare.ok) {
            // What a node does for eth_estimateGas: find the lowest limit that does not revert.
            uint256 reverts = 0;
            uint256 passes = GAS_TO_SPARE;
            while (reverts + 1 < passes) {
                uint256 mid = (reverts + passes) / 2;
                vm.revertToState(start);
                if (_callWith(from, target, value, data, mid).ok) passes = mid;
                else reverts = mid;
            }
            vm.revertToState(start);
            wallet = _callWith(from, target, value, data, passes); // no margin: some senders add none
        }
        vm.revertToStateAndDelete(start);
    }

    function _callWith(address from, address target, uint256 value, bytes memory data, uint256 gas_)
        private
        returns (Outcome memory outcome)
    {
        vm.recordLogs();
        vm.prank(from);
        (outcome.ok, outcome.returned) = target.call{gas: gas_, value: value}(data);
        outcome.events = keccak256(abi.encode(vm.getRecordedLogs()));
    }
}
