import { Card, DECK, ScoreLeaf, ScoreTree } from "./scoretree";
import { Exome } from "exome";
import { ContractReceipt } from "ethers";

export type GameEventName = 'created' | 'bet' | 'hand' | 'round' | 'win';

const NO_NEXT_PLAYER = 0xFF;

const NO_CARD = 0xFF;

interface _GameEventBase {
    game_id: bigint;
    event_type: GameEventName;
}

export interface GameEventBet extends _GameEventBase {
    bet: {
        player_idx: number;
        multiplier: number;
        pot: bigint;
        player_next_idx: number;
    }
}

export interface GameEventCreated extends _GameEventBase {
    created: {
        players: string[];
        bet_size: bigint;
        max_bet_mul: number;
        player_start_idx: number;
        pot: bigint;
    }
}

export interface GameEventHand extends _GameEventBase {
    hand: {
        player_idx: number;
        cards: Card[];
    }
}

export interface GameEventRound extends _GameEventBase {
    round: {
        round_idx: number;
        cards: Card[];
        player_next_idx: number;
    }
}

export interface GameEventWin extends _GameEventBase {
    win: {
        player_idx: number;
        payout: bigint;
    }
}

export type GameEvent = GameEventBet
                      | GameEventCreated
                      | GameEventHand
                      | GameEventRound
                      | GameEventWin;

// ------------------------------------------------------------------

function event_cards_decode(cards: string[]) : Card[] {
    const r : Card[] = [];
    for( const c of cards ) {
        const d = Number.parseInt(c);
        if( Number.isNaN(d) || d == 0xFF ) {
            continue;   // XXX: silently fail? We need to ignore 0xFF, but anything between MAX_CARDS and 0xFF is anamolous etc.
        }
        const e = DECK[d];
        r.push(e);
    }
    return r;
}

export function receipt_to_events(receipt:ContractReceipt) : GameEvent[]
{
    if( ! receipt.events ) {
        throw Error(`Receipt has no events! ${receipt}`);
    }

    const r : GameEvent[] = [];
    for( const e of receipt.events ) {
        if( ! e.event || ! e.args ) {
            throw Error(`Event was not decoded! ${e}`);
        }

        if( e.event == 'Created' ) {
            r.push({
                game_id: e.args.game_id,
                event_type: "created",
                created: {
                    players: e.args.players,
                    bet_size: e.args.bet_size,
                    max_bet_mul: e.args.max_bet_mul,
                    player_start_idx: e.args.player_start_idx,
                    pot: e.args.pot
                }
            } as GameEventCreated);
        }
        else if( e.event == 'Hand' ) {
            // e.args.cards is array of bytes, as hex encoded strings, decode to actual cards
            r.push({
                game_id: e.args.game_id,
                event_type: "hand",
                hand: {
                    player_idx: e.args.player_idx,
                    cards: event_cards_decode(e.args.cards)
                }
            } as GameEventHand);
        }
        else if( e.event == 'Round' ) {
            r.push({
                game_id: e.args.game_id,
                event_type: "round",
                round: {
                    round_idx: e.args.round_idx,
                    cards: event_cards_decode(e.args.cards),
                    player_next_idx: e.args.player_next_idx
                }
            } as GameEventRound);
        }
        else if( e.event == 'Bet' ) {
            r.push({
                game_id: e.args.game_id,
                event_type: "bet",
                bet: {
                    player_idx: e.args.player_idx,
                    multiplier: e.args.multiplier,
                    pot: e.args.pot,
                    player_next_idx: e.args.player_next_idx
                }
            } as GameEventBet);
        }
        else if( e.event == 'Win' ) {
            r.push({
                game_id: e.args.game_id,
                event_type: "win",
                win: {
                    player_idx: e.args.player_idx,
                    payout: e.args.payout
                }
            } as GameEventWin);
        }
        else {
            throw Error(`Unknown event type: ${e}`);
        }
    }

    return r;
}

// ------------------------------------------------------------------

interface GameResult {
    win: boolean;
    payout: bigint;
}

class PlayerState extends Exome {
    constructor(
        public idx: number,
        public folded: boolean,
        public address: string,
        public bets: number,
        public win?: boolean,
        public payout?: bigint
    ) {
        super();
    }
}

export class GameState extends Exome {
    declare public my_hand? : Card[];
    declare public dealer_cards? : Card[]
    declare public my_result? : GameResult;
    declare public my_best_hands? : ScoreLeaf[];
    declare public player_next_idx : number;
    declare public player_states : PlayerState[];
    declare public pot: bigint;
    declare public round: number;

    constructor(
        private st: ScoreTree,
        public game_id: bigint,
        public info: GameEventCreated['created'],
        public my_idx: number
    ) {
        super();
        this.player_next_idx = info.player_start_idx;
        this.pot = info.pot;
        this.player_states = info.players.map(function (_, index) {
            return new PlayerState(index, false, _, 0);
        });
        this.round = 0;
    }

    static from_receipt(st: ScoreTree, receipt:ContractReceipt, my_address: string) {
        return GameState.from_events(st, receipt_to_events(receipt), my_address);
    }

    static from_events( st: ScoreTree, events: GameEvent[], my_address: string ) {
        if( events[0].event_type != "created" ) {
            throw Error(`Game events must started with 'created'`);
        }
        const ce = events[0] as GameEventCreated;
        if( ce.event_type != "created" ) {
            throw Error(`Cannot create from a non-'created' event, got: ${ce.game_id} - ${ce.event_type}: ${ce}`);
        }
        const my_idx = ce.created.players.indexOf(my_address);
        if( my_idx == -1 ) {
            throw Error(`Couldn't find my player index, my addr: ${my_address}, players: ${ce.created.players}`);
        }
        const gs = new GameState(st, ce.game_id, ce.created, my_idx);
        for( const e of events.slice(1) ) {
            gs.step(e);
        }
        return gs;
    }

    public get best_hand () {
        if( ! this.my_best_hands || this.my_best_hands.length == 0 ) {
            throw Error('Not enough cards to calculate best hand!');
        }
        return this.my_best_hands.sort((a,b)=>{return a.score-b.score})[0];
    }

    public step( e:GameEvent )
    {
        //console.log(`Step (game=${this.game_id.toString()})`, e);

        if( e.event_type == "bet" ) {
            const bet = (e as GameEventBet).bet;
            const ps = this.player_states[bet.player_idx];
            ps.folded = bet.multiplier == 0;
            ps.bets += bet.multiplier;
            this.pot = bet.pot;
            this.player_next_idx = bet.player_next_idx;
        }
        else if( e.event_type == "hand" ) {
            const hand = (e as GameEventHand).hand;
            if( hand.player_idx == this.my_idx ) {
                this.my_hand = hand.cards;
            }
        }
        else if( e.event_type == "round" ) {
            const round = (e as GameEventRound).round;
            this.dealer_cards = (this.dealer_cards ?? []).concat(round.cards);
            if( ! this.my_hand ) {
                throw Error("Don't have 5 cards after the flop, what happened!");
            }
            this.my_best_hands = [];
            for( const _ of this.st.lookup_hands(this.dealer_cards.concat(this.my_hand)) ) {
                this.my_best_hands.push(_);
            }
            this.player_next_idx = round.player_next_idx;
            this.round = round.round_idx;
        }
        else if( e.event_type == "win" ) {
            const win = (e as GameEventWin).win;
            if( win.player_idx == this.my_idx ) {
                this.my_result = {
                    win: win.payout != 0n,
                    payout: win.payout
                }
            }
            const ps = this.player_states[win.player_idx];
            ps.win = win.payout != 0n;
            ps.payout = win.payout;
        }
        else {
            throw Error(`Unhandled event type (${e.game_id} - ${e.event_type}): ${e}`);
        }
    }

    public step_from_receipt( receipt:ContractReceipt ) {
        for( const e of receipt_to_events(receipt) ) {
            this.step(e);
        }
    }
}
