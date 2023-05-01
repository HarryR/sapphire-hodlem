// SPDX-License-Identifier: AGPL-3
pragma solidity ^0.8.0;

// ------------------------------------------------------------------
// Utilities for handling uint256 as a packed byte array

function byte_get(uint256 x, uint off)
    pure
    returns (uint)
{
    unchecked {
        return (x >> (off*8)) & 0xFF;
    }
}

function byte_set(uint256 x, uint off, uint val)
    pure
    returns (uint256)
{
    unchecked {
        off *= 8;
        uint z = x & (0xFF << off);
        return (x ^ z) | ((val&0xFF) << off);
    }
}

function bytes_unpack(uint256 packed, uint n_cards)
    pure
    returns (bytes memory cards)
{
    unchecked {
        cards = new bytes(n_cards);
        for( uint i = 0; i < n_cards; i++ ) {
            cards[i] = bytes1(uint8(packed & 0xFF));
            packed >>= 8;
        }
    }
}

function bytes_pack(bytes memory cards, uint n_cards)
    pure
    returns (uint256 packed)
{
    // NOTE: must pack so unpacking retrieves in same indexed order
    // Going from card 0 to card n results in card n coming out first

    unchecked {
        uint i = n_cards;
        while( i-- != 0 ) {
            packed <<= 8;
            packed = packed + uint8(cards[i]);
            if( i == 0 ) {
                break;
            }
        }
    }
}

// ------------------------------------------------------------------
// Handling the player / table queue

uint constant QUEUE_COUNT = 32;
uint constant PLAYERS_PER_QUEUE = 6;
uint constant NOT_IN_QUEUE = 0;

struct Queue {
    address[PLAYERS_PER_QUEUE] players;
    uint256 count;
}

struct QueueManager {
    Queue[QUEUE_COUNT] queues;
    mapping(address => uint256) player_queues;
}

// ------------------------------------------------------------------

contract Poker {
// ------------------------------------------------------------------
// Constants

    uint internal constant SCORE_BITMASK = 0xFFFF;

    uint8 internal constant MAX_BET_MULTIPLIER = 3;

    uint internal constant FORCE_FOLD_AFTER_N_SECONDS = 360;

    uint8 internal constant CARDS_PER_DECK = 52;

    uint internal constant CARDS_PER_PLAYER = 2;

    uint internal constant CARDS_PER_DEALER = 5;

    //uint internal constant MAX_PLAYERS = (CARDS_PER_DECK-CARDS_PER_DEALER-1) / CARDS_PER_PLAYER;
    uint internal constant MAX_PLAYERS = 5;

    uint8 internal constant NO_NEXT_PLAYER = 0xFF;

    bytes1 internal constant NO_CARD = 0xFF;

    uint256 internal constant NO_HAND_SCORE = (1<<24)-1;

// ------------------------------------------------------------------
// Events

    event Preset(uint256 preset_id, uint256 preset);

    event Created(uint256 indexed game_id, address[] players, uint256 bet_size, uint max_bet_mul, uint player_start_idx, uint256 pot);

    event Hand(uint256 indexed game_id, uint8 player_idx, bytes1[2] cards);

    event Round(uint256 indexed game_id, uint8 round_idx, bytes1[3] cards, uint8 player_next_idx);

    event Bet(uint256 indexed game_id, uint player_idx, uint8 multiplier, uint256 pot, uint8 player_next_idx);

    event Win(uint256 indexed game_id, uint8 player_idx, uint256 payout);

    event End(uint256 indexed game_id);

    event Balance(address indexed player, uint256 bal);

// ------------------------------------------------------------------
// Structures & more efficient packing of said structures

    struct TablePlayer {
        address addr;
        bytes1[CARDS_PER_PLAYER] hand;  // XXX: does this need to be packed?
        uint256 score;
        bool folded;
    }

    struct TableInfo {
        uint bet_size;      // 144 bits
        uint max_bet_mul;   // 8 bits
        uint state_round;   // 8 bits
        uint state_player;  // 8 bits
        uint state_bet;     // 8 bits
        uint player_count;  // 8 bits
        uint last_action;   // 32 bits, block.timestmap
    }

    struct Table {
        uint pot;
        uint256 tableinfo_packed;
        uint256[MAX_PLAYERS] players;
    }

    function tableinfo_pack(TableInfo memory t, bytes memory deck)
        internal pure
        returns (uint256 res)
    {
        res = 0;

        uint sh8 = 8;

        unchecked {
            for( uint i = 0; i < 5; i++ ) {
                res += uint8(deck[i]);
                res <<= sh8;
            }

            res += t.max_bet_mul;

            res <<= sh8;
            res += t.state_round;

            res <<= sh8;
            res += t.state_player;

            res <<= sh8;
            res += t.state_bet;

            res <<= sh8;
            res += t.player_count;

            res <<= 32;
            res += t.last_action;

            res <<= 144;
            res += t.bet_size;
        }
    }

    // Packs table info into 14 bytes (112 bits), allowing 18 bytes (144 bits) for bet_size
    function tableinfo_unpack(uint256 res)
        internal pure
        returns (TableInfo memory t, bytes memory deck)
    {
        uint sh8 = 8;
        uint ff = 0xFF;

        unchecked {
            uint bet_size = res & ((1<<144)-1);
            res >>= 144;

            uint last_action = res & 0xFFFFFFFF;
            res >>= 32;

            uint player_count = res & ff;
            res >>= sh8;

            uint state_bet = res & ff;
            res >>= sh8;

            uint state_player = res & ff;
            res >>= sh8;

            uint state_round = res & ff;
            res >>= sh8;

            uint max_bet_mul = res & ff;
            res >>= sh8;

            t = TableInfo(bet_size, max_bet_mul, state_round, state_player, state_bet, player_count, last_action);

            deck = new bytes(5);

            deck[4] = bytes1(uint8(res & ff));
            res >>= sh8;

            deck[3] = bytes1(uint8(res & ff));
            res >>= sh8;

            deck[2] = bytes1(uint8(res & ff));
            res >>= sh8;

            deck[1] = bytes1(uint8(res & ff));
            res >>= sh8;

            deck[0] = bytes1(uint8(res & ff));
            res >>= sh8;
        }
    }

    struct ProofData {
        bytes hand;
        uint score;
        bytes32[] path;
        uint24 index;
    }

    function playerinfo_pack(TablePlayer memory p)
        internal pure
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
        internal pure
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

// ------------------------------------------------------------------
// Contract storage

    uint256 internal g_game_counter;

    mapping(uint => Table) internal g_tables;

    bytes32 immutable internal g_scoring_merkle_root;

    mapping(address => uint256) internal g_balances;

    bytes32 internal g_secret_seed;

    QueueManager internal g_qm;

    uint256[QUEUE_COUNT] internal g_game_presets;

// ------------------------------------------------------------------
// Oasis Sapphire specific code

    address internal constant RANDOM_BYTES = 0x0100000000000000000000000000000000000001;

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

    constructor (bytes32 scoring_merkle_root)
    {
        g_game_counter = 1;

        g_scoring_merkle_root = scoring_merkle_root;

        g_secret_seed = _random_bytes32();
    }

    function presets_get()
        external
    {
        for( uint i = 0; i < QUEUE_COUNT; i++ )
        {
            uint preset = g_game_presets[i];

            if( preset != 0 )
            {
                emit Preset(i, preset);
            }
        }
    }

    // TODO: restrict to Manager DAO?
    function preset_change(uint256 preset_id, uint8 max_bet_mul, uint256 bet_size)
        external
    {
        require( 0 == g_qm.queues[preset_id].count );

        unchecked {
            require( bet_size < (1<<144) );

            uint preset = (bet_size << 8) | max_bet_mul;

            g_game_presets[preset_id] = preset;

            emit Preset(preset_id, preset);
        }
    }

    function cycle_seed(uint256 game_id)
        internal
        returns (uint256 y)
    {
        bytes32 x = g_secret_seed;

        y = uint256(keccak256(abi.encodePacked(game_id, x)));

        g_secret_seed = keccak256(abi.encodePacked(y, x));
    }

// ------------------------------------------------------------------
// Account balance utilities

    function deposit(address to)
        public payable
        returns (uint256)
    {
        require( msg.sender != address(0) );

        uint256 b = g_balances[to] + msg.value;

        g_balances[to] = b;

        if( msg.sender == to ) {
            return b;
        }

        return 0; // Don't reveal others balances
    }

    function deposit()
        public payable
        returns (uint256)
    {
        return deposit(msg.sender);
    }

    function balance()
        external
    {
        require( msg.sender != address(0) );

        emit Balance(msg.sender, g_balances[msg.sender]);
    }

    function withdraw(uint256 max_amount)
        external
    {
        return withdraw(max_amount, payable(msg.sender));
    }

    function withdraw(uint256 max_amount, address payable withdraw_to)
        public
    {
        require( msg.sender != address(0) );

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

// ------------------------------------------------------------------
// Queued entry mechanics

    event Queue_Leave(address indexed player, uint qid, uint bet_size, uint max_bet_mul);

    event Queue_Join(address indexed player, uint qid, uint bet_size, uint max_bet_mul);

    error Queue_Full();

    error Queue_Invalid_Id();

    error Queue_Not_Member();

    error Queue_No_Position();

    function queue_remove_position(Queue storage q, uint qid, uint position)
        internal
        returns (address player)
    {
        uint count = q.count;

        if( count == 0 || position >= count ) {
            return address(0);
        }

        unchecked {
            count -= 1;
        }

        player = q.players[position];

        if( position != count ) {
            // Shuffle end of queue into their position
            address moving_player = q.players[count];

            q.players[position] = moving_player;

            unchecked {
                g_qm.player_queues[moving_player] = byte_set(g_qm.player_queues[moving_player], qid, position + 1 );
            }
        }

        q.count = count;

        g_qm.player_queues[player] = byte_set(g_qm.player_queues[player], qid, NOT_IN_QUEUE);
    }

    function queue_add(Queue storage q, uint qid, address player)
        internal
        returns (uint count)
    {
        uint256 player_queue_positions = g_qm.player_queues[player];

        count = byte_get(player_queue_positions, qid);

        if( NOT_IN_QUEUE != count ) {
            unchecked {
                return count - 1;
            }
        }

        count = q.count;

        if( count == PLAYERS_PER_QUEUE ) {
            revert Queue_Full();
        }

        q.players[count] = player;

        unchecked {
            count += 1;
        }

        q.count = count;

        g_qm.player_queues[player] = byte_set(player_queue_positions, qid, count);
    }

    // accept_minimum = lowest number of players user will accept to play with
    function join(uint preset_id, uint accept_minimum)
        external payable
    {
        require( msg.sender != address(0) );

        uint preset = g_game_presets[preset_id];

        require( preset != 0 );

        uint min_balance;
        uint max_bet_mul;
        uint bet_size;
        unchecked {
            max_bet_mul = preset & 0xFF;
            bet_size = preset >> 8;
            min_balance = (bet_size * max_bet_mul);
            require( deposit() >= min_balance );
        }

        uint max_players = MAX_PLAYERS;
        uint min_players = 2;

        if( accept_minimum < min_players || accept_minimum > max_players ) {
            accept_minimum = max_players;
        }

        Queue storage q = g_qm.queues[preset_id];

        uint qc = queue_add(q, preset_id, msg.sender);

        if( qc >= accept_minimum )
        {
            address[] memory players = new address[](max_players);
            uint player_count = 0;

            unchecked {
                while( q.count != 0 )
                {
                    address player_addr = queue_remove_position(q, preset_id, 0);
                    if( player_addr == address(0) ) {
                        // Queue is now empty
                        break;
                    }

                    // eject from queue if Insufficient minimum balance
                    if( g_balances[player_addr] < min_balance ) {
                        // TODO: put a hold on the minimum balance for the game upon joining the queue
                        //       which is released upon leaving the queue
                        //       this prevents queue griefing, and ensures everybody who joins the queue can see the flop
                        emit Queue_Leave(player_addr, preset_id, bet_size, max_bet_mul);
                        continue;
                    }
                    players[player_count] = player_addr;
                    player_count += 1;
                }
            }

            require( player_count >= min_players );

            begin(players, player_count, bet_size, max_bet_mul);
        }
        else {
            emit Queue_Join(msg.sender, preset_id, bet_size, max_bet_mul);
        }
    }

    function leave(uint preset_id)
        external
    {
        require( msg.sender != address(0) );

        uint position = byte_get(g_qm.player_queues[msg.sender], preset_id);

        if( NOT_IN_QUEUE == position ) {
            revert Queue_Not_Member();
        }

        Queue storage q = g_qm.queues[preset_id];

        // Player position has 1 added, so 0 means 'not in queue', but queues themselves are 0 indexed
        unchecked {
            position -= 1;
        }

        queue_remove_position(q, preset_id, position);

        uint preset = g_game_presets[preset_id];
        uint max_bet_mul = preset & 0xFF;
        uint bet_size = preset >> 8;

        emit Queue_Leave(msg.sender, preset_id, bet_size, max_bet_mul);
    }

// ------------------------------------------------------------------
// Limit Hodl'em Poker implementation

    // Durstenfeld's version of Fisher-Yates shuffle
    // https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle
    function shuffle_deck(uint256 seed, uint k)
        internal pure
        returns (bytes memory deck)
    {
        require( k < 32 );
        deck = new bytes(k);
        unchecked {
            uint bt = 0;
            uint sc = 0;
            while( sc < k ) {
                uint j = seed % 52;
                uint n = 1<<j;
                seed >>= 8;
                if( bt & n != 0 ) {
                    continue;
                }
                deck[sc] = bytes1(uint8(j));
                bt |= n;
                sc += 1;
            }
        }
        return deck;
    }

    function shuffle_players_inplace(uint256 seed, address[] memory players, uint players_count)
        internal pure
    {
        unchecked {
            for( uint i = (players_count-1); i > 0; i-- )
            {
                uint j = seed % i;
                (players[j], players[i]) = (players[i], players[j]);
                seed >>= 8;
            }
        }
    }

    function _next_player_idx(TablePlayer[] memory players, uint start_i)
        internal pure
        returns (uint)
    {
        unchecked {
            for( uint i = start_i; i < players.length; i++ ) {
                if( false != players[i].folded ) {
                    continue;
                }
                return i;
            }
        }
        return NO_NEXT_PLAYER;
    }

    function begin(address[] memory players, uint players_length, uint bet_size, uint max_bet_mul)
        internal
    {
        require( players_length > 1 );
        require( players_length <= MAX_PLAYERS );

        uint game_id = g_game_counter;

        shuffle_players_inplace(cycle_seed(game_id), players, players_length);

        Table storage t = g_tables[game_id];
        TableInfo memory ti = TableInfo({
            bet_size: bet_size,
            max_bet_mul: max_bet_mul,
            state_round: 0,
            state_player: uint8(2 % players_length),
            state_bet: 1,
            player_count: players_length,
            last_action: block.timestamp
        });
        t.pot = (bet_size/2) + bet_size;

        bytes memory deck = shuffle_deck(cycle_seed(game_id), CARDS_PER_DEALER + (players_length * CARDS_PER_PLAYER));

        t.tableinfo_packed = tableinfo_pack(ti, deck);

        emit Created(game_id, players, bet_size, max_bet_mul, ti.state_player, t.pot);

        for( uint i = 0; i < players_length; i++ )
        {
            uint player_offset = CARDS_PER_DEALER + (i * CARDS_PER_PLAYER);

            bytes1[2] memory player_hand = [deck[player_offset], deck[player_offset + 1]];

            t.players[i] = playerinfo_pack(TablePlayer({
                addr: players[i],
                score: NO_HAND_SCORE,   // Lowest score wins
                hand: player_hand,
                folded: false
            }));

            emit Hand(game_id, uint8(i), player_hand);
        }

        g_balances[players[0]] -= bet_size / 2;

        g_balances[players[1]] -= bet_size;

        g_tables[game_id] = t;

        g_game_counter += 1;
    }

    function _delete_game(uint game_id, Table storage t)
        internal
    {
        unchecked {
            for( uint i = 0; i < MAX_PLAYERS; i++ )  {
                delete t.players[i];
            }
        }

        delete g_tables[game_id];

        emit End(game_id);
    }

    function _merkle_verify( bytes32 root, bytes32 leaf_hash, bytes32[] memory path, uint256 index )
        internal pure
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

    // Player can be forced to fold if they take too long, any player can trigger this
    function force2fold(uint game_id)
        external
    {
        Table storage t = g_tables[game_id];
        uint tableinfo_packed = t.tableinfo_packed;
        require( 0 != tableinfo_packed );

        (TableInfo memory ti, bytes memory deck) = tableinfo_unpack(tableinfo_packed);

        require( block.timestamp >= (ti.last_action + FORCE_FOLD_AFTER_N_SECONDS) );

        play(game_id, ti.state_player, 0, ProofData("", 0, new bytes32[](0), 0));
    }

    function _load_players(Table storage t)
        internal view
        returns (TablePlayer[] memory players)
    {
        unchecked {
            players = new TablePlayer[](MAX_PLAYERS);
            uint i;
            for( i = 0; i < MAX_PLAYERS; i++ ) {
                uint256 pi = t.players[i];
                if( pi == 0 ) {
                    break;
                }
                playerinfo_unpack(pi, players[i]);
            }
            // Override players.length
            assembly {
                mstore(players, i)
            }
        }
    }

    function play(
        uint game_id,
        uint player_idx,
        uint8 bet,
        ProofData memory proof
    )
        public
    {
        // Load game table
        Table storage t = g_tables[game_id];
        uint tableinfo_packed = t.tableinfo_packed;
        require( tableinfo_packed != 0 );

        (TableInfo memory ti, bytes memory dealer_cards) = tableinfo_unpack(t.tableinfo_packed);                // Ensure game exists

        // Ensure correct game state
        require( ti.state_player == player_idx );
        require( 0 == bet || bet >= ti.state_bet );  // Fold or meet minimum round bet size
        require( bet <= ti.max_bet_mul );            // Do not exceed maximum bet

        // Load players into memory, rather than accessing storage every time
        TablePlayer[] memory players = _load_players(t);
        TablePlayer memory player = players[player_idx];

        // User provides proof of their hands score in final round
        // If proof isn't provided they can't win!
        if( 0 != proof.path.length )
        {
            require( 3 == ti.state_round );

            require( 0 != proof.path.length );

            require( CARDS_PER_DEALER == proof.hand.length );

            unchecked {
                bytes32 leaf_hash = sha256(abi.encodePacked(
                    proof.hand,
                    bytes1(uint8(proof.score&0xFF)),
                    bytes1(uint8((proof.score>>8)&0xFF))));

                require( true == _merkle_verify(g_scoring_merkle_root, leaf_hash, proof.path, proof.index) );

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

            player.score = proof.score & SCORE_BITMASK;
            t.players[player_idx] = playerinfo_pack(player);
        }
        else {
            require( proof.hand.length == 0 );
            require( proof.index == 0 );
            require( proof.score == 0 );
        }

        // Subtract bet from balance, or force to fold if insufficient balance
        if( ti.bet_size != 0 )
        {
            uint256 bet_amount = ti.bet_size * bet;

            uint256 player_bal = g_balances[player.addr];

            if( player_bal < bet_amount )
            {
                bet = 0;
                bet_amount = 0;
            }
            else {
                g_balances[player.addr] = player_bal - bet_amount;
                // Increase pot and bet multiple
                t.pot += bet_amount;
                ti.state_bet = bet;
            }
        }

        uint256 table_pot = t.pot;

        // Player folds
        if( 0 == bet )
        {
            player.folded = true;
            t.players[player_idx] = playerinfo_pack(player);

            ti.player_count -= 1;

            // Single remaining player wins by default
            if( 1 == ti.player_count )
            {
                emit Bet(game_id, player_idx, bet, table_pot, NO_NEXT_PLAYER);

                _perform_round3(game_id, table_pot, players);

                _delete_game(game_id, t);

                return;
            }
        }

        uint8 next_player_idx = uint8(_next_player_idx(players, player_idx+1));

        emit Bet(game_id, player_idx, bet, table_pot, next_player_idx);

        // When all players have acted this round
        if( NO_NEXT_PLAYER == next_player_idx )
        {
            uint round = ti.state_round;

            ti.state_player = next_player_idx = uint8(_next_player_idx(players, 0));

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
                _delete_game(game_id, t);
                return;
            }

            // Reset round
            unchecked {
                ti.state_round = round + 1;
                ti.state_bet = 1;
            }
        }
        else {
            ti.state_player = next_player_idx;
        }

        ti.last_action = uint32(block.timestamp);

        t.tableinfo_packed = tableinfo_pack(ti, dealer_cards);
    }

    function _perform_round3(uint256 game_id, uint table_pot, TablePlayer[] memory players)
        internal
    {
        (address[] memory player_addresses, uint256[] memory payouts) = _winners(players, table_pot);

        for( uint i = 0; i < payouts.length; i++ )
        {
            uint256 po = payouts[i];

            emit Win(game_id, uint8(i), po);

            // All balances are modified to prevent on-chain analysis of winners
            g_balances[player_addresses[i]] += po;
        }
    }

    function _winners(TablePlayer[] memory players, uint256 pot)
        internal pure
        returns (
            address[] memory player_addresses,
            uint256[] memory payouts
        )
    {
        uint256 dust;

        uint lowest_score = NO_HAND_SCORE;

        uint lowest_count = 0;

        // Card comparison, users must have provided proof of their best in the previous round
        // If they don't provide proof, they won't win even if they have the best hand
        unchecked {
            for( uint i = 0; i < players.length; i++ )
            {
                TablePlayer memory x = players[i];

                if( x.folded ) {
                    continue;
                }

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

        // At least one player must win!
        require( 0 != lowest_count );

        // Payout is split equally between with the same lowest score
        // All other players get a zero payout

        payouts = new uint256[](players.length);

        player_addresses = new address[](players.length);

        uint256 winning_payout = pot / lowest_count;

        dust = pot - (winning_payout * lowest_count);

        unchecked {
            for( uint i = 0; i < players.length; i++ )
            {
                TablePlayer memory x = players[i];

                player_addresses[i] = x.addr;

                if( ! x.folded && x.score == lowest_score )
                {
                    payouts[i] = winning_payout + dust;

                    dust = 0;
                }
                else {
                    payouts[i] = 0;
                }
            }
        }
    }
}
