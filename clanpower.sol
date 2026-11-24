// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {RealmScoreRules} from "realmscorerules.sol";

/// New namespace deliberately starts empty; old paid-turn XP is never converted.
library ClanPower {
    bytes32 private constant SLOT=keccak256("ravengard.clan.influence.v1");
    struct Member {bytes32 identity;uint256 influence;uint256 reputation;uint256 resourceRemainder;}
    struct Ballot {bytes32 identity;uint256[3] spent;uint8 lastChoice;}
    struct CouncilVote {uint256 allowance;uint256 yes;uint256 no;}
    struct Data {
        mapping(uint64=>mapping(uint64=>Member)) members;
        mapping(uint64=>uint256) earned;
        mapping(uint64=>uint256) lastAttack;
        mapping(uint64=>mapping(uint64=>mapping(uint64=>Ballot))) diplomacy;
        mapping(uint256=>mapping(bytes32=>uint256)) recipientWeight;
        mapping(uint256=>bool) reputationJourney;
        mapping(uint64=>mapping(uint256=>uint256)) councilTotal;
        mapping(uint64=>mapping(uint256=>mapping(bytes32=>CouncilVote))) councilVotes;
    }
    function data() internal pure returns(Data storage d){bytes32 slot=SLOT;assembly("memory-safe"){d.slot:=slot}}
    function troopPoints(uint8 unit) internal pure returns(uint256){return (RealmScoreRules.trainingPoints(unit)+9)/10;}
    function armyPoints(uint256[20] memory units) internal pure returns(uint256 points){for(uint8 i;i<20;i++)if(units[i]>0)points+=units[i]*troopPoints(i+1);}
    function credit(uint64 clan,uint64 key,bytes32 identity,uint256 resources,uint256 fixedPoints) internal returns(uint256 points){
        Data storage d=data();Member storage m=d.members[clan][key];
        if(m.identity!=identity){m.identity=identity;m.influence=0;m.reputation=0;m.resourceRemainder=0;}
        uint256 raw=m.resourceRemainder+resources;points=raw/100+fixedPoints;m.resourceRemainder=raw%100;
        m.influence+=points;d.earned[clan]+=points;
    }
    function spend(uint64 clan,uint64 key,bytes32 identity,uint256 amount) internal {
        Member storage m=data().members[clan][key];require(amount>0&&m.identity==identity&&m.influence>=amount,"Not enough Influence");
        m.influence-=amount;m.reputation+=amount;
    }
}

/// Spent diplomacy Influence belongs to the clan, independently of membership.
/// Separate from personal ballots so departure/rejoining never reweights a stance.
library ClanDiplomacyWeights {
    bytes32 private constant SLOT=keccak256("ravengard.clan.diplomacy.weights.v1");
    struct Data {mapping(uint64=>mapping(uint64=>uint256[3])) weights;}
    function data() internal pure returns(Data storage d){bytes32 slot=SLOT;assembly("memory-safe"){d.slot:=slot}}
    function result(uint256[3] memory weights) internal pure returns(uint8) {
        if(weights[1]>weights[0]&&weights[1]>weights[2])return 1;
        if(weights[2]>weights[0]&&weights[2]>weights[1])return 2;
        return 0;
    }
    function record(uint64 clan,uint64 target,uint8 choice,uint256 amount) internal returns(uint8 previous,uint8 current) {
        uint256[3] storage weights=data().weights[clan][target];
        previous=result(weights);weights[choice]+=amount;current=result(weights);
    }
}

library ClanDonationReceipts {
    bytes32 private constant SLOT=keccak256("ravengard.clan.donation.identity.v1");
    struct Data {mapping(uint256=>bytes32) identity;mapping(uint256=>uint64) recipientClan;mapping(uint256=>bytes32) leaderIdentity;}
    function data() internal pure returns(Data storage d){bytes32 slot=SLOT;assembly("memory-safe"){d.slot:=slot}}
}
interface IClanInfluence {
    function recordDonation(uint64 clan,int32 x,int32 y,bytes32 identity,uint256 resources,uint256 fixedPoints) external;
}
interface IClanMembershipEpoch {function membershipEpoch(int32 x,int32 y) external view returns(uint256);}

/// Proposal escrow does not earn Reputation and is separate from spendable Influence.
library CouncilBonds {
    bytes32 private constant SLOT=keccak256("ravengard.clan.council.bonds.v1");
    struct Bond {uint64 key;bytes32 identity;uint256 amount;}
    struct Data {mapping(uint64=>Bond) bonds;}
    function data() internal pure returns(Data storage d){bytes32 slot=SLOT;assembly("memory-safe"){d.slot:=slot}}
    function lock(uint64 id,uint64 key,bytes32 identity,uint256 amount) internal {
        ClanPower.Member storage m=ClanPower.data().members[id][key];
        require(m.identity==identity&&m.influence>=amount,"Not enough Influence for proposal bond");
        m.influence-=amount;data().bonds[id]=Bond(key,identity,amount);
    }
    function resolve(uint64 id,bool approved) internal {
        Bond memory b=data().bonds[id];if(b.amount==0)return;
        delete data().bonds[id];
        ClanPower.Member storage m=ClanPower.data().members[id][b.key];
        if(approved&&m.identity==b.identity)m.influence+=b.amount;
    }
}
