import { Card, DECK, ScoreLeaf, ScoreTree } from "./scoretree";
import { Exome } from "exome";
import { ContractReceipt } from "ethers";
import * as Poker from "../typechain-types/Poker";

// ------------------------------------------------------------------
// Game Events

export type GameEventName = 'created' | 'bet' | 'hand' | 'round' | 'win' | 'end';

const NO_NEXT_PLAYER = 0xFF;

const NO_CARD = 0xFF;

export type QueueEventType = 'queue_join' | 'queue_leave';

export interface QueueEvent {
    player: string;
    qid: number;
    bet_size: bigint;
    max_bet_mul: number;
    event_type: QueueEventType;
}

interface _GameEventBase {
    game_id: bigint;
    event_type: GameEventName;
}

export interface GameEventEnd extends _GameEventBase {

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
                      | GameEventWin
                      | GameEventEnd;

export type GameOrQueueEvent = GameEvent | QueueEvent;

// ------------------------------------------------------------------
// Decoding game events from contract logs

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

export function receipt_to_events(receipt:ContractReceipt) : GameOrQueueEvent[]
{
    if( ! receipt.events ) {
        throw Error(`Receipt has no events! ${receipt}`);
    }

    const r : GameOrQueueEvent[] = [];
    for( const e of receipt.events ) {
        if( ! e.event || ! e.args ) {
            throw Error(`Event was not decoded! ${e}`);
        }

        if( e.event == 'Created' ) {
            const ta = e as Poker.CreatedEvent;
            r.push({
                game_id: ta.args.game_id.toBigInt(),
                event_type: "created",
                created: {
                    players: ta.args.players.filter((_)=>_!='0x0000000000000000000000000000000000000000'),
                    bet_size: ta.args.bet_size.toBigInt(),
                    max_bet_mul: ta.args.max_bet_mul.toNumber(),
                    player_start_idx: ta.args.player_start_idx,
                    pot: e.args.pot.toBigInt()
                }
            } as GameEventCreated);
        }
        else if( e.event == 'Hand' ) {
            // e.args.cards is array of bytes, as hex encoded strings, decode to actual cards
            const ta = e as Poker.HandEvent;
            r.push({
                game_id: e.args.game_id.toBigInt(),
                event_type: "hand",
                hand: {
                    player_idx: e.args.player_idx,
                    cards: event_cards_decode(e.args.cards)
                }
            } as GameEventHand);
        }
        else if( e.event == 'Round' ) {
            const ta = e as Poker.RoundEvent;
            r.push({
                game_id: ta.args.game_id.toBigInt(),
                event_type: "round",
                round: {
                    round_idx: ta.args.round_idx,
                    cards: event_cards_decode(ta.args.cards),
                    player_next_idx: ta.args.player_next_idx
                }
            } as GameEventRound);
        }
        else if( e.event == 'Bet' ) {
            const ta = e as Poker.BetEvent;
            r.push({
                game_id: ta.args.game_id.toBigInt(),
                event_type: "bet",
                bet: {
                    player_idx: ta.args.player_idx,
                    multiplier: ta.args.multiplier,
                    pot: ta.args.pot.toBigInt(),
                    player_next_idx: ta.args.player_next_idx
                }
            } as GameEventBet);
        }
        else if( e.event == 'Win' ) {
            const ta = e as Poker.WinEvent;
            r.push({
                game_id: ta.args.game_id.toBigInt(),
                event_type: "win",
                win: {
                    player_idx: ta.args.player_idx,
                    payout: ta.args.payout.toBigInt()
                }
            } as GameEventWin);
        }
        else if( e.event == 'End' ) {
            const ta = e as Poker.EndEvent;
            r.push({
                game_id: ta.args.game_id.toBigInt(),
                event_type: "end",
            } as GameEventEnd);
        }
        else if( e.event == 'Queue_Join' || e.event == 'Queue_Leave' ) {
            const ta = e as Poker.Queue_JoinEvent;
            r.push({
                player: ta.args.player,
                qid: ta.args.qid.toNumber(),
                bet_size: ta.args.bet_size.toBigInt(),
                max_bet_mul: ta.args.max_bet_mul.toNumber(),
                event_type: e.event.toLowerCase()
            } as QueueEvent);
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
            this.my_best_hands = [];
            if( this.my_hand ) {
                this.my_best_hands = this.st.lookup_hands(this.dealer_cards.concat(this.my_hand));
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
            throw Error(`Unhandled event type (${e.event_type}): ${e}`);
        }
    }
}

// ------------------------------------------------------------------
// Manages the lobby, joining and leaving games.

class GamePreset extends Exome {
    constructor(
        public preset_id: number,
        public bet_size: bigint,
        public max_bet_mul: number,
        public joined: boolean
    ) {
        super();
    }
}

export class LobbyState extends Exome {
    declare public queues: Map<number,GamePreset>;
    declare public games: Map<bigint,GameState>;
    declare public results: Map<bigint,GameState>;
    declare public balance: bigint | null;
    declare public game_ids: bigint[];
    constructor(
        private st: ScoreTree,
        _presets:GamePreset[],
        public my_addr:string
    ) {
        super();
        this.queues = new Map();
        this.games = new Map();
        this.results = new Map();
        this.game_ids = [];
        this.balance = null;
    }

    public step_from_receipt( r:ContractReceipt )
    {
        for( const e of receipt_to_events(r) ) {
            this.step(e);
        }
    }

    public step( e:GameOrQueueEvent )
    {
        if( e.event_type == "queue_join" || e.event_type == "queue_leave") {
            const qe = e as QueueEvent;
            if( qe.player == this.my_addr ) {
                const q = this.queues.get(e.qid);
                if( ! q ) {
                    this.queues.set(e.qid, new GamePreset(e.qid, e.bet_size, e.max_bet_mul, true));
                }
                else {
                    q.joined = (e.event_type == "queue_join");
                }
            }
        }
        else if( e.event_type == "created" ) {
            const ge = e as GameEventCreated;
            const my_idx = ge.created.players.indexOf(this.my_addr);
            if( my_idx != -1 ) {
                if( ! this.games.has(e.game_id) ) {
                    const gs = new GameState(this.st, e.game_id, ge.created, my_idx);
                    this.games.set(e.game_id, gs);
                    this.game_ids.push(e.game_id);
                }
                else {
                    console.error(`Processing Created event twice! game_id: ${e.game_id}`, e);
                }
            }
        }
        else if( e.event_type == "end" ) {
            const ge = e as GameEventEnd;
            const gs = this.games.get(ge.game_id);
            if( gs ) {
                this.game_ids = this.game_ids.filter(_ => _ != ge.game_id);
                this.games.delete(ge.game_id);
                this.results.set(ge.game_id, gs);
            }
        }
        else {
            const ge = e as GameEvent;
            const game = this.games.get(ge.game_id);
            if( game ) {
                game.step(ge);
            }
            else {
                console.error(`Unknown game ID ${ge.game_id} - cannot process event`, e)
            }
        }
    }
}
