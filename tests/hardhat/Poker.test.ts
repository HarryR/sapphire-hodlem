import { expect } from "chai";
import { readFileSync } from "fs";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import * as hre from "hardhat";
import { GameState, } from "../../ts/gamestate";
import { DECKIDX, ScoreTree } from "../../ts/scoretree";
import { BytesLike } from "ethers";
import { Poker } from "../../typechain-types";

const ethers = hre.ethers;

const MERKLE_ROOT = readFileSync('./cache/scores/scores.root');

describe('Poker', () => {
    async function deployFixture() {
        const Poker = await ethers.getContractFactory('Poker');
        const pkr = await Poker.deploy(MERKLE_ROOT);
        const accounts = (await ethers.getSigners()).map((_) => {
            return {
                wallet: _,
                address: _.address,
                contract: pkr.connect(_)
            } as {
                wallet: typeof _,
                address: string,
                contract: Poker,
                gs?: GameState
            };
        });
        return { Poker, pkr, accounts };
    }
    it('Runs', async ()=>{
        const { pkr, accounts } = await loadFixture(deployFixture);
        const player_accounts = accounts.slice(1, 5);
        const addrs = player_accounts.map((_) => _.address);

        // Every player deposits
        for( const p of player_accounts )  {
            const x = await p.contract["deposit()"]({value: 1000n});
            await x.wait();
        }

        // Begin a poker game with the players
        for( let game_count = 0; game_count < 2; game_count++ ) {
            const receipt = await (await pkr.begin(addrs, 2)).wait();
            let total_log_bytes = receipt.logs.map((_)=>_.data.length-2).reduce((a, b) => a + b, 0);
            let total_gas_used = receipt.gasUsed;

            const st = new ScoreTree('./cache/scores');

            // Pass Begin events to all players game states
            for( const pa of player_accounts ) {
                pa.gs = GameState.from_receipt(st, receipt, pa.address);
            }

            const empty_proof_data : [BytesLike, number, BytesLike[], number] = [[], 0, [], 0];
            let game_running = true;
            while( game_running )
            {
                const pa_idx = player_accounts[0].gs?.player_next_idx;
                if( pa_idx === undefined ) throw Error('Unable to determine next player index');

                const pa = player_accounts.filter((_)=>_.gs?.my_idx==pa_idx)[0];

                const gs = pa.gs;
                if( ! gs ) throw Error('Expected to have a player game state!');

                if( gs.my_idx != gs.player_next_idx ) {
                    continue;
                }

                console.log(`Player ${pa.address} = ${gs.my_idx}, ${gs.my_hand} | ${gs.dealer_cards}`);

                let my_proof : [BytesLike, number, BytesLike[], number];
                if( gs.round == 3 ) {
                    // submit cards
                    const bh = gs.best_hand;
                    const p = st.proof(bh.hand);
                    console.log(`   hand ${gs.round}, player ${pa.address}, submitting hand: ${p.hand} ${bh.kind} (${p.score})`);
                    const hand_indices = bh.hand.map((_)=>DECKIDX[_]);
                    my_proof = [hand_indices, p.score, p.path, p.idx];
                }
                else {
                    my_proof = empty_proof_data;
                }
                const p = {hand: my_proof[0], score: my_proof[1], path: my_proof[2], index: my_proof[3]};
                let p1 = await pa.contract.play(gs.game_id, gs.player_next_idx, 1, p);
                let p2 = await p1.wait();
                let total_log_bytes = p2.logs.map((_)=>_.data.length-2).reduce((a, b) => a + b, 0);
                total_gas_used = total_gas_used.add(p2.gasUsed);

                console.log(`   Round ${gs.round}/${gs.my_idx}/${gs.player_next_idx}, player ${pa.address}, gc=${p2.gasUsed}`);

                for( const pa2 of player_accounts ) {
                    pa2.gs?.step_from_receipt(p2);
                }

                if( gs.my_result ) {
                    game_running = false;
                    break;
                }

                console.log("");
            }

            console.log("")
            console.log("Total gas used:", total_gas_used.toString())
            console.log("Total log bytes:", total_log_bytes.toString())

            console.log("");
            for( const pa of player_accounts ) {
                console.log(pa.address, pa.gs?.my_result);
            }
            console.log("\n");
        }

        expect(true).to.be.eq(true);
    });
});

