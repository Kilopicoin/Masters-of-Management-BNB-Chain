// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
/// Lossless length-prefixed uint256 encoding. Zero uses one byte; no game value is narrowed.
library ScoutSnapshot {
    function write(bytes memory data,uint256 offset,uint256 value) internal pure returns(uint256){
        uint256 size;uint256 v=value;while(v!=0){size++;v>>=8;}data[offset++]=bytes1(uint8(size));
        for(uint256 i=size;i>0;i--)data[offset++]=bytes1(uint8(value>>((i-1)*8)));return offset;
    }
    function read(bytes memory data,uint256 offset) internal pure returns(uint256 value,uint256 next){
        require(offset<data.length,"Invalid scout snapshot");uint256 size=uint8(data[offset++]);require(size<=32&&offset+size<=data.length,"Invalid scout snapshot");
        for(uint256 i;i<size;i++)value=(value<<8)|uint8(data[offset++]);return(value,offset);
    }
}
