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
        t.pot = table.pot;
        t.tableinfo_packed = table.tableinfo_packed;

        for( uint i = 0; i < players.length; i++ ) {
            t.players[i] = playerinfo_pack(players[i]);
        }
    }


    function test1()
        public pure
    {
        TableInfo memory ti = TableInfo(32432423, 251,252,253,254,250,249);
        bytes memory deck = shuffle_deck(1, 5);
        uint256 res = tableinfo_pack(ti, deck);

        (TableInfo memory ti2, bytes memory deck2) = tableinfo_unpack(res);

        require( ti.bet_size == ti.bet_size );
        require( ti2.max_bet_mul == ti.max_bet_mul );
        require( ti2.state_round == ti.state_round );
        require( ti2.state_player == ti.state_player );
        require( ti2.state_bet == ti.state_bet );
        require( ti2.player_count == ti.player_count );
        require( ti2.last_action == ti.last_action );

        require( deck2[0] == deck[0] );
        require( deck2[1] == deck[1] );
        require( deck2[2] == deck[2] );
        require( deck2[3] == deck[3] );
        require( deck2[4] == deck[4] );
    }
}