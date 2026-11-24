// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
library ClanHallLevels {
 bytes32 constant SLOT=keccak256("mom.clan.hall.levels.v1");
 struct State {mapping(int32=>mapping(int32=>uint8)) level;mapping(uint64=>uint8) capacity;}
 function data() internal pure returns(State storage s){bytes32 p=SLOT;assembly("memory-safe"){s.slot:=p}}
}
interface IClanHallLevels {
 function leadershipHallEligible(uint64,int32,int32) external view returns(bool);
 function resetClanHallCapacity(int32,int32) external;
 function syncClanHallCapacity(uint64) external;
 function clanHallArmyLimit(uint64) external view returns(uint8);
 function upgradeClanHallFromMilitary(address,int32,int32,uint8) external;
}
