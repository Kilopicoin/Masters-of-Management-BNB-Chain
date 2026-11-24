// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// Separate namespace preserves historical balances and redemption accounting.
// Relics settled under the new rules remain visible in the realm inventory.
library RelicSettlement {
    bytes32 private constant SLOT=keccak256("ravengard.relic.retained.settlement.v1");
    struct Data {mapping(int32=>mapping(int32=>uint256)) settled;}
    function data() internal pure returns(Data storage d){bytes32 slot=SLOT;assembly("memory-safe"){d.slot:=slot}}
}
