# Project Write-Up: Decentralized Lottery

## Executive Summary

This document explains the design decisions, security considerations, and implementation details of the DecentralizedLottery smart contract. The project successfully implements all required features plus six bonus challenges, prioritizing security, gas efficiency, and user experience.

---

## 1. Architecture Overview

### Core Design Philosophy
The contract follows a **round-based model** where each lottery round is independent, time-boxed, and can result in either winner selection or automatic refunds. This design ensures fairness and prevents edge cases where funds could be locked.

### State Management
The contract separates state into three categories:
1. **Configuration** (constants): Immutable parameters like ticket price and duration
2. **Runtime State**: Current round information (players, timing, counts)
3. **Historical State**: Archived results from past rounds

This separation provides clarity and makes the contract easier to audit and maintain.

---

## 2. Design Decisions

### 2.1 Ticket Price: 0.01 ETH

**Rationale:**
- Low enough to encourage participation
- High enough to make gas costs proportionally reasonable
- Easy mental math for users (1 ETH = 100 tickets)
- Standard denomination in the Ethereum ecosystem

**Alternative Considered:**
Using a variable price would add complexity without significant benefit for this educational project.

### 2.2 Round Duration: 5 Minutes

**Rationale:**
- Short enough for testing and demos
- Long enough to allow multiple participants
- Configurable via constant for easy adjustment

**Production Consideration:**
For mainnet deployment, this should be extended to 1-24 hours to accommodate different time zones and provide adequate participation windows.

### 2.3 Multiple Winners (Bonus Feature)

**Decision:** Support up to 3 winners with tiered prizes

**Prize Distribution:**
```
1 winner:  100%
2 winners: 60% / 40%
3 winners: 50% / 30% / 20%
```

**Rationale:**
- Increases engagement (more chances to win)
- Common pattern in real-world lotteries
- Maintains excitement with substantial top prize
- Fixed split percentages avoid rounding issues

**Implementation Choice:**
The `_pickUniqueWinners()` function ensures all winners are different addresses, even if one address bought multiple tickets. This prevents prize concentration and feels more fair to users.

### 2.4 Ticket Limits (Bonus Feature)

**Decision:** Maximum 10 tickets per address per round

**Rationale:**
- Prevents single address from dominating odds
- Encourages broader participation
- Limits gas costs in refund scenarios
- Still allows strategic advantage for committed players

**Trade-off:**
Users could use multiple addresses to circumvent this, but the gas costs of doing so provide a natural deterrent.

### 2.5 Minimum Players (Bonus Feature)

**Decision:** Require 2 unique players to proceed

**Rationale:**
- Prevents owner from buying one ticket and winning own lottery
- Ensures competitive/fair rounds
- Works synergistically with multiple winner feature

**Why Not 3?**
Two players can still have competitive odds, and requiring 3 would increase refund frequency unnecessarily.

### 2.6 Automatic Refunds (Bonus Feature)

**Decision:** Full refunds if minimum players not met

**Implementation:**
```solidity
function _refundAll() internal returns (uint256 totalRefunded) {
    for (uint256 i = 0; i < len; i++) {
        (bool ok, ) = payable(players[i]).call{value: TICKET_PRICE}("");
        require(ok, "Refund transfer failed");
        totalRefunded += TICKET_PRICE;
    }
}
```

**Rationale:**
- Ensures user funds are never locked
- Builds trust in the system
- Eliminates edge cases around incomplete rounds

**Gas Consideration:**
Loop-based refunds can be gas-intensive with many tickets. For production, consider:
- Pull-based refunds (users withdraw)
- Batch processing
- Off-chain refund coordination

### 2.7 House Fee: 5% (Bonus Feature)

**Decision:** `HOUSE_FEE_BPS = 500` (5%)

**Rationale:**
- Incentivizes owner to maintain and promote lottery
- Industry-standard range (3-10%)
- Low enough to keep player returns attractive
- Paid before prize distribution (CEI pattern)

**Transparency:**
Fee is public constant, visible to all users before participation.

---

## 3. Security Considerations

### 3.1 Access Control

**Owner-Only Functions:**
```solidity
modifier onlyOwner() {
    require(msg.sender == owner, "Only owner");
    _;
}
```

Only `startNewRound()` requires owner access. This minimizes centralization while maintaining necessary control.

**Why Winner Selection Is Public:**
Any address can call `selectWinner()` after round ends. This:
- Prevents owner from delaying to manipulate outcomes
- Allows automated triggering by bots/users
- Increases decentralization

### 3.2 Reentrancy Protection

**Implementation:**
```solidity
bool private _locked;
modifier nonReentrant() {
    require(!_locked, "Reentrancy");
    _locked = true;
    _;
    _locked = false;
}
```

Applied to `selectWinner()` which handles all ETH transfers.

**Why Custom vs OpenZeppelin:**
Custom implementation reduces dependencies and gas costs for this educational project. Production code should use OpenZeppelin's battle-tested ReentrancyGuard.

### 3.3 Checks-Effects-Interactions (CEI) Pattern

**Every transfer follows CEI:**

```solidity
// CHECKS
require(!isRoundActive() && roundEndTime > 0, "Round not ended");

// EFFECTS
delete lastWinners; 
delete lastPrizes;
for (uint256 i = 0; i < winners.length; i++) {
    lastWinners.push(winners[i]);
    lastPrizes.push(prizes[i]);
}

// INTERACTIONS
(bool ok, ) = payable(winners[j]).call{value: prizes[j]}("");
require(ok, "Prize transfer failed");
```

This pattern prevents reentrancy attacks even without explicit guards.

### 3.4 Input Validation

**Every external function validates inputs:**
- `buyTickets()`: Checks ticket count > 0, correct ETH sent, round active
- `selectWinner()`: Checks round ended, has players
- State changes: Enforce limits (MAX_TICKETS_PER_ADDR)

### 3.5 Randomness Approach

**Current Implementation:**
```solidity
function _random(uint256 maxExclusive) internal returns (uint256) {
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
```

**Security Note:**
This is **pseudo-random** and suitable for educational/testnet use. It uses:
- `block.timestamp`: Publicly known
- `block.prevrandao`: Miner-influenceable
- `msg.sender`: Predictable
- `nonce`: Internal counter for uniqueness

**Production Requirement:**
For real money, use **Chainlink VRF** (Verifiable Random Function) or similar oracle-based true randomness. On-chain randomness can be predicted/manipulated by miners.

### 3.6 Preventing Direct ETH Transfers

```solidity
receive() external payable { revert("Direct ETH not allowed"); }
fallback() external payable { revert("Direct ETH not allowed"); }
```

**Rationale:**
- All ETH must come through `buyTickets()`
- Prevents accounting errors
- Makes prize pool calculations accurate

---

## 4. Gas Optimization Decisions

### 4.1 Storage vs Memory

**Players Array:**
```solidity
address[] public players;
```

Stored in state because it must persist between transactions and be accessible in winner selection.

**Winners Array:**
```solidity
address[] memory winners = new address[](n);
```

Uses memory during selection since it's temporary computation.

### 4.2 Mapping Strategies

**Dual Tracking:**
```solidity
mapping(uint256 => mapping(address => uint256)) private ticketsPerRound;
mapping(uint256 => mapping(address => bool)) private hasJoined;
```

Two mappings instead of one complex structure:
- `ticketsPerRound`: Enforces per-address limits
- `hasJoined`: Tracks unique count efficiently

**Trade-off:**
Slight increase in storage for significant gas savings when checking uniqueness.

### 4.3 Unique Winner Selection

**Current Algorithm (O(n²)):**
```solidity
while (selected < n) {
    uint256 idx = _random(players.length);
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
```

**Why This Is Acceptable:**
- Max 3 winners (n=3)
- O(n²) with n=3 is trivial (max 9 comparisons)
- Simpler than set-based approaches
- Avoids external library dependencies

**Worst Case:**
If all tickets are from same address (impossible due to ticket limits), infinite loop is prevented by uniqueness requirement being mathematically satisfiable.

---

## 5. History Tracking (Bonus Feature)

### 5.1 Data Structure

```solidity
struct RoundHistory {
    uint256 round;
    bool refunded;
    uint256 startTime;
    uint256 endTime;
    uint256 prizePoolOrRefundTotal;
    address[] winners;
    uint256[] prizes;
}
mapping(uint256 => RoundHistory) public history;
```

**Rationale:**
- Comprehensive audit trail
- Enables analytics and transparency
- Supports dispute resolution
- Minimal gas overhead (only on settlement)

### 5.2 Dual View System

**Quick Access:**
```solidity
address[] public lastWinners;
uint256[] public lastPrizes;
```

**Complete History:**
```solidity
mapping(uint256 => RoundHistory) public history;
```

**Why Both?**
- `lastWinners/lastPrizes`: Cheap reads for common UI needs
- `history`: Complete records for audits and deep dives

---

## 6. User Experience Features

### 6.1 Readable Output Functions

**Example:**
```solidity
function getTimeRemainingReadable() external view returns (string memory) {
    uint256 s = getTimeRemaining();
    uint256 m = s / 60;
    uint256 rem = s % 60;
    return string(abi.encodePacked(_u(m), " min ", _u(rem), " sec"));
}
```

**Rationale:**
While gas-intensive for writes, view functions can format human-readable strings for UIs without on-chain cost.

### 6.2 Round Summary Function

```solidity
function getRoundSummary() external view returns (...)
```

Single function call returns all UI-critical data, reducing RPC calls and improving frontend performance.

---

## 7. Event Design

### 7.1 Comprehensive Events

```solidity
event RoundStarted(uint256 indexed round, uint256 endTime);
event TicketPurchased(address indexed player, uint256 ticketCount, uint256 indexed round);
event RoundRefunded(uint256 indexed round, uint256 totalRefunded);
event WinnersSelected(uint256 indexed round, address[] winners, uint256[] prizes, ...);
```

**Indexing Strategy:**
- `indexed round`: Fast filtering by round
- `indexed player`: Fast user history queries
- Arrays not indexed (can't be)

**Use Cases:**
- Off-chain analytics
- User activity tracking
- Audit trails
- Frontend real-time updates

---

## 8. Known Limitations & Future Improvements

### 8.1 Current Limitations

1. **Randomness**: Not production-grade
   - **Fix**: Integrate Chainlink VRF

2. **Gas Costs**: Refund loops expensive
   - **Fix**: Pull-based withdrawal pattern

3. **No Pause**: Can't emergency stop
   - **Fix**: Add pausable functionality

4. **Fixed Parameters**: All constants hardcoded
   - **Fix**: Add owner-controlled configuration

### 8.2 Potential Enhancements

**Tier System:**
Multiple concurrent lotteries at different price points (0.01 ETH, 0.1 ETH, 1 ETH)

**Auto-Start:**
Rounds automatically begin when previous settles

**NFT Tickets:**
ERC-721 tokens as verifiable ticket proof

**DAO Governance:**
Community control over parameters via voting

**Cross-Chain:**
Support multiple blockchains simultaneously

---

## 9. Testing Strategy

### 9.1 Test Categories

1. **Happy Path**: Normal operation with 2-3 players
2. **Edge Cases**: 0, 1, or many players
3. **Access Control**: Non-owner attempting restricted functions
4. **Timing**: Before/during/after round states
5. **Payment**: Incorrect ETH amounts
6. **Limits**: Exceeding ticket caps

### 9.2 Test Networks Used

- **Local**: Hardhat Network for fast iteration
- **Testnet**: Sepolia for realistic conditions

---

## 10. Conclusion

This DecentralizedLottery contract successfully balances:
- **Security**: Multiple protection layers
- **Functionality**: All required + bonus features
- **Usability**: Comprehensive view functions
- **Transparency**: Public parameters and history
- **Fairness**: Automatic refunds and verifiable logic

The implementation demonstrates understanding of:
- Solidity best practices
- Smart contract security patterns
- Gas optimization techniques
- Real-world UX considerations

While suitable for educational purposes and testnets, production deployment would require:
- Chainlink VRF integration
- Professional security audit
- Comprehensive test suite (100% coverage)
- Multi-sig owner controls
- Emergency pause mechanism

---

**Project Completed By:** Tony  
**Institution:** Build Fellowship - City College of San Francisco  
**Course:** Blockchain SmartContract Development  
**Date:** November 2025
