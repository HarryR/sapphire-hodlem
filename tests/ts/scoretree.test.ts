import { ScoreTree, Card } from '../../ts/scoretree';

describe('scoretree', () => {
  test('prove', () => {
    const x = new ScoreTree('./cache/scores');
    const hand = ['As', '4c', '6d', '9h', 'Qh'] as Card[];
    const p = x.proof(hand);    // .proof() verifies merkle path vs root, hand etc. too
    expect(p.score).toBe(6426);
  });
});
