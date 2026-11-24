// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Sparse receipt discovery for ordinary public HTTP RPCs. These bookmarks
/// contain no balances or permissions; canonical transaction receipts remain
/// the source of events. Namespaced storage also works through fixed delegates.
abstract contract PublicRPCWriter {
    bytes32 private constant RPC_SLOT = keccak256("mom.public-rpc.activity.v1");
    modifier rpcIndexed() {
        _recordRPCActivity(RPC_SLOT);
        _;
    }
    function _recordRPCRecipient(address account) internal {
        _recordRPCActivity(keccak256(abi.encode(account, RPC_SLOT)));
    }
    function _recordRPCActivity(bytes32 slot) private {
        assembly ("memory-safe") {
            let value := or(shl(160, number()), origin())
            let count := sload(slot)
            mstore(0, slot)
            let base := keccak256(0, 32)
            if or(iszero(count), iszero(eq(sload(add(base, sub(count, 1))), value))) {
                sstore(add(base, count), value)
                sstore(slot, add(count, 1))
            }
        }
    }
}
abstract contract PublicRPCEvents is PublicRPCWriter {
    /// Bounded pages, readable at latest state without an archive node.
    function rpcActivity(address recipient, uint256 offset, uint256 limit) external view returns(uint256, uint256[] memory) {
        bytes32 slot = keccak256("mom.public-rpc.activity.v1");
        if(recipient!=address(0)) slot=keccak256(abi.encode(recipient,slot));
        assembly ("memory-safe") {
            if gt(limit, 128) { revert(0, 0) }
            let count := sload(slot)
            let length := 0
            if lt(offset, count) { length := sub(count, offset) }
            if gt(length, limit) { length := limit }
            let out := mload(0x40)
            mstore(out, count)
            mstore(add(out,32),64)
            mstore(add(out,64),length)
            mstore(0, slot)
            let base := add(keccak256(0, 32), offset)
            for { let i := 0 } lt(i, length) { i := add(i, 1) } {
                mstore(add(add(out, 96), mul(i, 32)), sload(add(base, i)))
            }
            return(out, add(96,mul(length,32)))
        }
    }
}
