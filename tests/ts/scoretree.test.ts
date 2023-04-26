import { ScoreTree, Card, DECK, hand_sort } from '../../ts/scoretree';
import { binomialCoefficient, combinations } from '../../ts/utils';

describe('scoretree', () => {
  test('prove', () => {
    const st = new ScoreTree('./cache/scores');
    const hand = ['As', '4c', '6d', '9h', 'Qh'] as Card[];
    const p = st.proof(hand);    // .proof() verifies merkle path vs root, hand etc. too
    expect(p.score).toBe(6426);
  });
  test('all match', () => {
    const st = new ScoreTree('./cache/scores');
    let i = 0;
    expect(st.hands_count()).toBe(binomialCoefficient(52, 5));
    for( const hand of combinations(DECK, 5) ) {
      const x = st.lookup_hand(hand);
      expect(x.hand).toEqual(hand);
      i +=1;
    }
    expect(i).toBe(st.hands_count());
  })
});
