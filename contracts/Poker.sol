// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

contract Poker {
    /*
    This implementation of Limit Texas Hold'em has the following rules:

     - Each game has a 'bet size', bets and raises are multiples of this.
     - Betting with a multiple of 0 is considered folding.
     - Each round the players can raise the bet multiplier to the maximum (3), or 'call' by keeping it at 1.
     - The multiplier resets at the end of the round.
     - The minimum amount won is (bet_size * 1.5), if everybody folds somebody will win by default
     - Player ordering & the card deck is shuffled at the beginning of the game
     - Every player must enter the game with (bet_size * 4) otherwise they will not be able to play a full game by placing the minimum bet at each round
     - The maximum amount won per game is (bet_size * 3 * 4)
        - Pre-flop, bet with knowledge of 2 cards
        - Flop, bet with knowledge of 5 cards
        - Turn, bet with knowledge of 6 cards
        - River, bet knowing all 7 cards
     - On the River players submit proof of their hands score from a pre-computed merkle tree with their bet
     - If a player takes too long to submit their turn, they can be forced to fold
    */

    uint8 private constant MAX_BET_MULTIPLIER = 3;

    uint8 private constant CARDS_PER_DECK = 52;

    uint8 private constant CARDS_PER_PLAYER = 2;

    uint8 private constant CARDS_PER_DEALER = 5;

    uint8 private constant MAX_PLAYERS = (CARDS_PER_DECK-CARDS_PER_DEALER-1) / CARDS_PER_PLAYER;

    uint8 private constant NO_NEXT_PLAYER = 0xFF;

    bytes1 private constant NO_CARD = 0xFF;

    uint256 private constant NO_HAND_SCORE = (1<<24)-1;

    event Created(uint256 game_id, address[] players, uint256 bet_size, uint8 max_bet_mul, uint8 player_start_idx, uint256 pot);

    event Hand(uint256 game_id, uint8 player_idx, bytes1[2] cards);

    event Round(uint256 game_id, uint8 round_idx, bytes1[3] cards, uint8 player_next_idx);

    event Bet(uint256 game_id, uint8 player_idx, uint8 multiplier, uint256 pot, uint8 player_next_idx);

    event Win(uint256 game_id, uint8 player_idx, uint256 payout);

    event Balance(uint256 bal);

    struct TablePlayer {
        address addr;
        bytes1[CARDS_PER_PLAYER] hand;
        uint256 score;
        bool folded;
    }

    struct Table {
        uint id;
        uint bet_size;
        uint pot;
        bytes1[CARDS_PER_DEALER] dealer;
        TablePlayer[] players;
        uint8 state_round;
        uint8 state_player;
        uint8 state_bet;
        uint8 player_count;
    }

    uint256 private g_game_counter;

    // Keeps payout rounding errors
    uint256 private g_dust;

    mapping(uint => Table) private g_tables;

    bytes32 immutable g_scoring_merkle_root;

    mapping(address => uint256) private g_balances;

    constructor (bytes32 scoring_merkle_root)
    {
        g_game_counter = 1;

        g_scoring_merkle_root = scoring_merkle_root;
    }

    // Dust cannot get trapped, but we don't care who harvests it
    function withdraw_dust()
        external
    {
        uint256 d = g_dust;

        if( d > 0 )
        {
            g_dust = 0;

            payable(msg.sender).transfer(d);
        }
    }

    function deposit()
        external payable
    {
        g_balances[msg.sender] += msg.value;
    }

    // Emitted event is public, must be obscured using single-use blinding value XOR with balance
    function balance(uint256 onetime_blinder)
        external
    {
        emit Balance(g_balances[msg.sender] ^ onetime_blinder);
    }

    function withdraw(uint256 max_amount)
        external
    {
        return withdraw(max_amount, payable(msg.sender));
    }

    function withdraw(uint256 max_amount, address payable withdraw_to)
        public
    {
        uint256 b = g_balances[msg.sender];

        if( b > 0 )
        {
            if( max_amount > b ) {
                max_amount = b;
            }

            g_balances[msg.sender] = max_amount;

            withdraw_to.transfer(max_amount);
        }
    }

    // Durstenfeld's version of Fisher-Yates shuffle
    // https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle
    function shuffle_deck(uint256 seed, uint8 k)
        private pure
        returns (bytes memory deck)
    {
        deck = new bytes(k);
        unchecked {
            for( uint8 i = 0; i < k; i++ ) {
                deck[i] = bytes1(i);
            }
            for( uint8 i = (k-1); i > 0; i-- ) {
                seed = uint256(keccak256(abi.encodePacked(seed)));
                uint8 j = uint8(seed % i);
                (deck[j], deck[i]) = (deck[i], deck[j]);
            }
        }
        return deck;
    }

    function shuffle_players_inplace(uint256 seed, address[] memory players)
        private pure
    {
        unchecked {
            for( uint i = (players.length-1); i > 0; i-- )
            {
                seed = uint256(keccak256(abi.encodePacked(seed)));
                uint8 j = uint8(seed % i);
                (players[j], players[i]) = (players[i], players[j]);
            }
        }
    }

    function _next_player_idx(TablePlayer[] storage players, uint8 start_i)
        internal view
        returns (uint8)
    {
        unchecked {
            for( uint8 i = start_i; i < players.length; i++ ) {
                if( true == players[i].folded ) {
                    continue;
                }
                return i;
            }
        }
        return NO_NEXT_PLAYER;
    }

    function begin(address[] memory players, uint bet_size)
        public
    {
        require( players.length > 1 );
        require( players.length < MAX_PLAYERS );

        uint game_id = g_game_counter;

        // TODO: replace shuffle seeds with randomly generated ones

        shuffle_players_inplace(game_id, players);

        uint8 players_length = uint8(players.length);

        bytes memory deck = shuffle_deck(game_id, CARDS_PER_DECK);

        Table storage t = g_tables[game_id];
        t.id = game_id;
        t.bet_size = bet_size;
        t.pot = (bet_size/2) + bet_size;
        t.state_round = 0;
        t.state_player = uint8(2 % players_length);
        t.state_bet = 1;
        t.player_count = uint8(players_length);

        emit Created(game_id, players, bet_size, MAX_BET_MULTIPLIER, t.state_player, t.pot);

        // Dealers cards end after player cards
        {
            uint dealer_offset = players_length * CARDS_PER_PLAYER;
            t.dealer = [
                deck[dealer_offset],
                deck[dealer_offset+1],
                deck[dealer_offset+2],
                deck[dealer_offset+3],
                deck[dealer_offset+4]
            ];

            for( uint8 i = 0; i < players_length; i++ )
            {
                uint player_offset = (i * CARDS_PER_PLAYER);

                bytes1[2] memory player_hand = [deck[player_offset], deck[player_offset + 1]];

                t.players.push(TablePlayer({
                    addr: players[i],
                    score: NO_HAND_SCORE,   // Lowest score wins
                    hand: player_hand,
                    folded: false
                }));

                emit Hand(game_id, i, player_hand);
            }
        }

        // TODO: subtract small & big blind from user balances

        g_tables[game_id] = t;

        g_game_counter += 1;
    }

    function _delete_game(Table storage t)
        private
    {
        TablePlayer[] storage players = t.players;

        uint players_length = players.length;

        for( uint i = 0; i < players_length; i++ )
        {
            delete players[i];
        }

        delete g_tables[t.id];
    }

    function _merkle_verify( bytes32 root, bytes32 leaf_hash, bytes32[] calldata path, uint256 index )
        private pure
        returns (bool)
    {
        bytes32 node = leaf_hash;
        uint256 path_length = path.length;

        for( uint256 i = 0; i < path_length; i++ )
        {
            if( 0 == (index & 1) ) {
                node = sha256(abi.encodePacked(node, path[i]));
            }
            else {
                node = sha256(abi.encodePacked(path[i], node));
            }

            index >>= 1;
        }

        return node == root;
    }

    // TODO: player can be forced to fold if taken too long...

    function play(
        uint game_id,
        uint8 player_idx,
        uint8 bet,
        bytes1[] calldata proof_hand,
        uint256 proof_score,
        bytes32[] calldata proof_path,
        uint24 proof_index
    )
        public
    {
        require( 0 != game_id );

        require( bet <= MAX_BET_MULTIPLIER );    // Bet is multiples, 0 = fold

        // Load game table
        Table storage t = g_tables[game_id];
        require( t.id == game_id );

        TablePlayer[] storage players = t.players;
        require( player_idx == t.state_player );

        TablePlayer storage player = players[player_idx];

        // Player must match bet multiple
        require( bet >= t.state_bet );

        // User provides proof of their hands score in final round
        if( 3 == t.state_round )
        {
            require( 0 != proof_path.length );

            require( CARDS_PER_DEALER == proof_hand.length );

            bytes memory leaf = abi.encodePacked(
                proof_hand[0],
                proof_hand[1],
                proof_hand[2],
                proof_hand[3],
                proof_hand[4],
                bytes1(uint8(proof_score&0xFF)),
                bytes1(uint8((proof_score>>8)&0xFF)));

            bytes32 leaf_hash = sha256(leaf);

            require( true == _merkle_verify(g_scoring_merkle_root, leaf_hash, proof_path, proof_index) );

            bytes1[CARDS_PER_DEALER+CARDS_PER_PLAYER] memory check_hand = [
                t.dealer[0],
                t.dealer[1],
                t.dealer[2],
                t.dealer[3],
                t.dealer[4],
                player.hand[0],
                player.hand[1]
            ];

            // Verify all cards in the proof hand exist in either dealer or player hands
            unchecked {
                uint256 hand_count = 0;

                for( uint i = 0; i < CARDS_PER_DEALER; i++ )
                {
                    for( uint j = 0; j < (CARDS_PER_DEALER+CARDS_PER_PLAYER); j++ )
                    {
                        if( check_hand[j] == proof_hand[i] )
                        {
                            hand_count += 1;
                        }
                        // SECURITY: don't break or continue, as gas usage could reveal which cards player has
                    }
                }

                // Proof must include all 4 hands
                require( CARDS_PER_DEALER == hand_count );
            }

            player.score = proof_score;
        }
        else {
            require( proof_hand.length == 0 );
            require( proof_index == 0 );
            require( proof_score == 0 );
        }

        // Subtract bet from balance, or force to fold if insufficient balance
        {
            uint256 bet_size = t.bet_size * bet;

            uint256 player_bal = g_balances[player.addr];

            if( player_bal < bet_size )
            {
                bet = 0;
                bet_size = 0;
            }
            else {
                g_balances[player.addr] = player_bal - bet_size;
            }

            // Increase pot and bet multiple
            t.pot += bet_size;
            t.state_bet = bet;
        }

        // Player folds
        if( 0 == bet )
        {
            player.folded = true;
            t.player_count -= 1;

            // Single remaining player wins by default
            if( 1 == t.player_count )
            {
                emit Bet(game_id, player_idx, bet, t.pot, NO_NEXT_PLAYER);

                uint256 winnings = t.pot;

                address winner = player.addr;

                _delete_game(t);

                emit Win(game_id, player_idx, winnings);

                g_balances[winner] += winnings;
            }
        }

        uint8 next_player_idx = _next_player_idx(players, player_idx+1);

        emit Bet(game_id, player_idx, bet, t.pot, next_player_idx);

        // When all players have acted this round
        if( NO_NEXT_PLAYER == next_player_idx )
        {
            uint8 round = t.state_round;

            t.state_player = next_player_idx = _next_player_idx(players, 0);

            if( 0 == round ) {
                emit Round(game_id, 1, [
                    t.dealer[0],
                    t.dealer[1],
                    t.dealer[2]
                ], next_player_idx);
            }
            else if( 1 == round ) {
                emit Round(game_id, 2, [t.dealer[3], NO_CARD, NO_CARD], next_player_idx);
            }
            else if( 2 == round ) {
                emit Round(game_id, 3, [t.dealer[4], NO_CARD, NO_CARD], next_player_idx);
            }
            else if( 3 == round ) {
                _perform_round3(game_id, t);
                _delete_game(t);
                return;
            }

            // Reset round
            t.state_round = round + 1;
            t.state_bet = 1;
        }
        else {
            t.state_player = next_player_idx;
        }
    }

    function _perform_round3(uint256 game_id, Table storage t)
        internal
    {
        (address[] memory player_addresses, uint256[] memory payouts, uint256 dust) = _winners(t.players, t.pot);

        uint8 payouts_length = uint8(payouts.length);

        for( uint8 i = 0; i < payouts_length; i++ )
        {
            uint256 po = payouts[i];

            emit Win(game_id, i, po);

            // All balances are modified to prevent on-chain analysis of winners
            g_balances[player_addresses[i]] += po;
        }

        g_dust += dust;
    }

    function _winners(TablePlayer[] storage players, uint256 pot)
        private view
        returns (
            address[] memory player_addresses,
            uint256[] memory payouts,
            uint256 dust
        )
    {
        uint8 players_length = uint8(players.length);

        uint lowest_score = NO_HAND_SCORE;

        uint lowest_count = 0;

        // Card comparison, users must have provided proof of their best in the previous round
        // If they don't provide proof, they won't win even if they have the best hand
        unchecked {
            for( uint i = 0; i < players_length; i++ )
            {
                TablePlayer storage x = players[i];
                uint x_score = x.score;

                if( x_score < lowest_score ) {
                    lowest_score = x_score;
                    lowest_count = 0;
                }

                if ( x_score == lowest_score ) {
                    lowest_count += 1;
                }
            }
        }

        require( lowest_count != 0 );

        // Payout is split equally between with the same lowest score
        // All other players get a zero payout

        payouts = new uint256[](players_length);

        player_addresses = new address[](players_length);

        uint256 winning_payout = pot / lowest_count;

        dust = pot - (winning_payout * lowest_count);

        unchecked {
            for( uint i = 0; i < players_length; i++ )
            {
                TablePlayer storage x = players[i];

                player_addresses[i] = x.addr;

                if( ! x.folded && x.score == lowest_score )
                {
                    payouts[i] = winning_payout;
                }
                else {
                    payouts[i] = 0;
                }
            }
        }
    }
}
