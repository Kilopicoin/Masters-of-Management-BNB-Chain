// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IReadMap {
    struct RegionTile { int32 x; int32 y; address occupant; bool isOnSale; uint8 bonus; }
    function getRegion(int32,int32,uint8,uint8) external view returns (RegionTile[] memory);
    function getSettledTilesPage(uint256,uint256) external view returns (uint64[] memory);
}
interface IReadLand {
    struct PublicRealm { uint256 level; uint256 points; }
    function getTilePublic(int32,int32) external view returns (PublicRealm memory);
}
interface IReadClan {
    function getTileName(int32,int32) external view returns (string memory);
    function getTileClan(int32,int32) external view returns (uint64);
}

/// Bounded, read-only aggregation. No custody, approvals, writes or admin methods.
contract WorldReader {
    IReadMap public immutable map;
    IReadLand public immutable land;
    IReadClan public immutable clan;
    struct Realm { int32 x; int32 y; address owner; bool isOnSale; uint8 bonus;
        uint256 level; uint256 points; string name; uint64 clanId; }
    constructor(address m,address l,address c) { map=IReadMap(m); land=IReadLand(l); clan=IReadClan(c); }
    function readRealm(int32 x,int32 y) private view returns (Realm memory) {
        IReadMap.RegionTile memory tile=map.getRegion(x,y,1,1)[0];
        IReadLand.PublicRealm memory info=land.getTilePublic(x,y);
        return Realm(x,y,tile.occupant,tile.isOnSale,tile.bonus,info.level,info.points,clan.getTileName(x,y),clan.getTileClan(x,y));
    }
    function settledPage(uint256 offset,uint256 limit) external view returns (Realm[] memory rows) {
        require(limit>0 && limit<=64,"Page limit 1-64");
        uint64[] memory keys=map.getSettledTilesPage(offset,limit);
        rows=new Realm[](keys.length);
        for(uint256 i;i<keys.length;i++) rows[i]=readRealm(int32(uint32(keys[i]>>32)),int32(uint32(keys[i])));
    }
    function realms(int32[] calldata xs,int32[] calldata ys) external view returns (Realm[] memory rows) {
        require(xs.length==ys.length && xs.length>0 && xs.length<=64,"Coordinates 1-64");
        rows=new Realm[](xs.length);
        for(uint256 i;i<xs.length;i++) rows[i]=readRealm(xs[i],ys[i]);
    }
}
