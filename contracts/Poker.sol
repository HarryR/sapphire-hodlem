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

// ------------------------------------------------------------------
// Constants

    uint8 private constant MAX_BET_MULTIPLIER = 3;

    uint8 private constant CARDS_PER_DECK = 52;

    uint private constant CARDS_PER_PLAYER = 2;

    uint private constant CARDS_PER_DEALER = 5;

    uint private constant MAX_PLAYERS = (CARDS_PER_DECK-CARDS_PER_DEALER-1) / CARDS_PER_PLAYER;

    uint8 private constant NO_NEXT_PLAYER = 0xFF;

    bytes1 private constant NO_CARD = 0xFF;

    uint256 private constant NO_HAND_SCORE = (1<<24)-1;

// ------------------------------------------------------------------
// Events

    event Created(uint256 indexed game_id, address[] players, uint256 bet_size, uint8 max_bet_mul, uint8 player_start_idx, uint256 pot);

    event Hand(uint256 indexed game_id, uint8 player_idx, bytes1[2] cards);

    event Round(uint256 indexed game_id, uint8 round_idx, bytes1[3] cards, uint8 player_next_idx);

    event Bet(uint256 indexed game_id, uint8 player_idx, uint8 multiplier, uint256 pot, uint8 player_next_idx);

    event Win(uint256 indexed game_id, uint8 player_idx, uint256 payout);

    event Balance(address indexed player, uint256 bal, bytes32 x);

// ------------------------------------------------------------------
// Structures & more efficient packing of said structures

    struct TablePlayer {
        address addr;
        bytes1[CARDS_PER_PLAYER] hand;  // XXX: does this need to be packed?
        uint256 score;
        bool folded;
    }

    function playerinfo_pack(TablePlayer memory p)
        private pure
        returns (uint256 res)
    {
        unchecked {
            res += uint8(p.hand[0]);

            res <<= 8;
            res += uint8(p.hand[1]);

            res <<= 24;
            res += uint(p.score);

            res <<= 8;
            res += uint(p.folded?1:0);

            res <<= 160;
            res += uint160(p.addr);
        }
    }

    function playerinfo_unpack(uint256 packed, TablePlayer memory p)
        private pure
    {
        unchecked {
            p.addr = address(uint160(packed & ((1<<160)-1)));
            packed >>= 160;

            p.folded = (packed & 0xFF)!=0?true:false;
            packed >>= 8;

            p.score = uint24(packed&((1<<24)-1));
            packed >>= 24;

            p.hand[1] = bytes1(uint8(packed&0xFF));
            packed >>= 8;

            p.hand[0] = bytes1(uint8(packed&0xFF));
        }
    }

    function bytes_unpack(uint256 packed, uint n_cards)
        private pure
        returns (bytes memory cards)
    {
        cards = new bytes(n_cards);
        for( uint i = 0; i < n_cards; i++ ) {
            cards[i] = bytes1(uint8(packed & 0xFF));
            packed >>= 8;
        }
    }

    function bytes_pack(bytes memory cards, uint n_cards)
        private pure
        returns (uint256 packed)
    {
        // NOTE: must pack so unpacking retrieves in same indexed order
        // Going from card 0 to card n results in card n coming out first

        uint i = n_cards;
        while( i-- != 0 ) {
            packed <<= 8;
            packed = packed + uint8(cards[i]);
            if( i == 0 ) {
                break;
            }
        }
    }

    struct Table {
        uint bet_size;
        uint pot;
        uint256 dealer;
        uint256[] players;
        uint8 state_round;
        uint8 state_player;
        uint8 state_bet;
        uint8 player_count;
    }

    struct ProofData {
        bytes hand;
        uint score;
        bytes32[] path;
        uint24 index;
    }

// ------------------------------------------------------------------
// Contract storage

    uint256 private g_game_counter;

    // Keeps payout rounding errors
    uint256 private g_dust;

    mapping(uint => Table) private g_tables;

    bytes32 immutable g_scoring_merkle_root;

    mapping(address => uint256) private g_balances;

    bytes32 g_secret_seed;

// ------------------------------------------------------------------
// Oasis Sapphire specific code

    address private constant RANDOM_BYTES = 0x0100000000000000000000000000000000000001;

    function _random_bytes32()
        internal view
        returns (bytes32)
    {
        // XXX: is personalization necessary here?
        bytes memory p13n = abi.encodePacked(block.chainid, block.number, block.timestamp, msg.sender, address(this));

        (bool success, bytes memory entropy) = RANDOM_BYTES.staticcall(
            abi.encode(uint256(32), p13n)
        );

        require( success );

        return keccak256(abi.encodePacked(bytes32(entropy)));
    }

// ------------------------------------------------------------------
// Limit Hodl'em Poker implementation

    constructor (bytes32 scoring_merkle_root)
    {
        g_game_counter = 1;

        g_scoring_merkle_root = scoring_merkle_root;

        g_secret_seed = _random_bytes32();
    }

    function cycle_seed(uint256 game_id)
        private
        returns (uint256 y)
    {
        bytes32 x = g_secret_seed;

        y = uint256(keccak256(abi.encodePacked(x, game_id)));

        g_secret_seed = keccak256(abi.encodePacked(x, y));
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

    function deposit(address to)
        external payable
    {
        g_balances[to] += msg.value;
    }

    function deposit()
        external payable
    {
        g_balances[msg.sender] += msg.value;
    }

    // Emitted event is public, must be obscured using single-use blinding value XOR with balance
    // Hash of blinder is provided for reference when user scans blockchain to find their balances
    function balance(uint256 onetime_blinder)
        external
    {
        emit Balance(msg.sender, g_balances[msg.sender] ^ onetime_blinder, keccak256(abi.encodePacked(onetime_blinder)));
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
            for( uint i = (k-1); i > 0; i-- ) {
                seed = uint256(keccak256(abi.encodePacked(seed)));
                uint j = seed % i;
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
                uint j = seed % i;
                (players[j], players[i]) = (players[i], players[j]);
            }
        }
    }

    function _next_player_idx(TablePlayer[] memory players, uint start_i)
        private pure
        returns (uint)
    {
        unchecked {
            for( uint i = start_i; i < players.length; i++ ) {
                if( true == players[i].folded ) {
                    continue;
                }
                return i;
            }
        }
        return NO_NEXT_PLAYER;
    }

    function begin(address[] memory players, uint bet_size)
        external
    {
        require( players.length > 1 );
        require( players.length < MAX_PLAYERS );

        uint game_id = g_game_counter;

        shuffle_players_inplace(cycle_seed(game_id), players);

        uint players_length = uint8(players.length);

        Table storage t = g_tables[game_id];
        t.bet_size = bet_size;
        t.pot = (bet_size/2) + bet_size;
        t.state_round = 0;
        t.state_bet = 1;
        unchecked {
            t.state_player = uint8(2 % players_length);
            t.player_count = uint8(players_length);
        }

        emit Created(game_id, players, bet_size, MAX_BET_MULTIPLIER, t.state_player, t.pot);

        unchecked {
            bytes memory deck = shuffle_deck(cycle_seed(game_id), CARDS_PER_DECK);

            t.dealer = bytes_pack(deck, CARDS_PER_DEALER);

            for( uint i = 0; i < players_length; i++ )
            {
                uint player_offset = CARDS_PER_DEALER + (i * CARDS_PER_PLAYER);

                bytes1[2] memory player_hand = [deck[player_offset], deck[player_offset + 1]];

                t.players.push(playerinfo_pack(TablePlayer({
                    addr: players[i],
                    score: NO_HAND_SCORE,   // Lowest score wins
                    hand: player_hand,
                    folded: false
                })));

                emit Hand(game_id, uint8(i), player_hand);
            }
        }

        g_balances[players[0]] -= bet_size / 2;

        g_balances[players[1]] -= bet_size;

        g_tables[game_id] = t;

        g_game_counter += 1;
    }

    function _delete_game(uint game_id, Table storage t, uint players_length)
        private
    {
        uint256[] storage players = t.players;

        unchecked {
            for( uint i = 0; i < players_length; i++ ) {
                delete players[i];
            }
        }

        delete g_tables[game_id];
    }

    function _merkle_verify( bytes32 root, bytes32 leaf_hash, bytes32[] calldata path, uint256 index )
        private pure
        returns (bool)
    {
        bytes32 node = leaf_hash;

        unchecked {
            for( uint256 i = 0; i < path.length; i++ )
            {
                if( 0 == (index & 1) ) {
                    node = sha256(abi.encodePacked(node, path[i]));
                }
                else {
                    node = sha256(abi.encodePacked(path[i], node));
                }

                index >>= 1;
            }
        }

        return node == root;
    }

    // TODO: player can be forced to fold if taken too long...

    function play(
        uint game_id,
        uint8 player_idx,
        uint8 bet,
        ProofData calldata proof
    )
        external
    {
        require( 0 != game_id );

        require( bet <= MAX_BET_MULTIPLIER );    // Bet is multiples, 0 = fold

        // Load game table
        Table storage t = g_tables[game_id];
        require( t.bet_size != 0 );
        require( t.state_player == player_idx );
        require( bet >= t.state_bet );  // Player must match bet multiple

        // Load players into memory, rather than accessing storage every time
        TablePlayer[] memory players = new TablePlayer[](t.players.length);
        unchecked {
            for( uint i = 0; i < players.length; i++ ) {
                playerinfo_unpack(t.players[i], players[i]);
            }
        }
        TablePlayer memory player = players[player_idx];

        // User provides proof of their hands score in final round
        // If proof isn't provided they can't win!
        if( 0 != proof.path.length )
        {
            require( 3 == t.state_round );

            require( 0 != proof.path.length );

            require( CARDS_PER_DEALER == proof.hand.length );

            unchecked {
                bytes32 leaf_hash = sha256(abi.encodePacked(
                    proof.hand,
                    bytes1(uint8(proof.score&0xFF)),
                    bytes1(uint8((proof.score>>8)&0xFF))));

                require( true == _merkle_verify(g_scoring_merkle_root, leaf_hash, proof.path, proof.index) );

                bytes memory dealer_cards = bytes_unpack(t.dealer, 5);

                // Verify all cards in the proof hand exist in either dealer or player hands
                uint256 hand_count = 0;

                for( uint i = 0; i < CARDS_PER_DEALER; i++ )
                {
                    for( uint j = 0; j < CARDS_PER_DEALER; j++ )
                    {
                        if( dealer_cards[j] == proof.hand[i] ) {
                            hand_count += 1;
                        }
                    }
                    for( uint j = 0; j < CARDS_PER_PLAYER; j++ ) {
                        if( player.hand[j] == proof.hand[i] ) {
                            hand_count += 1;
                        }
                    }
                }

                // Proof must include all 4 hands
                require( CARDS_PER_DEALER == hand_count );
            }

            player.score = proof.score & 0xFFFF;
            t.players[player_idx] = playerinfo_pack(player);
        }
        else {
            require( proof.hand.length == 0 );
            require( proof.index == 0 );
            require( proof.score == 0 );
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

        uint256 table_pot = t.pot;

        // Player folds
        if( 0 == bet )
        {
            player.folded = true;
            t.players[player_idx] = playerinfo_pack(player);

            t.player_count -= 1;

            // Single remaining player wins by default
            if( 1 == t.player_count )
            {
                emit Bet(game_id, player_idx, bet, table_pot, NO_NEXT_PLAYER);

                uint winning_player_idx = _next_player_idx(players, 0);

                require( winning_player_idx != NO_NEXT_PLAYER );

                emit Win(game_id, uint8(winning_player_idx), table_pot);

                g_balances[players[winning_player_idx].addr] += table_pot;

                _delete_game(game_id, t, players.length);

                return;
            }
        }

        uint8 next_player_idx = uint8(_next_player_idx(players, player_idx+1));

        emit Bet(game_id, player_idx, bet, table_pot, next_player_idx);

        // When all players have acted this round
        if( NO_NEXT_PLAYER == next_player_idx )
        {
            uint8 round = t.state_round;

            bytes memory dealer_cards = bytes_unpack(t.dealer, 5);

            t.state_player = next_player_idx = uint8(_next_player_idx(players, 0));

            if( 0 == round ) {
                emit Round(game_id, 1, [
                    dealer_cards[0],
                    dealer_cards[1],
                    dealer_cards[2]
                ], next_player_idx);
            }
            else if( 1 == round ) {
                emit Round(game_id, 2, [dealer_cards[3], NO_CARD, NO_CARD], next_player_idx);
            }
            else if( 2 == round ) {
                emit Round(game_id, 3, [dealer_cards[4], NO_CARD, NO_CARD], next_player_idx);
            }
            else if( 3 == round ) {
                _perform_round3(game_id, table_pot, players);
                _delete_game(game_id, t, players.length);
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

    function _perform_round3(uint256 game_id, uint table_pot, TablePlayer[] memory players)
        private
    {
        (address[] memory player_addresses, uint256[] memory payouts, uint256 dust) = _winners(players, table_pot);

        for( uint i = 0; i < payouts.length; i++ )
        {
            uint256 po = payouts[i];

            emit Win(game_id, uint8(i), po);

            // All balances are modified to prevent on-chain analysis of winners
            g_balances[player_addresses[i]] += po;
        }

        g_dust += dust;
    }

    function _winners(TablePlayer[] memory players, uint256 pot)
        private pure
        returns (
            address[] memory player_addresses,
            uint256[] memory payouts,
            uint256 dust
        )
    {
        uint players_length = players.length;

        uint lowest_score = NO_HAND_SCORE;

        uint lowest_count = 0;

        // Card comparison, users must have provided proof of their best in the previous round
        // If they don't provide proof, they won't win even if they have the best hand
        unchecked {
            for( uint i = 0; i < players_length; i++ )
            {
                TablePlayer memory x = players[i];
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
                TablePlayer memory x = players[i];

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
