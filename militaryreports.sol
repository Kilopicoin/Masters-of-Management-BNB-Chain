// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
pragma solidity 0.8.37;
import "journeyinterfaces.sol";
import "ArmySlots.sol";
import "ClanHallLevels.sol";
import "LegacyClanRefund.sol";
import "battleengine.sol";
import "fortificationrules.sol";
import {BattleArchive} from "BattleArchive.sol";
interface IMilitaryLogisticsRead {function returnedArmyIds(int32,int32,uint64) external view returns(uint256[] memory);}
interface IMilitaryModifiersRead {function personalModifiers(int32,int32,int32,int32) external view returns(uint256,uint256);}
interface IReportLand is IJLand {function _clan() external view returns(address);}
interface IMilitaryOwnersReport {function hasOccupiedTile(address) external view returns(bool);function getOccupiedTileByAddress(address) external view returns(int32[2] memory);}
// Fixed delegate module. Its storage prefix matches Military exactly.
contract MilitaryReports  is PublicRPCWriter {
 IJMap public immutable map;IReportLand public immutable land;BattleEngine public immutable engine;
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

 mapping(uint256=>bool) private armyReceived;
 mapping(uint256=>uint8[21]) private journeyResearchSnapshots;
 mapping(uint256=>bytes) private packedReports;
 mapping(uint256=>uint64) private battleAttackingClan;


 constructor(address m,address l,address e){map=IJMap(m);land=IReportLand(l);engine=BattleEngine(e);}
 function canReadBattle(uint256 id) public view returns(bool){
  if(reports[id].timestamp==0&&packedReports[id].length==0&&BattleArchive.data().pointers[id]==address(0))return false;
  int32[4] memory p=battleCoords[id];uint64 defender=battleClan[id];
  if(defender==0)return msg.sender!=address(0)&&(map.getTileOccupant(p[0],p[1])==msg.sender||map.getTileOccupant(p[2],p[3])==msg.sender);
  IMilitaryOwnersReport owners=IMilitaryOwnersReport(address(map));if(!owners.hasOccupiedTile(msg.sender))return false;
  int32[2] memory own=owners.getOccupiedTileByAddress(msg.sender);if(map.getTileOccupant(own[0],own[1])!=msg.sender)return false;
  uint64 current=IJClan(land._clan()).getTileClan(own[0],own[1]);return current!=0&&(current==defender||current==battleAttackingClan[id]);
 }
 function battleReport(uint256 id) external view returns(Report memory){
  require(canReadBattle(id),"Battle details are for participants only");
  address pointer=BattleArchive.data().pointers[id];bytes memory packed=pointer==address(0)?packedReports[id]:BattleArchive.read(pointer);if(packed.length==0)return reports[id];bytes memory raw=engine.unpackReport(packed);assembly("memory-safe"){return(add(raw,32),mload(raw))}
 }


 // Read-only helpers share the exact Military storage prefix and caller identity.
function combine(uint256[4] memory old,uint256[20] memory a) private pure returns(uint256[24] memory all){for(uint8 i;i<4;i++)all[i]=old[i];for(uint8 i;i<20;i++)all[i+4]=a[i];}
function journeyArmy(uint256 id) private view returns(uint256[20] memory army){if(!armyReceived[id])army=travelling[id];}
function _boost(uint256 level) private pure returns(uint256){return 10000+level*2500/(level+100);}
function _defenders(int32 x,int32 y,uint64 clanId,uint256[4] memory old) private view returns(BattleEngine.Cohort[] memory cohorts,uint256[] memory ids){
  // Only collected home inventory defends. Pending returns keep their departure snapshots.
  ids=new uint256[](0);cohorts=new BattleEngine.Cohort[](1);
  cohorts[0]=BattleEngine.Cohort(combine(old,clanId==0?troops[x][y]:clanTroops[clanId]),land.unitResearchLevels(x,y));
 }
function _calculate(int32 ax,int32 ay,int32 dx,int32 dy,uint64 clanId,uint256[24] memory a,BattleEngine.Cohort[] memory d,uint8[21] memory levels) private view returns(BattleEngine.Outcome memory o,uint256[24][] memory losses){
  uint256 ab=10000;uint256 db=10000;uint256 towers;
  if(clanId==0){IJLand.Inventory memory ai=land.getTileData(ax,ay);IJLand.Inventory memory di=land.getTileData(dx,dy);
   (uint256 aa,)=IMilitaryModifiersRead(land.stable()).personalModifiers(ax,ay,dx,dy);(,uint256 dd)=IMilitaryModifiersRead(land.stable()).personalModifiers(dx,dy,ax,ay);
   ab=_boost(ai.level)*aa/10000;db=_boost(di.level)*dd/10000;towers=land.fortificationUnits(dx,dy);}
  return engine.calculateCohorts(a,d,BattleEngine.Modifiers(ab,db,towers,levels,d[0].levels));
 }
function unit(uint8 id) external pure returns(MilitaryCatalog.Unit memory){return MilitaryCatalog.unit(id);}
function gearCost(uint8 id) external pure returns(uint256[4] memory){return MilitaryCatalog.gearCost(id);}
function totals(uint256[20] memory a) external pure returns(uint256 total,uint256 foot){for(uint8 i;i<20;i++){total+=a[i];if(i<12)foot+=a[i];}}
function preview(int32 ax,int32 ay,int32 dx,int32 dy,uint64 clanId,uint256[4] calldata oldA,uint256[4] calldata oldD,uint256[20] calldata selected) external view returns(BattleEngine.Outcome memory o){
  (BattleEngine.Cohort[] memory defenders,)=_defenders(dx,dy,clanId,oldD);
  (o,)=_calculate(ax,ay,dx,dy,clanId,combine(oldA,selected),defenders,land.unitResearchLevels(ax,ay));
 }
function overview(int32 x,int32 y) external view returns(uint256 attackPower,uint256 defensePower){
  IJLand.Inventory memory r=land.getTileData(x,y);uint256[4] memory cav=IJStable(land.stable()).inventory(x,y);
  uint256[4] memory old=[r.offensiveSoldier,r.defensiveSoldier,cav[2],cav[3]];
  (BattleEngine.Cohort[] memory cohorts,)=_defenders(x,y,0,old);uint256[24] memory empty;
  (uint256 ab,uint256 db)=IMilitaryModifiersRead(land.stable()).personalModifiers(x,y,x,y);
  attackPower=engine.powerCohorts(cohorts,empty,false)*(_boost(r.level)*ab/10000)/10000;
  defensePower=(engine.powerCohorts(cohorts,empty,true)+land.fortificationUnits(x,y)*FortificationRules.DEFENSE_PER_TOWER)*(_boost(r.level)*db/10000)/10000;
 }
function reportPage(uint256 offset,uint256 limit) external view returns(uint256[] memory ids,uint256 total){require(limit>0&&limit<=25,"Page size 1 to 25");total=battleIds.length;uint256 n=offset<total?total-offset:0;if(n>limit)n=limit;ids=new uint256[](n);for(uint256 i;i<n;i++)ids[i]=battleIds[total-1-offset-i];}

 event ArmyCapacityChanged(int32 indexed x,int32 indexed y,uint64 indexed clanId,uint8 level);
 event ClanTroopTypesChanged(uint64 indexed clanId,uint32 acceptedMask);
 event TroopsDismissed(int32 indexed x,int32 indexed y,uint64 indexed clanId,uint8 unit,uint256 amount);
 event MilitaryChanged(int32 indexed x,int32 indexed y);
 event ClanMilitaryChanged(uint64 indexed clanId);
 modifier armyLocked(){require(guard==1,"Busy");guard=2;_;guard=1;}
 function _armyOwner(int32 x,int32 y,uint64 id) private view {
  require(map.getTileOccupant(x,y)==msg.sender,"Not realm owner");
  if(id!=0){IJClan.Info memory c=IJClan(land._clan()).getClanInfo(id);require(c.exists&&c.leaderX==x&&c.leaderY==y,"Clan leader required");}
 }
 function armyCapacityLevel(int32 x,int32 y,uint64 id) public view returns(uint8 level){
  ArmySlots.State storage s=ArmySlots.data();
  if(id!=0){if(!IJClan(land._clan()).getClanInfo(id).exists)return 0;level=s.clanLevel[id];uint8 hall=IClanHallLevels(land.clanWar()).clanHallArmyLimit(id);if(hall>level)level=hall;return level==0?1:level;}
  if(land.getBuildingCounts(x,y)[4]==0)return 0;level=s.realmLevel[x][y];return level==0?1:level;
 }
 function occupiedArmyTypes(int32 x,int32 y,uint64 id) public view returns(uint32 mask){
  ArmySlots.State storage s=ArmySlots.data();uint256[20] storage home=id==0?troops[x][y]:clanTroops[id];uint256[20] storage away=id==0?s.realmAway[x][y]:s.clanAway[id];
  for(uint8 i;i<20;i++)if(home[i]>0||away[i]>0)mask|=uint32(1)<<i;
 }
 function armySlotState(int32 x,int32 y,uint64 id) external view returns(uint8 limit,uint32 occupied,uint32 accepted,uint256[20] memory away,uint256[4] memory nextCost){
  limit=armyCapacityLevel(x,y,id);occupied=occupiedArmyTypes(x,y,id);ArmySlots.State storage s=ArmySlots.data();accepted=id==0?0:s.accepted[id];away=id==0?s.realmAway[x][y]:s.clanAway[id];
  if(limit>0&&limit<20){uint256 cost=30000*(uint256(limit)+1);for(uint8 i;i<4;i++)nextCost[i]=cost;}
 }
 function checkTraining(int32 x,int32 y,uint8 unitId) external view {
  require(msg.sender==address(this),"Military only");require(unitId>=1&&unitId<=20,"Invalid troop type");
  uint32 mask=occupiedArmyTypes(x,y,0);uint8 cap=armyCapacityLevel(x,y,0);
  require(cap>0&&(mask&(uint32(1)<<(unitId-1))!=0||ArmySlots.count(mask)<cap),"Upgrade Fighting Pit for another troop type");
 }
 function checkClanDonation(uint64 id,uint256[20] calldata army) external view {
  uint32 allowed=ArmySlots.data().accepted[id];
  require(IJClan(land._clan()).getClanInfo(id).exists,"Clan missing");
  for(uint8 i;i<20;i++)if(army[i]>0)require(allowed&(uint32(1)<<i)!=0,"Clan does not accept this troop type");
 }
 function upgradeArmyCapacity(int32 x,int32 y,uint64 id,uint8 expectedLevel) rpcIndexed external armyLocked {
  land.requireWorldActive();_armyOwner(x,y,id);if(id!=0){IClanHallLevels(land.clanWar()).upgradeClanHallFromMilitary(msg.sender,x,y,expectedLevel);return;}require(land.getBuildingCounts(x,y)[4]>0,"Build the required building");
  uint8 current=armyCapacityLevel(x,y,id);require(current==expectedLevel&&current>0&&current<20,"Upgrade level changed or maximum reached");
  uint256 cost=30000*(uint256(current)+1);
  for(uint8 i;i<4;i++)land.adjustTileResources(x,y,i+1,cost,false);
  if(id==0)ArmySlots.data().realmLevel[x][y]=current+1;else ArmySlots.data().clanLevel[id]=current+1;
  emit ArmyCapacityChanged(x,y,id,current+1);if(id==0)emit MilitaryChanged(x,y);else emit ClanMilitaryChanged(id);
 }
 function setAcceptedTroopTypes(uint64 id,uint32 mask) rpcIndexed external armyLocked {
  land.requireWorldActive();IJClan.Info memory c=IJClan(land._clan()).getClanInfo(id);require(id!=0&&c.exists,"Clan missing");_armyOwner(c.leaderX,c.leaderY,id);
  require(mask<(uint32(1)<<20)&&ArmySlots.count(mask)<=armyCapacityLevel(c.leaderX,c.leaderY,id),"Too many accepted troop types");
  uint32 owned=occupiedArmyTypes(0,0,id);require(owned&mask==owned,"Dismiss or collect existing types first");
  ArmySlots.data().accepted[id]=mask;emit ClanTroopTypesChanged(id,mask);emit ClanMilitaryChanged(id);
 }
 function dismissTroops(int32 x,int32 y,uint64 id,uint8 unitId) rpcIndexed external armyLocked {
  land.requireWorldActive();_armyOwner(x,y,id);require(unitId>0&&unitId<=20,"Invalid troop type");
  uint256[20] storage home=id==0?troops[x][y]:clanTroops[id];uint256 n=home[unitId-1];require(n>0,"No troops at home");home[unitId-1]=0;
  emit TroopsDismissed(x,y,id,unitId,n);if(id==0)emit MilitaryChanged(x,y);else emit ClanMilitaryChanged(id);
 }
 function resetRealmArmyCapacity(int32 x,int32 y)  external {require(msg.sender==address(land),"Land only");require(occupiedArmyTypes(x,y,0)==0,"Troops remain");delete ArmySlots.data().realmLevel[x][y];}
 function recordArmyDeparture(uint256 id,int32 x,int32 y,uint64 clanId,uint256[20] calldata army)  external {
  require(msg.sender==address(this),"Military only");ArmySlots.State storage s=ArmySlots.data();require(!s.origin[id].recorded,"Departure already recorded");s.origin[id]=ArmySlots.Origin(x,y,clanId,true);
  uint256[20] storage away=clanId==0?s.realmAway[x][y]:s.clanAway[clanId];for(uint8 i;i<20;i++)away[i]+=army[i];
 }
 function recordArmyReceipt(uint256 id,uint256[20] calldata army)  external {
  require(msg.sender==address(this),"Military only");ArmySlots.State storage s=ArmySlots.data();ArmySlots.Origin memory o=s.origin[id];if(!o.recorded){for(uint8 i;i<20;i++)require(army[i]==0,"Journey migration required");return;}
  uint256[20] storage away=o.clanId==0?s.realmAway[o.x][o.y]:s.clanAway[o.clanId];for(uint8 i;i<20;i++)away[i]-=army[i];
 }
 function recordArmyLoss(uint256 id,uint256[24] calldata losses)  external {
  require(msg.sender==address(this),"Military only");ArmySlots.State storage s=ArmySlots.data();ArmySlots.Origin memory o=s.origin[id];require(o.recorded,"Journey migration required");
  uint256[20] storage away=o.clanId==0?s.realmAway[o.x][o.y]:s.clanAway[o.clanId];for(uint8 i;i<20;i++)away[i]-=losses[i+4];
 }


 function legacyClanRefund(int32 x,int32 y) external view returns(uint256[5] memory){return LegacyClanRefund.data().balance[x][y];}
 function collectLegacyClanRefund(int32 x,int32 y,uint256[5] calldata amounts) rpcIndexed external armyLocked {
  land.requireWorldActive();_armyOwner(x,y,0);uint256[5] storage balance=LegacyClanRefund.data().balance[x][y];bool any;
  if(amounts[4]>0){IJLand.DepotStatus memory d=land.getDepotStatus(x,y);uint256 used=d.stored[1]+d.listed[1]+d.cartsAway*4;require(used<=d.capacity[1]&&amounts[4]<=(d.capacity[1]-used)/4,"Not enough transport storage");}
  for(uint8 i;i<5;i++)if(amounts[i]>0){require(amounts[i]<=balance[i],"Refund exceeded");balance[i]-=amounts[i];land.adjustTileResources(x,y,i==4?12:i+1,amounts[i],true);any=true;}
  require(any,"No refund requested");emit MilitaryChanged(x,y);
 }
}
