// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "./worldreader.sol";
import "journeyinterfaces.sol";
import "JourneyRouteSource.sol";
interface IBrowserWar {
 struct State {uint256 offensive;uint256 defensive;uint256[4] resources;uint256 silos;uint256 feePool;uint256 experience;uint256 lastAttackExperience;uint256 protectedUntil;uint256 mountedOffensive;uint256 mountedDefensive;}
 function getState(uint64) external view returns(State memory);function capacity(uint64) external view returns(uint256);function siloCost(uint64) external view returns(uint256[4] memory);function cartStock(uint64) external view returns(uint256);
}
interface IBrowserJourneyClock {function secondsPerCell() external view returns(uint256);}

interface IBrowserClan {
    struct Info {string name; int32 leaderX; int32 leaderY; uint8 memberCount; bool exists;}
    function getClanInfo(uint64) external view returns(Info memory);
    function clanFlags(uint64) external view returns(uint256);
}
interface IBrowserLogistics {
    struct Journey {uint256 id; uint8 kind; uint8 state; address sender; int32 sx; int32 sy; int32 tx; int32 ty; uint64 sourceClan; uint64 targetClan; uint256 targetEpoch; uint256 startedAt; uint256 arrivesAt; uint256 returnStartedAt; uint256 returnsAt; uint256[8] cargo; uint256[4] army; uint256 carts;}
    function getActivePage(uint256,uint256) external view returns(Journey[] memory,uint256,uint256);
    function getJourney(uint256) external view returns(Journey memory);
}
interface IBrowserMilitary {function journeyArmy(uint256) external view returns(uint256[20] memory);}
/// Read-only aggregation for static browser clients. No storage writes, admin,
/// approvals, token transfers or changes to any game rule.
interface IBrowserRewards {
    function token() external view returns(address); function endsAt() external view returns(uint256);
    function initialPool() external view returns(uint256); function remainingPool() external view returns(uint256);
    function entitlement(address) external view returns(uint256,uint256,uint256); function claimed(address) external view returns(bool);
}
interface IBrowserRewardLand {
    function rewardPool() external view returns(uint256); function totalRelics() external view returns(uint256);
    function worldRewards() external view returns(address);
    function finalRelicQuoteState(address) external view returns(uint256,uint256,uint256,bool);
    function relicAccountSnapshot(address) external view returns(uint256,uint256);
}
interface IBrowserToken {function symbol() external view returns(string memory);function decimals() external view returns(uint8);}
interface IBrowserIndex {function reader() external view returns(address);function ready() external view returns(bool);}
interface IBrowserMapStatus {function nextSettlement() external view returns(int32,int32);function worldBounds() external view returns(int32,int32);}
contract BrowserReader is WorldReader, JourneyRouteTypes {
    IBrowserLogistics public immutable logistics;
    IBrowserMilitary public immutable military;
    struct MapTile {int32 x; int32 y; address occupant; bool isOnSale; uint8 bonus; uint256 level; uint64 clanId; uint256 flagId; bool leader;}
    struct ClanRow {uint64 id; string name; int32 leaderX; int32 leaderY; bool exists; uint256 flagId;}
    constructor(address m,address l,address c,address j,address a) WorldReader(m,l,c) {logistics=IBrowserLogistics(j);military=IBrowserMilitary(a);}

    struct ClanSupplies {address owner;uint64 membership;IBrowserClan.Info info;IBrowserWar.State state;uint256 capacity;uint256[4] cost;IJLand.Inventory inventory;uint256 cartCapacity;uint256 clanCarts;bool hasMarket;bool targetOnSale;uint256 secondsPerCell;}
    /// A bounded, same-block view of already public balances; no caller-based writes or approvals.
    function clanSupplies(uint64 id,int32 x,int32 y) external view returns(ClanSupplies memory r){
        IJLand l=IJLand(address(land));IBrowserWar w=IBrowserWar(l.clanWar());
        r.owner=IJMap(address(map)).getTileOccupant(x,y);r.membership=clan.getTileClan(x,y);
        r.info=IBrowserClan(address(clan)).getClanInfo(id);r.state=w.getState(id);r.capacity=w.capacity(id);r.cost=w.siloCost(id);
        r.inventory=l.getTileData(x,y);r.cartCapacity=l.cartCapacity(x,y);r.clanCarts=w.cartStock(id);r.hasMarket=l.hasMarketAtCoord(x,y);
        (,,r.targetOnSale,,,)=IJMap(address(map)).tiles(r.info.leaderX,r.info.leaderY);
        r.secondsPerCell=IBrowserJourneyClock(address(logistics)).secondsPerCell();
    }
    function clanRows(uint64[] calldata ids) external view returns(ClanRow[] memory rows) {
        require(ids.length>0&&ids.length<=64,"Clan limit 1-64");rows=new ClanRow[](ids.length);
        for(uint256 i;i<ids.length;i++){IBrowserClan.Info memory c=IBrowserClan(address(clan)).getClanInfo(ids[i]);rows[i]=ClanRow(ids[i],c.name,c.leaderX,c.leaderY,c.exists,IBrowserClan(address(clan)).clanFlags(ids[i]));}
    }
    function regionTiles(int32 x,int32 y,uint8 width,uint8 height) external view returns(MapTile[] memory rows) {
        require(width>0&&height>0&&uint256(width)*height<=64,"Region limit 1-64");
        IReadMap.RegionTile[] memory tiles=map.getRegion(x,y,width,height);
        rows=new MapTile[](tiles.length);
        for(uint256 i;i<tiles.length;i++) {
            IReadMap.RegionTile memory t=tiles[i];uint256 level;uint64 cid;uint256 flag;bool leader;
            if(t.occupant!=address(0)) {
                level=land.getTilePublic(t.x,t.y).level;cid=clan.getTileClan(t.x,t.y);
                if(cid!=0){IBrowserClan.Info memory info=IBrowserClan(address(clan)).getClanInfo(cid);if(info.exists){flag=IBrowserClan(address(clan)).clanFlags(cid);leader=info.leaderX==t.x&&info.leaderY==t.y;}}
            }
            rows[i]=MapTile(t.x,t.y,t.occupant,t.isOnSale,t.bonus,level,cid,flag,leader);
        }
    }
    function compact(IBrowserLogistics.Journey memory j) private view returns(Route memory) {
        uint256 amount;
        if(j.kind==1||j.kind==3||j.kind==4){for(uint256 i;i<4;i++)amount+=j.army[i];uint256[20] memory troops=military.journeyArmy(j.id);for(uint256 i;i<20;i++)amount+=troops[i];}
        else if(j.kind==6)amount=j.carts;else {for(uint256 i;i<8;i++)amount+=j.cargo[i];}
        return Route(j.id,j.kind,j.state,j.sx,j.sy,j.tx,j.ty,j.sourceClan,j.targetClan,j.startedAt,j.arrivesAt,j.returnStartedAt,j.returnsAt,amount);
    }
    function routesPage(uint256 offset,uint256 limit) external view returns(Route[] memory rows,uint256 total) {
        require(limit>0&&limit<=50,"Page limit 1-50");
        (IBrowserLogistics.Journey[] memory js,uint256 count,)=logistics.getActivePage(offset,limit);
        rows=new Route[](js.length);total=count;for(uint256 i;i<js.length;i++)rows[i]=compact(js[i]);
    }
    function routes(uint256[] calldata ids) external view returns(Route[] memory rows) {
        return JourneyRouteSource(address(logistics)).routeSummaries(ids);
    }
    struct Rewards {uint256 bnbPool;uint256 totalRelics;uint256 balance;uint256 availableAt;address token;uint256 end;uint256 pool;uint256 remaining;string symbol;uint8 decimals;uint256 points;uint256 totalPoints;uint256 amount;bool claimed;uint256 time;uint256 quotePool;uint256 quoteSupply;uint256 redeemed;bool closed;}
    // One bounded eth_call, pinned to one block, replaces independent panel reads.
    function rewards(address account) external view returns(Rewards memory r) {
        IBrowserRewardLand l=IBrowserRewardLand(address(land));
        r.bnbPool=l.rewardPool();r.totalRelics=l.totalRelics();
        (r.balance,r.availableAt)=l.relicAccountSnapshot(account);
        (r.quotePool,r.quoteSupply,r.redeemed,r.closed)=l.finalRelicQuoteState(account);
        IBrowserRewards w=IBrowserRewards(l.worldRewards());
        r.token=w.token();r.end=w.endsAt();r.pool=w.initialPool();r.remaining=w.remainingPool();
        try IBrowserToken(r.token).symbol() returns(string memory symbol){r.symbol=symbol;}catch{r.symbol="TOKEN";}
        r.decimals=IBrowserToken(r.token).decimals();
        (r.points,r.totalPoints,r.amount)=w.entitlement(account);r.claimed=w.claimed(account);r.time=block.timestamp;
    }
    function mapStatus(address index) external view returns(address source,bool ready,int32 nextX,int32 nextY,int32 min,int32 max){
        source=IBrowserIndex(index).reader();ready=IBrowserIndex(index).ready();
        (nextX,nextY)=IBrowserMapStatus(address(map)).nextSettlement();(min,max)=IBrowserMapStatus(address(map)).worldBounds();
    }
}
