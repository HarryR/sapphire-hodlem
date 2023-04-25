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
        //const players_by_addr = Object.fromEntries(player_accounts.map(_ => [_.address, _]));
        const addrs = player_accounts.map((_) => _.address);

        // Every player deposits
        for( const p of player_accounts )  {
            const x = await p.contract.deposit({value: 1000n});
            await x.wait();
        }

        // Begin a poker game with the players
        const receipt = await (await pkr.begin(addrs, 2)).wait();
        console.log('Begin gas', receipt.gasUsed);

        const st = new ScoreTree('./cache/scores');

        // Pass Begin events to all players game states
        for( const pa of player_accounts ) {
            pa.gs = GameState.from_receipt(st, receipt, pa.address);
        }

        const empty_proof_data : [BytesLike[], number, BytesLike[], number] = [[], 0, [], 0];

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

            let my_proof : [BytesLike[], number, BytesLike[], number];
            if( gs.round == 3 ) {
                // submit cards
                const bh = gs.best_hand;
                const p = st.proof(bh.hand);
                console.log(`   hand ${gs.round}, player ${pa.address}, submitting hand: ${p.hand} ${bh.kind} (${p.score})`);
                const hand_indices = bh.hand.map((_)=>'0x' + DECKIDX[_].toString(16).padStart(2, '0'));
                my_proof = [hand_indices, p.score, p.path, p.idx];
            }
            else {
                my_proof = empty_proof_data;
            }

            let p1 = await pa.contract.play(gs.game_id, gs.player_next_idx, 1, my_proof[0], my_proof[1], my_proof[2], my_proof[3]);
            let p2 = await p1.wait();

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

        console.log("\n");
        for( const pa of player_accounts ) {
            console.log(pa.address, pa.gs?.my_result);
        }

        /*
        // Now submit proofs of player cards
        console.log("\n\n\n\n");
        console.log('Next player', gs.player_next_idx);
        for( const ps of gs.player_states ) {
            const pa = players_by_addr[ps.address];
            console.log("Final Betting", ps.idx);
            st.proof()
        }
        */

        expect(true).to.be.eq(true);

        //const gs = new GameState();
    });
});

