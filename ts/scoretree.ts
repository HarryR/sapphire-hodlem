import { sha256 } from '@noble/hashes/sha256';
import { readFileSync } from "fs";
import { join } from "path";
import { binomialCoefficient, combinations } from "./utils";

const LEAF_SIZE_BYTES = 7;
const NODE_SIZE_BYTES = 32;


export type Card = '2c' | '2d' | '2h' | '2s' | '3c' | '3d' | '3h' | '3s' | '4c' | '4d' | '4h' | '4s' | '5c' | '5d' | '5h' | '5s' | '6c' | '6d' | '6h' | '6s' | '7c' | '7d' | '7h' | '7s' | '8c' | '8d' | '8h' | '8s' | '9c' | '9d' | '9h' | '9s' | 'Tc' | 'Td' | 'Th' | 'Ts' | 'Jc' | 'Jd' | 'Jh' | 'Js' | 'Qc' | 'Qd' | 'Qh' | 'Qs' | 'Kc' | 'Kd' | 'Kh' | 'Ks' | 'Ac' | 'Ad' | 'Ah' | 'As';

export const DECK:Card[] = ['2c', '2d', '2h', '2s', '3c', '3d', '3h', '3s', '4c', '4d', '4h', '4s', '5c', '5d', '5h', '5s', '6c', '6d', '6h', '6s', '7c', '7d', '7h', '7s', '8c', '8d', '8h', '8s', '9c', '9d', '9h', '9s', 'Tc', 'Td', 'Th', 'Ts', 'Jc', 'Jd', 'Jh', 'Js', 'Qc', 'Qd', 'Qh', 'Qs', 'Kc', 'Kd', 'Kh', 'Ks', 'Ac', 'Ad', 'Ah', 'As'];

export const DECKIDX : {[id:string]:number}= {'2c': 0, '2d': 1, '2h': 2, '2s': 3, '3c': 4, '3d': 5, '3h': 6, '3s': 7, '4c': 8, '4d': 9, '4h': 10, '4s': 11, '5c': 12, '5d': 13, '5h': 14, '5s': 15, '6c': 16, '6d': 17, '6h': 18, '6s': 19, '7c': 20, '7d': 21, '7h': 22, '7s': 23, '8c': 24, '8d': 25, '8h': 26, '8s': 27, '9c': 28, '9d': 29, '9h': 30, '9s': 31, 'Tc': 32, 'Td': 33, 'Th': 34, 'Ts': 35, 'Jc': 36, 'Jd': 37, 'Jh': 38, 'Js': 39, 'Qc': 40, 'Qd': 41, 'Qh': 42, 'Qs': 43, 'Kc': 44, 'Kd': 45, 'Kh': 46, 'Ks': 47, 'Ac': 48, 'Ad': 49, 'Ah': 50, 'As': 51};

const LOOKUP : {[id:string]:number} = {'2c': 69634, '2d': 73730, '2h': 81922, '2s': 98306, '3c': 135427, '3d': 139523, '3h': 147715, '3s': 164099, '4c': 266757, '4d': 270853, '4h': 279045, '4s': 295429, '5c': 529159, '5d': 533255, '5h': 541447, '5s': 557831, '6c': 1053707, '6d': 1057803, '6h': 1065995, '6s': 1082379, '7c': 2102541, '7d': 2106637, '7h': 2114829, '7s': 2131213, '8c': 4199953, '8d': 4204049, '8h': 4212241, '8s': 4228625, '9c': 8394515, '9d': 8398611, '9h': 8406803, '9s': 8423187, 'Tc': 16783383, 'Td': 16787479, 'Th': 16795671, 'Ts': 16812055, 'Jc': 33560861, 'Jd': 33564957, 'Jh': 33573149, 'Js': 33589533, 'Qc': 67115551, 'Qd': 67119647, 'Qh': 67127839, 'Qs': 67144223, 'Kc': 134224677, 'Kd': 134228773, 'Kh': 134236965, 'Ks': 134253349, 'Ac': 268442665, 'Ad': 268446761, 'Ah': 268454953, 'As': 268471337};


export type ScoreName = 'HIGH_CARD'
                      | 'ONE_PAIR'
                      | 'TWO_PAIRS'
                      | 'THREE_OF_A_KIND'
                      | 'STRAIGHT'
                      | 'FLUSH'
                      | 'FULL_HOUSE'
                      | 'FOUR_OF_A_KIND'
                      | 'STRAIGHT_FLUSH'
                      | 'ROYAL_FLUSH'
                      ;

export function score_name(score:number) : ScoreName {
    if (score > 6185) return 'HIGH_CARD';        // 1277 high card
    if (score > 3325) return 'ONE_PAIR';         // 2860 one pair
    if (score > 2467) return 'TWO_PAIRS';        // 858 two pair
    if (score > 1609) return 'THREE_OF_A_KIND';  // 858 three-kind
    if (score > 1599) return 'STRAIGHT';         // 10 straights
    if (score > 322)  return 'FLUSH';            // 1277 flushes
    if (score > 166)  return 'FULL_HOUSE';       // 156 full house
    if (score > 10)   return 'FOUR_OF_A_KIND';   // 156 four-kind
    if (score > 1)    return 'STRAIGHT_FLUSH';   // 9 straight-flushes
    return 'ROYAL_FLUSH';                        // 1 royal-flushes
};

// -------------------------------------------------------------------
// https://en.wikipedia.org/wiki/Combinatorial_number_system

export function hand_to_index(hand:Card[]) {
    if( hand.length != 5 ) {
        throw Error(`Requires 5 cards, but provided with: ${hand} (${hand.length})`);
    }
    let v:[number,number][] = [];
    let i = 0;
    for( const g of hand.map((m)=>DECKIDX[m]).sort((a,b) => a-b) )  {
        v.push([i,g]);
        i += 1;
    }
    return v.reverse().map((x) => { return binomialCoefficient(x[1], x[0]+1) }).reduce((a,b) => a+b, 0);
}

export function hand_sort(hand:Card[]) {
    return hand.map((_)=>DECKIDX[_]).sort((a,b) => a-b).map((_)=>DECK[_]);
}


export interface ScoreLeaf {
    idx: number;
    hand: Card[];
    score: number;
    kind: ScoreName;
    raw: Uint8Array;
    hash: Uint8Array;
}

function hash_node(lvl:number, idx:number, self_hash: Uint8Array, other_hash: Uint8Array) {
    let leaf = new Uint8Array(NODE_SIZE_BYTES * 2);
    leaf.set(self_hash, (idx&1) ? NODE_SIZE_BYTES : 0);
    leaf.set(other_hash, (idx&1) ? 0 : NODE_SIZE_BYTES);
    return Buffer.from(sha256(leaf));
}

function Leaf_load(leaf_data: Uint8Array, idx: number) : ScoreLeaf
{
    const leaf_count = leaf_data.length / LEAF_SIZE_BYTES;
    if( idx >= leaf_count ) {
        throw Error(`Index ${idx} exceeds leaf count ${leaf_count}`);
    }
    const offset = idx * LEAF_SIZE_BYTES;
    const leaf = leaf_data.slice(offset, offset+LEAF_SIZE_BYTES);
    // 8 bytes, 5 bytes of hand, 0 byte, 16 bit little-endian score
    const hand = [DECK[leaf[0]], DECK[leaf[1]], DECK[leaf[2]], DECK[leaf[3]], DECK[leaf[4]]];
    const score = leaf[5] + (leaf[6]<<8);
    return {
        idx: idx,
        hand: hand_sort(hand),
        score: score,
        kind: score_name(score),
        raw: leaf,
        hash: Buffer.from(sha256(leaf))
    }
}

export class ScoreTree {
    private levels_data: Uint8Array[];
    private leaf_data: Uint8Array;
    private root: Uint8Array;
    constructor(
        private base_path:string
    ) {
        this.levels_data = [];
        for( let i = 0; i < 22; i++ ) {
            const filename = `scores.${String(i).padStart(2, '0')}`;
            this.levels_data.push(this._load_file(filename));
        }
        this.leaf_data = this._load_file('scores.leaf');
        this.root = this._load_file('scores.root');
    }

    public _load_file(filename:string) {
        // TODO: on Node, use `readFileSync`
        //     in browser, load files remotely in 1mb blocks, aka demand paging
        return readFileSync(join(this.base_path, filename));
    }

    public _node(lvl:number, idx:number) {
        const offset = idx * NODE_SIZE_BYTES;
        const data = this.levels_data[lvl].slice(offset, offset + NODE_SIZE_BYTES);
        if( data.byteLength == 0 ) {
            return Buffer.from(new Uint8Array(Array(NODE_SIZE_BYTES).fill(lvl+1)));
        }
        return data;
    }

    public * lookup_hands(hand:Card[]) {
        for( const h of combinations<Card>(hand, 5) ) {
            yield this.lookup_hand(h);
        }
    }

    public lookup_hand(hand:Card[]) {
        if( hand.length != 5 ) {
            throw Error('Requires 5 cards to lookup')
        }
        const idx = hand_to_index(hand);
        const leaf = this.lookup_idx(idx);
        const sorted_hand = hand_sort(hand);
        if( leaf.hand.join('') != sorted_hand.join('') ) {
            throw Error(`Hand lookup by index returns wrong hand, expected: ${sorted_hand}, but got ${leaf.hand}`);
        }
        return leaf;
    }

    public lookup_idx(idx:number) {
        return Leaf_load(this.leaf_data, idx);
    }

    public proof(hand:Card[])
    {
        const leaf = this.lookup_hand(hand);

        let idx = leaf.idx;
        let self_hash = this.lookup_idx(idx).hash;
        let other_hash = this.lookup_idx((idx&1) ? (idx-1) : (idx+1)).hash;
        let path = [other_hash];

        self_hash = hash_node(-1, leaf.idx, self_hash, other_hash);

        for( let lvl = 0; lvl < (this.levels_data.length-1); lvl++ )
        {
            idx >>= 1;

            other_hash = this._node(lvl, (idx&1) ? (idx-1) : (idx+1));
            path.push(other_hash);

            self_hash = hash_node(lvl, idx, self_hash, other_hash);
        }

        if( Buffer.from(self_hash).toString('hex') != Buffer.from(this.root).toString('hex') ) {
            throw Error(`Merkle root mismatch, expected ${Buffer.from(this.root).toString('hex')}, got ${Buffer.from(self_hash).toString('hex')}`)
        }
        return {
            idx: leaf.idx,
            hand: leaf.hand,
            score: leaf.score,
            kind: leaf.kind,
            path: path,
            root: self_hash
        }
    }
}
