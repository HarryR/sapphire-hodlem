import { expect } from "chai";
import { readFileSync } from "fs";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import * as hre from "hardhat";
import { GameState, LobbyState, } from "../../ts/gamestate";
import { DECKIDX, ScoreTree } from "../../ts/scoretree";
import { BigNumber, BytesLike } from "ethers";
import { Poker } from "../../typechain-types";

const ethers = hre.ethers;

const MERKLE_ROOT = readFileSync('./cache/scores/scores.root');

describe('Poker', () => {
    const st = new ScoreTree('./cache/scores');

    async function deployFixture() {
        hre.tracer.enabled = false;
        const Poker = await ethers.getContractFactory('Poker');
        const pkr = await Poker.deploy(MERKLE_ROOT);

        // Setup some presets
        await (await pkr.preset_change(0, 5, 10)).wait();

        // Attach all the accounts to the lobby
        const accounts = (await ethers.getSigners()).map((_) => {
            const contract = pkr.connect(_);
            const lobby = new LobbyState(st, [], _.address);
            return {
                wallet: _,
                address: _.address,
                contract: contract,
                lobby: lobby
            };
        });

        return { Poker, pkr, accounts };
    }
    it('Runs', async ()=>{
        const { accounts } = await loadFixture(deployFixture);

        // Give every account some cash to play with
        for( const p of accounts )  {
            const x = await p.contract["deposit()"]({value: 1000n});
            await x.wait();
        }

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

                const empty_proof_data : [BytesLike, number, BytesLike[], number] = [[], 0, [], 0];
                let game_running = true;
                while( game_running )
                {
                    for( const pa of game_accounts ) {
                        const game = pa.lobby.games.get(game_id);
                        if( ! game ) {
                            throw Error("Account doesn't have game associated with it!");
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
                        let p1 = await pa.contract.play(game.game_id, game.player_next_idx, 1, p);
                        let p2 = await p1.wait();
                        total_log_bytes = total_log_bytes + p2.logs.map((_)=>_.data.length-2).reduce((a, b) => a + b, 0);
                        total_gas_used += p2.gasUsed.toBigInt();

                        console.log(`   Round ${game.round}/${game.my_idx}/${game.player_next_idx}, player ${pa.address}, gc=${p2.gasUsed}`);

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

                console.log("")
                console.log("Total gas used:", total_gas_used.toString())
                console.log("Total log bytes:", total_log_bytes.toString())

                console.log("");
                for( const pa of game_accounts ) {
                    const gs = pa.lobby.results.get(game_id);
                    expect(gs).to.not.be.undefined;
                    console.log(pa.address, gs?.my_result);
                }
                console.log("\n");
            }
        }

        expect(true).to.be.eq(true);
    });
});

