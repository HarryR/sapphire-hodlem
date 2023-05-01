// SPDX-License-Identifier: AGPL-3
pragma solidity ^0.8.0;

import "../Poker.sol";

contract TestablePoker is Poker
{
    constructor (bytes32 scoring_merkle_root)
        Poker(scoring_merkle_root)
    {
        g_secret_seed = bytes32(uint256(4));
    }

    event DumpEvent(Table t, TablePlayer[] p, bytes b);

    function dump_state( uint game_id )
        public
    {
        Table storage t = g_tables[game_id];
        TablePlayer[] memory players = _load_players(t);

        emit DumpEvent(t, players, abi.encode(t, players));
    }

    function load_state(bytes calldata state, uint game_id)
        public
    {
        Table memory table; // = g_tables[game_id];
        TablePlayer[] memory players;

        (table, players) = abi.decode(state, (Table, TablePlayer[]));

        Table storage t = g_tables[game_id];
        t.bet_size = table.bet_size;
        t.pot = table.pot;
        t.dealer = table.dealer;
        t.max_bet_mul = table.max_bet_mul;
        t.state_round = table.state_round;
        t.state_player = table.state_player;
        t.state_bet = table.state_bet;
        t.player_count = table.player_count;
        t.last_action = table.last_action;

        for( uint i = 0; i < players.length; i++ ) {
            t.players[i] = playerinfo_pack(players[i]);
        }
    }
}