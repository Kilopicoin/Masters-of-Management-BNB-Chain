// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Display-only successful withdrawal history, separate from payout accounting.
/// Bit 1: account rewards; bit 2: treasury remainder. A reverted transfer rolls
/// this marker back too. Namespaced storage preserves all existing layouts.
library WalletClaimStatus {
    bytes32 private constant SLOT=keccak256("mom.wallet.claim-status.v1");
    struct Data {mapping(address=>uint256) flags;}
    function data() private pure returns(Data storage d){bytes32 slot=SLOT;assembly("memory-safe"){d.slot:=slot}}
    function mark(address account,uint256 flag) internal {data().flags[account]|=flag;}
    function status(address account) internal view returns(uint256){return data().flags[account];}
}
