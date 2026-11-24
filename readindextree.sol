// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Order-statistic AVL tree. Rank and page lookup are logarithmic in world size.
/// Optional subtree rectangles also support bounded, resumable spatial queries.
library ReadIndexTree {
    struct Box { int32 minX; int32 minY; int32 maxX; int32 maxY; }
    struct Node { uint256 left; uint256 right; uint256 score; uint32 count; uint8 height; Box own; Box bounds; }
    struct Tree { uint256 root; mapping(uint256=>Node) nodes; }
    function higher(Tree storage t,uint256 a,uint256 b) internal view returns(bool) {
        return t.nodes[a].score>t.nodes[b].score || (t.nodes[a].score==t.nodes[b].score && a<b);
    }
    function refresh(Tree storage t,uint256 id,bool spatial) private {
        Node storage n=t.nodes[id]; Node storage l=t.nodes[n.left]; Node storage r=t.nodes[n.right];
        n.count=1+l.count+r.count; n.height=1+(l.height>r.height?l.height:r.height);
        if(spatial){Box memory b=n.own;
            if(n.left!=0)b=merge(b,l.bounds); if(n.right!=0)b=merge(b,r.bounds); n.bounds=b;}
    }
    function merge(Box memory a,Box memory b) private pure returns(Box memory) {
        return Box(a.minX<b.minX?a.minX:b.minX,a.minY<b.minY?a.minY:b.minY,a.maxX>b.maxX?a.maxX:b.maxX,a.maxY>b.maxY?a.maxY:b.maxY);
    }
    function rotateLeft(Tree storage t,uint256 a,bool spatial) private returns(uint256 b) {
        b=t.nodes[a].right;t.nodes[a].right=t.nodes[b].left;t.nodes[b].left=a;refresh(t,a,spatial);refresh(t,b,spatial);
    }
    function rotateRight(Tree storage t,uint256 a,bool spatial) private returns(uint256 b) {
        b=t.nodes[a].left;t.nodes[a].left=t.nodes[b].right;t.nodes[b].right=a;refresh(t,a,spatial);refresh(t,b,spatial);
    }
    function balance(Tree storage t,uint256 id,bool spatial) private returns(uint256) {
        if(id==0)return 0;refresh(t,id,spatial);Node storage n=t.nodes[id];
        if(uint256(t.nodes[n.left].height)>uint256(t.nodes[n.right].height)+1){
            Node storage l=t.nodes[n.left];if(t.nodes[l.right].height>t.nodes[l.left].height)n.left=rotateLeft(t,n.left,spatial);
            return rotateRight(t,id,spatial);
        }
        if(uint256(t.nodes[n.right].height)>uint256(t.nodes[n.left].height)+1){
            Node storage r=t.nodes[n.right];if(t.nodes[r.left].height>t.nodes[r.right].height)n.right=rotateRight(t,n.right,spatial);
            return rotateLeft(t,id,spatial);
        }
        return id;
    }
    function insert(Tree storage t,uint256 root,uint256 id,bool spatial) private returns(uint256) {
        if(root==0)return id;
        if(higher(t,id,root))t.nodes[root].left=insert(t,t.nodes[root].left,id,spatial);
        else t.nodes[root].right=insert(t,t.nodes[root].right,id,spatial);
        return balance(t,root,spatial);
    }
    function removeFirst(Tree storage t,uint256 root,bool spatial) private returns(uint256 next,uint256 first) {
        if(t.nodes[root].left==0)return(t.nodes[root].right,root);
        (t.nodes[root].left,first)=removeFirst(t,t.nodes[root].left,spatial);return(balance(t,root,spatial),first);
    }
    function erase(Tree storage t,uint256 root,uint256 id,bool spatial) private returns(uint256) {
        if(root==id){
            uint256 l=t.nodes[root].left;uint256 r=t.nodes[root].right;
            if(l==0)return r;if(r==0)return l;
            (uint256 rest,uint256 replacement)=removeFirst(t,r,spatial);
            t.nodes[replacement].left=l;t.nodes[replacement].right=rest;return balance(t,replacement,spatial);
        }
        require(root!=0,"Missing index entry");
        if(higher(t,id,root))t.nodes[root].left=erase(t,t.nodes[root].left,id,spatial);
        else t.nodes[root].right=erase(t,t.nodes[root].right,id,spatial);
        return balance(t,root,spatial);
    }
    function set(Tree storage t,uint256 id,uint256 score,Box memory box,bool present) internal {_set(t,id,score,box,present,true);}
    function setRank(Tree storage t,uint256 id,uint256 score,bool present) public {
        require(id!=0,"Zero index key");Node storage n=t.nodes[id];
        if(n.height!=0){
            if(present){if(n.score==score)return;
                // A rising score can only cross its predecessor; a falling one
                // can only cross its successor. Do not read the other subtree.
                bool rising=score>n.score;uint256 current=t.root;uint256 neighbour;
                while(current!=id){if(higher(t,id,current)){if(!rising)neighbour=current;current=t.nodes[current].left;}else{if(rising)neighbour=current;current=t.nodes[current].right;}}
                current=rising?n.left:n.right;
                if(current!=0){neighbour=current;while(true){current=rising?t.nodes[neighbour].right:t.nodes[neighbour].left;if(current==0)break;neighbour=current;}}
                if(neighbour==0||(rising?(t.nodes[neighbour].score>score||(t.nodes[neighbour].score==score&&neighbour<id)):(score>t.nodes[neighbour].score||(score==t.nodes[neighbour].score&&id<neighbour)))){n.score=score;return;}
            }
            t.root=erase(t,t.root,id,false);if(!present){delete t.nodes[id];return;}n.left=0;n.right=0;
        }
        if(present){n.score=score;n.count=1;n.height=1;t.root=insert(t,t.root,id,false);}
    }
    function _set(Tree storage t,uint256 id,uint256 score,Box memory box,bool present,bool spatial) private {
        require(id!=0,"Zero index key");Node storage n=t.nodes[id];
        if(n.height!=0){
            if(present&&(!spatial||(n.own.minX==box.minX&&n.own.minY==box.minY&&n.own.maxX==box.maxX&&n.own.maxY==box.maxY))){
                if(n.score==score)return;
                // Small score changes usually do not cross either neighbour.
                // Keep the existing node and avoid erase/reinsert storage writes.
                uint256 current=t.root;uint256 before;uint256 afterNode;
                while(current!=id){if(higher(t,id,current)){afterNode=current;current=t.nodes[current].left;}else{before=current;current=t.nodes[current].right;}}
                if(n.left!=0){before=n.left;while(t.nodes[before].right!=0)before=t.nodes[before].right;}
                if(n.right!=0){afterNode=n.right;while(t.nodes[afterNode].left!=0)afterNode=t.nodes[afterNode].left;}
                bool above=before==0||t.nodes[before].score>score||(t.nodes[before].score==score&&before<id);
                bool below=afterNode==0||score>t.nodes[afterNode].score||(score==t.nodes[afterNode].score&&id<afterNode);
                if(above&&below){n.score=score;return;}
            }
            t.root=erase(t,t.root,id,spatial);if(!present){delete t.nodes[id];return;}n.left=0;n.right=0;
        }
        if(present){n.score=score;if(spatial){n.own=box;n.bounds=box;}n.count=1;n.height=1;t.root=insert(t,t.root,id,spatial);}
    }
    function count(Tree storage t) internal view returns(uint256){return t.nodes[t.root].count;}
    function at(Tree storage t,uint256 offset) internal view returns(uint256 id){
        id=t.root;while(id!=0){uint256 left=t.nodes[t.nodes[id].left].count;if(offset==left)return id;if(offset<left)id=t.nodes[id].left;else{offset-=left+1;id=t.nodes[id].right;}}
    }
    function rank(Tree storage t,uint256 target) internal view returns(uint256 position){
        if(t.nodes[target].height==0)return 0;uint256 id=t.root;position=1;
        while(id!=target){if(higher(t,target,id))id=t.nodes[id].left;else{position+=1+t.nodes[t.nodes[id].left].count;id=t.nodes[id].right;}}
        return position+t.nodes[t.nodes[id].left].count;
    }
    function overlaps(Box memory a,Box memory b) internal pure returns(bool){return a.minX<=b.maxX&&a.maxX>=b.minX&&a.minY<=b.maxY&&a.maxY>=b.minY;}
}
