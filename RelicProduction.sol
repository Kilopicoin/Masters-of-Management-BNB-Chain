// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
// Realm-scoped, namespaced state survives forge demolition and upgrades.
library RelicProduction {
    bytes32 internal constant SLOT = keccak256("mom.relic.production.cooldown.v1");
    struct State { mapping(int32 => mapping(int32 => uint256)) nextAt; }
    function data() internal pure returns (State storage s) {
        bytes32 slot = SLOT;
        assembly { s.slot := slot }
    }
}
