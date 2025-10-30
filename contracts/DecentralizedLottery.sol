// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title DecentralizedLottery
 * @notice Simple time-boxed lottery:
 *  - Owner starts a round (fixed duration).
 *  - Players buy tickets at a fixed price (can buy multiple per txn).
 *  - After the round ends, anyone can call selectWinner().
 *  - Winner receives the entire prize pool.
 *
 * SECURITY:
 *  - Access control on round start (onlyOwner).
 *  - Checks-Effects-Interactions (CEI) on prize payout.
 *  - Rejects direct ETH (receive/fallback) to avoid orphaned funds.
 *
 * NOTE (randomness):
 *  - Uses simple on-chain pseudo-randomness for education purposes only.
 *  - Not suitable for high-stakes/production deployments.
 */
contract DecentralizedLottery {
    // ============ STATE VARIABLES ============

    // Owner and configuration
    address public owner;                              // Contract admin (can start rounds)
    uint256 public constant TICKET_PRICE = 0.01 ether; // Fixed ticket price
    uint256 public constant ROUND_DURATION = 5 minutes;// Each round's length

    // Current round state
    uint256 public roundNumber;    // Counts rounds (starts at 0, increments on start)
    uint256 public roundEndTime;   // Unix timestamp when the active round ends (0 means no active round)
    address[] public players;      // Each ticket = one entry (addresses repeated)
    address public lastWinner;     // Most recent round's winner
    uint256 public lastPrizeAmount;// Most recent round's prize amount (wei)

    // Randomness (educational pseudo-random nonce)
    uint256 private nonce;

    // ============ EVENTS ============

    event RoundStarted(uint256 indexed roundNumber, uint256 endTime);
    event TicketPurchased(address indexed player, uint256 ticketCount);
    event WinnerSelected(address indexed winner, uint256 prize);

    // ============ MODIFIERS ============

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    // ============ CONSTRUCTOR ============

    constructor() {
        owner = msg.sender;
        roundNumber = 0;
        // roundEndTime stays 0 until first startNewRound()
    }

    // ============ ROUND MANAGEMENT ============

    /**
     * @notice Start a new lottery round. Only callable when no active round.
     * - Sets the deadline.
     * - Clears previous players.
     * - Increments the round counter.
     */
    function startNewRound() external onlyOwner {
        require(!isRoundActive(), "Round already active");

        // Clear previous entries (important so odds only reflect current round)
        delete players;

        // Increment round number then set end-time
        roundNumber += 1;
        roundEndTime = block.timestamp + ROUND_DURATION;

        emit RoundStarted(roundNumber, roundEndTime);
    }

    // ============ TICKET SALES ============

    /**
     * @notice Buy one or more tickets for the current round.
     * @param ticketCount Number of tickets to purchase (>=1).
     * Requirements:
     *  - Round must be active.
     *  - Exact ETH must be sent: ticketCount * TICKET_PRICE.
     *  - Adds one entry per ticket (duplicates allowed to reflect multiple tickets).
     */
    function buyTickets(uint256 ticketCount) external payable {
        require(isRoundActive(), "No active round");
        require(ticketCount > 0, "ticketCount must be > 0");

        uint256 cost = ticketCount * TICKET_PRICE;
        require(msg.value == cost, "Incorrect ETH sent");

        // Add one entry per ticket purchased
        // (Gas note: in real apps consider a more compact structure for large counts)
        for (uint256 i = 0; i < ticketCount; i++) {
            players.push(msg.sender);
        }

        emit TicketPurchased(msg.sender, ticketCount);
    }

    // ============ WINNER SELECTION & PAYOUT ============

    /**
     * @notice Select the round winner and pay out the full prize pool.
     * Anyone can call this AFTER the round has ended.
     * Uses CEI pattern for safety:
     *  1) CHECKS: round ended, players exist.
     *  2) EFFECTS: determine winner, record state, reset roundEndTime & players.
     *  3) INTERACTIONS: transfer prize to winner via call.
     */
    function selectWinner() external {
        // --- CHECKS ---
        require(roundEndTime > 0, "No round to settle");
        require(block.timestamp >= roundEndTime, "Round not ended");
        uint256 playerCount = players.length;
        require(playerCount > 0, "No players");

        // Pseudo-random index (educational only)
        uint256 randomIndex = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,       // current block time
                    block.prevrandao,      // randomness beacon (post-merge)
                    address(this).balance, // dynamic value
                    playerCount,           // current pool size
                    nonce                  // evolving nonce
                )
            )
        ) % playerCount;
        nonce++;

        address winner = players[randomIndex];
        uint256 prize = address(this).balance;

        // --- EFFECTS ---
        lastWinner = winner;
        lastPrizeAmount = prize;

        // Mark round as finalized by zeroing the end-time,
        // so selectWinner() can't be called again for this round.
        roundEndTime = 0;

        // Clear entries for the next round
        delete players;

        emit WinnerSelected(winner, prize);

        // --- INTERACTIONS ---
        // Use .call to avoid 2300-gas transfer limitation
        (bool ok, ) = payable(winner).call{value: prize}("");
        require(ok, "Prize transfer failed");
    }

    // ============ VIEW HELPERS ============

    /// @notice True if a round is currently active (deadline exists & not passed).
    function isRoundActive() public view returns (bool) {
        return (roundEndTime > 0) && (block.timestamp < roundEndTime);
    }

    /// @notice Seconds remaining in the active round (0 if none/ended).
    function getTimeRemaining() public view returns (uint256) {
        if (!isRoundActive()) return 0;
        return roundEndTime - block.timestamp;
    }

    /// @notice Number of ticket entries currently in the pool.
    function getPlayerCount() public view returns (uint256) {
        return players.length;
    }

    /// @notice Current ETH prize pool (all ETH held by this contract).
    function getPrizePool() public view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Returns the entire players array (useful for debugging/demo).
    function getPlayers() public view returns (address[] memory) {
        return players;
    }

    // ============ SAFETY GUARDS ============

    // Explicitly reject unexpected ETH to avoid orphaned funds that don't buy tickets.
    receive() external payable {
        revert("Send via buyTickets()");
    }

    fallback() external payable {
        revert("Invalid call");
    }
}

