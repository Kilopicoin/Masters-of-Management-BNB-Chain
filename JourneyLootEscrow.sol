// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// Separate namespace: existing world balances, routes and module layouts are unchanged.
library JourneyLootEscrow {
 bytes32 private constant SLOT=keccak256("mom.journey.loot.escrow.v1");
 struct Entry {uint256 amount; int32 x; int32 y; uint64 clanId; bool recorded;}
 struct State {mapping(uint256=>Entry) entries; uint256 total;}
 function data() internal pure returns(State storage s){bytes32 slot=SLOT;assembly("memory-safe"){s.slot:=slot}}
}
interface IJourneyLoot {
 function journeyLoot(uint256 id) external view returns(uint256);
 function collectJourneyLoot(uint256 id,int32 x,int32 y,uint64 clanId) external;
}
