import { binomialCoefficient, combinations } from "../../ts/utils";

describe('utils', () => {
  test('binomialCoefficient', () => {
    expect(binomialCoefficient(10,9)).toBe(10);
    expect(binomialCoefficient(20,10)).toBe(184756);
  });
  test('combinations', () => {
    let i = 0;
    const k = [[1,2],[1,3],[2,3]];
    for( const j of combinations([1,2,3], 2) ) {
        expect(j).toStrictEqual(k[i]);
        i += 1;
    }
  });
});
