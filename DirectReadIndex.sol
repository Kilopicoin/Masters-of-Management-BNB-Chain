// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
pragma solidity ^0.8.24;
import "./BrowserReader.sol";
import "./readindextree.sol";
interface IIndexMap {function owner() external view returns(address);function settledCount() external view returns(uint256);function getSettledTilesPage(uint256,uint256) external view returns(uint64[] memory);function nextSettlement() external view returns(int32,int32);function worldBounds() external view returns(int32,int32);}
interface IIndexLogistics {function activeCount() external view returns(uint256);function activeId(uint256) external view returns(uint256);}
interface IIndexLand {function readIndex() external view returns(address);function marketplaceAddress() external view returns(address);function clanWar() external view returns(address);}

/// Authoritative read projection maintained atomically by gameplay hooks.
/// No assets, prices or game rules. Anyone may repair a row from canonical contracts;
/// callers cannot supply scores, inventories or timestamps to this projection.
contract DirectReadIndex  is PublicRPCEvents {
    error Unauthorized();

    error UnknownRoute();
    error InitializationFailed();


    error InvalidQuery();
    using ReadIndexTree for ReadIndexTree.Tree;
    BrowserReader public immutable reader;
    address public immutable map;
    address public immutable land;
    address public immutable clan;
    address public immutable logistics;
    address public immutable market;
    address public immutable clanWar;
    bool public ready;
    uint256 public knownRealms;
    uint256 public revision;
    ReadIndexTree.Tree private realmRanks;
    ReadIndexTree.Tree private clanRanks;
    ReadIndexTree.Tree private spatial;
    mapping(uint256=>WorldReader.Realm) private realmData;
    mapping(uint64=>BrowserReader.ClanRow) private clanData;
    mapping(uint64=>uint256) public clanPoints;
    mapping(uint64=>uint256) public clanMembers;
    mapping(uint256=>BrowserReader.Route) private routeData;
    mapping(uint256=>uint256[]) private related;
    mapping(uint256=>mapping(uint256=>uint256)) private relatedPosition;
    // Append-only endpoint lists replace route-tree writes. Legacy storage stays untouched.
    mapping(uint256=>uint256[]) private endpointBuckets;
    mapping(uint256=>mapping(uint256=>uint256)) private endpointPositions;
    mapping(uint256=>bool) private endpointIndexed;
    uint256 private endpointRouteCount;
    bool public endpointsReady;
    // Append-only layout extension: legacy routeData remains readable until each
    // row is next updated. Full-width cargo amounts are never truncated.
    struct PackedRoute {uint256 endpoints;uint256 times;uint256 flags;uint256 amount;}
    mapping(uint256=>PackedRoute) private packedRoutes;
    function _route(uint256 id) private view returns(BrowserReader.Route memory r){
        PackedRoute storage p=packedRoutes[id];if(p.flags==0)return routeData[id];
        uint256 e=p.endpoints;uint256 t=p.times;r.id=id;r.kind=uint8(p.flags);r.state=uint8(p.flags>>8);
        r.sx=int32(uint32(e));r.sy=int32(uint32(e>>32));r.tx=int32(uint32(e>>64));r.ty=int32(uint32(e>>96));
        r.sourceClan=uint64(e>>128);r.targetClan=uint64(e>>192);
        r.startedAt=uint64(t);r.arrivesAt=uint64(t>>64);r.returnStartedAt=uint64(t>>128);r.returnsAt=uint64(t>>192);r.amount=p.amount;
    }
    function _storeRoute(BrowserReader.Route memory r,bool active_) private {
        if(!active_){delete packedRoutes[r.id];if(routeData[r.id].id!=0)delete routeData[r.id];return;}
        if((r.startedAt|r.arrivesAt|r.returnStartedAt|r.returnsAt)>type(uint64).max){routeData[r.id]=r;delete packedRoutes[r.id];return;}
        PackedRoute storage p=packedRoutes[r.id];
        p.endpoints=uint256(uint32(r.sx))|(uint256(uint32(r.sy))<<32)|(uint256(uint32(r.tx))<<64)|(uint256(uint32(r.ty))<<96)|(uint256(r.sourceClan)<<128)|(uint256(r.targetClan)<<192);
        p.times=r.startedAt|(r.arrivesAt<<64)|(r.returnStartedAt<<128)|(r.returnsAt<<192);
        p.flags=uint256(r.kind)|(uint256(r.state)<<8)|(1<<16);p.amount=r.amount;
        if(routeData[r.id].id!=0)delete routeData[r.id];
    }
    event RouteEndpointChanged(uint256 indexed bucket,uint256 indexed realm,BrowserReader.Route route);
    event ClanMemberUpdated(uint64 indexed clanId,int32 x,int32 y);
    event RealmInventoryChanged(uint256 indexed realm,int32 x,int32 y);
    event SettlementProgress(int32 nextX,int32 nextY,int32 min,int32 max);
    event RealmChanged(uint256 indexed bucket,uint256 indexed realm,int32 x,int32 y,address occupant,bool isOnSale,uint8 bonus,uint256 level,uint256 points,uint64 clanId);
    event ClanChanged(uint64 indexed id,string name,int32 leaderX,int32 leaderY,bool exists,uint256 flagId);
    event RouteChanged(uint256 indexed bucket0,uint256 indexed bucket1,uint256 indexed bucket2,BrowserReader.Route route);
    event Activity(uint256 indexed bucket,uint256 indexed realm,uint8 kind,int32 ax,int32 ay,int32 dx,int32 dy,uint256 value);
    event IndexReady();
    constructor(address source){reader=BrowserReader(source);map=address(reader.map());land=address(reader.land());clan=address(reader.clan());logistics=address(reader.logistics());market=IIndexLand(land).marketplaceAddress();clanWar=IIndexLand(land).clanWar();}
    function activity(uint8 kind,int32 ax,int32 ay,int32 dx,int32 dy,uint256 value) rpcIndexed external {
        if(!(msg.sender==land||msg.sender==market||msg.sender==clanWar))revert Unauthorized();
        emit Activity(kind==0?bucket(ax,ay,ax,ay):bucket(dx,dy,dx,dy),kind==0?realmKey(ax,ay):realmKey(dx,dy),kind,ax,ay,dx,dy,value);
    }
    function realmKey(int32 x,int32 y) public pure returns(uint256){return (uint256(uint32(x)^0x80000000)<<32|uint32(y)^0x80000000)+1;}
    function coordinates(uint256 id) private pure returns(int32 x,int32 y){uint64 k=uint64(id-1);return(int32(uint32(k>>32)^0x80000000),int32(uint32(k)^0x80000000));}
    // Region keys use signed floor division. 16-cell leaves; 32 enclosing levels.
    function bucket(int32 sx,int32 sy,int32 tx,int32 ty) public pure returns(uint256){
        uint32 ax=uint32(sx)^0x80000000;uint32 ay=uint32(sy)^0x80000000;uint32 bx=uint32(tx)^0x80000000;uint32 by=uint32(ty)^0x80000000;
        uint256 shift=4;while(shift<32&&((ax>>shift)!=(bx>>shift)||(ay>>shift)!=(by>>shift)))shift++;
        return (shift<<64)|(uint256(ax>>shift)<<32)|uint256(ay>>shift);
    }
    function emptyBox() private pure returns(ReadIndexTree.Box memory){return ReadIndexTree.Box(0,0,0,0);}
    function syncRealm(int32 x,int32 y) rpcIndexed public {
        int32[] memory xs=new int32[](1);int32[] memory ys=new int32[](1);xs[0]=x;ys[0]=y;
        WorldReader.Realm memory r=reader.realms(xs,ys)[0];uint256 id=realmKey(x,y);WorldReader.Realm memory old=realmData[id];
        if(r.owner==address(0))return; // Settlement initialization precedes the map's final ownership write.
        if(keccak256(abi.encode(old))==keccak256(abi.encode(r)))return;
        if(old.owner==address(0)){knownRealms++;if(ready){(int32 nx,int32 ny)=IIndexMap(map).nextSettlement();(int32 min,int32 max)=IIndexMap(map).worldBounds();emit SettlementProgress(nx,ny,min,max);}}
        if(old.clanId==r.clanId){if(r.clanId!=0&&old.points!=r.points)clanPoints[r.clanId]=clanPoints[r.clanId]-old.points+r.points;}
        else {if(old.clanId!=0){clanPoints[old.clanId]-=old.points;clanMembers[old.clanId]--;}
            if(r.clanId!=0){clanPoints[r.clanId]+=r.points;clanMembers[r.clanId]++;if(clanData[r.clanId].id==0)syncClan(r.clanId);}}
        if(old.clanId!=0)emit ClanMemberUpdated(old.clanId,x,y);if(r.clanId!=0&&r.clanId!=old.clanId)emit ClanMemberUpdated(r.clanId,x,y);
        realmData[id]=r;realmRanks.setRank(id,r.points,r.points>0);
        if(old.clanId!=0&&old.clanId!=r.clanId)_clanRank(old.clanId);if(r.clanId!=0)_clanRank(r.clanId);
        revision++;emit RealmChanged(bucket(x,y,x,y),id,x,y,r.owner,r.isOnSale,r.bonus,r.level,r.points,r.clanId);
    }
    /// Score hooks carry only values already written by the authoritative land.
    /// Ownership, membership, names and flags keep using canonical full sync.
    function inventoryChanged(int32 x,int32 y) rpcIndexed external {
        if(msg.sender!=land)revert Unauthorized();emit RealmInventoryChanged(realmKey(x,y),x,y);
    }
    function syncRealmScore(int32 x,int32 y,uint256 points,uint256 level) rpcIndexed external {
        if(!(msg.sender==land))revert Unauthorized();
        uint256 id=realmKey(x,y);WorldReader.Realm storage r=realmData[id];
        if(r.owner==address(0)){syncRealm(x,y);return;}
        uint256 previous=r.points;
        if(previous==points&&r.level==level){emit RealmInventoryChanged(id,x,y);return;}
        if(previous!=points){
            r.points=points;realmRanks.setRank(id,points,points>0);
            if(r.clanId!=0){clanPoints[r.clanId]=clanPoints[r.clanId]-previous+points;_clanRank(r.clanId);}
        }
        if(r.level!=level)r.level=level;
        revision++;emit RealmChanged(bucket(x,y,x,y),id,x,y,r.owner,r.isOnSale,r.bonus,level,points,r.clanId);
    }
    function _clanRank(uint64 id) private{clanRanks.setRank(id,clanPoints[id],clanPoints[id]>0&&clanMembers[id]>0&&clanData[id].exists);}
    function syncClan(uint64 id) rpcIndexed public {
        if(id==0)return;uint64[] memory ids=new uint64[](1);ids[0]=id;BrowserReader.ClanRow memory c=reader.clanRows(ids)[0];if(keccak256(abi.encode(c))==keccak256(abi.encode(clanData[id])))return;clanData[id]=c;_clanRank(id);
        revision++;emit ClanChanged(id,c.name,c.leaderX,c.leaderY,c.exists,c.flagId);
    }
    function _related(uint256 key,uint256 id,bool add) private {
        uint256 pos=relatedPosition[key][id];if(add){if(pos==0){related[key].push(id);relatedPosition[key][id]=related[key].length;}}
        else if(pos!=0){uint256 last=related[key][related[key].length-1];related[key][pos-1]=last;relatedPosition[key][last]=pos;related[key].pop();delete relatedPosition[key][id];}
    }
    function relationKeys(BrowserReader.Route memory r) private pure returns(uint256[4] memory keys){
        keys[0]=realmKey(r.sx,r.sy);keys[1]=realmKey(r.tx,r.ty);if(r.sourceClan!=0)keys[2]=(1<<128)|r.sourceClan;if(r.targetClan!=0)keys[3]=(1<<128)|r.targetClan;
    }
    function morton(int32 x,int32 y) private pure returns(uint256 value){
        uint32 a=uint32(x)^0x80000000;uint32 b=uint32(y)^0x80000000;
        for(uint256 i;i<32;i++){value|=uint256((a>>i)&1)<<(i*2);value|=uint256((b>>i)&1)<<(i*2+1);}
    }
    function _floor(int64 n,int64 size) private pure returns(int64){int64 q=n/size;return n<0&&n%size!=0?q-1:q;}
    function _routeBucket(int64 x,int64 y,uint256 shift) private pure returns(uint256){return(shift<<64)|(uint256((uint32(int32(x))^0x80000000)>>shift)<<32)|uint256((uint32(int32(y))^0x80000000)>>shift);}
    /// Supercover grid traversal, coarsened until its work is bounded. Three
    /// indexed cells share each full event, avoiding a follow-up RPC per reader.
    function _routeEvent(BrowserReader.Route memory r) private {
        int64 dx=int64(r.tx)-r.sx;int64 dy=int64(r.ty)-r.sy;int64 ax=dx<0?-dx:dx;int64 ay=dy<0?-dy:dy;uint256 shift=4;
        while(uint64(ax+ay)>>shift>10)shift++;int64 size=int64(uint64(1)<<shift);
        int64 x=_floor(r.sx,size);int64 y=_floor(r.sy,size);int64 ex=_floor(r.tx,size);int64 ey=_floor(r.ty,size);int64 sx=dx<0?int64(-1):int64(1);int64 sy=dy<0?int64(-1):int64(1);
        int64 nx=dx<0?int64(r.sx)-x*size:(x+1)*size-r.sx;int64 ny=dy<0?int64(r.sy)-y*size:(y+1)*size-r.sy;
        uint256[48] memory keys;uint256 used;keys[used++]=_routeBucket(x*size,y*size,shift);
        while(x!=ex||y!=ey){
            if(x==ex||y!=ey&&int256(nx)*ay>int256(ny)*ax){y+=sy;ny+=size;}
            else if(y==ey||int256(nx)*ay<int256(ny)*ax){x+=sx;nx+=size;}
            else {keys[used++]=_routeBucket((x+sx)*size,y*size,shift);keys[used++]=_routeBucket(x*size,(y+sy)*size,shift);x+=sx;y+=sy;nx+=size;ny+=size;}
            keys[used++]=_routeBucket(x*size,y*size,shift);
        }
        for(uint256 i;i<used;i+=3)emit RouteChanged(keys[i],i+1<used?keys[i+1]:type(uint256).max,i+2<used?keys[i+2]:type(uint256).max,r);
    }
    function _endpoint(uint256 key,uint256 id,bool add) private {
        uint256 pos=endpointPositions[key][id];if(add){if(pos==0){endpointBuckets[key].push(id);endpointPositions[key][id]=endpointBuckets[key].length;}}
        else if(pos!=0){uint256 last=endpointBuckets[key][endpointBuckets[key].length-1];endpointBuckets[key][pos-1]=last;endpointPositions[key][last]=pos;endpointBuckets[key].pop();delete endpointPositions[key][id];}
    }
    function syncRoute(uint256 id) rpcIndexed public {
        uint256[] memory ids=new uint256[](1);ids[0]=id;BrowserReader.Route memory r=reader.routes(ids)[0];if(!(r.id==id&&r.state!=0))revert UnknownRoute();
        BrowserReader.Route memory old=_route(id);bool active=r.state!=3;
        if(!active&&old.id==0)return;
        if(endpointIndexed[id]&&active&&keccak256(abi.encode(r))==keccak256(abi.encode(old)))return;
        if(old.id==0&&active){uint256[4] memory keys=relationKeys(r);for(uint256 i;i<4;i++)if(keys[i]!=0)_related(keys[i],id,true);}
        if(old.id!=0&&!active){uint256[4] memory keys=relationKeys(old);for(uint256 i;i<4;i++)if(keys[i]!=0)_related(keys[i],id,false);}
        uint256 source=bucket(r.sx,r.sy,r.sx,r.sy);uint256 target=bucket(r.tx,r.ty,r.tx,r.ty);
        if(active&&!endpointIndexed[id]){_endpoint(source,id,true);if(target!=source)_endpoint(target,id,true);endpointIndexed[id]=true;endpointRouteCount++;}
        if(!active&&endpointIndexed[id]){_endpoint(source,id,false);if(target!=source)_endpoint(target,id,false);delete endpointIndexed[id];endpointRouteCount--;}
        _storeRoute(r,active);revision++;
        emit RouteEndpointChanged(source,realmKey(r.sx,r.sy),r);if(r.sx!=r.tx||r.sy!=r.ty)emit RouteEndpointChanged(target,realmKey(r.tx,r.ty),r);
    }
    function seedEndpointRoutes(uint256 offset,uint256 limit) rpcIndexed external {if(!(!endpointsReady&&limit>0&&limit<=50))revert InitializationFailed();uint256 count=IIndexLogistics(logistics).activeCount();for(uint256 i=offset;i<count&&i<offset+limit;i++)syncRoute(IIndexLogistics(logistics).activeId(i));}
    function activateEndpoints()  public {if(!(!endpointsReady&&endpointRouteCount==IIndexLogistics(logistics).activeCount()))revert InitializationFailed();endpointsReady=true;}
    function _contains(ReadIndexTree.Box memory b,int32 x,int32 y) private pure returns(bool){return x>=b.minX&&x<=b.maxX&&y>=b.minY&&y<=b.maxY;}
    /// Scan only buckets containing visible endpoints; routes crossing the viewport keep their full line.
    function endpointRoutes(ReadIndexTree.Box calldata visible,ReadIndexTree.Box calldata viewport,uint256[] calldata cursor,uint256 limit) external view returns(BrowserReader.Route[] memory rows,uint256[] memory next){
        if(!(limit>0&&limit<=128))revert InvalidQuery();return _endpointRoutes(visible,viewport,cursor,limit,512);
    }
    function endpointRoutesPage(ReadIndexTree.Box calldata visible,ReadIndexTree.Box calldata viewport,uint256[] calldata cursor,uint256 limit) external view returns(uint256[5][] memory rows,uint256[] memory next){
        if(!(limit>0&&limit<=256))revert InvalidQuery();BrowserReader.Route[] memory full;(full,next)=_endpointRoutes(visible,viewport,cursor,limit,1024);
        // Both arrays are bounded above by 256 rows and a two-word cursor.
        unchecked { bytes memory encoded=new bytes(128+160*full.length+32*next.length);uint256 tail=96+160*full.length;
        assembly("memory-safe"){let out:=add(encoded,32)mstore(out,64)mstore(add(out,32),tail)mstore(add(out,64),mload(full))mstore(add(out,tail),mload(next))}
        for(uint256 i;i<full.length;i++){BrowserReader.Route memory a=full[i];if(!((a.startedAt|a.arrivesAt|a.returnStartedAt|a.returnsAt)>>64==0))revert InvalidQuery();
          assembly("memory-safe"){
            let dest:=add(add(encoded,128),mul(i,160))
            mstore(dest,mload(a))mstore(add(dest,32),mload(add(a,416)))
            mstore(add(dest,64),or(or(or(and(mload(add(a,96)),0xffffffff),shl(32,and(mload(add(a,128)),0xffffffff))),or(shl(64,and(mload(add(a,160)),0xffffffff)),shl(96,and(mload(add(a,192)),0xffffffff)))),or(shl(128,mload(add(a,32))),shl(136,mload(add(a,64))))))
            mstore(add(dest,96),or(mload(add(a,224)),shl(64,mload(add(a,256)))))
            mstore(add(dest,128),or(or(mload(add(a,288)),shl(64,mload(add(a,320)))),or(shl(128,mload(add(a,352))),shl(192,mload(add(a,384))))))
          }
        }
        for(uint256 i;i<next.length;i++){assembly("memory-safe"){mstore(add(add(add(encoded,64),tail),mul(i,32)),mload(add(add(next,32),mul(i,32))))}}
        assembly("memory-safe"){return(add(encoded,32),mload(encoded))} }
    }
    function _endpointRoutes(ReadIndexTree.Box memory visible,ReadIndexTree.Box memory viewport,uint256[] memory cursor,uint256 limit,uint256 scanLimit) private view returns(BrowserReader.Route[] memory rows,uint256[] memory next){
        if(!(endpointsReady&&(cursor.length==0||cursor.length==2)&&visible.minX<=visible.maxX&&visible.minY<=visible.maxY))revert InvalidQuery();
        int64 minX=_floor(visible.minX,16);int64 minY=_floor(visible.minY,16);uint256 height=uint256(uint64(_floor(visible.maxY,16)-minY+1));uint256 cells=uint256(uint64(_floor(visible.maxX,16)-minX+1))*height;
        uint256 cell=cursor.length==0?0:cursor[0];uint256 offset=cursor.length==0?0:cursor[1];if(!(cell<=cells))revert InvalidQuery();rows=new BrowserReader.Route[](limit);uint256 found;uint256 visited;uint256 empty;
        while(cell<cells&&found<limit&&visited+found*2<scanLimit&&empty<64){
            int32 x=int32((minX+int64(uint64(cell/height)))*16);int32 y=int32((minY+int64(uint64(cell%height)))*16);uint256 current=bucket(x,y,x,y);uint256[] storage ids=endpointBuckets[current];
            if(offset>=ids.length){cell++;offset=0;empty++;continue;}
            uint256 id=ids[offset++];visited++;BrowserReader.Route memory r=_route(id);bool source=_contains(visible,r.sx,r.sy);bool target=_contains(visible,r.tx,r.ty);
            if((source||target)&&current==(source?bucket(r.sx,r.sy,r.sx,r.sy):bucket(r.tx,r.ty,r.tx,r.ty))&&crosses(r,viewport))rows[found++]=r;
        }
        assembly("memory-safe"){mstore(rows,found)}if(cell<cells){next=new uint256[](2);next[0]=cell;next[1]=offset;}else next=new uint256[](0);
    }
    function seedRealms(uint256 offset,uint256 limit) rpcIndexed external {if(!(!ready&&limit<=64&&limit>0))revert InitializationFailed();uint64[] memory ids=IIndexMap(map).getSettledTilesPage(offset,limit);for(uint256 i;i<ids.length;i++)syncRealm(int32(uint32(ids[i]>>32)),int32(uint32(ids[i])));}
    function seedRoutes(uint256 offset,uint256 limit) rpcIndexed external {if(!(!ready&&limit<=50&&limit>0))revert InitializationFailed();uint256 n=IIndexLogistics(logistics).activeCount();for(uint256 i=offset;i<n&&i<offset+limit;i++)syncRoute(IIndexLogistics(logistics).activeId(i));}
    function activate() rpcIndexed external {if(!(!ready&&IIndexLand(land).readIndex()==address(this)))revert InitializationFailed();if(!(knownRealms==IIndexMap(map).settledCount()&&endpointRouteCount==IIndexLogistics(logistics).activeCount()))revert InitializationFailed();ready=true;if(!endpointsReady)activateEndpoints();emit IndexReady();}
    function regionTiles(int32 x,int32 y,uint8 width,uint8 height) external view returns(BrowserReader.MapTile[] memory rows){
        if(!(width>0&&height>0&&uint256(width)*height<=256))revert InvalidQuery();rows=new BrowserReader.MapTile[](uint256(width)*height);
        for(uint256 a;a<width;a++)for(uint256 b;b<height;b++){
            int32 px=x+int32(uint32(a));int32 py=y+int32(uint32(b));WorldReader.Realm storage r=realmData[realmKey(px,py)];BrowserReader.ClanRow storage c=clanData[r.clanId];
            rows[a*height+b]=BrowserReader.MapTile(px,py,r.owner,r.isOnSale,r.bonus,r.level,r.clanId,c.exists?c.flagId:0,c.exists&&c.leaderX==px&&c.leaderY==py);
        }
    }
    struct RankRow {uint256 id;int32 x;int32 y;uint256 points;string name;string clanName;uint256 members;}
    struct RealmReference {int32 x;int32 y;address owner;uint64 clanId;}
    function realmReferences(int32[] calldata xs,int32[] calldata ys) external view returns(RealmReference[] memory rows){
        if(!(xs.length==ys.length&&xs.length<=256))revert InvalidQuery();rows=new RealmReference[](xs.length);
        for(uint256 i;i<xs.length;i++){WorldReader.Realm storage r=realmData[realmKey(xs[i],ys[i])];rows[i]=RealmReference(xs[i],ys[i],r.owner,r.clanId);}
    }
    function clanRows(uint64[] calldata ids) external view returns(BrowserReader.ClanRow[] memory rows){
        if(!(ids.length<=128))revert InvalidQuery();rows=new BrowserReader.ClanRow[](ids.length);for(uint256 i;i<ids.length;i++)rows[i]=clanData[ids[i]];
    }
    function rankings(bool clans,uint256 offset,uint256 limit,int32 ownX,int32 ownY) external view returns(RankRow[] memory rows,uint256 total,uint256 ownRank,uint256 ownPoints,uint256 ownClan){
        if(!(limit>0&&limit<=64))revert InvalidQuery();ReadIndexTree.Tree storage tree=clans?clanRanks:realmRanks;total=tree.count();uint256 count=offset>=total?0:(total-offset<limit?total-offset:limit);rows=new RankRow[](count);
        for(uint256 i;i<count;i++){uint256 id=tree.at(offset+i);if(clans){BrowserReader.ClanRow storage c=clanData[uint64(id)];rows[i]=RankRow(id,c.leaderX,c.leaderY,clanPoints[uint64(id)],c.name,"",clanMembers[uint64(id)]);}
            else{WorldReader.Realm storage r=realmData[id];rows[i]=RankRow((uint256(uint32(r.x))<<32)|uint32(r.y),r.x,r.y,r.points,r.name,clanData[r.clanId].name,0);}}
        uint256 own=realmKey(ownX,ownY);ownClan=realmData[own].clanId;if(clans)own=ownClan;ownRank=tree.rank(own);if(ownRank>0)ownPoints=tree.nodes[own].score;
    }
    function routeCount() external view returns(uint256){return endpointsReady?endpointRouteCount:spatial.count();}
    function relatedRoutes(int32 x,int32 y,uint64 clanId,uint256 offset,uint256 limit) external view returns(BrowserReader.Route[] memory rows,uint256 total){
        if(!(limit>0&&limit<=50))revert InvalidQuery();uint256 key=clanId==0?realmKey(x,y):(1<<128)|clanId;uint256[] storage ids=related[key];total=ids.length;uint256 count=offset>=total?0:(total-offset<limit?total-offset:limit);rows=new BrowserReader.Route[](count);for(uint256 i;i<count;i++)rows[i]=_route(ids[offset+i]);
    }
    function side(int32 ax,int32 ay,int32 bx,int32 by,int32 x,int32 y) private pure returns(int256){return(int256(bx)-ax)*(int256(y)-ay)-(int256(by)-ay)*(int256(x)-ax);}
    function crosses(BrowserReader.Route memory r,ReadIndexTree.Box memory b) private pure returns(bool){
        if(r.sx<b.minX&&r.tx<b.minX||r.sx>b.maxX&&r.tx>b.maxX||r.sy<b.minY&&r.ty<b.minY||r.sy>b.maxY&&r.ty>b.maxY)return false;
        int256 a=side(r.sx,r.sy,r.tx,r.ty,b.minX,b.minY);int256 c=side(r.sx,r.sy,r.tx,r.ty,b.maxX,b.minY);int256 d=side(r.sx,r.sy,r.tx,r.ty,b.minX,b.maxY);int256 e=side(r.sx,r.sy,r.tx,r.ty,b.maxX,b.maxY);
        return !(a>0&&c>0&&d>0&&e>0||a<0&&c<0&&d<0&&e<0);
    }
    /// Compatibility scan for clients without vision; cursor is an active-list offset.
    function routesInArea(ReadIndexTree.Box calldata box,uint256[] calldata cursor,uint256 limit) external view returns(BrowserReader.Route[] memory rows,uint256[] memory next,uint256 visited){
        if(!(limit>0&&limit<=128&&cursor.length<=1&&box.minX<=box.maxX&&box.minY<=box.maxY))revert InvalidQuery();uint256 offset=cursor.length==0?0:cursor[0];uint256 total=IIndexLogistics(logistics).activeCount();rows=new BrowserReader.Route[](limit);uint256 found;
        while(offset<total&&found<limit&&visited<512){uint256 id=IIndexLogistics(logistics).activeId(offset++);visited++;BrowserReader.Route memory route=_route(id);if(crosses(route,box))rows[found++]=route;}
        if(offset<total){next=new uint256[](1);next[0]=offset;}else next=new uint256[](0);assembly("memory-safe"){mstore(rows,found)}
    }
}

