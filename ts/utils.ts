// https://decipher.dev/30-seconds-of-typescript/docs/binomialCoefficient/

export function binomialCoefficient (n: number, k: number): number {
    if (Number.isNaN(n) || Number.isNaN(k)) return NaN;
    if (k < 0 || k > n) return 0;
    if (k === 0 || k === n) return 1;
    if (k === 1 || k === n - 1) return n;
    if (n - k < k) k = n - k;
    let res = n;
    for (let j = 2; j <= k; j++) res *= (n - j + 1) / j;
    return Math.round(res);
};

// ------------------------------------------------------------------

// https://stackoverflow.com/questions/45813439/itertools-combinations-in-javascript

export function* range(start: number, end: number) {
    for (; start <= end; ++start) { yield start; }
}

export function last<T>(arr: T[]) { return arr[arr.length - 1]; }

export function* numericCombinations(n: number, r: number, loc: number[] = []): IterableIterator<number[]> {
    const idx = loc.length;
    if (idx === r) {
        yield loc;
        return;
    }
    for (let next of range(idx ? last(loc) + 1 : 0, n - r + idx)) {
        yield* numericCombinations(n, r, loc.concat(next));
    }
}

export function* combinations<T>(arr: T[], r: number) {
    for (let idxs of numericCombinations(arr.length, r)) {
        yield idxs.map(i => arr[i]);
    }
}
