import itertools
import struct
import os
from time import time
from os import makedirs
from os.path import dirname
from hashlib import sha256
from math import comb, ceil

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

def hand_to_index(x):
    v = tuple(enumerate(sorted(x)))
    return sum(comb(j,i+1) for i,j in v[::-1])

# -------------------------------------------------------------------

CACHE_DIR = os.path.join(dirname(dirname(__file__)), 'cache')
SCORES_DIR = os.path.join(CACHE_DIR, 'scores')
makedirs(SCORES_DIR, exist_ok=True)

def main():
    # map itertools.combinations to combinatorial indices
    print('Evaluating all hands (a handful of seconds)')
    offsets = dict()
    start = time()
    for hand in itertools.combinations(DECK, 5):
        z = sorted(DECKIDX[_] for _ in hand)
        offsets[hand_to_index(z)] = (z, eval5(hand))
    print(' -', time() - start, 'seconds')

    # Retrieve lowest score for each two pairs
    print('Calculating pre-flop odds (a few minutes)')
    start = time()
    preflop = dict()
    max_i = comb(52,2)
    for i,(h0,h1) in enumerate(itertools.combinations(DECKIDX.values(), 2)):
        la, lb, lc, ld = 0, 0, 0xFFFFFF, 0
        for z, s in offsets.values():
            if h0 in z and h1 in z:
                if s < lc:
                    lc = s
                if s > ld:
                    ld = s
                la += s
                lb += 1
        preflop[hand_to_index((h0,h1))] = lc, ld, ceil(la / lb), h0, h1
        #print('%2d' % (h0,), '%2d' % (h1,), '%4d' % (lc,), '%4d' % (ld,), ceil(la / lb), '%02d%%' % ((i/max_i)*100,))  # Average pre-flop score
    assert len(preflop) == max_i
    print(' -', time() - start, 'seconds')
    print(" - avg min:", min(_[2] for _ in preflop.values()), 'max:', max(_[2] for _ in preflop.values()))
    print(" - best min:", min(_[0] for _ in preflop.values()), 'max:', max(_[0] for _ in preflop.values()))
    print(" - worst min:", min(_[1] for _ in preflop.values()), 'max:', max(_[1] for _ in preflop.values()))
    with open(os.path.join(SCORES_DIR, 'scores.preflop'), 'wb') as handle:
        for k in sorted(preflop.keys()):
            a,b,c,d,e = preflop[k]
            handle.write(bytes([d,e]) + struct.pack('<H',a) + struct.pack('<H',b) + struct.pack('<H',c))

    """
    # Verify bijective mapping
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
    start = time()
    merkle_level = list()
    with open(os.path.join(SCORES_DIR, 'scores.leaf'), 'wb') as handle:
        for k in sorted(offsets.keys()):
            z, score = offsets[k]
            # XXX: we don't need to write the score, it's only used to verify the hand matche
            entry = bytes(z) + struct.pack('<H', score)
            merkle_level.append(sha256(entry).digest())
            handle.write(entry)
    print(' -', time() - start, 'seconds')

    # Populate merkle tree
    start = time()
    widths = []
    level = 0
    while len(merkle_level) != 1:
        next_level = list()
        widths.append(len(merkle_level))
        with open(os.path.join(SCORES_DIR, 'scores.%02d' % (level,)), 'wb') as tree:
            for i in range(0, len(merkle_level), 2):
                if i + 1 >= len(merkle_level):
                    p, n = merkle_level[i], bytes([level] * 32)   # Fill unbalanced tree edges with known values
                else:
                    p, n = merkle_level[i], merkle_level[i+1]
                x = sha256(p + n).digest()
                next_level.append(x)
                tree.write(x)
        print('Hashed level', level, len(merkle_level))
        level += 1
        merkle_level = next_level
        next_level = list()

    with open(os.path.join(SCORES_DIR, 'scores.root'), 'wb') as tree:
        tree.write(merkle_level[0])
    print(' -', time() - start, 'seconds')

if __name__ == "__main__":
    main()

#print('merkle root = 0x' + bytes.hex(merkle_level[0]))
#for i, w in enumerate(widths[1:]):
#    print(i, w)
