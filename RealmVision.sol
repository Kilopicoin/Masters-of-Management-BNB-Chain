// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
pragma solidity ^0.8.24;
import "DirectReadIndex.sol";
import "scoutsnapshot.sol";
import "journeyinterfaces.sol";
interface IVisionMap {
    function hasOccupiedTile(address) external view returns(bool);
    function getOccupiedTileByAddress(address) external view returns(int32[2] memory);
    function getTileOccupant(int32,int32) external view returns(address);
    function ownershipEpoch(int32,int32) external view returns(uint256);
    function worldBounds() external view returns(int32,int32);
    function bonuses(int32,int32) external view returns(uint8);
}
interface IVisionLand is IJLand {function relicBalances(int32,int32) external view returns(uint256);}
interface IVisionMilitary {function realmArmy(int32,int32) external view returns(uint256[20] memory);}
interface IVisionStable {function specializations(int32,int32) external view returns(uint8,uint256);}
/// Gameplay visibility, not secrecy for public blockchain storage.
/// Cooldowns belong to the realm; permissions and reports also bind its ownership epoch.
contract RealmVision  is PublicRPCEvents {
    IVisionMap public immutable map;
    IVisionLand public immutable land;
    DirectReadIndex public immutable index;
    uint256 public constant SCOUT_INTERVAL=24 hours;
    uint256 private constant SCOUT_DURATION=24 hours;
    uint256 private constant EXPLORATION_RADIUS=2;
    struct Scout {int32 x;int32 y;uint64 until;uint64 atBlock;uint256 epoch;uint256 targetEpoch;}
    struct State {bool owned;int32 x;int32 y;uint256 radius;bool intelligence;Scout exploration;Scout report;uint256 nowAt;}
    mapping(uint64=>Scout) private exploration;
    mapping(uint64=>Scout) private intelligence;
    // Appended to keep existing discovery permissions and cooldowns intact.
    mapping(uint64=>bytes) private reportSnapshots;
    event Scouted(address indexed account,int32 indexed x,int32 indexed y,bool area,uint256 expiresAt);
    constructor(address m,address l,address i){map=IVisionMap(m);land=IVisionLand(l);index=DirectReadIndex(i);}
    function _key(int32 x,int32 y) private pure returns(uint64){return(uint64(uint32(x))<<32)|uint64(uint32(y));}
    function status(address account) public view returns(State memory s){
        s.nowAt=block.timestamp;if(!map.hasOccupiedTile(account))return s;
        int32[2] memory p=map.getOccupiedTileByAddress(account);s.x=p[0];s.y=p[1];
        if(map.getTileOccupant(s.x,s.y)!=account)return s;s.owned=true;
        s.radius=IReadLand(address(land)).getTilePublic(s.x,s.y).level/10+1;s.intelligence=land.getBuildingCounts(s.x,s.y)[12]>0;
        s.exploration=exploration[_key(s.x,s.y)];s.report=intelligence[_key(s.x,s.y)];
        uint256 epoch=map.ownershipEpoch(s.x,s.y);
        if(!s.intelligence||s.exploration.epoch!=epoch)s.exploration.atBlock=0;
        if(!s.intelligence||s.report.epoch!=epoch||s.report.targetEpoch!=map.ownershipEpoch(s.report.x,s.report.y))s.report.atBlock=0;
    }
    function _inside(int32 x,int32 y,int32 cx,int32 cy,uint256 radius) private pure returns(bool){
        uint256 dx=uint256(x>cx?int256(x)-cx:int256(cx)-x);uint256 dy=uint256(y>cy?int256(y)-cy:int256(cy)-y);return dx<=radius&&dy<=radius;
    }
    function _visible(State memory s,int32 x,int32 y) private view returns(bool){
        if(!s.owned)return false;if(_inside(x,y,s.x,s.y,s.radius))return true;
        Scout memory a=s.exploration;
        return s.intelligence&&a.atBlock>0&&block.timestamp<a.until&&_inside(x,y,a.x,a.y,EXPLORATION_RADIUS);
    }
    function canSee(address account,int32 x,int32 y) external view returns(bool){return _visible(status(account),x,y);}
    function requireDestination(address account,int32 sx,int32 sy,int32 tx,int32 ty) external view {
        State memory s=status(account);require(s.owned&&s.x==sx&&s.y==sy&&_visible(s,tx,ty),"Destination outside vision");
    }
    function _scout(int32 x,int32 y,bool area) private {
        land.requireWorldActive();State memory s=status(msg.sender);require(s.owned&&s.intelligence,"Intelligence Center required");
        (int32 min,int32 max)=map.worldBounds();require(x>=min&&x<=max&&y>=min&&y<=max,"Outside world");
        Scout storage previous=area?exploration[_key(s.x,s.y)]:intelligence[_key(s.x,s.y)];
        // Both visibility and reuse expire 24 hours after the successful scout.
        // Ownership changes cannot reset the realm's cooldown.
        require(previous.until==0||block.timestamp>=uint256(previous.until)+SCOUT_INTERVAL-SCOUT_DURATION,"Scout cooldown: 24 hours");
        if(area)require(!_visible(s,x,y),"Choose an unexplored cell");
        else require(_visible(s,x,y)&&(x!=s.x||y!=s.y)&&map.getTileOccupant(x,y)!=address(0),"Choose a visible foreign realm");
        previous.x=x;previous.y=y;previous.until=uint64(block.timestamp+SCOUT_DURATION);previous.atBlock=uint64(block.number);
        previous.epoch=map.ownershipEpoch(s.x,s.y);previous.targetEpoch=map.ownershipEpoch(x,y);
        if(!area)reportSnapshots[_key(s.x,s.y)]=_encodeReport(_observe(x,y));
        emit Scouted(msg.sender,x,y,area,previous.until);
    }
    function explore(int32 x,int32 y) rpcIndexed external {_scout(x,y,true);}
    function scout(int32 x,int32 y) rpcIndexed external {_scout(x,y,false);}
    function requireReport(address account,int32 x,int32 y) external view {
        State memory s=status(account);Scout memory r=s.report;
        require(s.intelligence&&block.timestamp<r.until&&r.x==x&&r.y==y&&r.epoch==map.ownershipEpoch(s.x,s.y)&&r.targetEpoch==map.ownershipEpoch(x,y),"Scout report expired or unavailable");
    }
    struct Report {uint256[4] resources;uint256[20] army;uint8[21] levels;uint256 level;uint256 relics;uint256 towers;uint8 bonus;uint8 specialization;uint256 observedAt;uint256 castles;}
    function reportData(address account) external view returns(Report memory r){
        State memory s=status(account);Scout memory q=s.report;this.requireReport(account,q.x,q.y);
        bytes memory data=reportSnapshots[_key(s.x,s.y)];require(data.length>0,"Scout report needs renewal");return _decodeReport(data);
    }
    function _observe(int32 x,int32 y) private view returns(Report memory r){
        IJLand.Inventory memory h=land.getTileData(x,y);r.resources=[h.food,h.wood,h.stone,h.iron];r.level=h.level;r.relics=land.relicBalances(x,y);
        r.towers=land.getBuildingCounts(x,y)[7];r.castles=land.getCastleCount(x,y);r.bonus=map.bonuses(x,y);r.army=IVisionMilitary(land.military()).realmArmy(x,y);r.levels=land.unitResearchLevels(x,y);
        (r.specialization,)=IVisionStable(land.stable()).specializations(x,y);r.observedAt=block.timestamp;
    }
    function _encodeReport(Report memory r) private pure returns(bytes memory data){
        data=new bytes(29*33+23);uint256 n;
        for(uint256 i;i<4;i++)n=ScoutSnapshot.write(data,n,r.resources[i]);for(uint256 i;i<20;i++)n=ScoutSnapshot.write(data,n,r.army[i]);
        n=ScoutSnapshot.write(data,n,r.level);n=ScoutSnapshot.write(data,n,r.relics);n=ScoutSnapshot.write(data,n,r.towers);n=ScoutSnapshot.write(data,n,r.observedAt);
        for(uint256 i;i<21;i++)data[n++]=bytes1(r.levels[i]);data[n++]=bytes1(r.bonus);data[n++]=bytes1(r.specialization);n=ScoutSnapshot.write(data,n,r.castles);assembly("memory-safe"){mstore(data,n)}
    }
    function _decodeReport(bytes memory data) private pure returns(Report memory r){
        uint256 n;for(uint256 i;i<4;i++)(r.resources[i],n)=ScoutSnapshot.read(data,n);for(uint256 i;i<20;i++)(r.army[i],n)=ScoutSnapshot.read(data,n);
        (r.level,n)=ScoutSnapshot.read(data,n);(r.relics,n)=ScoutSnapshot.read(data,n);(r.towers,n)=ScoutSnapshot.read(data,n);(r.observedAt,n)=ScoutSnapshot.read(data,n);
        require(n+23<=data.length,"Invalid scout snapshot");for(uint256 i;i<21;i++)r.levels[i]=uint8(data[n++]);r.bonus=uint8(data[n++]);r.specialization=uint8(data[n++]);
        // Legacy reports without a Castle field retain their original zero count.
        if(n<data.length)(r.castles,n)=ScoutSnapshot.read(data,n);require(n==data.length,"Invalid scout snapshot");
    }
    /// Sparse reply: hidden cells are never serialized to the browser.
    function region(int32 x,int32 y,uint8 width,uint8 height) public view returns(BrowserReader.MapTile[] memory rows){
        require(width>0&&height>0&&uint256(width)*height<=256,"Region limit");State memory s=status(msg.sender);
        if(!s.owned)return new BrowserReader.MapTile[](0);
        int32 endX=int32(int256(x)+int256(uint256(width))-1);int32 endY=int32(int256(y)+int256(uint256(height))-1);
        Scout memory a=s.exploration;
        if((_inside(x,y,s.x,s.y,s.radius)&&_inside(endX,endY,s.x,s.y,s.radius))||
          (s.intelligence&&a.atBlock>0&&block.timestamp<a.until&&_inside(x,y,a.x,a.y,EXPLORATION_RADIUS)&&_inside(endX,endY,a.x,a.y,EXPLORATION_RADIUS)))return index.regionTiles(x,y,width,height);
        rows=new BrowserReader.MapTile[](uint256(width)*height);uint256 count;
        // Read only contiguous visible runs, rather than 256 hidden canonical records.
        for(uint256 i;i<width;i++){
            int32 px=int32(int256(x)+int256(i));uint256 j;
            while(j<height){while(j<height&&!_visible(s,px,int32(int256(y)+int256(j))))j++;uint256 start=j;
                while(j<height&&_visible(s,px,int32(int256(y)+int256(j))))j++;
                if(j>start){BrowserReader.MapTile[] memory part=index.regionTiles(px,int32(int256(y)+int256(start)),1,uint8(j-start));for(uint256 n;n<part.length;n++)rows[count++]=part[n];}
            }
        }
        assembly("memory-safe"){mstore(rows,count)}
    }
    function _bound(int256 v) private pure returns(int32){return v<type(int32).min?type(int32).min:v>type(int32).max?type(int32).max:int32(v);}
    function visibleRoutes(ReadIndexTree.Box calldata box,uint256[] calldata cursor,uint256 limit) external view returns(BrowserReader.Route[] memory rows,uint256[] memory next){
        State memory s=status(msg.sender);if(!s.owned)return(new BrowserReader.Route[](0),new uint256[](0));
        require(limit>0&&limit<=128&&box.minX<=box.maxX&&box.minY<=box.maxY&&cursor.length<=3,"Invalid spatial query");
        uint256 phase=cursor.length==0?0:cursor[0];require(phase<=1,"Invalid route phase");Scout memory a=s.exploration;bool extra=s.intelligence&&a.atBlock>0&&block.timestamp<a.until;
        if(phase==1&&!extra)return(new BrowserReader.Route[](0),new uint256[](0));
        int256 radius=phase==0?int256(s.radius):int256(EXPLORATION_RADIUS);int32 cx=phase==0?s.x:a.x;int32 cy=phase==0?s.y:a.y;
        ReadIndexTree.Box memory visible=ReadIndexTree.Box(_bound(int256(cx)-radius),_bound(int256(cy)-radius),_bound(int256(cx)+radius),_bound(int256(cy)+radius));
        uint256[] memory continuation=new uint256[](cursor.length==0?0:cursor.length-1);for(uint256 i;i<continuation.length;i++)continuation[i]=cursor[i+1];
        (rows,continuation)=index.endpointRoutes(visible,box,continuation,limit);
        if(continuation.length>0){next=new uint256[](3);next[0]=phase;next[1]=continuation[0];next[2]=continuation[1];}
        else if(phase==0&&extra){next=new uint256[](1);next[0]=1;}else next=new uint256[](0);
    }

    function visibleRoutesCompact(ReadIndexTree.Box calldata box,uint256[] calldata cursor,uint256 limit) external view returns(uint256[5][] memory rows,uint256[] memory next){
        State memory s=status(msg.sender);if(!s.owned)return(new uint256[5][](0),new uint256[](0));
        require(limit>0&&limit<=256&&box.minX<=box.maxX&&box.minY<=box.maxY&&cursor.length<=3,"Invalid spatial query");
        uint256 phase=cursor.length==0?0:cursor[0];require(phase<=1,"Invalid route phase");Scout memory a=s.exploration;bool extra=s.intelligence&&a.atBlock>0&&block.timestamp<a.until;
        if(phase==1&&!extra)return(new uint256[5][](0),new uint256[](0));
        int256 radius=phase==0?int256(s.radius):int256(EXPLORATION_RADIUS);int32 cx=phase==0?s.x:a.x;int32 cy=phase==0?s.y:a.y;
        ReadIndexTree.Box memory visible=ReadIndexTree.Box(_bound(int256(cx)-radius),_bound(int256(cy)-radius),_bound(int256(cx)+radius),_bound(int256(cy)+radius));
        uint256[] memory continuation=new uint256[](cursor.length==0?0:cursor.length-1);for(uint256 i;i<continuation.length;i++)continuation[i]=cursor[i+1];
        (rows,continuation)=index.endpointRoutesPage(visible,box,continuation,limit);
        if(continuation.length>0){next=new uint256[](3);next[0]=phase;next[1]=continuation[0];next[2]=continuation[1];}
        else if(phase==0&&extra){next=new uint256[](1);next[0]=1;}else next=new uint256[](0);
    }


    function regionCompact(int32 x,int32 y,uint8 width,uint8 height) external view returns(uint256[4][] memory rows){
        BrowserReader.MapTile[] memory full=region(x,y,width,height);rows=new uint256[4][](full.length);
        for(uint256 i;i<full.length;i++){BrowserReader.MapTile memory r=full[i];rows[i]=[uint256(uint32(r.x))|(uint256(uint32(r.y))<<32)|(uint256(uint160(r.occupant))<<64)|(uint256(r.bonus)<<224)|(r.isOnSale?uint256(1)<<232:0)|(r.leader?uint256(1)<<233:0),r.level,uint256(r.clanId),r.flagId];}
    }
    function realmReferencesCompact(int32[] calldata xs,int32[] calldata ys) external view returns(uint256[2][] memory rows){
        require(xs.length==ys.length&&xs.length<=1024,"Reference limit");State memory s=status(msg.sender);rows=new uint256[2][](xs.length);uint256 count;
        for(uint256 start;start<xs.length;start+=256){uint256 size=xs.length-start;if(size>256)size=256;int32[] memory ax=new int32[](size);int32[] memory ay=new int32[](size);uint256 visible;
            for(uint256 i;i<size;i++)if(_visible(s,xs[start+i],ys[start+i])){ax[visible]=xs[start+i];ay[visible++]=ys[start+i];}
            assembly("memory-safe"){mstore(ax,visible)mstore(ay,visible)}
            DirectReadIndex.RealmReference[] memory refs=index.realmReferences(ax,ay);
            for(uint256 i;i<refs.length;i++){DirectReadIndex.RealmReference memory r=refs[i];rows[count++]=[uint256(uint32(r.x))|(uint256(uint32(r.y))<<32)|(uint256(uint160(r.owner))<<64),uint256(r.clanId)];}
        }
        assembly("memory-safe"){mstore(rows,count)}
    }

    function memberNames(int32[] calldata xs,int32[] calldata ys) external view returns(string[] memory names){
      require(xs.length==ys.length&&xs.length<=30,"Member limit");names=new string[](xs.length);
      for(uint256 i;i<xs.length;i++)names[i]=IReadClan(index.clan()).getTileName(xs[i],ys[i]);
    }
}

