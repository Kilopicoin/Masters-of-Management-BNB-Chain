// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// New reports use immutable code storage; existing reports retain their slots.
library BattleArchive {
    bytes32 private constant SLOT=keccak256("ravengard.military.report.archive.v1");
    struct Data {mapping(uint256=>address) pointers;}
    function data() internal pure returns(Data storage d){bytes32 slot=SLOT;assembly("memory-safe"){d.slot:=slot}}
    function write(uint256 id,bytes memory packed) internal {
        data().pointers[id]=address(new BattleReportData(abi.encodePacked(bytes1(0),packed)));
    }
    function useCode(bytes memory packed) internal pure returns(bool){
        // Sparse short reports have zero storage words, which are cheap to keep.
        // Select code only when its creation/deposit estimate beats storage with
        // a margin for construction and decoding overhead. No value is narrowed.
        uint256 storageCost=22100;uint256 size=packed.length;
        for(uint256 offset;offset<size;offset+=32){
            uint256 word;assembly("memory-safe"){word:=mload(add(add(packed,32),offset))}
            if(size-offset<32)word=(word>>((32-(size-offset))*8));
            storageCost+=word==0?2200:22100;
        }
        return storageCost>60000+200*(size+1);
    }
    function read(address pointer) internal view returns(bytes memory packed){
        uint256 length=pointer.code.length-1;packed=new bytes(length);
        assembly("memory-safe"){extcodecopy(pointer,add(packed,32),1,length)}
    }
}
/// STOP-prefixed data; no executable methods or destruction path.
contract BattleReportData {
    constructor(bytes memory data){assembly("memory-safe"){return(add(data,32),mload(data))}}
}
