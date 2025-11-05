// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DecentralizedLottery (+ bonus features)
 * @notice Time-boxed lottery:
 *  - Owner starts a round (fixed duration).
 *  - Players buy tickets at fixed price (ETH).
 *  - After the end, anyone may settle:
 *      * if enough unique players -> pick up to 3 unique winners & pay (minus fee)
 *      * else -> automatically refund all tickets
 *
 *  SECURITY
 *   - onlyOwner can start a round
 *   - CEI pattern for all transfers
 *   - simple nonReentrant guard on settlement/refunds
 *
 *  RANDOMNESS
 *   - simple on-chain pseudo-randomness (OK for class/test; NOT for real-money prod)
 */
contract DecentralizedLottery {
    // ========= CONFIG (constants for class simplicity) =========
    address public owner;

    // Price per ticket: 0.01 ETH
    uint256 public constant TICKET_PRICE = 0.01 ether;

    // Duration of each round
    uint256 public constant ROUND_DURATION = 5 minutes;

    // House fee (basis points = parts per 10,000); 500 = 5%
    uint256 public constant HOUSE_FEE_BPS = 500;

    // Max tickets per address per round
    uint256 public constant MAX_TICKETS_PER_ADDR = 10;

    // Minimum unique participants required to run (else refunds)
    uint256 public constant MIN_UNIQUE_PLAYERS = 2;

    // ========= CURRENT ROUND STATE =========
    uint256 public roundNumber;          // current round id
    uint256 public roundEndTime;         // unix timestamp when round ends
    address[] public players;            // entries (duplicates per ticket)

    // tickets bought per address in a given round
    mapping(uint256 => mapping(address => uint256)) private ticketsPerRound;
    // joined flag (per round) to count unique addresses cheaply
    mapping(uint256 => mapping(address => bool)) private hasJoined;
    // unique count per round
    mapping(uint256 => uint256) private uniquePlayersCount;

    // simple nonce for randomness
    uint256 private nonce;

    // quick "last settlement" info
    address[] public lastWinners;
    uint256[] public lastPrizes;
    uint256 public lastPrizePool;
    bool public lastRoundRefunded;

    // ========= HISTORY =========
    struct RoundHistory {
        uint256 round;
        bool refunded;
        uint256 startTime;
        uint256 endTime;
        uint256 prizePoolOrRefundTotal;
        address[] winners;
        uint256[] prizes;
    }
    mapping(uint256 => RoundHistory) public history; // by round

    // ========= EVENTS =========
    event RoundStarted(uint256 indexed round, uint256 endTime);
    event TicketPurchased(address indexed player, uint256 ticketCount, uint256 indexed round);
    event RoundRefunded(uint256 indexed round, uint256 totalRefunded);
    event WinnersSelected(
        uint256 indexed round,
        address[] winners,
        uint256[] prizes,
        uint256 poolAfterFee,
        uint256 feePaid
    );

    // ========= MODIFIERS =========
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    bool private _locked;
    modifier nonReentrant() {
        require(!_locked, "Reentrancy");
        _locked = true;
        _;
        _locked = false;
    }

    // ========= CONSTRUCTOR =========
    constructor() {
        owner = msg.sender;
        roundNumber = 0;
    }

    // Disallow stray ETH transfers
    receive() external payable { revert("Direct ETH not allowed"); }
    fallback() external payable { revert("Direct ETH not allowed"); }

    // ========= ROUND MANAGEMENT =========

    /// @notice Start a new lottery round. Only owner. Round must be inactive.
    function startNewRound() external onlyOwner {
        require(!isRoundActive(), "Round already active");

        // clear players array
        delete players;

        // move to next round
        roundNumber += 1;
        roundEndTime = block.timestamp + ROUND_DURATION;

        // reset quick-view
        delete lastWinners;
        delete lastPrizes;
        lastPrizePool = 0;
        lastRoundRefunded = false;

        emit RoundStarted(roundNumber, roundEndTime);
    }

    // ========= TICKET SALES =========

    /// @notice Buy N tickets for the active round. Must send exact ETH = N * TICKET_PRICE.
    function buyTickets(uint256 ticketCount) external payable {
        require(ticketCount > 0, "ticketCount > 0");
        require(isRoundActive(), "No active round");
        require(msg.value == ticketCount * TICKET_PRICE, "Incorrect ETH");

        // enforce per-address cap
        uint256 already = ticketsPerRound[roundNumber][msg.sender];
        require(already + ticketCount <= MAX_TICKETS_PER_ADDR, "Exceeds per-address limit");

        // mark unique joiner
        if (!hasJoined[roundNumber][msg.sender]) {
            hasJoined[roundNumber][msg.sender] = true;
            uniquePlayersCount[roundNumber] += 1;
        }

        // append entries (duplicates allowed to represent odds)
        for (uint256 i = 0; i < ticketCount; i++) {
            players.push(msg.sender);
        }
        ticketsPerRound[roundNumber][msg.sender] = already + ticketCount;

        emit TicketPurchased(msg.sender, ticketCount, roundNumber);
    }

    // ========= SETTLEMENT =========

    /**
     * @notice Settle the round:
     *  - if not enough unique players -> refund all tickets
     *  - else -> pay house fee then split pool among up to 3 unique winners
     *  Anyone can call after round end.
     */
    function selectWinner() external nonReentrant {
        require(!isRoundActive() && roundEndTime > 0, "Round not ended");
        uint256 ucount = uniquePlayersCount[roundNumber];

        // A) refunds if not enough participants
        if (ucount < MIN_UNIQUE_PLAYERS) {
            uint256 refunded = _refundAll();
            _archiveRound(true, refunded, new address[](0), new uint256[](0));
            return;
        }

        // B) choose winners and pay
        require(players.length > 0, "No entries");
        uint256 pool = address(this).balance;
        lastPrizePool = pool;

        // fee first
        uint256 fee = (pool * HOUSE_FEE_BPS) / 10000;
        uint256 poolAfterFee = pool - fee;

        // number of winners = min(ucount, 3)
        uint256 numWinners = ucount >= 3 ? 3 : ucount;
        address[] memory winners = _pickUniqueWinners(numWinners);
        uint256[] memory prizes = _computePrizes(numWinners, poolAfterFee);

        // EFFECTS: set "last" values
        delete lastWinners; delete lastPrizes;
        for (uint256 i = 0; i < winners.length; i++) {
            lastWinners.push(winners[i]);
            lastPrizes.push(prizes[i]);
        }
        lastRoundRefunded = false;

        // INTERACTIONS: fee then prizes (CEI)
        if (fee > 0) {
            (bool okFee, ) = payable(owner).call{value: fee}("");
            require(okFee, "Fee transfer failed");
        }
        for (uint256 j = 0; j < winners.length; j++) {
            (bool ok, ) = payable(winners[j]).call{value: prizes[j]}("");
            require(ok, "Prize transfer failed");
        }

        emit WinnersSelected(roundNumber, winners, prizes, poolAfterFee, fee);

        // archive & reset
        _archiveRound(false, poolAfterFee, winners, prizes);
    }

    // Refund each entry at face value (can be gas heavy for many tickets; ok for class/demo)
    function _refundAll() internal returns (uint256 totalRefunded) {
        uint256 len = players.length;
        for (uint256 i = 0; i < len; i++) {
            (bool ok, ) = payable(players[i]).call{value: TICKET_PRICE}("");
            require(ok, "Refund transfer failed");
            totalRefunded += TICKET_PRICE;
        }
        emit RoundRefunded(roundNumber, totalRefunded);
    }

    // Write a round snapshot to history and reset runtime state
    function _archiveRound(
        bool refunded,
        uint256 poolOrRefunded,
        address[] memory winners,
        uint256[] memory prizes
    ) internal {
        RoundHistory storage rh = history[roundNumber];
        rh.round = roundNumber;
        rh.refunded = refunded;
        rh.startTime = roundEndTime - ROUND_DURATION;
        rh.endTime = roundEndTime;
        rh.prizePoolOrRefundTotal = poolOrRefunded;

        // store arrays
        delete rh.winners;
        delete rh.prizes;
        for (uint256 i = 0; i < winners.length; i++) {
            rh.winners.push(winners[i]);
            rh.prizes.push(prizes[i]);
        }

        // reset basic runtime flags for next round
        roundEndTime = 0;
        delete players;
        // mappings keyed by roundNumber do not require clearing
    }

    // Pick N unique winners by sampling players[] until N different addresses are found
    function _pickUniqueWinners(uint256 n) internal returns (address[] memory) {
        address[] memory result = new address[](n);
        uint256 selected = 0;

        // small n (<=3); O(n^2) uniqueness check is fine
        while (selected < n) {
            uint256 idx = _random(players.length);           // 0..len-1
            address candidate = players[idx];

            bool seen = false;
            for (uint256 k = 0; k < selected; k++) {
                if (result[k] == candidate) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                result[selected] = candidate;
                selected++;
            }
        }
        return result;
    }

    // Prize splits for 1/2/3 winners: 100 / 60-40 / 50-30-20
    function _computePrizes(uint256 numWinners, uint256 poolAfterFee)
        internal
        pure
        returns (uint256[] memory)
    {
        uint256[] memory p = new uint256[](numWinners);
        if (numWinners == 1) {
            p[0] = poolAfterFee;
        } else if (numWinners == 2) {
            p[0] = (poolAfterFee * 60) / 100;
            p[1] = poolAfterFee - p[0];
        } else {
            uint256 w0 = (poolAfterFee * 50) / 100;
            uint256 w1 = (poolAfterFee * 30) / 100;
            uint256 w2 = poolAfterFee - w0 - w1;
            p[0] = w0; p[1] = w1; p[2] = w2;
        }
        return p;
    }

    // Pseudo-random index 0..maxExclusive-1
    function _random(uint256 maxExclusive) internal returns (uint256) {
        require(maxExclusive > 0, "maxExclusive=0");
        uint256 r = uint256(keccak256(abi.encodePacked(
            block.timestamp,
            block.prevrandao,
            msg.sender,
            players.length,
            nonce
        )));
        nonce++;
        return r % maxExclusive;
    }

    // ========= VIEW HELPERS (human-readable) =========

    function isRoundActive() public view returns (bool) {
        return (roundEndTime > 0) && (block.timestamp < roundEndTime);
    }

    function getTimeRemaining() public view returns (uint256) {
        if (!isRoundActive()) return 0;
        return roundEndTime - block.timestamp; // seconds
    }

    /// @notice "M min S sec"
    function getTimeRemainingReadable() external view returns (string memory) {
        uint256 s = getTimeRemaining();
        uint256 m = s / 60;
        uint256 rem = s % 60;
        return string(abi.encodePacked(_u(m), " min ", _u(rem), " sec"));
    }

    /// @notice total entries (tickets) for current round
    function getPlayerCount() external view returns (uint256) {
        return players.length;
    }

    /// @notice unique addresses that joined this round
    function getUniquePlayerCount() external view returns (uint256) {
        return uniquePlayersCount[roundNumber];
    }

    function getPlayers() external view returns (address[] memory) {
        return players;
    }

    function getPrizePool() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice "0.01 ETH"
    function getTicketPriceReadable() external pure returns (string memory) {
        return "0.01 ETH";
    }

    /// @notice "<x.yyyy> ETH"
    function getPrizePoolReadable() external view returns (string memory) {
        return _formatEth(getPrizePool());
    }

    /// @notice Compact round snapshot for UIs
    function getRoundSummary()
        external
        view
        returns (
            uint256 _round,
            bool _active,
            uint256 _timeLeftSec,
            uint256 _tickets,
            uint256 _unique,
            uint256 _poolWei
        )
    {
        _round       = roundNumber;
        _active      = isRoundActive();
        _timeLeftSec = getTimeRemaining();
        _tickets     = players.length;
        _unique      = uniquePlayersCount[roundNumber];
        _poolWei     = address(this).balance;
    }

    // ========= STRING / FORMAT UTILS =========

    function _u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v; uint256 l;
        while (j != 0) { l++; j /= 10; }
        bytes memory b = new bytes(l);
        j = v;
        while (j != 0) {
            b[--l] = bytes1(uint8(48 + (j % 10)));
            j /= 10;
        }
        return string(b);
    }

    // displays 4 decimals: x.yyyy ETH
    function _formatEth(uint256 weiAmt) internal pure returns (string memory) {
        uint256 whole = weiAmt / 1e18;
        uint256 frac = (weiAmt % 1e18) / 1e14; // 4 decimals
        string memory f = _u(frac);
        // left-pad to 4 digits
        if (bytes(f).length == 1) f = string(abi.encodePacked("000", f));
        else if (bytes(f).length == 2) f = string(abi.encodePacked("00", f));
        else if (bytes(f).length == 3) f = string(abi.encodePacked("0", f));
        return string(abi.encodePacked(_u(whole), ".", f, " ETH"));
    }
}
