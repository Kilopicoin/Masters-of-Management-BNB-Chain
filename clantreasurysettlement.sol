// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
import {WalletClaimStatus} from "./WalletClaimStatus.sol";
pragma solidity 0.8.37;
import {ClanFinalPool,FinalClanAllocation} from "ClanFinalPool.sol";
import {ClanPower} from "./clanpower.sol";

interface ICTMap {
    function ownershipEpoch(int32,int32) external view returns(uint256);
    function getOccupiedTileByAddress(address) external view returns(int32[2] memory);
    function getTileOccupant(int32,int32) external view returns(address);
}
interface ICTClan {
    function membershipEpoch(int32,int32) external view returns(uint256);
    struct Member {int32 x;int32 y;uint64 clanId;uint256 flagId;}
    function getTileClan(int32,int32) external view returns(uint64);
    function getClanMemberTiles(uint64) external view returns(Member[] memory);
}
interface ICTWar {
    struct State {uint256 offensive;uint256 defensive;uint256[4] resources;uint256 silos;uint256 feePool;uint256 experience;uint256 lastAttackExperience;uint256 protectedUntil;uint256 mountedOffensive;uint256 mountedDefensive;}
    function finalClanSnapshot(uint64) external view returns(address,uint32);
    function getState(uint64) external view returns(State memory);
    function memberPower(uint64,int32,int32) external view returns(uint256,uint256);
}
interface ICTLand {function worldEndsAt() external view returns(uint256);}

/// Fixed payout module. Membership, ownership, Reputation and funding freeze at closure.
/// Views read ClanWar; claims run only by delegatecall under its existing reentrancy guard.
contract ClanTreasurySettlement  is PublicRPCWriter {
    // Exact ClanWar storage prefix through guard. Compiler layouts are checked together.
    struct Contribution {bytes32 identity;uint256 experience;}
    struct Vote {bytes32 identity;uint8 stance;}
    mapping(uint64=>ICTWar.State) private states;
    mapping(uint64=>mapping(uint64=>Contribution)) private contributions;
    mapping(uint64=>mapping(uint64=>mapping(uint64=>Vote))) private votes;
    mapping(address=>uint256) private leaderClaims;
    mapping(address=>uint256) private lootClaims;
    uint256 private totalFeePools;
    uint256 private totalLeaderClaims;
    uint256 private totalLootClaims;
    uint256 private guard;
    error InvalidClaimRecipient();
    error NoClanClaim();
    error WorldStillOpen();
    error ClanClaimTransferFailed();
    error ClanClaimContextRequired();
    event Claimed(address indexed member,address indexed recipient,uint256 leaderFee,uint256 loot);
    event NativePayoutAccrued(address indexed account,uint256 amount);
    event FinalClanPoolAllocated(uint64 indexed clanId,uint256 amount);
    function claim(address payable recipient,bool leaderFee,bool loot) rpcIndexed external {
        if(address(this)!=address(war)||guard!=2)revert ClanClaimContextRequired();
        if(block.timestamp<worldEndsAt)revert WorldStillOpen();
        if(recipient==address(0)||recipient==address(this))revert InvalidClaimRecipient();
        uint256 finalReward=loot?_takeFinalReward(msg.sender):0;
        uint256 l=leaderFee?leaderClaims[msg.sender]:0;uint256 w=loot?lootClaims[msg.sender]:0;
        if(l+w+finalReward==0)revert NoClanClaim();
        if(leaderFee){leaderClaims[msg.sender]=0;totalLeaderClaims-=l;}
        if(loot){lootClaims[msg.sender]=0;totalLootClaims-=w+finalReward;}
        WalletClaimStatus.mark(msg.sender,1);
        (bool ok,)=recipient.call{value:l+w+finalReward}("");if(!ok)revert ClanClaimTransferFailed();
        emit Claimed(msg.sender,recipient,l,w+finalReward);
    }
    function _takeFinalReward(address member) private returns(uint256 amount) {
        if(block.timestamp<worldEndsAt)return 0;
        uint64 id=_memberClan(member);if(id==0)return 0;
        ClanFinalPool.Snapshot storage snapshot=ClanFinalPool.data().clans[id];
        if(snapshot.allocation==address(0)){
            if(states[id].feePool==0)return 0;
            (,uint256 pool,address[] memory owners,uint256[] memory amounts)=_allocation(member,true);
            uint256 count;uint256 largest;for(uint256 i;i<amounts.length;i++)if(amounts[i]>0){count++;if(amounts[i]>largest)largest=amounts[i];}
            if(count==0)return 0;
            // Few recipients are cheaper in the existing credit slots than in a new data contract.
            if(count<=4){
                states[id].feePool=0;totalFeePools-=pool;totalLootClaims+=pool;
                for(uint256 i;i<owners.length;i++)if(amounts[i]>0){lootClaims[owners[i]]+=amounts[i];emit NativePayoutAccrued(owners[i],amounts[i]);}
                emit FinalClanPoolAllocated(id,pool);return 0;
            }
            uint256 width=1;while(largest>255){largest>>=8;width++;}
            uint256 length=2+count*(20+width);
            // Extra padding makes the final packed mstore safe, even for a one-byte amount.
            bytes memory records=new bytes(length+32);records[1]=bytes1(uint8(width));uint256 at=2;
            uint256 shift=(32-width)*8;
            for(uint256 i;i<owners.length;i++)if(amounts[i]>0){
                address owner=owners[i];uint256 share=amounts[i];
                assembly("memory-safe"){mstore(add(add(records,32),at),shl(96,owner)) mstore(add(add(records,52),at),shl(shift,share))}
                at+=20+width;
            }
            assembly("memory-safe"){mstore(records,length)}
            snapshot.allocation=address(new FinalClanAllocation(records));
            // Reserve all frozen entitlements once, without writing one credit slot per owner.
            states[id].feePool=0;totalFeePools-=pool;totalLootClaims+=pool;
            emit FinalClanPoolAllocated(id,pool);
        }
        bytes memory data=_records(snapshot.allocation);
        uint256 width=uint8(data[0]);uint256 stride=20+width;uint256 shift=(32-width)*8;
        uint256 claimed=snapshot.claimed;uint256 found;
        // _records validates the bounded layout once. Walk its packed records directly.
        assembly("memory-safe") {
            let at:=add(data,33)
            let end:=add(add(data,32),mload(data))
            for {let mask:=1} lt(at,end) {at:=add(at,stride) mask:=shl(1,mask)} {
                if eq(shr(96,mload(at)),member) {
                    if iszero(and(claimed,mask)) {amount:=shr(shift,mload(add(at,20))) found:=mask}
                    break
                }
            }
        }
        if(found!=0){
            snapshot.claimed=uint32(claimed|found);
            emit NativePayoutAccrued(member,amount);
        }
    }
    function _records(address pointer) private view returns(bytes memory data){
        uint256 size=pointer.code.length;require(size>2&&size<=1562,"Invalid final allocation");
        data=new bytes(size-1+32);assembly("memory-safe"){extcodecopy(pointer,add(data,32),1,sub(size,1)) mstore(data,sub(size,1))}
        uint256 width=uint8(data[0]);require(width>0&&width<=32&&(data.length-1)%(20+width)==0&&_count(data)<=30,"Invalid final records");
    }
    function _count(bytes memory data) private pure returns(uint256){return (data.length-1)/(20+uint8(data[0]));}
    function _record(bytes memory data,uint256 index) private pure returns(address owner,uint256 amount){
        uint256 width=uint8(data[0]);uint256 at=1+index*(20+width);uint256 shift=(32-width)*8;
        assembly("memory-safe"){owner:=shr(96,mload(add(add(data,32),at))) amount:=shr(shift,mload(add(add(data,52),at)))}
    }
    function _memberClan(address member) private view returns(uint64){
        if(member==address(0))return 0;
        try map.getOccupiedTileByAddress(member) returns(int32[2] memory p){
            if(map.getTileOccupant(p[0],p[1])==member)return clans.getTileClan(p[0],p[1]);
        }catch{}return 0;
    }
    ICTMap public immutable map;
    ICTClan public immutable clans;
    ICTWar public immutable war;
    uint256 public immutable worldEndsAt;
    constructor(address warAddress,address mapAddress,address landAddress,address clanAddress) {
        war=ICTWar(warAddress);map=ICTMap(mapAddress);clans=ICTClan(clanAddress);
        worldEndsAt=ICTLand(landAddress).worldEndsAt();
    }
    function allocation(address member) public view returns(uint64 id,uint256 pool,address[] memory owners,uint256[] memory amounts) {return _allocation(member,false);}
    function _allocation(address member,bool delegated) private view returns(uint64 id,uint256 pool,address[] memory owners,uint256[] memory amounts) {
        owners=new address[](0);amounts=new uint256[](0);
        // Before closure this is a live estimate. All inputs freeze at world end;
        // only the guarded claim path is allowed to reserve and pay that final share.
        if(member==address(0))return(id,pool,owners,amounts);
        id=_memberClan(member);
        if(id==0)return(id,pool,owners,amounts);
        (address pointer,uint32 claimed)=delegated?(ClanFinalPool.data().clans[id].allocation,ClanFinalPool.data().clans[id].claimed):war.finalClanSnapshot(id);
        if(pointer!=address(0)){
            bytes memory records=_records(pointer);uint256 count=_count(records);
            owners=new address[](count);amounts=new uint256[](count);
            for(uint256 i;i<count;i++){(owners[i],amounts[i])=_record(records,i);if((claimed&(uint32(1)<<uint32(i)))!=0)amounts[i]=0;pool+=amounts[i];}
            return(id,pool,owners,amounts);
        }
        pool=delegated?states[id].feePool:war.getState(id).feePool;
        if(pool==0)return(id,pool,owners,amounts);
        ICTClan.Member[] memory members=clans.getClanMemberTiles(id);
        require(members.length>0&&members.length<=30,"Invalid final members");
        owners=new address[](members.length);amounts=new uint256[](members.length);
        uint256 total;
        for(uint256 i;i<members.length;i++) {
            owners[i]=map.getTileOccupant(members[i].x,members[i].y);
            require(owners[i]!=address(0),"Missing final owner");
            if(delegated){
                // The guarded claim executes in ClanWar storage. Reuse the owner
                // already read above and load only Reputation, not Influence.
                int32 x=members[i].x;int32 y=members[i].y;
                ClanPower.Member storage power=ClanPower.data().members[id][uint64(uint32(x))<<32|uint64(uint32(y))];
                // No positive Reputation means no weight regardless of identity.
                // Avoid two external epoch reads for zero-weight members.
                if(power.reputation>0){
                    bytes32 identity=keccak256(abi.encode(clans.membershipEpoch(x,y),owners[i],map.ownershipEpoch(x,y)));
                    if(power.identity==identity)amounts[i]=power.reputation;
                }
            }else (,amounts[i])=war.memberPower(id,members[i].x,members[i].y);
            total+=amounts[i];
        }
        bool equal=total==0;if(equal)total=members.length;
        uint256 cumulative;uint256 allocated;
        for(uint256 i;i<members.length;i++) {
            cumulative+=equal?1:amounts[i];
            // Cumulative apportionment distributes every wei, independent of claim order.
            // Full precision multiplication also handles very large Reputation totals.
            uint256 next=_mulDiv(pool,cumulative,total);
            amounts[i]=next-allocated;allocated=next;
        }
    }
    function pending(address member) external view returns(uint256 amount) {
        (,,address[] memory owners,uint256[] memory amounts)=allocation(member);
        for(uint256 i;i<owners.length;i++)if(owners[i]==member)amount+=amounts[i];
    }
    // Exact floor(x*y/d) with a 512-bit intermediate. The final result is <= the funded pool.
    function _mulDiv(uint256 x,uint256 y,uint256 d) private pure returns(uint256 result){
        unchecked {
            uint256 low;uint256 high;
            assembly("memory-safe"){let mm:=mulmod(x,y,not(0)) low:=mul(x,y) high:=sub(sub(mm,low),lt(mm,low))}
            if(high==0)return low/d;
            require(d>high,"Reward overflow");
            uint256 remainder;
            assembly("memory-safe"){remainder:=mulmod(x,y,d) high:=sub(high,gt(remainder,low)) low:=sub(low,remainder)}
            uint256 twos=d&(~d+1);
            assembly("memory-safe"){d:=div(d,twos) low:=div(low,twos) twos:=add(div(sub(0,twos),twos),1)}
            low|=high*twos;
            uint256 inverse=(3*d)^2;
            inverse*=2-d*inverse;inverse*=2-d*inverse;inverse*=2-d*inverse;
            inverse*=2-d*inverse;inverse*=2-d*inverse;inverse*=2-d*inverse;
            return low*inverse;
        }
    }
}
