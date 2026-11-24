// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// A max heap of incoming attack order deadlines. Reads are O(1), updates O(log n).
/// Expired journeys do not block redemption even before someone records their return.
library RelicThreats {
    bytes32 private constant SLOT=keccak256("ravengard.logistics.relic-threats.v1");
    struct Heap {uint256[] ids;mapping(uint256=>uint256) position;mapping(uint256=>uint256) expiry;}
    struct State {mapping(uint64=>Heap) realms;}
    function state() private pure returns(State storage s){bytes32 slot=SLOT;assembly("memory-safe"){s.slot:=slot}}
    function until(uint64 key) internal view returns(uint256){Heap storage h=state().realms[key];return h.ids.length==0?0:h.expiry[h.ids[0]];}
    function swap(Heap storage h,uint256 a,uint256 b) private{
        uint256 x=h.ids[a];uint256 y=h.ids[b];h.ids[a]=y;h.ids[b]=x;h.position[x]=b+1;h.position[y]=a+1;
    }
    function balance(Heap storage h,uint256 pos) private{
        while(pos>0){uint256 parent=(pos-1)/2;if(h.expiry[h.ids[parent]]>=h.expiry[h.ids[pos]])break;swap(h,parent,pos);pos=parent;}
        for(;;){uint256 left=pos*2+1;if(left>=h.ids.length)break;uint256 right=left+1;
            uint256 best=right<h.ids.length&&h.expiry[h.ids[right]]>h.expiry[h.ids[left]]?right:left;
            if(h.expiry[h.ids[pos]]>=h.expiry[h.ids[best]])break;swap(h,pos,best);pos=best;
        }
    }
    function track(uint64 key,uint256 id,uint256 expiry) internal{
        Heap storage h=state().realms[key];uint256 p=h.position[id];
        if(expiry==0){
            if(p==0)return;uint256 pos=p-1;uint256 last=h.ids.length-1;
            if(pos!=last)swap(h,pos,last);h.ids.pop();delete h.position[id];delete h.expiry[id];
            if(pos<h.ids.length)balance(h,pos);
        }else{
            h.expiry[id]=expiry;
            if(p==0){h.ids.push(id);h.position[id]=h.ids.length;p=h.ids.length;}
            balance(h,p-1);
        }
    }
}

