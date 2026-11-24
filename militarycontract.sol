// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
pragma solidity 0.8.37;
import "fortificationrules.sol";
import "journeyinterfaces.sol";
import "battleengine.sol";
import "militaryreports.sol";
import "ArmySlots.sol";
import {BattleArchive} from "BattleArchive.sol";

interface IMilitaryLand is IJLand {
 function chargeMilitary(int32 x,int32 y,uint256[4] calldata cost,uint256 quantity,uint8 building) external;
 function recordTrainingScore(int32 x,int32 y,uint8 unit,uint256 quantity) external;
 function military() external view returns(address);
 function _clan() external view returns(address);
}
interface IMilitaryLogistics {
 function returnedTroops(int32 x,int32 y,uint64 clanId) external view returns(uint256[20] memory);
 function returnedArmyIds(int32 x,int32 y,uint64 clanId) external view returns(uint256[] memory);
}
interface IMilitaryLevel {function getTilePublic(int32 x,int32 y) external view returns(uint256 level,uint256 points);}
interface IMilitaryOwners {function hasOccupiedTile(address) external view returns(bool);function getOccupiedTileByAddress(address) external view returns(int32[2] memory);}
interface IMilitaryModifiers {function personalModifiers(int32 x,int32 y,int32 dx,int32 dy) external view returns(uint256,uint256);}

/// @notice New inventories are realm-owned. Legacy inventories remain in their original slots.
contract Military  is PublicRPCEvents {
 IJMap public immutable map;IMilitaryLand public immutable land;BattleEngine public immutable engine;
 mapping(int32=>mapping(int32=>uint256[20])) private troops;
 mapping(int32=>mapping(int32=>uint256[15])) private equipment;
 mapping(uint64=>uint256[20]) private clanTroops;
 mapping(uint256=>uint256[20]) private travelling;
 uint256 private guard=1;
 struct Summary {uint256 attackPower;uint256 defensePower;uint256[4] attackLoss;uint256[4] defenseLoss;uint256 sent;uint256 defenders;uint256 attackerLosses;uint256 defenderLosses;uint256 capacity;}
 struct Report {uint256 timestamp;uint256[24] sent;uint256[24] defenders;BattleEngine.Outcome result;}
 mapping(uint256=>Report) private reports;
 uint256[] private battleIds;
 mapping(uint256=>int32[4]) public battleCoords;
 mapping(uint256=>uint64) public battleClan;
 event MilitaryChanged(int32 indexed x,int32 indexed y);
 event ClanMilitaryChanged(uint64 indexed clanId);
 event EquipmentProduced(int32 indexed x,int32 indexed y,uint8 item,uint256 amount);
 event TroopsTrained(int32 indexed x,int32 indexed y,uint8 unit,uint256 amount);
 event BattleResolved(uint256 indexed journeyId,uint256 attackPower,uint256 defensePower);
 error InsufficientEquipment(uint8 item,uint256 required,uint256 available);
 error InsufficientTroops(uint8 unit,uint256 required,uint256 available);
 modifier onlyLogistics(){require(msg.sender==land.logistics(),"Only Logistics");_;}
 modifier locked(){require(guard==1,"Busy");guard=2;_;guard=1;}
 constructor(address m,address l,address e){reportsModule=new MilitaryReports(m,l,e);require(m.code.length>0&&l.code.length>0&&e.code.length>0,"Invalid modules");map=IJMap(m);land=IMilitaryLand(l);engine=BattleEngine(e);}
 function _owner(int32 x,int32 y) private {require(map.getTileOccupant(x,y)==msg.sender,"Not realm owner");(,,bool sale,,,)=map.tiles(x,y);require(!sale,"Remove realm sale first");land.recordActivity(x,y,msg.sender);}
 function _amount(uint256 n) private pure {require(n>0&&n<=100000,"Quantity 1 to 100000");}
 function unit(uint8 id) internal pure returns(MilitaryCatalog.Unit memory){return MilitaryCatalog.unit(id);}
 function gearCost(uint8 id) internal pure returns(uint256[4] memory){return MilitaryCatalog.gearCost(id);}
 function inventory(int32 x,int32 y) external view returns(uint256[20] memory,uint256[15] memory){return(troops[x][y],equipment[x][y]);}
 function realmArmy(int32 x,int32 y) public view returns(uint256[20] memory){return troops[x][y];}
 function clanArmy(uint64 id) external view returns(uint256[20] memory){return clanTroops[id];}
 function journeyArmy(uint256 id) public view returns(uint256[20] memory army){if(!armyReceived[id])army=travelling[id];}
 function inventoryHash(int32 x,int32 y) external view returns(bytes32){return keccak256(abi.encode(troops[x][y],equipment[x][y]));}
 function clanHash(uint64 id) external view returns(bytes32){return keccak256(abi.encode(clanTroops[id]));}
 function produce(int32 x,int32 y,uint8 item,uint256 n) rpcIndexed external locked { land.requireWorldActive(); 
  _owner(x,y);_amount(n);uint256[4] memory cost=MilitaryCatalog.gearCost(item);
  land.requireDepotSpace(x,y,item+100,n,false);
  land.chargeMilitary(x,y,cost,n,item<=10?2:1);equipment[x][y][item-1]+=n;
  emit EquipmentProduced(x,y,item,n);emit MilitaryChanged(x,y);
 }
 function _trainCost(int32 x,int32 y,uint8 id,uint256 n) private {
  MilitaryCatalog.Unit memory u=MilitaryCatalog.unit(id);(uint256 level,)=IMilitaryLevel(address(land)).getTilePublic(x,y);require(level>=u.level,"Realm level too low");
  if(id>=13)require(land.getBuildingCounts(x,y)[11]>0,"Build a Stable first");
  land.chargeMilitary(x,y,[uint256(id>=13?400:240),120,90,id>=13?100:60],n,4);
 }
 function train(int32 x,int32 y,uint8 id,uint256 n) rpcIndexed external locked { land.requireWorldActive(); 
  _owner(x,y);_amount(n);MilitaryCatalog.Unit memory u=MilitaryCatalog.unit(id);IArmySlots(address(this)).checkTraining(x,y,id);_trainCost(x,y,id,n);
  for(uint8 k;k<5;k++)if(u.recipe[k]>0)_takeEquipment(x,y,u.recipe[k],n);
  if(id>=13)land.adjustTileResources(x,y,11,n,false);
  troops[x][y][id-1]+=n;land.recordTrainingScore(x,y,id,n);emit TroopsTrained(x,y,id,n);emit MilitaryChanged(x,y);
 }
 // Retain the old selector so stale clients fail clearly; infantry can no longer be converted.
 function mount(int32,int32,uint8,uint256) external pure {revert("Train mounted troops directly");}
 /// Market escrow uses stable permanent item IDs 101..115; never trades soldiers.
 function adjustEquipment(int32 x,int32 y,uint8 item,uint256 n,bool adding) rpcIndexed external { land.requireWorldActive(); 
  require(msg.sender==address(land)&&item>=101&&item<=115,"Only Land equipment");
  if(adding)equipment[x][y][item-101]+=n;else _takeEquipment(x,y,item-100,n);emit MilitaryChanged(x,y);
 }
 function _takeEquipment(int32 x,int32 y,uint8 item,uint256 n) private {
  uint256 available=equipment[x][y][item-1];if(available<n)revert InsufficientEquipment(item,n,available);
  unchecked{equipment[x][y][item-1]=available-n;}
 }
 function _takeTroops(uint256[20] storage home,uint8 index,uint256 n) private {
  uint256 available=home[index];if(available<n)revert InsufficientTroops(index+1,n,available);
  unchecked{home[index]=available-n;}
 }
 function depart(uint256 id,int32 x,int32 y,uint64 clanId,uint256[20] calldata a) rpcIndexed external onlyLogistics { land.requireWorldActive(); 
  uint256[20] storage home=clanId==0?troops[x][y]:clanTroops[clanId];
  IArmySlots(address(this)).recordArmyDeparture(id,x,y,clanId,a);
  journeyResearchSnapshots[id]=land.unitResearchLevels(x,y);
  for(uint8 i;i<20;i++)if(a[i]>0){_takeTroops(home,i,a[i]);travelling[id][i]=a[i];}
  if(clanId==0)emit MilitaryChanged(x,y);else emit ClanMilitaryChanged(clanId);
 }
 // Each journey inventory is consumed once. Retaining its historical slots
 // avoids twenty storage clears; all live reads go through journeyArmy.
 function _receive(uint256 id,uint256[20] memory merged) private returns(uint256 total){
  if(armyReceived[id])return 0;
  IArmySlots(address(this)).recordArmyReceipt(id,travelling[id]);
  for(uint8 i;i<20;i++){uint256 n=travelling[id][i];merged[i]+=n;total+=n;}
  if(total>0)armyReceived[id]=true;
 }
 function _deposit(int32 x,int32 y,uint64 clanId,uint256[20] memory merged) private {
  if(clanId!=0)IArmySlots(address(this)).checkClanDonation(clanId,merged);
  uint256[20] storage home=clanId==0?troops[x][y]:clanTroops[clanId];bool moved;
  for(uint8 i;i<20;i++)if(merged[i]>0){home[i]+=merged[i];moved=true;}
  if(moved){if(clanId==0)emit MilitaryChanged(x,y);else emit ClanMilitaryChanged(clanId);}
 }
 function donateLocalArmy(int32 x,int32 y,uint64 id,uint256[20] calldata army) rpcIndexed external onlyLogistics {land.requireWorldActive();
  IJClan.Info memory info=IJClan(land._clan()).getClanInfo(id);require(info.exists&&info.leaderX==x&&info.leaderY==y,"Leader realm required");
  IArmySlots(address(this)).checkClanDonation(id,army);
  for(uint8 i;i<20;i++)if(army[i]>0){_takeTroops(troops[x][y],i,army[i]);clanTroops[id][i]+=army[i];}
  emit MilitaryChanged(x,y);emit ClanMilitaryChanged(id);
 }
 function receiveArmy(uint256 id,int32 x,int32 y,uint64 clanId) rpcIndexed external onlyLogistics returns(uint256 total){land.requireWorldActive();
  uint256[20] memory merged;total=_receive(id,merged);_deposit(x,y,clanId,merged);
 }
 function receiveArmies(uint256[] calldata ids,int32 x,int32 y,uint64 clanId) rpcIndexed external onlyLogistics returns(uint256[] memory totals){land.requireWorldActive();
  require(ids.length<=32,"Too many returns");totals=new uint256[](ids.length);uint256[20] memory merged;
  for(uint256 i;i<ids.length;i++)totals[i]=_receive(ids[i],merged);
  _deposit(x,y,clanId,merged);
 }
 function disband(uint64 id) rpcIndexed external { land.requireWorldActive(); require(msg.sender==land.clanWar(),"Only clan battle module");delete clanTroops[id];emit ClanMilitaryChanged(id);}
 function combine(uint256[4] memory old,uint256[20] memory a) public pure returns(uint256[24] memory all){for(uint8 i;i<4;i++)all[i]=old[i];for(uint8 i;i<20;i++)all[i+4]=a[i];}
 function totals(uint256[20] memory a) internal pure returns(uint256 total,uint256 foot){for(uint8 i;i<20;i++){total+=a[i];if(i<12)foot+=a[i];}}
 function pace(uint256[4] calldata old,uint256[20] calldata a) external view returns(uint256){return engine.pace(combine(old,a));}
 function paceAt(int32 x,int32 y,uint256[4] calldata old,uint256[20] calldata a) external view returns(uint256){return engine.paceResearched(combine(old,a),land.unitResearchLevels(x,y));}
 function _boost(uint256 level) private pure returns(uint256){return 10000+level*2500/(level+100);}
 function journeyResearch(uint256 id) public view returns(uint8[21] memory){return journeyResearchSnapshots[id];}
 function _defenders(int32 x,int32 y,uint64 clanId,uint256[4] memory old) private view returns(BattleEngine.Cohort[] memory cohorts,uint256[] memory ids){
  // Only collected home inventory defends. Pending returns keep their departure snapshots.
  ids=new uint256[](0);cohorts=new BattleEngine.Cohort[](1);
  cohorts[0]=BattleEngine.Cohort(combine(old,clanId==0?troops[x][y]:clanTroops[clanId]),land.unitResearchLevels(x,y));
 }
 function _calculate(int32 ax,int32 ay,int32 dx,int32 dy,uint64 clanId,uint256[24] memory a,BattleEngine.Cohort[] memory d,uint8[21] memory levels) private view returns(BattleEngine.Outcome memory o,uint256[24][] memory losses){
  uint256 ab=10000;uint256 db=10000;uint256 towers;
  if(clanId==0){(uint256 attackerLevel,)=IMilitaryLevel(address(land)).getTilePublic(ax,ay);(uint256 defenderLevel,)=IMilitaryLevel(address(land)).getTilePublic(dx,dy);
   (uint256 aa,)=IMilitaryModifiers(land.stable()).personalModifiers(ax,ay,dx,dy);(,uint256 dd)=IMilitaryModifiers(land.stable()).personalModifiers(dx,dy,ax,ay);
   ab=_boost(attackerLevel)*aa/10000;db=_boost(defenderLevel)*dd/10000;towers=land.fortificationUnits(dx,dy);}
  return engine.calculateCohorts(a,d,BattleEngine.Modifiers(ab,db,towers,levels,d[0].levels));
 }
 function preview(int32 ax,int32 ay,int32 dx,int32 dy,uint64 clanId,uint256[4] calldata oldA,uint256[4] calldata oldD,uint256[20] calldata selected) internal view returns(BattleEngine.Outcome memory o){
  (BattleEngine.Cohort[] memory defenders,)=_defenders(dx,dy,clanId,oldD);
  (o,)=_calculate(ax,ay,dx,dy,clanId,combine(oldA,selected),defenders,land.unitResearchLevels(ax,ay));
 }
 function resolve(uint256 id,int32 ax,int32 ay,int32 dx,int32 dy,uint64 clanId,uint256[4] calldata oldA,uint256[4] calldata oldD) rpcIndexed external returns(Summary memory result){land.requireWorldActive();
  require(msg.sender==(clanId==0?land.marketplaceAddress():land.clanWar()),"Only battle module");require(reports[id].timestamp==0&&packedReports[id].length==0&&BattleArchive.data().pointers[id]==address(0),"Battle already resolved");
  uint256[20] storage home=clanId==0?troops[dx][dy]:clanTroops[clanId];uint256[24] memory a=combine(oldA,journeyArmy(id));
  (BattleEngine.Cohort[] memory defenders,)=_defenders(dx,dy,clanId,oldD);
  (BattleEngine.Outcome memory o,uint256[24][] memory losses)=_calculate(ax,ay,dx,dy,clanId,a,defenders,journeyResearchSnapshots[id]);
  uint256[24] memory d;for(uint256 c;c<defenders.length;c++)for(uint8 i;i<24;i++)d[i]+=defenders[c].army[i];
  bytes memory packed=engine.packReport(_rawReport(a,d,o));if(BattleArchive.useCode(packed))BattleArchive.write(id,packed);else packedReports[id]=packed;
  if(clanId!=0)battleAttackingClan[id]=IJClan(land._clan()).getTileClan(ax,ay);battleIds.push(id);battleCoords[id]=clanId==0?[ax,ay,dx,dy]:IJLogistics(land.logistics()).journeyBattleLocation(id);battleClan[id]=clanId;
  IArmySlots(address(this)).recordArmyLoss(id,o.attackLoss);
  for(uint8 i;i<20;i++){if(o.attackLoss[i+4]>0)travelling[id][i]-=o.attackLoss[i+4];if(losses[0][i+4]>0)home[i]-=losses[0][i+4];}
  if(clanId==0)emit MilitaryChanged(dx,dy);else emit ClanMilitaryChanged(clanId);emit BattleResolved(id,o.attackPower,o.defensePower);
  result.attackPower=o.attackPower;result.defensePower=o.defensePower;result.capacity=o.capacity;
  for(uint8 i;i<24;i++){result.sent+=a[i];result.defenders+=d[i];result.attackerLosses+=o.attackLoss[i];result.defenderLosses+=o.defenseLoss[i];if(i<4){result.attackLoss[i]=o.attackLoss[i];result.defenseLoss[i]=o.defenseLoss[i];}}
 }

 function _rawReport(uint256[24] memory a,uint256[24] memory d,BattleEngine.Outcome memory o) private view returns(bytes memory raw){
  raw=new bytes(3200);
  assembly("memory-safe"){
   let p:=add(raw,32) mstore(p,timestamp())
   for{let i:=0}lt(i,768){i:=add(i,32)}{mstore(add(add(p,32),i),mload(add(a,i)))mstore(add(add(p,800),i),mload(add(d,i)))mstore(add(add(p,1632),i),mload(add(mload(add(o,64)),i)))mstore(add(add(p,2400),i),mload(add(mload(add(o,96)),i)))}
   mstore(add(p,1568),mload(o)) mstore(add(p,1600),mload(add(o,32))) mstore(add(p,3168),mload(add(o,128)))
  }
 }
 function reportPage(uint256 offset,uint256 limit) internal view returns(uint256[] memory ids,uint256 total){require(limit>0&&limit<=25,"Page size 1 to 25");total=battleIds.length;uint256 n=offset<total?total-offset:0;if(n>limit)n=limit;ids=new uint256[](n);for(uint256 i;i<n;i++)ids[i]=battleIds[total-1-offset-i];}
 function overview(int32 x,int32 y) internal view returns(uint256 attackPower,uint256 defensePower){
  IJLand.Inventory memory r=land.getTileData(x,y);uint256[4] memory cav=IJStable(land.stable()).inventory(x,y);
  uint256[4] memory old=[r.offensiveSoldier,r.defensiveSoldier,cav[2],cav[3]];
  (BattleEngine.Cohort[] memory cohorts,)=_defenders(x,y,0,old);uint256[24] memory empty;
  (uint256 ab,uint256 db)=IMilitaryModifiers(land.stable()).personalModifiers(x,y,x,y);
  attackPower=engine.powerCohorts(cohorts,empty,false)*(_boost(r.level)*ab/10000)/10000;
  defensePower=(engine.powerCohorts(cohorts,empty,true)+land.fortificationUnits(x,y)*FortificationRules.DEFENSE_PER_TOWER)*(_boost(r.level)*db/10000)/10000;
 }
 // Appended storage: old inventories and journey receipts retain their exact slots.
 mapping(uint256=>bool) private armyReceived;
 mapping(uint256=>uint8[21]) private journeyResearchSnapshots;
 mapping(uint256=>bytes) private packedReports;
 mapping(uint256=>uint64) private battleAttackingClan;

 MilitaryReports public immutable reportsModule;
 fallback() external {address target=address(reportsModule);assembly("memory-safe"){calldatacopy(0,0,calldatasize())let ok:=delegatecall(gas(),target,0,calldatasize(),0,0)returndatacopy(0,0,returndatasize())switch ok case 0 {revert(0,returndatasize())}default{return(0,returndatasize())}}}
}
