// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// Namespaced additions preserve every pre-existing inventory and report slot.
library ArmySlots {
 bytes32 internal constant SLOT=keccak256("mom.army.type.slots.v1");
 struct Origin {int32 x;int32 y;uint64 clanId;bool recorded;}
 struct State {
  mapping(int32=>mapping(int32=>uint8)) realmLevel;
  mapping(uint64=>uint8) clanLevel;
  mapping(uint64=>uint32) accepted;
  mapping(int32=>mapping(int32=>uint256[20])) realmAway;
  mapping(uint64=>uint256[20]) clanAway;
  mapping(uint256=>Origin) origin;
 }
 function data() internal pure returns(State storage s){bytes32 p=SLOT;assembly("memory-safe"){s.slot:=p}}
 function count(uint32 mask) internal pure returns(uint8 n){while(mask!=0){mask&=mask-1;n++;}}
}
interface IArmySlots {
 function resetRealmArmyCapacity(int32,int32) external;
 function checkTraining(int32,int32,uint8) external view;
 function checkClanDonation(uint64,uint256[20] calldata) external view;
 function recordArmyDeparture(uint256,int32,int32,uint64,uint256[20] calldata) external;
 function recordArmyReceipt(uint256,uint256[20] calldata) external;
 function recordArmyLoss(uint256,uint256[24] calldata) external;
 function occupiedArmyTypes(int32,int32,uint64) external view returns(uint32);
}
