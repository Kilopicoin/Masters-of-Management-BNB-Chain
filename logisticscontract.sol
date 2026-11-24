// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
pragma solidity 0.8.37;
interface IRelicThreatSync {function syncRelicThreat(uint256) external;}
interface IWorldReadIndex {function syncRealm(int32,int32) external;function syncClan(uint64) external;function syncRoute(uint256) external;}
interface IReadIndexSource {function readIndex() external view returns(address);}

import {LogisticsExtension} from "logisticsextension.sol";
import "journeyinterfaces.sol";
import "JourneyLootEscrow.sol";
import "relicthreats.sol";
import {ClanPower,ClanDonationReceipts,IClanInfluence,IClanMembershipEpoch} from "clanpower.sol";
interface IJourneyLevel {function getTilePublic(int32,int32) external view returns(uint256 level,uint256 points);}
import "militarycontract.sol";
import "journeyviews.sol";
import "JourneyRouteSource.sol";
interface IMilitaryMarket {function resolveExpeditionTyped(uint256 id,int32 ax,int32 ay,int32 dx,int32 dy,uint256[4] calldata army) external returns(uint256[4] memory,uint256[4] memory);}
interface ILocalClanDonation {function donateLocalResources(uint64,int32,int32,uint256[4] calldata) external;}
interface IMilitaryClan {function departTyped(uint64 a,uint64 d,uint256[4] calldata army,uint256 extra) external;function resolveTyped(uint256 id,uint64 a,uint64 d,uint256[4] calldata army) external returns(uint256[4] memory,uint256[4] memory);}

/// @notice Escrowed, distance-timed journeys. Arrival needs no keeper: chain time determines readiness.
contract Logistics is PublicRPCEvents, JourneyRouteSource  {
    error RealmOnSale();
    error JourneyCooldown(uint256 availableAt);
    uint256 public constant JOURNEY_COOLDOWN=10 minutes;
    error ClanMissing();
    error ClanMemberRequired();
    error ClanActionInProgress();
    error EnemyClanDelivery();
    error RealmOwnerRequired();
    error ClanLeaderRequired();

    error OrderWindowExpired();
    error DeliveryRecipientChanged();
    error ExpeditionTargetChanged();
    error InvalidCargo();
    error InvalidArmyQuantity();
    error LegacyMilitaryRetired();
    error DestinationOnSale();
    error InvalidDeliveryDistance();
    error MarketplaceRequired();
    error UnoccupiedDestination();
    error TooManyJourneys();
    error JourneyLevelRequired();
    error JourneyLimitReached(uint256 activeJourneys,uint256 limit);
    error OnlyActiveCombat(); error InvalidRaid(); error ReturnedCargoChanged();
    error UnknownJourney(); error InvalidPageSize(); error TooManyClanJourneys(); error RawResourcesOnly(); error NotDelivery();
    IJMap public immutable map;
    IJLand public immutable land;
    IJClan public immutable clans;
    IJClanWar public immutable clanWar;
    IJMarket public immutable market;
    uint256 public immutable secondsPerCell;
    JourneyViews public immutable views;
    uint256 public constant CART_CAPACITY=10000;
    uint256 public constant MAX_OUTGOING=32;
    uint256 public constant MAX_REALM_JOURNEYS=10;
    uint256 public constant ORDER_WAIT_SECONDS=96 hours;
    // kind: 0 realm cargo, 1 realm army, 2 clan supplies, 3 clan army donation, 4 clan expedition, 5 friendly clan delivery.
    // state: 1 outward / awaiting orders, 2 returning / awaiting collection, 3 completed.
    mapping(uint256=>JourneyTypes.Journey) private journeys;
    mapping(int32=>mapping(int32=>uint256)) public outgoing;
    mapping(uint64=>uint256) public clanOutgoing;
    uint256[] private active;
    mapping(uint256=>uint256) private activeIndex;
    mapping(uint64=>uint256[]) private realmJourneys;
    mapping(uint64=>uint256[]) private clanJourneys;
    uint256 public nextId;
    uint256 public lockedNative;
    uint256 private guard=1;
    event JourneyStarted(uint256 indexed id,uint8 kind,int32 sx,int32 sy,int32 tx,int32 ty,uint256 arrivesAt);
    event JourneyAccepted(uint256 indexed id);
    event JourneyReturning(uint256 indexed id,uint256 returnsAt);
    event JourneyCollected(uint256 indexed id,bool complete);
    event JourneyBattle(uint256 indexed id);
    modifier nonReentrant(){if(guard!=1)revert ClanActionInProgress();guard=2;_;_flushReadIndex();guard=1;}
    constructor(address m,address l,address c,address w,address k,uint256 speed,address journeyViews,address extensionAddress){
        // Deploy the stateless view helper separately to keep creation code below EIP-3860.
        require(journeyViews.code.length>0,"Journey views required");
        views=JourneyViews(journeyViews);
        require(extensionAddress.code.length>0,"Logistics module required");extension=LogisticsExtension(payable(extensionAddress));
        require(extension.configurationHash()==keccak256(abi.encode(m,l,c,w,k,speed,journeyViews)),"Logistics module mismatch");
        require(speed>=2 && speed<=1 days,"Invalid travel speed");
        map=IJMap(m);land=IJLand(l);clans=IJClan(c);clanWar=IJClanWar(w);market=IJMarket(k);secondsPerCell=speed;
    }
    function _requireResourceDiplomacy(int32 sx,int32 sy,int32 tx,int32 ty) private view {
        market.requireResourceDiplomacy(sx,sy,tx,ty);
    }
    function _owner(int32 x,int32 y) private {
        land.recordActivity(x,y,msg.sender);
        if(map.getTileOccupant(x,y)!=msg.sender)revert RealmOwnerRequired();
        (,,bool sale,,,)=map.tiles(x,y);if(!(!sale))revert RealmOnSale();
    }
    function _leader(uint64 id) private view returns(IJClan.Info memory info){
        info=clans.getClanInfo(id);if(!info.exists||map.getTileOccupant(info.leaderX,info.leaderY)!=msg.sender)revert ClanLeaderRequired();
    }
    function _diff(int32 a,int32 b) private pure returns(uint256){return uint256(a>b?int256(a)-int256(b):int256(b)-int256(a));}
    function _key(int32 x,int32 y) private pure returns(uint64){return uint64(uint32(x))<<32|uint64(uint32(y));}
    function distance(int32 sx,int32 sy,int32 tx,int32 ty) public pure returns(uint256){return _diff(sx,tx)+_diff(sy,ty);}
    function duration(int32 sx,int32 sy,int32 tx,int32 ty,bool mounted) public view returns(uint256){
        uint256 d=distance(sx,sy,tx,ty);if(d==0)d=1;
        uint256 t=d*secondsPerCell;return mounted?(t+1)/2:t;
    }
    // Every uncompleted departure from this realm shares the same level-based quota.
    function journeyLimit(int32 x,int32 y) public view returns(uint256 limit){
        (uint256 level,)=IJourneyLevel(address(land)).getTilePublic(x,y);limit=level/10;
        if(limit>MAX_REALM_JOURNEYS)limit=MAX_REALM_JOURNEYS;
    }
    function _new(uint8 kind,int32 sx,int32 sy,int32 tx,int32 ty,uint64 sourceClan,uint64 targetClan,uint256 pace) private returns(JourneyTypes.Journey storage j){
        uint256 limit=journeyLimit(sx,sy);
        if(limit==0)revert JourneyLevelRequired();
        if(outgoing[sx][sy]>=limit)revert JourneyLimitReached(outgoing[sx][sy],limit);
        address vision=land.realmVision();
        if(vision!=address(0))IRealmVision(vision).requireDestination(msg.sender,sx,sy,tx,ty);
        uint256 availableAt=nextJourneyAt[msg.sender];
        if(block.timestamp<availableAt)revert JourneyCooldown(availableAt);
        nextJourneyAt[msg.sender]=block.timestamp+JOURNEY_COOLDOWN;
        if(!(map.getTileOccupant(tx,ty)!=address(0)))revert UnoccupiedDestination();
        uint256 id=++nextId;j=journeys[id];j.id=id;j.kind=kind;j.state=1;j.sender=msg.sender;
        j.sx=sx;j.sy=sy;j.tx=tx;j.ty=ty;j.sourceClan=sourceClan;j.targetClan=targetClan;
        j.targetEpoch=map.ownershipEpoch(tx,ty);j.startedAt=block.timestamp;j.arrivesAt=block.timestamp+(duration(sx,sy,tx,ty,false)*100+pace-1)/pace;
        outgoing[sx][sy]++;if(kind==4||kind==5){if(clanOutgoing[sourceClan]>=MAX_OUTGOING)revert TooManyClanJourneys();clanOutgoing[sourceClan]++;}
        realmJourneys[_key(sx,sy)].push(id);if(kind==4||kind==5)clanJourneys[sourceClan].push(id);
        activeIndex[id]=active.length;active.push(id);
        if(kind==2||kind==3||kind==6)ClanDonationReceipts.data().identity[id]=_donationIdentity(sx,sy);
        emit JourneyStarted(id,kind,sx,sy,tx,ty,j.arrivesAt); _indexRoute(id);
    }
    function _takeArmy(int32 x,int32 y,uint256[4] memory army) private {
        uint256 n;for(uint8 i;i<4;i++){n+=army[i];if(army[i]>0)land.adjustTileResources(x,y,i<2?i+9:i+11,army[i],false);}
        // Combined legacy and typed quantity is checked before departure.
    }
    // Empty carts are escrowed with the army and returned to their source realm.
    function _clanCarts(JourneyTypes.Journey storage j,uint256 count) private {
        if(count==0)return;if(count>type(uint256).max/CART_CAPACITY)revert InvalidCargo();
        clanWar.adjustCarts(j.sourceClan,count,false);j.carts=count;journeyCartCapacity[j.id]=CART_CAPACITY;clanOwnedCarts[j.id]=true;
    }
    function _armyCarts(JourneyTypes.Journey storage j,uint256 count) private {
        if(count==0)return;
        uint256 capacity=land.cartCapacity(j.sx,j.sy);
        if(count>type(uint256).max/capacity)revert InvalidCargo();
        land.adjustTileResources(j.sx,j.sy,12,count,false);j.carts=count;journeyCartCapacity[j.id]=capacity;
    }
    function lootCapacity(uint256 id,uint256 soldierCapacity) external view returns(uint256){
        uint256 perCart=journeyCartCapacity[id];uint256 cartCapacity=journeys[id].carts*(perCart==0?CART_CAPACITY:perCart);
        return soldierCapacity<cartCapacity?soldierCapacity:cartCapacity;
    }
    function _carts(JourneyTypes.Journey storage j,uint256 amount) private {
        uint256 capacity=land.cartCapacity(j.sx,j.sy);uint256 count=amount/capacity+(amount%capacity==0?0:1);
        if(count==0)revert InvalidCargo();land.adjustTileResources(j.sx,j.sy,12,count,false);j.carts=count;journeyCartCapacity[j.id]=capacity;
    }
    function _pace(int32 x,int32 y,uint256[4] memory army,uint256[20] memory types,uint256) private view returns(uint256){return Military(land.military()).paceAt(x,y,army,types);}
    function _total(uint256[20] memory types) private pure returns(uint256 n){for(uint8 i;i<20;i++)n+=types[i];}
    function _depart(JourneyTypes.Journey storage j,uint256[4] memory army,uint256[20] memory types) private {j.army=army;if(land.military()!=address(0))Military(land.military()).depart(j.id,j.sx,j.sy,j.sourceClan,types);else require(_total(types)==0,"Military unavailable");}
    function _deploy(int32 sx,int32 sy,int32 tx,int32 ty,uint256[4] memory army,uint256[20] memory types,uint256 carts) private returns(uint256){
        if(army[0]|army[1]|army[2]|army[3]!=0)revert LegacyMilitaryRetired();
        if(carts!=0)revert InvalidCargo();
        _owner(sx,sy);market.prepareExpedition(sx,sy,tx,ty,army[0]+army[2]+_total(types),army[1]+army[3]);
        JourneyTypes.Journey storage j=_new(1,sx,sy,tx,ty,0,0,_pace(sx,sy,army,types,carts));_depart(j,army,types);return j.id;
    }
    
    
    
    // Same minimum and per-resource rounding as personal army departures.
    function _chargeDonationArmy(int32 x,int32 y,int32 tx,int32 ty,uint256 count) private {
        if(count<100)revert InvalidArmyQuantity();
        uint256 d=distance(x,y,tx,ty);if(d==0)d=1;
        uint256 base=d*count*5;
        for(uint8 i;i<4;i++)land.adjustTileResources(x,y,i+1,base*(40-i*10)/100,false);
    }
    function _donate(uint64 id,int32 x,int32 y,uint256[4] memory army,uint256[20] memory types) private returns(uint256){
        if(army[0]|army[1]|army[2]|army[3]!=0)revert LegacyMilitaryRetired();
        _owner(x,y);IJClan.Info memory info=clans.getClanInfo(id);if(id==0||!info.exists||clans.getTileClan(x,y)!=id)revert ClanMemberRequired();
        uint256 size=army[0]+army[1]+army[2]+army[3]+_total(types);if(size<100)revert InvalidArmyQuantity();
        IArmySlots(land.military()).checkClanDonation(id,types);
        if(x==info.leaderX&&y==info.leaderY){Military(land.military()).donateLocalArmy(x,y,id,types);IClanInfluence(address(clanWar)).recordDonation(id,x,y,_donationIdentity(x,y),0,ClanPower.armyPoints(types));return 0;}
        _chargeDonationArmy(x,y,info.leaderX,info.leaderY,size);
        JourneyTypes.Journey storage j=_new(3,x,y,info.leaderX,info.leaderY,0,id,_pace(x,y,army,types,0));_depart(j,army,types);return j.id;
    }
    
    
    function _deployClan(uint64 a,uint64 d,uint256[4] memory army,uint256[20] memory types,uint256 carts) private returns(uint256){if(army[0]|army[1]|army[2]|army[3]!=0)revert LegacyMilitaryRetired();if(carts!=0)revert InvalidCargo();
        IJClan.Info memory own=_leader(a);_owner(own.leaderX,own.leaderY);IJClan.Info memory target=clans.getClanInfo(d);require(target.exists,"Invalid target");
        if(land.military()==address(0))clanWar.depart(a,d,army);else IMilitaryClan(address(clanWar)).departTyped(a,d,army,_total(types));
        JourneyTypes.Journey storage j=_new(4,own.leaderX,own.leaderY,target.leaderX,target.leaderY,a,d,_pace(own.leaderX,own.leaderY,army,types,carts));_depart(j,army,types);return j.id;
    }
    function _arrived(JourneyTypes.Journey storage j) private view {
        require(j.state==1&&block.timestamp>=j.arrivesAt,"Not arrived");
        if(!(block.timestamp<j.arrivesAt+ORDER_WAIT_SECONDS))revert OrderWindowExpired();
    }
    // Time determines the return even if nobody sends a transaction at expiry.
    function _effective(JourneyTypes.Journey memory j) private view returns(JourneyTypes.Journey memory){
        if(j.state==1&&block.timestamp>=j.arrivesAt+ORDER_WAIT_SECONDS){
            j.state=2;j.returnStartedAt=j.arrivesAt+ORDER_WAIT_SECONDS;
            j.returnsAt=j.returnStartedAt+j.arrivesAt-j.startedAt;
        }
        if(!(j.kind==4||j.kind==5))j.sender=map.getTileOccupant(j.sx,j.sy);
        else {IJClan.Info memory info=clans.getClanInfo(j.sourceClan);j.sender=map.getTileOccupant(info.leaderX,info.leaderY);}
        return j;
    }
    function _expire(JourneyTypes.Journey storage j) private {
        if(j.state==1&&block.timestamp>=j.arrivesAt+ORDER_WAIT_SECONDS){
            j.state=2;j.returnStartedAt=j.arrivesAt+ORDER_WAIT_SECONDS;
            j.returnsAt=j.returnStartedAt+j.arrivesAt-j.startedAt;
            emit JourneyReturning(j.id,j.returnsAt); _indexRoute(j.id);
        }
    }
    function _commander(JourneyTypes.Journey storage j) private {
        if((j.kind==4||j.kind==5)){
            IJClan.Info memory info=_leader(j.sourceClan);
            land.recordActivity(info.leaderX,info.leaderY,msg.sender);
        }else{require(map.getTileOccupant(j.sx,j.sy)==msg.sender,"Only sender");land.recordActivity(j.sx,j.sy,msg.sender);}
    }
    function _recipient(JourneyTypes.Journey storage j) private {
        if(j.kind==0){
            require(map.getTileOccupant(j.tx,j.ty)==msg.sender,"Only recipient");
            land.recordActivity(j.tx,j.ty,msg.sender);
        }else{
            IJClan.Info memory info=_leader(j.targetClan);
            land.recordActivity(info.leaderX,info.leaderY,msg.sender);
        }
    }
    function accept(uint256 id) internal nonReentrant { land.requireWorldActive(); 
        JourneyTypes.Journey storage j=journeys[id];_arrived(j);if(j.kind!=0&&j.kind!=2&&j.kind!=3&&j.kind!=5&&j.kind!=6)revert NotDelivery();_recipient(j);
        _creditDonation(j);
        if(j.kind==6){clanWar.adjustCarts(j.targetClan,j.carts,true);j.carts=0;}else if(j.kind==0){
            if(!(map.ownershipEpoch(j.tx,j.ty)==j.targetEpoch))revert DeliveryRecipientChanged();
            _requireResourceDiplomacy(j.sx,j.sy,j.tx,j.ty);
            for(uint8 i;i<8;i++)if(j.cargo[i]>0){land.adjustTileResources(j.tx,j.ty,i+1,j.cargo[i],true);j.cargo[i]=0;}
        }else{
            uint256[4] memory supplies;
            if(j.kind==5)clanWar.requireFriendship(j.sourceClan,j.targetClan);
            for(uint8 i;i<4;i++){supplies[i]=j.cargo[i];j.cargo[i]=0;}
            clanWar.receiveCargo(j.targetClan,supplies,j.army);delete j.army;if(j.kind!=5&&land.military()!=address(0))Military(land.military()).receiveArmy(j.id,0,0,j.targetClan);
        }
        emit JourneyAccepted(id); _indexRoute(id);if(j.carts>0)_return(j);else _close(j);
    }
    function reject(uint256 id) internal nonReentrant { land.requireWorldActive(); 
        JourneyTypes.Journey storage j=journeys[id];_arrived(j);if(j.kind!=0&&j.kind!=2&&j.kind!=3&&j.kind!=5&&j.kind!=6)revert NotDelivery();_recipient(j);
        _return(j);
    }
    function recall(uint256 id) internal nonReentrant { land.requireWorldActive(); 
        JourneyTypes.Journey storage j=journeys[id];require(j.state==1&&block.timestamp<j.arrivesAt+ORDER_WAIT_SECONDS,"Not outbound");_commander(j);_return(j);
    }
    function _return(JourneyTypes.Journey storage j) private {
        uint256 elapsed=block.timestamp-j.startedAt;uint256 full=j.arrivesAt-j.startedAt;
        uint256 t=elapsed<full?elapsed:full;
        j.state=2;j.returnStartedAt=block.timestamp;j.returnsAt=block.timestamp+t;
        emit JourneyReturning(j.id,j.returnsAt); _indexRoute(j.id);
    }
    function attack(uint256 id) rpcIndexed external nonReentrant { land.requireWorldActive(); 
        JourneyTypes.Journey storage j=journeys[id];_arrived(j);_commander(j);require(j.kind==1||j.kind==4,"Not an army");
        uint256[2] memory losses;uint256[4] memory exactLoss;uint256[4] memory loot;bool typed=land.military()!=address(0);
        if(j.kind==1){
            if(!(map.ownershipEpoch(j.tx,j.ty)==j.targetEpoch))revert ExpeditionTargetChanged();
            // Only collected home inventory defends; returned armies stay separate.
            
            if(typed)(exactLoss,loot)=IMilitaryMarket(address(market)).resolveExpeditionTyped(j.id,j.sx,j.sy,j.tx,j.ty,j.army);else (losses,loot)=market.resolveExpedition(j.id,j.sx,j.sy,j.tx,j.ty,j.army[0]+j.army[2],j.army[1]+j.army[3]);
        }else{if(typed)(exactLoss,loot)=IMilitaryClan(address(clanWar)).resolveTyped(j.id,j.sourceClan,j.targetClan,j.army);else (losses,loot)=clanWar.resolveExpeditionForJourney(j.id,j.sourceClan,j.targetClan,j.army);}
        if(typed){for(uint8 i;i<4;i++)j.army[i]-=exactLoss[i];}else for(uint8 i;i<2;i++){
            uint256 total=j.army[i]+j.army[i+2];uint256 mounted=total==0?0:losses[i]*j.army[i+2]/total;
            j.army[i]-=losses[i]-mounted;j.army[i+2]-=mounted;
        }
        for(uint8 i;i<4;i++)j.cargo[i]=loot[i];
        emit JourneyBattle(id); _indexRoute(id);_return(j);
    }
    /// @notice All cargo must fit; any failure leaves the complete journey unchanged.
    function collect(uint256 id) rpcIndexed external nonReentrant { land.requireWorldActive(); 
        JourneyTypes.Journey storage j=journeys[id];_commander(j);_expire(j);
        require(j.state==2&&block.timestamp>=j.returnsAt,"Not home yet");
        require(_collect(j),"No storage space; free capacity first");
    }
    /// @notice Completed returns remain under the same commander authority as collect.
    function settle(uint256 id) rpcIndexed external nonReentrant { land.requireWorldActive(); 
        JourneyTypes.Journey storage j=journeys[id];_commander(j);_expire(j);
        require(j.state==2&&block.timestamp>=j.returnsAt,"Not home yet");
        require(_collect(j),"No storage space; free capacity first");
    }
    // The fixed delegate reuses the core return handler instead of duplicating it.
    function settleHome(int32 x,int32 y,uint64 clanId) rpcIndexed external {
        require(msg.sender==address(this)&&guard==2,"Only active journey");
        if(clanId==0)_settleRealm(x,y);else _settleClan(clanId);
    }
    function _settleRealm(int32 x,int32 y) private {_settleHome(realmJourneys[_key(x,y)],x,y,0);}
    function _settleClan(uint64 id) private {_settleHome(clanJourneys[id],0,0,id);}
    function _settleHome(uint256[] memory ids,int32 x,int32 y,uint64 clanId) private {
        uint256 count;
        for(uint256 i;i<ids.length;i++){
            JourneyTypes.Journey storage j=journeys[ids[i]];if(clanId==0&&(j.kind==4||j.kind==5))continue;
            _expire(j);if(j.state==2&&block.timestamp>=j.returnsAt)ids[count++]=j.id;
        }
        if(count==0)return;
        assembly("memory-safe"){mstore(ids,count)}
        address military=land.military();uint256[] memory moved=new uint256[](count);
        if(military!=address(0))moved=Military(military).receiveArmies(ids,x,y,clanId);
        for(uint256 i;i<count;i++)_collectCargo(journeys[ids[i]],moved[i]);
    }
    function _collect(JourneyTypes.Journey storage j) private returns(bool) {
        uint256 moved;address military=land.military();if(military!=address(0))moved=Military(military).receiveArmy(j.id,j.sx,j.sy,(j.kind==4||j.kind==5)?j.sourceClan:0);
        return _collectCargo(j,moved);
    }
    function _collectCargo(JourneyTypes.Journey storage j,uint256 moved) private returns(bool) {
        uint256 remaining;
        if((j.kind==4||j.kind==5)){
            if(!clans.getClanInfo(j.sourceClan).exists)revert ClanMissing();
            bool hasAssets;for(uint8 i;i<4;i++)if(j.cargo[i]>0||j.army[i]>0)hasAssets=true;
            if(hasAssets){
            uint256[4] memory room=clanWar.resourceRoom(j.sourceClan);uint256[4] memory supplies;
            for(uint8 i;i<4;i++){uint256 n=j.cargo[i];require(n<=room[i],"No storage space; free capacity first");supplies[i]=n;j.cargo[i]-=n;remaining+=j.cargo[i];moved+=n;}
            for(uint8 i;i<4;i++)moved+=j.army[i];
            clanWar.receiveCargo(j.sourceClan,supplies,j.army);delete j.army;
            }
        }else{
            for(uint8 i;i<8;i++){
                uint256 n=j.cargo[i];if(n==0)continue;if(i<4){uint256 room=land.getResourceHeadroom(j.sx,j.sy,i+1);require(n<=room,"No storage space; free capacity first");}
                if(n>0){land.adjustTileResources(j.sx,j.sy,i+1,n,true);j.cargo[i]-=n;moved+=n;}remaining+=j.cargo[i];
            }
            for(uint8 i;i<4;i++)if(j.army[i]>0){uint256 n=j.army[i];j.army[i]=0;land.adjustTileResources(j.sx,j.sy,i<2?i+9:i+11,n,true);moved+=n;}
        }
        if(remaining==0&&j.carts>0){if(clanOwnedCarts[j.id])clanWar.adjustCarts(j.sourceClan,j.carts,true);else land.adjustTileResources(j.sx,j.sy,12,j.carts,true);moved+=j.carts;j.carts=0;}
        if(moved==0&&remaining>0)return false;
        if(remaining==0){
            if(j.kind==1)IJourneyLoot(address(land)).collectJourneyLoot(j.id,j.sx,j.sy,0);
            else if(j.kind==4)IJourneyLoot(address(clanWar)).collectJourneyLoot(j.id,j.sx,j.sy,j.sourceClan);
            _close(j);
        }emit JourneyCollected(j.id,remaining==0); _indexRoute(j.id);
        return true;
    }
    function _close(JourneyTypes.Journey storage j) private {
        j.state=3;outgoing[j.sx][j.sy]--;if((j.kind==4||j.kind==5))clanOutgoing[j.sourceClan]--;
        uint256 index=activeIndex[j.id];uint256 last=active[active.length-1];active[index]=last;activeIndex[last]=index;
        active.pop();delete activeIndex[j.id];
        _removeHomeId(realmJourneys[_key(j.sx,j.sy)],j.id);
        if((j.kind==4||j.kind==5))_removeHomeId(clanJourneys[j.sourceClan],j.id);
    }
    function _removeHomeId(uint256[] storage ids,uint256 id) private {
        for(uint256 i;i<ids.length;i++)if(ids[i]==id){ids[i]=ids[ids.length-1];ids.pop();break;}
    }
    function _home(JourneyTypes.Journey memory j) private view returns(bool){
        return (j.state==2&&block.timestamp>=j.returnsAt)||(j.state==1&&block.timestamp>=j.arrivesAt+ORDER_WAIT_SECONDS+j.arrivesAt-j.startedAt);
    }
    /// @notice Only fully returned assets can accompany a realm transfer; nothing is discarded.
    function clanJourneysHome(uint64 id) external view returns(bool){return views.clanJourneysHome(id);}
    function canTransferRealm(int32 x,int32 y) external view returns(bool){return views.canTransferRealm(x,y);}
    function getRealmSaleStateHash(int32 x,int32 y) external view returns(bytes32 value){return views.getRealmSaleStateHash(x,y);}
    /// @notice Public travelling assets which have already returned. Realm and clan stores stay separate.
    function returnedAssets(int32 x,int32 y,uint64 clanId) public view returns(uint256[8] memory cargo,uint256[4] memory army){
        uint256[] storage ids=clanId==0?realmJourneys[_key(x,y)]:clanJourneys[clanId];uint256 now_=_returnedNow();
        for(uint256 n;n<ids.length;n++){JourneyTypes.Journey storage j=journeys[ids[n]];
            if((clanId==0&&(j.kind==4||j.kind==5))||!_returnedHome(j,now_))continue;
            for(uint8 i;i<8;i++)cargo[i]+=j.cargo[i];for(uint8 i;i<4;i++)army[i]+=j.army[i];}
    }
    // Match JourneyViews: world closure freezes automatic return time. Read only needed storage.
    function _returnedNow() private view returns(uint256){uint256 end=land.worldEndsAt();return block.timestamp<end?block.timestamp:end;}
    function _returnedHome(JourneyTypes.Journey storage j,uint256 now_) private view returns(bool){
        return(j.state==2&&now_>=j.returnsAt)||(j.state==1&&now_>=j.arrivesAt+ORDER_WAIT_SECONDS+j.arrivesAt-j.startedAt);
    }
    /// @dev Called back only by the combat module while Logistics owns the battle lock.
    function seizeReturnedCargo(int32 x,int32 y,uint64 clanId,uint8 resourceType,uint256 amount) rpcIndexed external { land.requireWorldActive(); 
        if(guard!=2||msg.sender!=(clanId==0?address(market):address(clanWar)))revert OnlyActiveCombat();
        if(resourceType<1||resourceType>4)revert RawResourcesOnly();
        _seize(x,y,clanId,resourceType,amount);
    }
    function _seize(int32 x,int32 y,uint64 clanId,uint8 resourceType,uint256 amount) private {
        uint256[] memory ids=clanId==0?realmJourneys[_key(x,y)]:clanJourneys[clanId];
        for(uint256 n;n<ids.length&&amount>0;n++){JourneyTypes.Journey storage j=journeys[ids[n]];
            if((clanId==0&&(j.kind==4||j.kind==5))||!_home(j))continue;
            _expire(j);uint256 taken=j.cargo[resourceType-1];if(taken>amount)taken=amount;
            if(taken==0)continue;j.cargo[resourceType-1]-=taken;amount-=taken;
            // Keep the cart in the journey until normal collection; no callback into the combat module.
            emit JourneyCollected(j.id,false); _indexRoute(j.id);
        }
        if(amount!=0)revert ReturnedCargoChanged();
    }
    function raidRealmResource(int32 ax,int32 ay,int32 dx,int32 dy,uint8 kind,uint256 stock,uint256 percent) rpcIndexed external returns(uint256){ land.requireWorldActive(); return _raidRealmResource(ax,ay,dx,dy,kind,stock,percent,type(uint256).max);}
    function raidRealmResourceLimited(int32 ax,int32 ay,int32 dx,int32 dy,uint8 kind,uint256 stock,uint256 percent,uint256 limit) rpcIndexed external returns(uint256){ land.requireWorldActive(); return _raidRealmResource(ax,ay,dx,dy,kind,stock,percent,limit);}
    function _raidRealmResource(int32 ax,int32 ay,int32 dx,int32 dy,uint8 kind,uint256 stock,uint256 percent,uint256 limit) private returns(uint256 stolen){
        if(guard!=2||msg.sender!=address(market))revert OnlyActiveCombat();
        if(kind<1||kind>4||percent>100)revert InvalidRaid();
        (uint256[8] memory cargo,)=returnedAssets(dx,dy,0);uint256 reserve=cargo[kind-1];uint256 total=stock+reserve;
        if(total>1){
            stolen=total*percent/100;uint256 room=land.getResourceHeadroom(ax,ay,kind);if(stolen>room)stolen=room;if(stolen>limit)stolen=limit;
            uint256 fromReturn=stolen*reserve/total;
            if(stolen>fromReturn)land.adjustTileResources(dx,dy,kind,stolen-fromReturn,false);
            if(fromReturn>0)_seize(dx,dy,0,kind,fromReturn);
        }
    }
    function getJourney(uint256 id) external view returns(JourneyTypes.Journey memory){return views.getJourney(id);}
    function getActivePage(uint256 offset,uint256 limit) external view returns(JourneyTypes.Journey[] memory rows,uint256 total,uint256 chainTime){return views.getActivePage(offset,limit);}
    function returnedArmyIds(int32 x,int32 y,uint64 clanId) external view returns(uint256[] memory ids){
        uint256[] storage home=clanId==0?realmJourneys[_key(x,y)]:clanJourneys[clanId];
        ids=new uint256[](home.length);uint256 count;uint256 now_=_returnedNow();
        for(uint256 i;i<home.length;i++){JourneyTypes.Journey storage j=journeys[home[i]];
            if((clanId==0&&(j.kind==4||j.kind==5))||!_returnedHome(j,now_))continue;ids[count++]=j.id;}
        assembly("memory-safe"){mstore(ids,count)}
    }
    function returnedTroops(int32 x,int32 y,uint64 clanId) external view returns(uint256[20] memory army){return views.returnedTroops(x,y,clanId);}
    function journeyLoot(uint256 id) external view returns(uint256 relics,uint256 bnb){
        JourneyTypes.Journey storage j=journeys[id];
        if(j.kind==1)relics=IJourneyLoot(address(land)).journeyLoot(id);
        else if(j.kind==4)bnb=IJourneyLoot(address(clanWar)).journeyLoot(id);
    }
    error ReturnedArmyAwaitingCollection(uint256 journeyId);
    function requireNoUncollectedArmy(int32 x,int32 y) external view {
        uint256 now_=_returnedNow();uint256[] storage own=realmJourneys[_key(x,y)];
        for(uint256 i;i<own.length;i++){JourneyTypes.Journey storage j=journeys[own[i]];
            if((j.kind==1||j.kind==3)&&_returnedHome(j,now_))revert ReturnedArmyAwaitingCollection(j.id);
        }
        uint64 id=clans.getTileClan(x,y);if(id==0)return;
        IJClan.Info memory info=clans.getClanInfo(id);if(!info.exists||info.leaderX!=x||info.leaderY!=y)return;
        uint256[] storage ids=clanJourneys[id];for(uint256 i;i<ids.length;i++){
            JourneyTypes.Journey storage j=journeys[ids[i]];if(j.kind==4&&_returnedHome(j,now_))revert ReturnedArmyAwaitingCollection(j.id);
        }
    }
    function rawJourney(uint256 id) external view returns(JourneyTypes.Journey memory){return journeys[id];}
    /// Public map projection: read only route fields, without identity or unrelated cargo.
    /// No cached balances or new storage; legacy and new journeys share the same source.
    function routeSummaries(uint256[] calldata ids) external view override returns(Route[] memory rows){
        require(ids.length>0&&ids.length<=50,"Route limit 1-50");
        rows=new Route[](ids.length);uint256 clock=_returnedNow();
        for(uint256 n;n<ids.length;n++){
            uint256 id=ids[n];if(id==0||id>nextId)revert UnknownJourney();
            JourneyTypes.Journey storage j=journeys[id];uint256 amount;
            if(j.kind==1||j.kind==3||j.kind==4){
                for(uint256 i;i<4;i++)amount+=j.army[i];
                uint256[20] memory troops=Military(land.military()).journeyArmy(id);
                for(uint256 i;i<20;i++)amount+=troops[i];
            }else if(j.kind==6)amount=j.carts;
            else for(uint256 i;i<8;i++)amount+=j.cargo[i];
            Route memory r=Route(j.id,j.kind,j.state,j.sx,j.sy,j.tx,j.ty,j.sourceClan,j.targetClan,j.startedAt,j.arrivesAt,j.returnStartedAt,j.returnsAt,amount);
            if(r.state==1&&clock>=r.arrivesAt+ORDER_WAIT_SECONDS){r.state=2;r.returnStartedAt=r.arrivesAt+ORDER_WAIT_SECONDS;r.returnsAt=r.returnStartedAt+r.arrivesAt-r.startedAt;}
            rows[n]=r;
        }
    }
    function homeIds(int32 x,int32 y,uint64 clanId) external view returns(uint256[] memory){return clanId==0?realmJourneys[_key(x,y)]:clanJourneys[clanId];}
    function activeId(uint256 index) external view returns(uint256){return active[index];}
    function activeCount() external view returns(uint256){return active.length;}

    /// Fixed delegate module; no setter and no administrator upgrade route.
    LogisticsExtension public immutable extension;
    fallback() external payable {address target=address(extension);assembly("memory-safe"){let ptr:=mload(0x40) calldatacopy(ptr,0,calldatasize()) let ok:=delegatecall(gas(),target,ptr,calldatasize(),0,0) returndatacopy(ptr,0,returndatasize()) switch ok case 0 {revert(ptr,returndatasize())} default {return(ptr,returndatasize())}}}
    // Departure snapshot; pre-upgrade journeys keep their original 10,000 per cart.
    mapping(uint256=>uint256) private journeyCartCapacity;
    // Shared by every departure type, keyed by the wallet that starts it.
    mapping(address=>uint256) public nextJourneyAt;

    // Journal is flushed after all asset/military callbacks, including nested raid seizures.
    uint256[] private readIndexDirty;
    mapping(uint256=>bool) private clanOwnedCarts;
    function _indexRoute(uint256 id) private {for(uint256 i;i<readIndexDirty.length;i++)if(readIndexDirty[i]==id)return;readIndexDirty.push(id);}
    function _flushReadIndex() private {address target=IReadIndexSource(address(land)).readIndex();for(uint256 i;i<readIndexDirty.length;i++){if(target!=address(0))IWorldReadIndex(target).syncRoute(readIndexDirty[i]);}delete readIndexDirty;}
    function _donationIdentity(int32 x,int32 y) private view returns(bytes32){return keccak256(abi.encode(IClanMembershipEpoch(address(clans)).membershipEpoch(x,y),map.getTileOccupant(x,y),map.ownershipEpoch(x,y)));}
    function _creditDonation(JourneyTypes.Journey storage j) private {
        if(j.kind==0){
          ClanDonationReceipts.Data storage r=ClanDonationReceipts.data();uint64 c=r.recipientClan[j.id];bytes32 identity=r.identity[j.id];if(c==0||identity==bytes32(0))return;
          IJClan.Info memory info=clans.getClanInfo(c);
          bool valid=info.exists&&info.leaderX==j.tx&&info.leaderY==j.ty&&clans.getTileClan(j.sx,j.sy)==c&&_donationIdentity(j.sx,j.sy)==identity&&_donationIdentity(j.tx,j.ty)==r.leaderIdentity[j.id];
          delete r.identity[j.id];delete r.recipientClan[j.id];delete r.leaderIdentity[j.id];
          if(valid){uint256 raw;for(uint8 i;i<4;i++)raw+=j.cargo[i];IClanInfluence(address(clanWar)).recordDonation(c,j.sx,j.sy,identity,raw,0);}return;
        }
        if(j.kind!=3)return;bytes32 identity=ClanDonationReceipts.data().identity[j.id];if(identity==bytes32(0))return;
        uint256 raw;uint256 points;
        if(j.kind==2)for(uint8 i;i<4;i++)raw+=j.cargo[i];
        else if(j.kind==6)points=j.carts*13;
        else points=ClanPower.armyPoints(Military(land.military()).journeyArmy(j.id));
        delete ClanDonationReceipts.data().identity[j.id];IClanInfluence(address(clanWar)).recordDonation(j.targetClan,j.sx,j.sy,identity,raw,points);
    }

    /// Retired ABI: post-closure redemption has no incoming-army lock. Old heap slots stay untouched.
    function incomingRelicThreatUntil(int32,int32) external pure returns(uint256){return 0;}
    function syncRelicThreat(uint256) external view {require(msg.sender==address(this)&&guard==2,"Only active journey");}
    function syncIncomingThreats(uint256[] calldata ids) external pure {require(ids.length<=64,"Page size 1 to 64");}


}


