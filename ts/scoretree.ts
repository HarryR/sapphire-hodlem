import { sha256 } from '@noble/hashes/sha256';
import { readFileSync } from "fs";
import { join } from "path";
import { binomialCoefficient, combinations } from "./utils";

const LEAF_SIZE_BYTES = 7;

const PREFLOP_SIZE_BYTES = 8;

const NODE_SIZE_BYTES = 32;

export type Card = '2c' | '2d' | '2h' | '2s' | '3c' | '3d' | '3h' | '3s' | '4c' | '4d' | '4h' | '4s' | '5c' | '5d' | '5h' | '5s' | '6c' | '6d' | '6h' | '6s' | '7c' | '7d' | '7h' | '7s' | '8c' | '8d' | '8h' | '8s' | '9c' | '9d' | '9h' | '9s' | 'Tc' | 'Td' | 'Th' | 'Ts' | 'Jc' | 'Jd' | 'Jh' | 'Js' | 'Qc' | 'Qd' | 'Qh' | 'Qs' | 'Kc' | 'Kd' | 'Kh' | 'Ks' | 'Ac' | 'Ad' | 'Ah' | 'As';

export const DECK:Card[] = ['2c', '2d', '2h', '2s', '3c', '3d', '3h', '3s', '4c', '4d', '4h', '4s', '5c', '5d', '5h', '5s', '6c', '6d', '6h', '6s', '7c', '7d', '7h', '7s', '8c', '8d', '8h', '8s', '9c', '9d', '9h', '9s', 'Tc', 'Td', 'Th', 'Ts', 'Jc', 'Jd', 'Jh', 'Js', 'Qc', 'Qd', 'Qh', 'Qs', 'Kc', 'Kd', 'Kh', 'Ks', 'Ac', 'Ad', 'Ah', 'As'];

export const DECKIDX : {[id:string]:number}= {'2c': 0, '2d': 1, '2h': 2, '2s': 3, '3c': 4, '3d': 5, '3h': 6, '3s': 7, '4c': 8, '4d': 9, '4h': 10, '4s': 11, '5c': 12, '5d': 13, '5h': 14, '5s': 15, '6c': 16, '6d': 17, '6h': 18, '6s': 19, '7c': 20, '7d': 21, '7h': 22, '7s': 23, '8c': 24, '8d': 25, '8h': 26, '8s': 27, '9c': 28, '9d': 29, '9h': 30, '9s': 31, 'Tc': 32, 'Td': 33, 'Th': 34, 'Ts': 35, 'Jc': 36, 'Jd': 37, 'Jh': 38, 'Js': 39, 'Qc': 40, 'Qd': 41, 'Qh': 42, 'Qs': 43, 'Kc': 44, 'Kd': 45, 'Kh': 46, 'Ks': 47, 'Ac': 48, 'Ad': 49, 'Ah': 50, 'As': 51};

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

// https://en.wikipedia.org/wiki/Combinatorial_number_system
export function hand_to_index(hand:Card[]) {
    if( hand.length != 2 && hand.length != 5 ) {
        throw Error(`Requires 5 cards, but provided with ${hand.length}: ${hand}`);
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
    const sorted_hand = hand.map((_)=>DECKIDX[_]).sort((a,b) => a-b).map((_)=>DECK[_]);
    return sorted_hand;
}

export interface PreflopLeaf {
    idx:number;
    hand: Card[];
    avg: number;
    avg_kind: ScoreName;
    best: number;
    best_kind: ScoreName;
    worst: number;
    worst_kind: ScoreName;
}

function load_u16(data:Uint8Array, offset:number) {
    return data[offset] + (data[offset+1]<<8)
}

function Preflop_from_bytes(entry:Uint8Array, idx:number) : PreflopLeaf {
    const a = load_u16(entry, 2);
    const b = load_u16(entry, 4);
    const c = load_u16(entry, 6);
    return {
        idx: idx,
        hand: [DECK[entry[0]], DECK[entry[1]]],
        avg: a,
        avg_kind: score_name(a),
        best: b,
        best_kind: score_name(b),
        worst: c,
        worst_kind: score_name(c)
    };
}

function Preflop_load(preflop_data:Uint8Array, idx:number) {
    const offset = idx * PREFLOP_SIZE_BYTES;
    const entry = preflop_data.slice(offset, offset + PREFLOP_SIZE_BYTES);
    return Preflop_from_bytes(entry, idx);
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

function ScoreLeaf_from_bytes(idx:number, leaf:Uint8Array) : ScoreLeaf
{
    if( leaf.length != LEAF_SIZE_BYTES ) {
        throw Error('Invalid leaf size!');
    }
    const hand = [DECK[leaf[0]], DECK[leaf[1]], DECK[leaf[2]], DECK[leaf[3]], DECK[leaf[4]]];
    const score = load_u16(leaf, 5);
    return {
        idx: idx,
        hand: hand_sort(hand),
        score: score,
        kind: score_name(score),
        raw: leaf,
        hash: Buffer.from(sha256(leaf))
    }
}

function ScoreLeaf_load(leaf_data: Uint8Array, idx: number)
{
    const leaf_count = leaf_data.length / LEAF_SIZE_BYTES;
    if( idx >= leaf_count ) {
        throw Error(`Index ${idx} exceeds leaf count ${leaf_count}`);
    }
    const offset = idx * LEAF_SIZE_BYTES;
    const leaf = leaf_data.slice(offset, offset+LEAF_SIZE_BYTES);
    return ScoreLeaf_from_bytes(idx, leaf);
}

export class ScoreTree {
    private levels_data: Uint8Array[];
    private leaf_data: Uint8Array;
    public root: Uint8Array;
    private preflop_data: Uint8Array;
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
        this.preflop_data = this._load_file('scores.preflop');
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

    public lookup_preflop(hole:Card[]) {
        const idx = hand_to_index(hole);
        const data = this.preflop_data.slice();
        return Preflop_load(this.preflop_data, idx);
    }

    public lookup_hands(hand:Card[]) {
        let ret = [];
        for( const h of combinations<Card>(hand, 5) ) {
            ret.push(this.lookup_hand(h));
        }
        return ret;
    }

    public hands_count() {
        return this.leaf_data.length / LEAF_SIZE_BYTES;
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
        return ScoreLeaf_load(this.leaf_data, idx);
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
