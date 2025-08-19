"use strict";
var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.StakingClient = void 0;
const aptos_1 = require("aptos");
class StakingClient {
    constructor(nodeUrl, pid, network) {
        this.client = new aptos_1.AptosClient(nodeUrl);
        // Initialize the module owner account here
        this.pid = pid;
        this.provider = new aptos_1.Provider(network);
    }
    /**
     * Create Staking
     * @param stakingCreator staking creator
     * @param dpr daily interest rate
     * @param collectionName Collection name
     * @param totalAmount Total Amount
     * @param typeArgs Type Arguments
     * @returns Promise<TxnBuilderTypes.RawTransaction>
     */
    // :!:>createStaking
    createStaking(stakingCreator, dpr, collectionName, totalAmount, typeArgs) {
        return __awaiter(this, void 0, void 0, function* () {
            return yield this.provider.generateTransaction(stakingCreator, {
                function: `${this.pid}::movement_staking::create_staking`,
                type_arguments: [typeArgs],
                arguments: [dpr, collectionName, collectionName, totalAmount],
            });
        });
    }
    /**
     *  Update DPR
     * @param  stakingCreator staking creator
     * @param dpr daily interest rate
     * @param collectionName Collection name
     * @returns Promise<TxnBuilderTypes.RawTransaction>
     */
    // :!:>updateDPR
    updateDPR(stakingCreator, dpr, collectionName) {
        return __awaiter(this, void 0, void 0, function* () {
            return yield this.provider.generateTransaction(stakingCreator, {
                function: `${this.pid}::movement_staking::update_dpr`,
                type_arguments: [],
                arguments: [dpr, collectionName,],
            });
        });
    }
    /**
   *  creatorStopStaking
   * @param  stakingCreator staking creator
   * @param collectionName Collection name
   * @returns Promise<TxnBuilderTypes.RawTransaction>
   */
    // :!:>creatorStopStaking
    creatorStopStaking(stakingCreator, collectionName) {
        return __awaiter(this, void 0, void 0, function* () {
            return yield this.provider.generateTransaction(stakingCreator, {
                function: `${this.pid}::movement_staking::creator_stop_staking`,
                type_arguments: [],
                arguments: [collectionName,],
            });
        });
    }
    /**
   *  deposit_staking_rewards
   * @param  stakingCreator staking creator
   * @param amount additional staking rewards
   * @param collectionName Collection name
   * @param typeArgs Type Arguments
   * @returns Promise<TxnBuilderTypes.RawTransaction>
   */
    // :!:>deposit_staking_rewards
    depositStakingRewards(stakingCreator, amount, collectionName, typeArgs) {
        return __awaiter(this, void 0, void 0, function* () {
            return yield this.provider.generateTransaction(stakingCreator, {
                function: `${this.pid}::movement_staking::deposit_staking_rewards`,
                type_arguments: [typeArgs],
                arguments: [collectionName, amount,],
            });
        });
    }
    /**
    *  Staking
    * @param staker Who stakes token
    * @param stakingCreator staking creator
    * @param collectionName Collection name
    * @param tokenName Token name
    * @param propertyVersion token property version
    * @param tokens number of tokens to be staked
    * @returns Promise<TxnBuilderTypes.RawTransaction>
    */
    // :!:>stakeToken
    stakeToken(staker, stakingCreator, collectionName, tokenName, propertyVersion, tokens) {
        return __awaiter(this, void 0, void 0, function* () {
            return yield this.provider.generateTransaction(staker, {
                function: `${this.pid}::movement_staking::stake_token`,
                type_arguments: [],
                arguments: [stakingCreator, collectionName, tokenName, propertyVersion, tokens],
            });
        });
    }
    /**
     *  Claim Reward
     * @param staker Who stakes token
     * @param stakingCreator staking creator
     * @param collectionName Collection name
     * @param tokenName Token name
     * @returns Promise<TxnBuilderTypes.RawTransaction>
     */
    // :!:>claim_reward
    claimReward(staker, stakingCreator, collectionName, tokenName) {
        return __awaiter(this, void 0, void 0, function* () {
            return yield this.provider.generateTransaction(staker, {
                function: `${this.pid}::movement_staking::claim_reward`,
                type_arguments: [],
                arguments: [collectionName, tokenName, stakingCreator,],
            });
        });
    }
    /**
  *  UnStaking
  * @param staker Who stakes token
  * @param stakingCreator staking creator
  * @param collectionName Collection name
  * @param tokenName Token name
  * @param propertyVersion token property version
  * @param typeArgs type Arguments
  * @returns Promise<TxnBuilderTypes.RawTransaction>
  */
    // :!:>unstakeToken
    unstakeToken(staker, stakingCreator, collectionName, tokenName, propertyVersion, typeArgs) {
        return __awaiter(this, void 0, void 0, function* () {
            return yield this.provider.generateTransaction(staker, {
                function: `${this.pid}::movement_staking::unstake_token`,
                type_arguments: [typeArgs],
                arguments: [stakingCreator, collectionName, tokenName, propertyVersion,],
            });
        });
    }
}
exports.StakingClient = StakingClient;
//# sourceMappingURL=staking.js.map