/*
-----------------------------------------------------------------
FILE INFORMATION
-----------------------------------------------------------------
file:       Court.sol
version:    0.2
author:     Anton Jurisevic
            Mike Spain

date:       2018-1-16

checked:    Mike Spain
approved:   Samuel Brooks

-----------------------------------------------------------------
MODULE DESCRIPTION
-----------------------------------------------------------------

This provides the nomin contract with a confiscation
facility, if enough havven owners vote to confiscate a target
account's nomins.

This is designed to provide a mechanism to respond to abusive
contracts such as nomin wrappers, which would allow users to
trade wrapped nomins without accruing fees on those transactions.

In order to prevent tyranny, an account may only be frozen if
users controlling at least 30% of the value of havvens participate,
and a two thirds majority is attained in that vote.
In order to prevent tyranny of the majority or mob justice,
confiscation actions are only approved if the havven foundation
approves the result.
This latter requirement may be lifted in future versions.

The foundation, or any user with a sufficient havven balance may bring a
confiscation action.
A vote lasts for a default period of one week, with a further confirmation
period in which the foundation approves the result.
The latter period may conclude early upon the foundation's decision to either
veto or approve the mooted confiscation action.
If the confirmation period elapses without the foundation making a decision,
the action fails.

In order to vote, a havven holder must lock their havvens. They may cast
a vote for only one action at a time, but may cancel their vote
at any time except during the confirmation period, in order to unlock
their havven balance.
The weight of their vote will be proportional with their locked balance.

Hence an action to confiscate the balance of a given address composes
a state machine built of the following states:


Waiting:
  - A user with standing brings a vote:
    If the target address is not frozen;
    initialise vote tallies to 0;
    transition to the Voting state.

  - An account cancels a previous vote:
    the account is unlocked,
    remain in the Waiting state.

Voting:
  - The foundation vetoes the in-progress vote:
    transition to the Waiting state.

  - The voting period elapses:
    transition to the Confirmation state.

  - An account votes (for or against the motion):
    the account is locked, its balance is added to the appropriate tally;
    remain in the Voting state.

  - An account cancels its previous vote:
    the account is unlocked, its balance is deducted from the appropriate tally (if any);
    remain in the Voting state.

Confirmation:
  - The foundation vetoes the completed vote:
    transition to the Waiting state.

  - The foundation approves confiscation of the target account:
    freeze the target account, transfer its nomin balance to the fee pool;
    transition to the Waiting state.

  - The confirmation period elapses:
    transition to the Waiting state.


User votes are not automatically cancelled upon the conclusion of a vote.
Therefore, after a vote comes to a conclusion, if a user wishes to free
their havven balance, they must manually cancel their vote in order to do so.

This procedure is designed to be relatively simple.
There are some things that can be added to enhance the functionality
at the expense of simplicity and efficiency:

  - Unique action IDs for clearer logging if multiple actions are mooted for a given account;
  - Democratic unfreezing of nomin accounts (induces multiple categories of vote)
  - Configurable per-vote durations;
  - Vote standing denominated in a fiat quantity rather than a quantity of havvens;
  - Confiscate from multiple addresses in a single vote;
  - Allow users to vote in multiple actions at once (up to a limit).

We might consider updating the contract with any of these features at a later date if necessary.

-----------------------------------------------------------------
LICENCE INFORMATION
-----------------------------------------------------------------

Copyright (c) 2018 Havven.io

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

-----------------------------------------------------------------
RELEASE NOTES
-----------------------------------------------------------------

*/

pragma solidity ^0.4.19;


import "contracts/Owned.sol";
import "contracts/SafeDecimalMath.sol";
import "contracts/EtherNomin.sol";
import "contracts/Havven.sol";


contract Court is Owned, SafeDecimalMath {

    /* ========== STATE VARIABLES ========== */

    // The addresses of the token contracts this confiscation court interacts with.
    Havven havven;
    EtherNomin nomin;

    // The minimum havven balance required to be considered to have standing
    // to begin confiscation proceedings.
    uint public minStandingBalance = 100 * UNIT;

    // The voting period lasts for this duration,
    // and if set, must fall within the given bounds.
    uint public votingPeriod = 1 weeks;
    uint constant minVotingPeriod = 3 days;
    uint constant maxVotingPeriod = 4 weeks;

    // Duration of the period during which the foundation may confirm
    // or veto a vote that has concluded.
    // If set, the confirmation duration must fall within the given bounds.
    uint public confirmationPeriod = 1 weeks;
    uint constant minConfirmationPeriod = 1 days;
    uint constant maxConfirmationPeriod = 2 weeks;

    // No fewer than this fraction of havvens must participate in the vote
    // in order for a quorum to be reached.
    // The participation fraction required may be set no lower than 10%.
    uint public requiredParticipation = 3 * UNIT / 10;
    uint constant minRequiredParticipation = UNIT / 10;

    // At least this fraction of participating votes must be in favour of
    // confiscation for the proposal to pass.
    // The required majority may be no lower than 50%.
    uint public requiredMajority = (2 * UNIT) / 3;
    uint constant minRequiredMajority = UNIT / 2;

    // The timestamp at which a vote began. This is used to determine
    // Whether a vote is running, is in the confirmation period,
    // or has concluded.
    // A vote runs from its start time t until (t + votingPeriod),
    // and then the confirmation period terminates no later than
    // (t + votingPeriod + confirmationPeriod).
    mapping(address => uint) public voteStartTimes;

    // The tallies for and against confiscation of a given balance.
    // These are set to zero at the start of a vote, and also on conclusion,
    // just to keep the blockchain clean.
    mapping(address => uint) public votesFor;
    mapping(address => uint) public votesAgainst;

    // The penultimate average balance of a user at the time they voted.
    // If we did not save this information then we would have to
    // disallow transfers into an account lest it cancel a vote
    // with greater weight than that with which it originally voted,
    // and the fee period rolled over in between.
    mapping(address => uint) voteWeight;

    // The possible vote types.
    // Absention: not participating in a vote; This is the default value.
    // Yea: voting in favour of an action.
    // Nay: voting against an action.
    enum Vote {Abstention, Yea, Nay}

    // A given account's vote in some confiscation action.
    // This requires the default value of the Vote enum to correspond to an abstention.
    mapping(address => Vote) public userVote;
    // The vote a user last participated in.
    mapping(address => address) public voteTarget;

    /* ========== CONSTRUCTOR ========== */

    function Court(Havven _havven, EtherNomin _nomin, address _owner)
        Owned(_owner)
        public
    {
        havven = _havven;
        nomin = _nomin;
    }


    /* ========== SETTERS ========== */

    function setMinStandingBalance(uint balance)
        public
        onlyOwner
    {
        // No requirement on the standing threshold here;
        // the foundation can set this value such that
        // anyone or noone can actually start an action.
        minStandingBalance = balance;
    }

    function setVotingPeriod(uint duration)
        public
        onlyOwner
    {
        require(minVotingPeriod <= duration &&
                duration <= maxVotingPeriod);
        // Require that the voting period is no longer than a single fee period,
        // So that a single vote can span at most two fee periods.
        require(duration <= havven.targetFeePeriodDurationSeconds());
        votingPeriod = duration;
    }

    function setConfirmationPeriod(uint duration)
        public
        onlyOwner
    {
        require(minConfirmationPeriod <= duration &&
                duration <= maxConfirmationPeriod);
        confirmationPeriod = duration;
    }

    function setRequiredParticipation(uint fraction)
        public
        onlyOwner
    {
        require(minRequiredParticipation <= fraction);
        requiredParticipation = fraction;
    }

    function setRequiredMajority(uint fraction)
        public
        onlyOwner
    {
        require(minRequiredMajority <= fraction);
        requiredMajority = fraction;
    }


    /* ========== VIEW FUNCTIONS ========== */


    function hasVoted(address account)
        public
        view
        returns (bool)
    {
        return userVote[account] != Court.Vote.Abstention;
    }

    /* There is an action in progress on the specified
     * account, and votes are being accepted in that action.
     */
    function voting(address target)
        public
        view
        returns (bool)
    {
        // No need to check (startTime < now) as there is no way
        // to set future start times for votes.
        return now < voteStartTimes[target] + votingPeriod;
    }

    /* A vote on the target account has concluded, but the action
     * has not yet been approved, vetoed, or closed.
     */
    function confirming(address target)
        public
        view
        returns (bool)
    {
        uint startTime = voteStartTimes[target];
        return startTime + votingPeriod <= now &&
               now < startTime + votingPeriod + confirmationPeriod;
    }

    /* A vote has either not begun, or it has completely terminated. */
    function waiting(address target)
        public
        view
        returns (bool)
    {
        return voteStartTimes[target] + votingPeriod + confirmationPeriod <= now;
    }

    /* If the vote was to terminate at this instant, it would pass.
     * That is: there was sufficient participation and a sizeable enough majority.
     */
    function votePasses(address target)
        public
        view
        returns (bool)
    {
        uint yeas = votesFor[target];
        uint nays = votesAgainst[target];
        uint totalVotes = yeas + nays;

        if (totalVotes == 0) {
            return false;
        }

        uint participation = safeDecDiv(totalVotes, havven.totalSupply());
        uint fractionInFavour = safeDecDiv(yeas, totalVotes);

        // We require the result to be strictly greater than the requirement
        // to enforce a majority being "50% + 1", and so on.
        return participation > requiredParticipation &&
               fractionInFavour > requiredMajority;
    }


    /* ========== MUTATIVE FUNCTIONS ========== */

    /* Begin a vote to confiscate the funds in a given nomin account.
     * Only the foundation, or accounts with sufficient havven balances
     * may elect to start such a vote.
     */
    function beginConfiscationAction(address target)
        public
    {
        // A confiscation action must be mooted by someone with standing.
        require((havven.balanceOf(msg.sender) >= minStandingBalance) ||
                msg.sender == owner);

        // Require that the voting period is longer than a single fee period,
        // So that a single vote can span at most two fee periods.
        require(votingPeriod <= havven.targetFeePeriodDurationSeconds());

        // There must be no confiscation vote already running for this account.
        require(waiting(target));

        // Disallow votes on accounts that have previously been frozen.
        require(!nomin.isFrozen(target));

        voteStartTimes[target] = now;
        votesFor[target] = 0;
        votesAgainst[target] = 0;
        ConfiscationVote(msg.sender, msg.sender, target, target);
    }

    /* The sender casts a vote in favour of confiscation of the
     * target account's nomin balance.
     */
    function voteFor(address target)
        public
    {
        // There must be an active vote for this target running.
        // Vote totals must only change during the voting phase.
        require(voting(target));

        // This user can't already have voted in anything.
        require(!hasVoted(msg.sender));

        uint weight;
        // We use a fee period guaranteed to have terminated before
        // the start of the vote. Select the right period if
        // a fee period rolls over in the middle of the vote.
        if (voteStartTimes[target] < havven.feePeriodStartTime()) {
            weight = havven.penultimateAverageBalance(msg.sender);
        } else {
            weight = havven.lastAverageBalance(msg.sender);
        }

        // Users must have a nonzero voting weight to vote.
        require(weight > 0);

        // The user should not have voted previously without cancelling
        // that vote; the previous check ensures this, along with
        // the one inside setVotedYea().
        setVotedYea(msg.sender, target);
        voteWeight[msg.sender] = weight;
        votesFor[target] += weight;
        VoteFor(msg.sender, msg.sender, target, target, weight);
    }

    /* The sender casts a vote against confiscation of the
     * target account's nomin balance. */
    function voteAgainst(address target)
        public
    {
        // There must be an active vote for this target running.
        // Vote totals must only change during the voting phase.
        require(voting(target));

        // This user can't already have voted in anything.
        require(!hasVoted(msg.sender));

        uint weight;
        // We use a fee period guaranteed to have terminated before
        // the start of the vote. Select the right period if
        // a fee period rolls over in the middle of the vote.
        if (voteStartTimes[target] < havven.feePeriodStartTime()) {
            weight = havven.penultimateAverageBalance(msg.sender);
        } else {
            weight = havven.lastAverageBalance(msg.sender);
        }

        // Users must have a nonzero voting weight to vote.
        require(weight > 0);

        // The user should not have voted previously without cancelling
        // that vote; the previous check ensures this, along with
        // the one inside setVotedNay().
        setVotedNay(msg.sender, target);
        voteWeight[msg.sender] = weight;
        votesAgainst[target] += weight;
        VoteAgainst(msg.sender, msg.sender, target, target, weight);
    }

    /* Cancel an existing vote by the sender on an action
     * to confiscate the target balance.
     */
    function cancelVote(address target)
        public
    {
        // An account may cancel its vote either before the confirmation phase
        // when the vote is still open, or after the confirmation phase,
        // when the vote has concluded.
        // But the totals must not change during the confirmation phase itself.
        require(!confirming(target));

        // If we are not voting, there is no reason to update the vote totals.
        if (voting(target)) {
            // This call to getVote() must come before the later call to cancelVote(), obviously.
            Vote vote = userVote[msg.sender];

            if (vote == Vote.Yea) {
                votesFor[target] -= voteWeight[msg.sender];
            }
            else if (vote == Vote.Nay) {
                votesAgainst[target] -= voteWeight[msg.sender];
            } else {
                // The sender has not voted.
                return;
            }

            // A cancelled vote is only meaningful if a vote is running
            voteWeight[msg.sender] = 0;
            CancelledVote(msg.sender, msg.sender, target, target);
        }

        // Disallow users from cancelling a vote for a different target
        // than the one they have previously voted for.
        require(voteTarget[msg.sender] == target);
        userVote[msg.sender] = Court.Vote.Abstention;
        voteTarget[msg.sender] = 0;
    }

    /* If a vote has concluded, or if it lasted its full duration but not passed,
     * then anyone may close it (for example in order to unlock their havven account).
     */
    function closeVote(address target)
        public
    {
        require((confirming(target) && !votePasses(target)) || waiting(target));

        voteStartTimes[target] = 0;
        votesFor[target] = 0;
        votesAgainst[target] = 0;
        VoteClosed(target, target);
    }

    /* The foundation may only confiscate a balance during the confirmation
     * period after a vote has passed.
     */
    function approve(address target)
        public
        onlyOwner
    {
        require(confirming(target));
        require(votePasses(target));

        nomin.confiscateBalance(target);
        voteStartTimes[target] = 0;
        votesFor[target] = 0;
        votesAgainst[target] = 0;
        VoteClosed(target, target);
        ConfiscationApproval(target, target);
    }

    /* The foundation may veto an action at any time. */
    function veto(address target)
        public
        onlyOwner
    {
        require(!waiting(target));
        voteStartTimes[target] = 0;
        votesFor[target] = 0;
        votesAgainst[target] = 0;
        VoteClosed(target, target);
        Veto(target, target);
    }

    /* Indicate that the given account voted yea in a confiscation
     * action on the target account.
     * The account must not have an active vote in any action.
     */
    function setVotedYea(address account, address target)
        internal
    {
        require(userVote[account] == Court.Vote.Abstention);
        userVote[account] = Court.Vote.Yea;
        voteTarget[account] = target;
    }

    /* Indicate that the given account voted nay in a confiscation
     * action on the target account.
     * The account must not have an active vote in any action.
     */
    function setVotedNay(address account, address target)
        internal
    {
        require(userVote[account] == Court.Vote.Abstention);
        userVote[account] = Court.Vote.Nay;
        voteTarget[account] = target;
    }

    /* ========== EVENTS ========== */

    event ConfiscationVote(address initator, address indexed initiatorIndex, address target, address indexed targetIndex);

    event VoteFor(address account, address indexed accountIndex, address target, address indexed targetIndex, uint balance);

    event VoteAgainst(address account, address indexed accountIndex, address target, address indexed targetIndex, uint balance);

    event CancelledVote(address account, address indexed accountIndex, address target, address indexed targetIndex);

    event VoteClosed(address target, address indexed targetIndex);

    event Veto(address target, address indexed targetIndex);

    event ConfiscationApproval(address target, address indexed targetIndex);
}