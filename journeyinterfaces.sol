// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

interface IJMap {
    function getTileOccupant(int32 x,int32 y) external view returns(address);
    function ownershipEpoch(int32 x,int32 y) external view returns(uint256);
    function nativeUnitWei() external view returns(uint256);
    function tiles(int32 x,int32 y) external view returns(bool,address,bool,uint256,uint256,uint256);
}
interface IRealmVision {function requireDestination(address,int32,int32,int32,int32) external view;function requireReport(address,int32,int32) external view;}
interface IJLand {
    function realmVision() external view returns(address);
    struct DepotStatus {uint256[2] buildings;uint256[2] capacity;uint256[2] stored;uint256[2] listed;uint256 cartsAway;}
    function getDepotStatus(int32 x,int32 y) external view returns(DepotStatus memory);
    function requireDepotSpace(int32 x,int32 y,uint8 kind,uint256 amount,bool convertingHorses) external view;

    function researchLevels(int32 x,int32 y) external view returns(uint8[17] memory);
    function unitResearchLevels(int32 x,int32 y) external view returns(uint8[21] memory);
    function cartCapacity(int32 x,int32 y) external view returns(uint256);
    function worldEndsAt() external view returns(uint256);
    function requireWorldActive() external view;
    function recordActivity(int32 x,int32 y,address actor) external;
    struct Inventory {uint256 food;uint256 wood;uint256 stone;uint256 iron;uint256 level;uint256 accumulatedTurns;uint256 offensiveArmor;uint256 defensiveArmor;uint256 offensiveWeapon;uint256 defensiveWeapon;uint256 offensiveSoldier;uint256 defensiveSoldier;uint16 offensiveTech;uint16 defensiveTech;uint256 points;}
    function getTileData(int32 x,int32 y) external view returns(Inventory memory);
    function logistics() external view returns(address);
    function stable() external view returns(address);
    function military() external view returns(address);
    function marketplaceAddress() external view returns(address);
    function clanWar() external view returns(address);
    function getBuildingCounts(int32 x,int32 y) external view returns(uint256[13] memory);
    function getCastleCount(int32 x,int32 y) external view returns(uint256);
    function fortificationUnits(int32 x,int32 y) external view returns(uint256);
    function hasMarketAtCoord(int32 x,int32 y) external view returns(bool);
    function adjustTileResources(int32 x,int32 y,uint8 kind,uint256 amount,bool adding) external;
    function getResourceHeadroom(int32 x,int32 y,uint8 kind) external view returns(uint256);
    function createSoldier(int32 x,int32 y,uint8 kind,uint256 amount) external;
}
interface IJStable {
    function inventory(int32 x,int32 y) external view returns(uint256[4] memory);
    function inventoryHash(int32 x,int32 y) external view returns(bytes32);
    function adjust(int32 x,int32 y,uint8 kind,uint256 amount,bool adding) external;
    function loseDefenders(int32 x,int32 y,uint256 off,uint256 def) external;
}
interface IJLogistics {
    function requireNoUncollectedArmy(int32 x,int32 y) external view;
    function journeyBattleLocation(uint256 id) external view returns(int32[4] memory);
    function reservedCarts(int32 x,int32 y) external view returns(uint256);
    function lootCapacity(uint256 id,uint256 soldierCapacity) external view returns(uint256);
    function raidRealmResource(int32 ax,int32 ay,int32 dx,int32 dy,uint8 kind,uint256 stock,uint256 percent) external returns(uint256);
    function canTransferRealm(int32 x,int32 y) external view returns(bool);
    function getRealmSaleStateHash(int32 x,int32 y) external view returns(bytes32);
    function returnedAssets(int32 x,int32 y,uint64 clanId) external view returns(uint256[8] memory cargo,uint256[4] memory army);
    function seizeReturnedCargo(int32 x,int32 y,uint64 clanId,uint8 resourceType,uint256 amount) external;
    function outgoing(int32 x,int32 y) external view returns(uint256);
    function clanOutgoing(uint64 id) external view returns(uint256);
    function clanJourneysHome(uint64 id) external view returns(bool);
}
interface IJClan {
    struct Info {string name;int32 leaderX;int32 leaderY;uint8 memberCount;bool exists;}
    function getClanInfo(uint64 id) external view returns(Info memory);
    function getTileClan(int32 x,int32 y) external view returns(uint64);
}
interface IJMarket {
    function requireResourceDiplomacy(int32 sx,int32 sy,int32 tx,int32 ty) external view;
    function depotEscrow(int32 x,int32 y) external view returns(uint256[2] memory);
    function reservedResources(int32 x,int32 y,uint8 kind) external view returns(uint256);
    function prepareExpedition(int32 ax,int32 ay,int32 dx,int32 dy,uint256 off,uint256 def) external;
    function resolveExpedition(uint256 id,int32 ax,int32 ay,int32 dx,int32 dy,uint256 off,uint256 def) external returns(uint256[2] memory losses,uint256[4] memory loot);
}
interface IJClanWar {
    function cartStock(uint64 id) external view returns(uint256);
    function adjustCarts(uint64 id,uint256 amount,bool adding) external;
    function departSupplies(uint64 source,uint64 target,uint256[4] calldata amounts,uint256 foodCost) external;
    function requireFriendship(uint64 source,uint64 target) external view;
    function depart(uint64 a,uint64 d,uint256[4] calldata army) external;
    function receiveCargo(uint64 id,uint256[4] calldata supplies,uint256[4] calldata army) external;
    function resourceRoom(uint64 id) external view returns(uint256[4] memory);
    function resolveExpeditionForJourney(uint256 journeyId,uint64 a,uint64 d,uint256[4] calldata army) external returns(uint256[2] memory losses,uint256[4] memory loot);
}

interface IRealmFeatures {
 function productionBps(int32 x,int32 y) external view returns(uint256);
 function combatPowers(int32 ax,int32 ay,int32 dx,int32 dy,uint256 off,uint256 def) external view returns(uint256,uint256);
 function battleLosses(uint256[2] calldata a,uint256[2] calldata d,uint256 ap,uint256 dp,uint256 towers) external pure returns(uint256[4] memory);
 function queueRedemption(int32 x,int32 y,uint256 quantity,uint256 minimum,address account) external;
 function pendingRedemption(int32 x,int32 y) external view returns(uint256);
}
interface IRelicSettlement {
 function quoteRelicReward(uint256 quantity) external view returns(uint256);
 function nextRelicRedemptionAt() external view returns(uint256);
 function redeemRelics(int32 x,int32 y,uint256 quantity,uint256 minimum) external;
}
interface IClanGovernance {
 function relationship(uint64 a,uint64 b) external view returns(uint8,uint8,uint8);
 function canTransferRealm(int32 x,int32 y) external view returns(bool);
}
