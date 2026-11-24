// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// Test-world migration refunds are realm-bound and cannot generate Influence.
library LegacyClanRefund {
 bytes32 internal constant SLOT=keccak256("mom.legacy.clan.store.refund.v1");
 struct State {mapping(int32=>mapping(int32=>uint256[5])) balance;}
 function data() internal pure returns(State storage s){bytes32 p=SLOT;assembly("memory-safe"){s.slot:=p}}
}
