import itertools
import struct
import os
from os import makedirs
from os.path import dirname
from hashlib import sha256
from math import comb

# -------------------------------------------------------------------
# Python Implementation of Cactus Kev's Poker Hand Evaluator
# Taken from https://github.com/fogleman/Poker/
# See: https://web.archive.org/web/20121214132056/http://www.suffecool.net/poker/evaluator.html

import poker_data

_SUITS = [1 << (i + 12) for i in range(4)]
_RANKS = [(1 << (i + 16)) | (i << 8) for i in range(13)]
_PRIMES = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41]
_DECK = [_RANKS[rank] | _SUITS[suit] | _PRIMES[rank] for rank, suit in
    itertools.product(range(13), range(4))]

SUITS = 'cdhs'
RANKS = '23456789TJQKA'
DECK = [''.join(s) for s in itertools.product(RANKS, SUITS)]
DECKIDX = {k: v for v, k in enumerate(DECK)}
LOOKUP = dict(zip(DECK, _DECK))

def hash_function(x):
    x += 0xe91aaa35
    x ^= x >> 16
    x += x << 8
    x &= 0xffffffff
    x ^= x >> 4
    b = (x >> 8) & 0x1ff
    a = (x + (x << 2)) >> 19
    r = (a ^ poker_data.HASH_ADJUST[b]) & 0x1fff
    return poker_data.HASH_VALUES[r]

def eval5(hand):
    c1, c2, c3, c4, c5 = (LOOKUP[x] for x in hand)
    q = (c1 | c2 | c3 | c4 | c5) >> 16
    if 0xf000 & c1 & c2 & c3 & c4 & c5:
        return poker_data.FLUSHES[q]
    s = poker_data.UNIQUE_5[q]
    if s:
        return s
    p = (c1 & 0xff) * (c2 & 0xff) * (c3 & 0xff) * (c4 & 0xff) * (c5 & 0xff)
    return hash_function(p)

def eval7(hand):
    return min(eval5(x) for x in itertools.combinations(hand, 5))

# -------------------------------------------------------------------
# https://en.wikipedia.org/wiki/Combinatorial_number_system

def hand_to_index(x:list[int]):
    v = list(enumerate(sorted(x)))
    return sum(comb(j,i+1) for i,j in v[::-1])

# -------------------------------------------------------------------

CACHE_DIR = os.path.join(dirname(dirname(__file__)), 'cache')
SCORES_DIR = os.path.join(CACHE_DIR, 'scores')
makedirs(SCORES_DIR, exist_ok=True)

def main():
    # map itertools.combinations to combinatorial indices
    print('Evaluating all hands')
    offsets = dict()
    for hand in itertools.combinations(DECK, 5):
        z = sorted([DECKIDX[_] for _ in hand])
        offsets[hand_to_index(z)] = (z, eval5(hand))

    # Verify bijective mapping
    """
    print('Verifying hand scoring')
    i = 0
    for hand in itertools.combinations(DECK, 5):
        blah = [DECKIDX[_] for _ in hand]
        z, score = offsets[hand_to_index(blah)]
        assert z == blah
        assert score == eval5(hand)
        i += 1
    assert i == len(offsets)
    """
    assert len(offsets) == 2598960

    # Compact encoding of hands and their scores
    print('Hashing leaf level')
    merkle_level = list()
    with open(os.path.join(SCORES_DIR, 'scores.leaf'), 'wb') as handle:
        for k in sorted(offsets.keys()):
            z, score = offsets[k]
            entry = bytes(z) + struct.pack('<H', score)
            merkle_level.append(sha256(entry).digest())
            handle.write(entry)

    # Populate merkle tree
    widths = []
    level = 0
    while len(merkle_level) != 1:
        next_level = list()
        widths.append(len(merkle_level))
        with open(os.path.join(SCORES_DIR, f'scores.{level:02d}'), 'wb') as tree:
            for i in range(0, len(merkle_level), 2):
                if i + 1 >= len(merkle_level):
                    p, n = merkle_level[i], bytes([level] * 32)   # Fill unbalanced tree edges with known values
                else:
                    p, n = merkle_level[i], merkle_level[i+1]
                x = sha256(p + n).digest()
                next_level.append(x)
                tree.write(x)
        print(f'Hashed level {level}: {len(merkle_level)}')
        level += 1
        merkle_level = next_level
        next_level = list()

    with open(os.path.join(SCORES_DIR, f'scores.root'), 'wb') as tree:
        tree.write(merkle_level[0])

if __name__ == "__main__":
    main()

#print('merkle root = 0x' + bytes.hex(merkle_level[0]))
#for i, w in enumerate(widths[1:]):
#    print(i, w)
