import { expect } from "chai";
import { readFileSync } from "fs";
import * as hre from "hardhat";
import { LobbyState, } from "../../ts/gamestate";
import { DECKIDX, ScoreTree } from "../../ts/scoretree";
import { BytesLike, ContractTransaction } from "ethers";

const ethers = hre.ethers;

var seed = 1;
function deterministic_random() {
    var x = Math.sin(seed++) * 10000;
    return x - Math.floor(x);
}

function randint(min: number, max: number): number {
    return Math.floor(deterministic_random() * (max - min) + min);
}

function random_bet(fold_chance:number, min: number, max: number)
{
    const m = randint(1, fold_chance);
    if( m == 1 ) {
        return ['fold', 0];
    }
    const n = randint(Math.max(1, min), max);
    return [`bet ${n}`, n];
}

const MERKLE_ROOT = readFileSync('./cache/scores/scores.root');

describe('Poker', () => {
    const st = new ScoreTree('./cache/scores');

    async function deployFixture() {
        hre.tracer.enabled = false;
        const Poker = await ethers.getContractFactory('TestablePoker');
        const pkr = await Poker.deploy(MERKLE_ROOT);

        let signers = (await ethers.getSigners()).slice(0, 6);
        while( signers.length < 5 ) {
            throw Error('Not enough signers to run tests!');
        }

        // Setup some presets
        console.log('   - Setting initial presets');
        const preset_tx = await pkr.preset_change(0, 5, 10);
        await preset_tx.wait();

        const accounts = [];
        for( const _ of signers ) {
            const contract = pkr.connect(_);
            const addr = _.address;
            const lobby = new LobbyState(st, [], addr);
            accounts.push({
                wallet: _,
                address: addr,
                contract: contract,
                lobby: lobby
            });
        }

        return { accounts };
    }

    it('Doesnt break again', async () => {

    });

    it('Runs', async ()=>{
        const { accounts } = await deployFixture();

        // Give every account some cash to play with
        console.log('   - Making deposits');
        let deposit_txs : Promise<ContractTransaction>[] = [];
        for( const p of accounts ) {
            console.log('     -', p.address);
            const x = p.contract["deposit()"]({value: 100000n});
            deposit_txs.push(x);
        }
        Promise.all((await Promise.all(deposit_txs)).map(_ => _.wait()));

        // Simulate game queues with 2 to 10 players
        for( let player_count = 2; player_count <= 5; player_count++ )
        {
            console.log('--------------------------------------------');
            console.log("PLAYER COUNT", player_count);
            // Begin a poker game with the players
            for( let game_count = 0; game_count < 2; game_count++ ) {
                console.log("GAME COUNT", game_count);
                console.log('.......................');
                let total_log_bytes = 0;
                let total_gas_used = 0n;

                if( accounts.length < player_count ) {
                    throw Error('Not enough players');
                }
                const game_accounts = accounts.slice(0, player_count);

                for( const pa of game_accounts ) {
                    const join_tx = await pa.contract.join(0, player_count);
                    const join_receipt = await join_tx.wait();
                    total_log_bytes += join_receipt.logs.map((_)=>_.data.length-2).reduce((a, b) => a + b, 0);
                    total_gas_used += join_receipt.gasUsed.toBigInt();
                    console.log(`Player ${pa.address} joined`, join_receipt.gasUsed.toBigInt());

                    for( const pb of game_accounts ) {
                        pb.lobby.step_from_receipt(join_receipt);
                    }
                }

                // Players have only joined one game
                for( const pa of game_accounts ) {
                    expect(pa.lobby.games).to.have.lengthOf(1);
                }

                // All players are in the same game
                let game_id : bigint | null = null;
                for( const [gs_game_id, gs] of game_accounts[0].lobby.games.entries() ) {
                    if( game_id == null ) {
                        game_id = gs_game_id
                    }
                    else {
                        expect(gs_game_id).to.be.equal(game_id);
                    }
                }

                if( game_id == null ) {
                    throw Error('Unable to determine game_id!');
                }

                // Get initial game state for inspection
                /*
                console.log('Initial state!');
                const p3 = await game_accounts[0].contract.dump_state(game_id);
                const p4 = await p3.wait();
                console.log({t: p4.events?.[0].args?.t, p: p4.events?.[0].args?.p, b:p4.events?.[0].args?.b});
                */

                const empty_proof_data : [BytesLike, number, BytesLike[], number] = [[], 0, [], 0];
                let game_running = true;
                let fold_count = 0;
                while( game_running )
                {
                    for( const pa of game_accounts ) {
                        const game = pa.lobby.games.get(game_id);
                        if( ! game ) {
                            throw Error(`Account ${pa.address} doesn't have game associated with it!`);
                        }

                        if( game.my_idx != game.player_next_idx ) {
                            continue;
                        }

                        let my_proof : [BytesLike, number, BytesLike[], number];
                        if( game.round == 3 ) {
                            // submit cards
                            const bh = game.best_hand;
                            const p = st.proof(bh.hand);
                            console.log(`   hand ${game.round}, player ${pa.address}, submitting hand: ${p.hand} ${bh.kind} (${p.score})`);
                            const hand_indices = bh.hand.map((_)=>DECKIDX[_]);
                            my_proof = [hand_indices, p.score, p.path, p.idx];
                        }
                        else {
                            my_proof = empty_proof_data;
                        }

                        const p = {hand: my_proof[0], score: my_proof[1], path: my_proof[2], index: my_proof[3]};
                        const [bet_kind, bet_size] = random_bet(10, game.min_bet_mul, game.info.max_bet_mul);

                        console.log(`   ${game_id} Round ${game.round}/${game.my_idx}/${game.player_next_idx}, player ${pa.address}, ${bet_kind}`);

                        hre.tracer.enabled = true;
                        let p1 = await pa.contract.play(game.game_id, game.player_next_idx, bet_size, p);
                        let p2 = await p1.wait();
                        hre.tracer.enabled = false;

                        total_log_bytes = total_log_bytes + p2.logs.map((_)=>_.data.length-2).reduce((a, b) => a + b, 0);
                        total_gas_used += p2.gasUsed.toBigInt();
                        if( bet_kind == 'fold' ) {
                            fold_count += 1;
                        }

                        console.log(`    ... gc=${p2.gasUsed}`);

                        // Notify other accounts of this games actions
                        for( const pa2 of game_accounts ) {
                            pa2.lobby.step_from_receipt(p2);
                        }

                        if( game.my_result ) {
                            game_running = false;
                            break;
                        }
                    }
                }

                // TODO: verify that there is at least one winner

                console.log("")
                console.log("Total gas used:", total_gas_used.toString())
                console.log("Total log bytes:", total_log_bytes.toString())

                console.log("");
                for( const pa of game_accounts ) {
                    const gs = pa.lobby.results.get(game_id);
                    expect(gs).to.not.be.undefined;
                    if( ! gs ) throw Error("Game state must not be undefined");
                    const folded = gs.has_folded;
                    console.log(pa.address, `folded=${folded}`, gs?.my_result);
                    expect(gs.my_result).to.not.be.undefined;
                    if( folded ) {
                        expect(gs.my_result?.payout).to.equal(0n);
                    }
                }
                console.log("\n");
            }
        }
    });
});

