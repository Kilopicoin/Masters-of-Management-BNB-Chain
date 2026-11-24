// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
pragma solidity 0.8.37;
import "ClanWarExtensionStorage.sol";
import "ClanHallLevels.sol";
/// Fixed delegate-only council writer; no admin, upgrade setter or separate player state.
contract ClanCouncil is PublicRPCWriter, ClanWarExtensionStorage  {
    address private immutable self=address(this);
    error CouncilDelegateRequired();
    error CouncilLeaderRequired();
    event ClanNotice(address indexed recipient,uint64 indexed clanId,uint8 kind,int32 x,int32 y);
    modifier onlyDelegate(){if(address(this)==self)revert CouncilDelegateRequired();_;}
    constructor(address m,address l,address c) ClanWarExtensionStorage(m,l,c){}
    function _councilMember(uint64 id) private view returns(int32 x,int32 y){
        int32[2] memory tile=map.getOccupiedTileByAddress(msg.sender);x=tile[0];y=tile[1];_member(id,x,y);
    }
    function proposeCouncil(uint64 id,uint8 kind,int32 x,int32 y) rpcIndexed external onlyDelegate nonReentrant { IJLand(address(land)).requireWorldActive(); 
        (int32 mx,int32 my)=_councilMember(id);Council storage p=councils[id];
        if(!(!p.active||block.timestamp>=p.createdAt+7 days))revert CouncilProposalOpen();
        if(!(kind>=1&&kind<=3))revert InvalidCouncilDecision();
        if(kind==1)if(!(IClanHallLevels(address(this)).leadershipHallEligible(id,x,y)))revert InvalidCouncilNominee();
        if(kind==3){
            ICWClan.Info memory info=clans.getClanInfo(id);
            if(!(clans.getTileClan(x,y)==id&&(info.leaderX!=x||info.leaderY!=y)))revert InvalidRemovalTarget();
        }
        // Only an executed or expired proposal releases the proposal slot.
        // Expired decisions lose any unresolved bond.
        CouncilBonds.resolve(id,false);
        uint256 bond=councilBondRequired(id);
        CouncilBonds.lock(id,_key(mx,my),_identity(mx,my),bond);
        councilTargetIdentity[id]=kind==2?bytes32(0):_identity(x,y);
        p.kind=kind;p.x=x;p.y=y;p.createdAt=block.timestamp;p.nonce++;p.active=true;
        delete electorate[id];ICWClan.Member[] memory members=clans.getClanMemberTiles(id);
        for(uint256 i;i<members.length;i++){
            ICWClan.Member memory m=members[i];bytes32 identity=_identity(m.x,m.y);address recipient=map.getTileOccupant(m.x,m.y);electorate[id].push(Recipient(m.x,m.y,recipient,identity));
            {_recordRPCRecipient(recipient);emit ClanNotice(recipient,id,0,0,0);}
            uint256 available=contribution(id,m.x,m.y);ClanPower.data().councilVotes[id][p.nonce][identity].allowance=available;ClanPower.data().councilTotal[id][p.nonce]+=available;
        }
        require(ClanPower.data().councilTotal[id][p.nonce]>0,"Clan needs Influence");
        IActivityLand(address(land)).recordActivity(mx,my,msg.sender);emit CouncilProposed(id,p.nonce,kind,x,y);
    }
    function voteCouncil(uint64 id,bool approve,uint256 amount,uint256 expectedNonce) rpcIndexed external onlyDelegate nonReentrant {IJLand(address(land)).requireWorldActive();
        (int32 x,int32 y)=_councilMember(id);Council storage p=councils[id];
        require(p.nonce==expectedNonce&&p.active&&CouncilBonds.data().bonds[id].amount>0&&_targetCurrent(id,p)&&block.timestamp<p.createdAt+7 days,"Council proposal changed");
        bytes32 identity=_identity(x,y);ClanPower.CouncilVote storage v=ClanPower.data().councilVotes[id][p.nonce][identity];
        require(amount>0&&v.yes+v.no+amount<=v.allowance,"Exceeds original voting allowance");
        ClanPower.spend(id,_key(x,y),identity,amount);if(approve)v.yes+=amount;else v.no+=amount;
        (,,uint256 no,uint256 total,)=councilStatus(id);if(no>total/2){CouncilBonds.resolve(id,false);} // Rejection ends voting, but holds the slot until expiry.
        IActivityLand(address(land)).recordActivity(x,y,msg.sender);emit InfluenceSpent(id,msg.sender,amount);emit CouncilVoted(id,p.nonce,msg.sender,approve);
    }
    function _targetCurrent(uint64 id,Council memory p) private view returns(bool){
        if(p.kind==2)return true;
        return councilTargetIdentity[id]!=bytes32(0)&&clans.getTileClan(p.x,p.y)==id
            &&_identity(p.x,p.y)==councilTargetIdentity[id]
            &&(p.kind!=1||IClanHallLevels(address(this)).leadershipHallEligible(id,p.x,p.y));
    }
    function councilStatus(uint64 id) public view returns(Council memory proposal,uint256 yes,uint256 no,uint256 total,bool targetCurrent){
        proposal=councils[id];total=ClanPower.data().councilTotal[id][proposal.nonce];targetCurrent=_targetCurrent(id,proposal);
        if(block.timestamp>=proposal.createdAt+7 days)proposal.active=false;
        for(uint256 i;i<electorate[id].length;i++){Recipient storage r=electorate[id][i];if(!_eligible(id,r))continue;ClanPower.CouncilVote storage v=ClanPower.data().councilVotes[id][proposal.nonce][r.identity];yes+=v.yes;no+=v.no;}
    }
    function executeCouncil(uint64 id,uint256 expectedNonce) rpcIndexed external payable onlyDelegate { IJLand(address(land)).requireWorldActive(); 
        ICWClan.Info memory info=clans.getClanInfo(id);
        if(!info.exists||map.getTileOccupant(info.leaderX,info.leaderY)!=msg.sender)revert CouncilLeaderRequired();
        (Council memory p,uint256 yes,,uint256 total,bool targetCurrent)=councilStatus(id);
        require(p.nonce==expectedNonce,"Council proposal changed");
        if(p.kind==1&&!IClanHallLevels(address(this)).leadershipHallEligible(id,p.x,p.y))revert InvalidCouncilNominee();
        if(!(p.active&&targetCurrent&&CouncilBonds.data().bonds[id].amount>0&&block.timestamp<p.createdAt+7 days))revert CouncilOutsideReviewWindow();
        if(!(yes>total/2))revert CouncilMajorityRequired();
        if(!(msg.value==(p.kind==3?clans.REMOVE_MEMBER_COST():0)))revert IncorrectCouncilPayment();
        if(p.kind!=3){
            IJLogistics j=IJLogistics(IJLand(address(land)).logistics());
            if(!(j.clanOutgoing(id)==0))revert CouncilJourneysOutstanding();
        }
        councils[id].active=false;CouncilBonds.resolve(id,true);clans.applyCouncil{value:msg.value}(id,p.kind,p.x,p.y);emit CouncilExecuted(id,p.nonce,p.kind);
    }
    function councilAllowance(uint64 id,int32 x,int32 y) external view returns(uint256 remaining){ClanPower.CouncilVote storage v=ClanPower.data().councilVotes[id][councils[id].nonce][_identity(x,y)];return v.allowance-v.yes-v.no;}
    function councilBondRequired(uint64) public pure returns(uint256){return 5000;}
    function councilBond(uint64 id) external view returns(uint256){return CouncilBonds.data().bonds[id].amount;}
}
