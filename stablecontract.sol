// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
pragma solidity 0.8.37;
import "journeyinterfaces.sol";
import "fortificationrules.sol";
interface IMilitaryOverview {function overview(int32 x,int32 y) external view returns(uint256,uint256);}

/// @notice Realm-owned horses, carts and mounted troops. Only travelling cargo is public in the UI.
contract Stable  is PublicRPCEvents {
    IJMap public immutable map;
    IJLand public immutable land;
    // Horse, cart, mounted offensive, mounted defensive. Markets trade types 11 and 12 only.
    mapping(int32=>mapping(int32=>uint256[4])) private stock;
    uint256 private guard=1;
    modifier nonReentrant(){require(guard==1,"Busy");guard=2;_;guard=1;}
    modifier owner(int32 x,int32 y){require(map.getTileOccupant(x,y)==msg.sender,"Not realm owner");_;}
    event Produced(int32 x,int32 y,uint8 kind,uint256 quantity);
    event MountedTrained(int32 x,int32 y,uint8 kind,uint256 quantity);
    error InsufficientTransport(uint8 kind,uint256 required,uint256 available);
    constructor(address m,address l){map=IJMap(m);land=IJLand(l);}
    function inventory(int32 x,int32 y) external view returns(uint256[4] memory){
        require(msg.sender==map.getTileOccupant(x,y)||msg.sender==address(land)||msg.sender==land.marketplaceAddress()||msg.sender==land.logistics()||msg.sender==land.military(),"Private inventory");
        return stock[x][y];
    }
    /// @notice A game reconnaissance report, not a privacy guarantee for public chain data.
    function scoutRealm(int32 sx,int32 sy,int32 tx,int32 ty) external view owner(sx,sy)
        returns(uint256[4] memory resources,uint256[4] memory army,uint256[4] memory returnedCargo,uint256[4] memory listed,uint256 observedAt){
        revert("Legacy scout retired; use RealmVision reportData");
    }
    function inventoryHash(int32 x,int32 y) external view returns(bytes32){return keccak256(abi.encode(stock[x][y],specializations[x][y],scoutMarks[x][y]));}
    function adjust(int32 x,int32 y,uint8 kind,uint256 amount,bool adding)  external { land.requireWorldActive(); 
        require(msg.sender==address(land)&&kind>=11&&kind<=12,"Only Land");
        if(adding)stock[x][y][kind-11]+=amount;else {
            uint256 available=stock[x][y][kind-11];if(available<amount)revert InsufficientTransport(kind,amount,available);
            unchecked{stock[x][y][kind-11]=available-amount;}
        }
    }
    /// @notice Base recipe before realm-specific Stable discounts.
    function productionCost(uint8 kind,uint256 quantity) public pure returns(uint256[4] memory cost,uint256 horses){
        require((kind==1||kind==2)&&quantity>0&&quantity<=100000,"Invalid production");
        cost=kind==1?[uint256(400),120,60,80]:[uint256(100),800,100,300];
        for(uint8 i;i<4;i++)cost[i]*=quantity;
        horses=0; // Kept in the quote ABI; neither recipe consumes horses.
    }
    function productionQuote(int32 x,int32 y,uint8 kind,uint256 quantity) public view returns(uint256[4] memory cost,uint256 horses){
        require(quantity>0&&quantity<=100000,"Invalid production");
        uint256 count=land.getBuildingCounts(x,y)[11];
        require(count>0,"Build a Stable first");
        (cost,)=productionCost(kind,1);
        // floor(sqrt(count)), matching Armory, Blacksmith and Fighting Pit.
        uint256 divisor=count;uint256 next=count/2+count%2;
        while(next<divisor){divisor=next;next=(count/next+next)/2;}
        // Round each per-item resource cost up before multiplying the batch.
        for(uint8 i;i<4;i++)cost[i]=((cost[i]+divisor-1)/divisor)*quantity;
        horses=0; // Kept in the quote ABI; neither recipe consumes horses.
    }
    function produce(int32 x,int32 y,uint8 kind,uint256 quantity) rpcIndexed external nonReentrant owner(x,y){ land.requireWorldActive(); 
        (uint256[4] memory cost,)=productionQuote(x,y,kind,quantity);
        land.requireDepotSpace(x,y,kind+10,quantity,false);
        for(uint8 i;i<4;i++)land.adjustTileResources(x,y,i+1,cost[i],false);
        stock[x][y][kind-1]+=quantity;
        land.recordActivity(x,y,msg.sender);
        emit Produced(x,y,kind,quantity);
    }
    function trainMounted(int32,int32,uint8,uint256) external pure { revert("Legacy military retired"); }
    function loseDefenders(int32 x,int32 y,uint256 off,uint256 def)  external { land.requireWorldActive(); 
        require(msg.sender==land.marketplaceAddress(),"Only battle engine");
        // Caller provides mounted losses only; foot losses are applied by the battle engine.
        stock[x][y][2]-=off;stock[x][y][3]-=def;
    }

    // Appended state: old horses, carts and riders retain their exact storage slots.
    struct Specialization {uint8 kind;uint256 changedAt;}
    mapping(int32=>mapping(int32=>Specialization)) public specializations;
    struct ScoutMark {int32 x;int32 y;uint256 expiresAt;uint256 nextAt;uint256 ownershipEpoch;}
    // Retired target-mark storage is reserved to preserve existing worlds. It has no gameplay effect.
    mapping(int32=>mapping(int32=>ScoutMark)) private scoutMarks;
    event SpecializationChanged(int32 x,int32 y,uint8 kind);

    function chooseSpecialization(int32 x,int32 y,uint8 kind) rpcIndexed external nonReentrant owner(x,y) { land.requireWorldActive(); 
        require(kind<=3,"Unknown specialization");
        Specialization storage s=specializations[x][y];
        require(kind!=s.kind,"Already selected");
        require(s.changedAt==0||block.timestamp>=s.changedAt+7 days,"Specialization locked for seven days");
        require(IJLogistics(land.logistics()).outgoing(x,y)==0,"Collect outgoing journeys first");
        (,,bool onSale,,,)=map.tiles(x,y);require(!onSale,"Remove realm sale first");
        s.kind=kind;s.changedAt=block.timestamp;land.recordActivity(x,y,msg.sender);
        emit SpecializationChanged(x,y,kind);
    }
    function productionBps(int32 x,int32 y) public view returns(uint256){uint8 s=specializations[x][y].kind;return s==1?11000:s==2?9500:10000;}
    function armyPower(uint256 offensive,uint256 defensive,uint256 technology,uint256 level,bool defending) public pure returns(uint256){
        uint256 base=defending?offensive+defensive*2:offensive*2+defensive;
        uint256 boost=level*2500/(level+100);
        return base*(10000+boost)/10000;
    }
    function personalModifiers(int32 x,int32 y,int32,int32) public view returns(uint256 attackBps,uint256 defenseBps){
        uint8 s=specializations[x][y].kind;
        attackBps=s==3?11000:s==1?9000:10000;
        defenseBps=s==2?11000:s==1?9000:s==3?9500:10000;
    }
    function homePowers(int32 x,int32 y) external view returns(uint256 attackPower,uint256 defensePower){
        if(land.military()!=address(0))return IMilitaryOverview(land.military()).overview(x,y);
        IJLand.Inventory memory r=land.getTileData(x,y);
        (,uint256[4] memory returned)=IJLogistics(land.logistics()).returnedAssets(x,y,0);
        uint256 off=r.offensiveSoldier+stock[x][y][2]+returned[0]+returned[2];
        uint256 def=r.defensiveSoldier+stock[x][y][3]+returned[1]+returned[3];
        uint8 s=specializations[x][y].kind;
        attackPower=armyPower(off,def,r.offensiveTech,r.level,false)*(s==3?11000:s==1?9000:10000)/10000;
        (,uint256 db)=personalModifiers(x,y,x,y);
        defensePower=(armyPower(off,def,r.defensiveTech,r.level,true)+land.fortificationUnits(x,y)*(FortificationRules.DEFENSE_PER_TOWER/100))*db/10000;
    }
    function combatPowers(int32 ax,int32 ay,int32 dx,int32 dy,uint256 off,uint256 def) public view returns(uint256 ap,uint256 dp){
        IJLand.Inventory memory a=land.getTileData(ax,ay);IJLand.Inventory memory d=land.getTileData(dx,dy);
        (,uint256[4] memory returned)=IJLogistics(land.logistics()).returnedAssets(dx,dy,0);
        (uint256 ab,)=personalModifiers(ax,ay,dx,dy);(,uint256 db)=personalModifiers(dx,dy,ax,ay);
        ap=armyPower(off,def,a.offensiveTech,a.level,false)*ab/10000;
        uint256 homeOff=d.offensiveSoldier+stock[dx][dy][2]+returned[0]+returned[2];
        uint256 homeDef=d.defensiveSoldier+stock[dx][dy][3]+returned[1]+returned[3];
        dp=(armyPower(homeOff,homeDef,d.defensiveTech,d.level,true)+land.fortificationUnits(dx,dy)*(FortificationRules.DEFENSE_PER_TOWER/100))*db/10000;
    }
    function _limited(uint256 off,uint256 def,uint256 size,uint256 enemyPower,uint256 ownPower) private pure returns(uint256,uint256){
        uint256 budget=enemyPower<ownPower?size*enemyPower/ownPower:size;
        if(off+def<=budget)return(off,def);
        uint256 limited=off*budget/(off+def);return(limited,budget-limited);
    }
    function _lossPercent(uint256 value) private pure returns(uint256){return value>90?90:value<10?10:value;}
    function battleLosses(uint256[2] memory a,uint256[2] memory d,uint256 ap,uint256 dp,uint256 towers) public pure returns(uint256[4] memory v){
        require(ap+dp>0,"Empty combat");uint256 m=(ap>dp?ap-dp:dp-ap)*100/(ap+dp);
        if(ap>dp){v[0]=a[0]*_lossPercent(25+(100-m)/2)/100;v[1]=a[1]*_lossPercent(10+(100-m)/4)/100;v[2]=d[0]*_lossPercent(50+m)/100;v[3]=d[1]*_lossPercent(50+m)/100;}
        else{v[0]=a[0]*_lossPercent(50+m)/100;v[1]=a[1]*_lossPercent(25+m/2)/100;v[2]=d[0]*_lossPercent(15+(100-m)/4)/100;v[3]=d[1]*_lossPercent(10+(100-m)/4)/100;}
        // Shared virtual operators bound fortification damage without creating soldiers.
        (v[0],v[1])=_limited(v[0],v[1],d[0]+d[1]+towers*FortificationRules.OPERATORS_PER_TOWER,dp,ap);
        (v[2],v[3])=_limited(v[2],v[3],a[0]+a[1],ap,dp);
    }
    struct BattlePreview {uint256 attackPower;uint256 defensePower;uint256[4] losses;uint256[4] loot;uint256 observedAt;}
    function previewBattle(int32 ax,int32 ay,int32 dx,int32 dy,uint256[4] calldata force) external view owner(ax,ay) returns(BattlePreview memory p){
        revert("Legacy battle preview retired");
    }

    struct Redemption {int32 x;int32 y;address account;uint256 epoch;uint256 quantity;uint256 minimum;uint256 requestedAt;uint8 status;}
    mapping(uint256=>Redemption) public redemptions;
    mapping(int32=>mapping(int32=>uint256)) public pendingRedemption;
    uint256 public redemptionTail;
    uint256 public redemptionHead;
    event RedemptionQueued(uint256 indexed id,int32 x,int32 y,address account,uint256 quantity);
    event RedemptionFinished(uint256 indexed id,uint8 status);
    // Legacy queue storage is retained for local-world compatibility; new requests are disabled.
    error RedemptionQueueRemoved();
    function queueRedemption(int32,int32,uint256,uint256,address) external pure { revert RedemptionQueueRemoved(); }
    function processRedemption() external pure { revert RedemptionQueueRemoved(); }
    // Old requests never burned relics. Their owners can clear historical records without payment.
    function cancelRedemption(uint256 id) rpcIndexed external nonReentrant {
        Redemption storage r=redemptions[id];require(r.account==msg.sender,"Not request owner");
        require(r.status==1,"Request is closed");r.status=3;delete pendingRedemption[r.x][r.y];
        emit RedemptionFinished(id,3);
    }
}
