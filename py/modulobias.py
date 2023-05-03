#!/usr/bin/env python3

from math import log2
from statistics import stdev
from random import randint

def calchist(m,k=52,r=50):
    z = 0xFFFFFF
    hist = list(range(k))
    for i in range(z):
        n = randint(0,m)
        hist[n%k] += 1
    t = z/k
    return hist, [t/_ for _ in hist]


def main():
    for k in [52, 103]:
        for a in [0xFFFFFFFF, 0xFFFFFFF, 0xFFFFFF, 0xFFFFF, 0xFFFF, 0xFFF, 0xFF, 128, 105, 104, 103, 102, 64, 53, 52, 51]:
            if a < (k-1):
                continue
            x = calchist(a, k=k)
            print(k, a, log2(a)/log2(k), stdev(x[1]))

if __name__ == "__main__":
    main()