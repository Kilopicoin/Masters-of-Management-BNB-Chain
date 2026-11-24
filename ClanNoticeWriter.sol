// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "./PublicRPCEvents.sol";
interface INoticeMap {function getTileOccupant(int32,int32) external view returns(address);}

/// Fixed, delegate-only notification writer. Reads the member-array slot supplied
/// by Clan's private caller; writes only the namespaced RPC recipient index.
contract ClanNoticeWriter is PublicRPCWriter {
    address private immutable clan;
    INoticeMap private immutable map;
    event ClanNotice(address indexed recipient,uint64 indexed clanId,uint8 kind,int32 x,int32 y);
    constructor(address source){clan=msg.sender;map=INoticeMap(source);}
    function _toLower(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        for (uint i = 0; i < b.length; i++) {
            uint8 c = uint8(b[i]);
            if (c >= 65 && c <= 90) {
                // 'A'..'Z'
                b[i] = bytes1(c + 32);
            }
        }
        return string(b);
    }

    function _trim(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length == 0) return s;

        uint start = 0;
        while (start < b.length && b[start] == 0x20) {
            start++;
        } // skip leading spaces

        if (start == b.length) return ""; // all spaces

        uint end = b.length - 1;
        while (end > start && b[end] == 0x20) {
            end--;
        } // skip trailing spaces

        bytes memory out = new bytes(end - start + 1);
        for (uint i = 0; i < out.length; i++) {
            out[i] = b[start + i];
        }
        return string(out);
    }

    function nameKey(string memory name) external pure returns(bytes32 key,bool nonEmpty) {
        string memory trimmed=_trim(name);
        return (keccak256(bytes(_toLower(trimmed))),bytes(trimmed).length!=0);
    }
    function notify(uint64 id,uint8 kind,int32 x,int32 y,uint256 memberSlot) external payable {
        require(address(this)==clan,"Clan delegate required");
        uint64[] storage members;
        assembly("memory-safe"){members.slot:=memberSlot}
        for(uint256 i;i<members.length;i++){
            uint64 key=members[i];address recipient=map.getTileOccupant(int32(uint32(key>>32)),int32(uint32(key)));
            _recordRPCRecipient(recipient);
            emit ClanNotice(recipient,id,kind,x,y);
        }
    }
}
