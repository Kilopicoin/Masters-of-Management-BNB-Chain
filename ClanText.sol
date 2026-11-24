// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
library ClanText {
error InvalidText();
    function validate(bytes memory text) internal pure {
        for (uint256 i; i < text.length;) {
            uint8 c = uint8(text[i]);
            if (c < 0x80) {
                if (c < 0x20 || c == 0x7f) revert InvalidText();
                ++i;
                continue;
            }
            uint256 size;
            if (c >= 0xc2 && c <= 0xdf) size = 2;
            else if (c >= 0xe0 && c <= 0xef) size = 3;
            else if (c >= 0xf0 && c <= 0xf4) size = 4;
            else revert InvalidText();
            if (i + size > text.length) revert InvalidText();
            uint8 second = uint8(text[i+1]);
            if ((c == 0xe0 && second < 0xa0) || (c == 0xed && second >= 0xa0) ||
                (c == 0xf0 && second < 0x90) || (c == 0xf4 && second >= 0x90)) revert InvalidText();
            for (uint256 j = 1; j < size; ++j) {
                uint8 next = uint8(text[i+j]);
                if (next < 0x80 || next > 0xbf) revert InvalidText();
            }
            i += size;
        }
    }

    function normalize(string calldata raw) internal pure returns (string memory) {
        bytes calldata text = bytes(raw);
        uint256 first = text.length;
        uint256 last;
        for (uint256 i; i < text.length;) {
            uint8 lead = uint8(text[i]);
            uint256 size = lead < 128 ? 1 : lead < 224 ? 2 : lead < 240 ? 3 : 4;
            if (i + size > text.length) revert InvalidText();
            uint32 cp = size == 1 ? lead : uint32(lead & uint8(127 >> size));
            for (uint256 j = 1; j < size; ++j) cp = (cp << 6) | (uint8(text[i+j]) & 63);
            bool padding = cp == 32 || (cp >= 9 && cp <= 13) || cp == 0x85 || cp == 0xa0 ||
                cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200f) ||
                (cp >= 0x2028 && cp <= 0x202f) || cp == 0x205f ||
                (cp >= 0x2060 && cp <= 0x206f) || cp == 0x3000 || cp == 0xfeff;
            if (!padding) { if (first == text.length) first = i; last = i + size; }
            i += size;
        }
        return last == 0 ? "" : string(text[first:last]);
    }

}
interface IClanText {function validateClanName(string calldata name) external pure;function validateGameText(bytes calldata text) external pure; function normalizeRealmName(string calldata raw) external pure returns(string memory);}
