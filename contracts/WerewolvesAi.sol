// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

contract WolfGPT {
    // ========== STATE VARIABLES ========== 
    uint256 public constant ROUND_DURATION = 10 minutes;

    mapping(uint => Match) public matches;
    mapping(uint => mapping(address => Player)) private playerInfoByMatch;
    uint public matchCount = 0;

    // ========== EVENTS ========== 

    // ========== STRUCTS AND ENUMS ========== 
    struct ActionContext {
        Actions action;
        address target;
        string args;
    }

    struct Player {
        address playerAddress;
        Roles role;
        bool isAlive;
        ActionContext actionContext;
        bool hasActed;  // Indicates if the player has acted in the current round
        bool isDead;
    }


    // New struct to represent the status of a player for external queries
    struct PlayerStatus {
        address playerAddress;
        bool isAlive;
        Roles role;
    }


    struct Match {
        uint matchId;
        uint entryFee;
        MatchStatus status;
        Player[6] players;
        uint playerCount;
        uint roundNumber;
        GamePhase currentPhase;  // Add this line
        Roles winningFaction; 
        uint winnersCount;   
        mapping(address => uint) votes; 
        address targetedByWerewolves; 
        uint256 roundEndTime;
        uint256 playersActedThisRound; 
        mapping(address => bool) checkedRecords; 
        uint256 totalPot; // This will store the total ETH for this match
        ActionContext[6] lastRoundActions; // Actions from the previous round for all players
    }


    enum MatchStatus { NOT_STARTED, STARTED, ENDED }
    enum Roles { NONE,PROPHET, HUNTER, VILLAGER, WEREWOLF }
    enum Actions { NONE, KILL, VERIFY, SPEAK, VOTE,CHECK }
    enum GamePhase {
        NIGHT,
        DAY_SPEAKING,
        DAY_VOTING
    }


    // ========== MODIFIERS ========== 
    modifier isParticipant(uint _matchId) {
        require(matches[_matchId].status != MatchStatus.NOT_STARTED, "Match hasn't started yet");
        require(playerInfoByMatch[_matchId][msg.sender].playerAddress == msg.sender, "You are not a participant in this match");
        _;
    }




    // ========== PUBLIC FUNCTIONS ========== 

    function createMatch(uint _entryFee) external returns(uint) {
        
        Match storage newMatch = matches[matchCount];
        newMatch.matchId = matchCount;
        newMatch.entryFee = _entryFee;
        newMatch.status = MatchStatus.NOT_STARTED;
        // The players array in newMatch is already initialized to its default values by default
        newMatch.playerCount = 0;
        
        matchCount++;
        return matchCount - 1;
    }

    function joinMatch(uint _matchId) external payable {
        require(matches[_matchId].status == MatchStatus.NOT_STARTED, "Match already started");
        require(matches[_matchId].playerCount < 6, "Match is full");
        require(msg.value == matches[_matchId].entryFee, "Invalid entry fee");

        Player memory newPlayer;
        newPlayer.playerAddress = msg.sender;
        newPlayer.role = Roles.VILLAGER; // default role
        newPlayer.isAlive = true;
        newPlayer.actionContext = ActionContext({
            action: Actions.NONE,
            target: address(0),
            args: ""
        });
        newPlayer.isDead = false;

        matches[_matchId].players[matches[_matchId].playerCount] = newPlayer;
        
        // Update the mapping with player's info
        playerInfoByMatch[_matchId][msg.sender] = newPlayer;
        
        matches[_matchId].totalPot += msg.value;
        matches[_matchId].playerCount++;

        if (matches[_matchId].playerCount == 6) {
            startMatch(_matchId);
        }
    }

    


    function doAction(uint _matchId, Actions _action, address _target,string memory args) external isParticipant(_matchId) {
        checkEndRound(_matchId);
        require(matches[_matchId].status == MatchStatus.STARTED, "Match has not started or has already ended");
        
        Player storage player = playerInfoByMatch[_matchId][msg.sender];
        require(player.isAlive, "You are no longer in the game");
        require(!player.hasActed, "You have already acted in this round");  // Ensure the player hasn't acted yet

        Match storage currentMatch = matches[_matchId];
        GamePhase currentPhase =  matches[_matchId].currentPhase;
        // ... (rest of the function, as previously provided)
        if(currentPhase == GamePhase.NIGHT) {
            if(_action == Actions.KILL) {
                if(currentMatch.targetedByWerewolves == address(0)) {
                    currentMatch.targetedByWerewolves = _target;
                    require(player.role == Roles.WEREWOLF, "Only werewolves can kill during the night");
                    require(playerInfoByMatch[_matchId][_target].isAlive, "Target is already out of the game");
                } 

            } else if(_action == Actions.CHECK) {
                require(player.role == Roles.PROPHET, "Only the seer can check during the night");
                currentMatch.checkedRecords[_target] = true;

            } else {
                revert("Invalid action for the night phase");
            }
        } else if(currentPhase == GamePhase.DAY_SPEAKING) {
            require(_action == Actions.SPEAK, "Only speaking is allowed during this phase");
        } else if(currentPhase == GamePhase.DAY_VOTING) {
            require(_action == Actions.VOTE, "Only voting is allowed during this phase");
            require(playerInfoByMatch[_matchId][_target].isAlive, "Target is already out of the game");
            matches[_matchId].votes[_target] += 1;  
        } else {
            revert("Invalid game phase");
        }

        currentMatch.playersActedThisRound += 1;


        player.actionContext = ActionContext({
            action: _action,
            target: _target,
            args: args
        });
        player.hasActed = true;  // Mark the player as having acted in this round
    }
 
    function endRound(uint _matchId) public {
        Match storage game = matches[_matchId];

        require(block.timestamp > matches[_matchId].roundEndTime, "Cannot manually end the round before the time limit.");

        require(game.status == MatchStatus.NOT_STARTED, "The match is not ongoing.");

        if(game.currentPhase == GamePhase.NIGHT) {
            if(matches[_matchId].targetedByWerewolves != address(0)) {
                playerInfoByMatch[_matchId][matches[_matchId].targetedByWerewolves].isDead = true;
                matches[_matchId].targetedByWerewolves = address(0); 
            }


            game.currentPhase = GamePhase.DAY_SPEAKING;
        } else if(game.currentPhase == GamePhase.DAY_SPEAKING) {
            game.currentPhase = GamePhase.DAY_VOTING;
        } else if(game.currentPhase == GamePhase.DAY_VOTING) {
            address maxVotedPlayer = address(0);
            uint maxVotes = 0;

            for(uint i = 0; i < matches[_matchId].playerCount; i++) {
                address currentPlayerAddress = matches[_matchId].players[i].playerAddress;
                uint currentVotes = matches[_matchId].votes[currentPlayerAddress];
                if(currentVotes > maxVotes) {
                    maxVotedPlayer = currentPlayerAddress;
                    maxVotes = currentVotes;
                }
            }

            if(maxVotedPlayer != address(0)) {
                playerInfoByMatch[_matchId][maxVotedPlayer].isDead = true;
            }

            for(uint i = 0; i < matches[_matchId].playerCount; i++) {
                delete matches[_matchId].votes[matches[_matchId].players[i].playerAddress];
            }
            game.currentPhase = GamePhase.NIGHT;
            game.roundNumber += 1;
        }



        uint wolfCount = 0;
        uint villagerCount = 0;
        for(uint i = 0; i < game.playerCount; i++) {
            if(game.players[i].role == Roles.WEREWOLF && !game.players[i].isDead) {
                wolfCount++;
            } else if(!game.players[i].isDead) {
                villagerCount++;
            }
        }

        Match storage currentMatch = matches[_matchId];
        if(wolfCount == 0) {
            game.winningFaction = Roles.VILLAGER;
            game.winnersCount = villagerCount;
            distributeRewards(_matchId);
            currentMatch.status = MatchStatus.ENDED;
            return;
        } else if(wolfCount >= villagerCount) {
            game.winningFaction = Roles.WEREWOLF;
            game.winnersCount = wolfCount;
            distributeRewards(_matchId);
            currentMatch.status = MatchStatus.ENDED;
            return;
        }

        //  start new round    
        currentMatch.roundEndTime = block.timestamp + ROUND_DURATION;
        currentMatch.playersActedThisRound = 0;


        // Update lastRoundActions for the match after determining the actions for the current round
        for (uint i = 0; i < 6; i++) {
            matches[_matchId].lastRoundActions[i] = matches[_matchId].players[i].actionContext;
        }

    }

    // ========== PUBLIC VIEWS ========== 
       // Other utility functions, events and game logic as needed
    function getMyRole(uint _matchId) external view returns(Roles) {
        require(playerInfoByMatch[_matchId][msg.sender].playerAddress == msg.sender, "You are not part of this match");
        return playerInfoByMatch[_matchId][msg.sender].role;
    }
    
    // New view function to get the status of all players in a match
    function getMatchStatus(uint _matchId) external view returns (PlayerStatus[6] memory) {
        PlayerStatus[6] memory statusList;
        
         for (uint i = 0; i < 6; i++) {
            Player memory currentPlayer = matches[_matchId].players[i];
            statusList[i] = PlayerStatus({
                playerAddress: currentPlayer.playerAddress,
                isAlive: currentPlayer.isAlive,
                role: currentPlayer.role
            });
        }
        
        
        return statusList;
    }

    function getMatchResult(uint _matchId) external view returns (Roles winningFaction, uint winnersCount) {
        Match storage game = matches[_matchId];
        require(game.status == MatchStatus.ENDED, "The match is not finished yet.");

        return (game.winningFaction, game.winnersCount);
    }

    // ========== INTERNAL FUNCTIONS ========== 
    function checkEndRound(uint256 matchId) internal {
        Match storage currentMatch = matches[matchId];

        if (currentMatch.playersActedThisRound == currentMatch.players.length && block.timestamp > currentMatch.roundEndTime) {
            endRound(matchId);
        }
    }

    function startMatch(uint _matchId) internal {
        Match storage game = matches[_matchId];
        
        require(game.playerCount == 6, "Not enough players");

        bytes32 randomHash = blockhash(block.number - 1);

        for (uint i = 0; i < 6; i++) {
            Roles role;
            if (i < 2) {
                role = Roles.WEREWOLF ;  
            } else if (i == 2) {
                role = Roles.PROPHET;  
            } else if (i == 3) {
                role = Roles.HUNTER;  
            } else {
                role = Roles.VILLAGER;  
            }

            uint n = uint(randomHash) % 6;
            Player storage playerToAssign = game.players[n];
            while(playerToAssign.role != Roles.NONE) {
                n = (n+1) % 6;
                playerToAssign = game.players[n];
            }

            playerToAssign.role = Roles(role);
        }
        
        matches[_matchId].currentPhase = GamePhase.NIGHT; 
        matches[_matchId].status = MatchStatus.STARTED;
        
    }


    function distributeRewards(uint _matchId) internal {
        Match storage game = matches[_matchId];
        uint256 rewardPerWinner = game.totalPot / game.winnersCount; // split the pot equally among winners

        for (uint i = 0; i < game.playerCount; i++) {
            if (!game.players[i].isDead && ((game.winningFaction == Roles.WEREWOLF && game.players[i].role == game.winningFaction) || (game.winningFaction != Roles.WEREWOLF && game.players[i].role != Roles.WEREWOLF)))  {
                address payable winnerAddress = payable(game.players[i].playerAddress); // convert to payable address
                winnerAddress.transfer(rewardPerWinner); // transfer the rewards
            }
        }

        game.totalPot = 0; // reset the pot for the match
    }

}
