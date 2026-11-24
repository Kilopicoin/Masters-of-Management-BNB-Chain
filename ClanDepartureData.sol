// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
library ClanDepartureData {
    error InvalidDepartureData();
    bytes32 private constant SLOT=keccak256("ravengard.clan.departure.data.v1");
    struct Data {mapping(uint256=>address) allocations;}
    function data() internal pure returns(Data storage d){bytes32 slot=SLOT;assembly("memory-safe"){d.slot:=slot}}
    // Legacy records are 96 bytes (28-byte coordinates/owner, identity, weight).
    // The first four bytes of each legacy record are zero. Version 1 can thus
    // use a nonzero leading marker without confusing any existing departure.
    function pack(bytes memory records) internal pure returns(bytes memory packed){
        uint256 count=(records.length-1)/96;uint256 largest;
        assembly("memory-safe"){
            for{let i:=0}lt(i,count){i:=add(i,1)}{largest:=or(largest,mload(add(add(records,97),mul(i,96))))}
        }
        uint256 width;for(uint256 n=largest;n!=0;n>>=8)width++;
        uint256 size=4+count*(60+width);packed=new bytes(size+32);
        assembly("memory-safe"){
            let start:=add(packed,32)mstore8(add(start,1),1)mstore8(add(start,2),count)mstore8(add(start,3),width)
            for{let i:=0}lt(i,count){i:=add(i,1)}{
                let src:=add(add(records,33),mul(i,96))let dst:=add(add(start,4),mul(i,add(60,width)))
                mstore(dst,shl(32,mload(src)))mstore(add(dst,28),mload(add(src,32)))mstore(add(dst,60),shl(mul(sub(32,width),8),mload(add(src,64))))
            }
            mstore(packed,size)
        }
    }
    function read(address pointer) internal view returns(bytes memory records){
        uint256 length=pointer.code.length-1;bytes memory packed=new bytes(length);
        assembly("memory-safe"){extcodecopy(pointer,add(packed,32),1,length)}
        uint256 version;uint256 count;uint256 width;
        assembly("memory-safe"){let header:=mload(add(packed,32))version:=byte(0,header)count:=byte(1,header)width:=byte(2,header)}
        if(version==0)return packed;
        if(version!=1||count>30||width==0||width>32||length!=3+count*(60+width))revert InvalidDepartureData();
        records=new bytes(count*96);
        assembly("memory-safe"){
            for{let i:=0}lt(i,count){i:=add(i,1)}{
                let src:=add(add(packed,35),mul(i,add(60,width)))let dst:=add(add(records,32),mul(i,96))
                mstore(dst,shr(32,mload(src)))mstore(add(dst,32),mload(add(src,28)))mstore(add(dst,64),shr(mul(sub(32,width),8),mload(add(src,60))))
            }
        }
    }
}
