/// Contract to stake NFTs (aka tokens) and earn FA rewards
/// Adapted from a contract created by Mokshya Protocol

module movement_staking::nft_staking
{
    use std::signer;

    use std::vector;

    use aptos_framework::account;
    use aptos_framework::fungible_asset;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self as object, Object};
    use aptos_framework::timestamp;
    use aptos_token_objects::collection::Collection;
    use aptos_token_objects::token::{Self, Token};

    use movement_staking::freeze_registry;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::smart_table::{Self, SmartTable};
    use std::bcs::to_bytes;

    // Staking resource for collection
    struct MovementStaking has key {
        collection: address,
        // amount of token paid in a week for staking one token,
        // changed to dpr (daily percentage return)in place of apr addressing demand
        dpr: u64,
        //the statust of the staking can be turned of by the creator to stop payments
        state: bool,
        //the amount stored in the vault to distribute for token staking
        amount: u64,
        //the FA metadata object in which the staking rewards are paid
        metadata: Object<fungible_asset::Metadata>, 
        //treasury_cap
        treasury_cap: account::SignerCapability,
        // if true, freeze rewards on claim (pre-TGE soulbound)
        is_locked: bool,
    }

    // Reward vault for staking
    struct MovementReward has drop, key {
        //staker
        staker: address,
        //address of the collection
        collection: address,
        // staked token address
        token_address: address,
        //withdrawn amount
        withdraw_amount: u64,
        //treasury_cap
        treasury_cap: account::SignerCapability,
        //time
        start_time: u64,
        //amount of tokens
        tokens: u64,
    }

    // Resource info for mapping collection address to staking address
    struct ResourceInfo has key {
        resource_map: SimpleMap<address, address>,
    }

    // Resource info for mapping seed (collection + token) to reward treasury address
    struct SeedResourceInfo has key {
        seed_resource_map: SimpleMap<vector<u8>, address>,
    }

    // Registry to track staked NFTs per user
    struct StakedNFTsRegistry has key {
        staked_nfts: SmartTable<address, vector<StakedNFTInfo>>,
    }

    // Registry of allowed collection IDs for staking
    struct AllowedCollectionsRegistry has key {
        allowed_collections: SmartTable<address, bool>, // collection_addr -> true/false
        admin: address,
    }

    // Global registry of all staking pools for easy discovery
    struct StakingPoolsRegistry has key {
        staking_pools: SmartTable<address, address>, // collection_addr -> resource_address
    }

    // Info about each staked NFT
    struct StakedNFTInfo has store, drop, copy {
        nft_object_address: address,
        collection_addr: address,
        staked_at: u64,
    }

    // Info about user rewards for a specific FA
    struct UserRewardInfo has store, drop, copy {
        rewards: u64,
        fa_address: address,
    }

    // Getter functions for UserRewardInfo
    public fun get_rewards(reward_info: &UserRewardInfo): u64 {
        reward_info.rewards
    }

    public fun get_fa_address(reward_info: &UserRewardInfo): address {
        reward_info.fa_address
    }

    // Error codes
    const ENO_COLLECTION: u64=0;
    const ESTAKING_EXISTS: u64=1;
    const ENO_STAKING: u64=2;
    const ENO_TOKEN_IN_TOKEN_STORE: u64=3;
    const ESTOPPED: u64=4;
    const EMETADATA_MISMATCH: u64=5;
    const ESTAKER_MISMATCH: u64=6;
    const EINSUFFICIENT_FUND: u64=7;
    const EINSUFFICIENT_TOKENS: u64=8;
    const ECOLLECTION_NOT_ALLOWED: u64=9;
    const ENOT_ADMIN: u64=10;


    // -------- Functions -------- 
    
    /// Initializes the global registries for tracking staked NFTs and allowed collections
    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        
        // Initialize staked NFTs registry
        move_to(admin, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
        
        // Initialize allowed collections registry
        move_to(admin, AllowedCollectionsRegistry {
            allowed_collections: smart_table::new(),
            admin: admin_addr,
        });

        // Initialize staking pools registry
        move_to(admin, StakingPoolsRegistry {
            staking_pools: smart_table::new(),
        });
    }
    
    /// Creates a new staking pool for a collection with specified daily percentage return
    public entry fun create_staking(
        creator: &signer,
        dpr: u64,//rate of payment,
        collection_obj: Object<Collection>,
        total_amount: u64,
        metadata: Object<fungible_asset::Metadata>,
        // Whether or not to lock the reward tokens earned in the user's account 
        is_locked: bool,
    ) acquires ResourceInfo, AllowedCollectionsRegistry, StakingPoolsRegistry {
        //verify the creator has the collection (DA standard)
        let collection_addr = object::object_address(&collection_obj);
        assert!(object::is_object(collection_addr), ENO_COLLECTION);
        
        // Check if collection is allowed for staking
        let allowed_collections = borrow_global<AllowedCollectionsRegistry>(@movement_staking);
        assert!(smart_table::contains(&allowed_collections.allowed_collections, collection_addr), ECOLLECTION_NOT_ALLOWED);
        //
        let (staking_treasury, staking_treasury_cap) = account::create_resource_account(creator, to_bytes(&collection_addr)); //resource account to store funds and data
        let staking_treasury_signer_from_cap = account::create_signer_with_capability(&staking_treasury_cap);
        let staking_address = signer::address_of(&staking_treasury);
        assert!(!exists<MovementStaking>(staking_address), ESTAKING_EXISTS);
        create_add_resource_info(creator, collection_addr, staking_address);
        // the creator needs to transfer FA into the staking treasury
        primary_fungible_store::transfer(creator, metadata, staking_address, total_amount);
        move_to<MovementStaking>(&staking_treasury_signer_from_cap, MovementStaking{
        collection: collection_addr,
        dpr,
        state: true,
        amount: total_amount,
        metadata, 
        treasury_cap: staking_treasury_cap,
        is_locked,
        });
        
        // Add to global staking pools registry (just for discovery)
        let global_registry = borrow_global_mut<StakingPoolsRegistry>(@movement_staking);
        smart_table::add(&mut global_registry.staking_pools, collection_addr, staking_address);
    }

    /// Updates the daily percentage return rate for an existing staking pool
    public entry fun update_dpr(
        creator: &signer,
        dpr: u64, //rate of payment,
        collection_obj: Object<Collection>, //the collection object owned by Creator 
    ) acquires MovementStaking, ResourceInfo {
        let creator_addr = signer::address_of(creator);
        //verify the creator has the collection
        let collection_addr = object::object_address(&collection_obj);
        let staking_address = get_and_validate_staking_address(creator_addr, collection_addr);
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        staking_data.dpr = dpr;
        

    }

    /// Stops staking for a collection, preventing new stakes and claims
    public entry fun creator_stop_staking(
        creator: &signer,
        collection_obj: Object<Collection>, //the collection object owned by Creator 
    ) acquires MovementStaking, ResourceInfo {
        let creator_addr = signer::address_of(creator);
        //get staking address
        let collection_addr = object::object_address(&collection_obj);
        let staking_address = get_resource_address(creator_addr, collection_addr);
        assert!(exists<MovementStaking>(staking_address), ENO_STAKING);// the staking doesn't exists
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        staking_data.state = false;
        

    }

    /// Deposits additional reward tokens into the staking pool (does not change staking state)
    public entry fun deposit_staking_rewards(
        creator: &signer,
        collection_obj: Object<Collection>, //the collection object owned by Creator 
        amount: u64,
        ) acquires MovementStaking, ResourceInfo {
        let creator_addr = signer::address_of(creator);
        //verify the creator has the collection
         assert!(exists<ResourceInfo>(creator_addr), ENO_STAKING);
        let collection_addr = object::object_address(&collection_obj);
        let staking_address = get_resource_address(creator_addr, collection_addr);
        assert!(exists<MovementStaking>(staking_address), ENO_STAKING);// the staking doesn't exists       
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        // Transfer FA from creator to staking treasury store
        primary_fungible_store::transfer(creator, staking_data.metadata, staking_address, amount);
        staking_data.amount = staking_data.amount + amount;
        // Note: deposit_staking_rewards does NOT change the staking state
        

    }

    /// Allows the creator to resume staking for a previously stopped collection
    /// This function explicitly re-enables staking after it has been stopped
    public entry fun creator_resume_staking(
        creator: &signer,
        collection_obj: Object<Collection>,
    ) acquires MovementStaking, ResourceInfo {
        let creator_addr = signer::address_of(creator);
        // Verify the creator has the collection
        assert!(exists<ResourceInfo>(creator_addr), ENO_STAKING);
        let collection_addr = object::object_address(&collection_obj);
        let staking_address = get_resource_address(creator_addr, collection_addr);
        assert!(exists<MovementStaking>(staking_address), ENO_STAKING);
        
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        // Re-enable staking
        staking_data.state = true;
        

    }

    /// Adds a collection to the allowed list for staking (admin only)
    public entry fun add_allowed_collection(
        admin: &signer,
        collection_obj: Object<Collection>,
    ) acquires AllowedCollectionsRegistry {
        let admin_addr = signer::address_of(admin);
        let collection_addr = object::object_address(&collection_obj);
        let allowed_collections = borrow_global_mut<AllowedCollectionsRegistry>(@movement_staking);
        assert!(allowed_collections.admin == admin_addr, ENOT_ADMIN);
        
        if (!smart_table::contains(&allowed_collections.allowed_collections, collection_addr)) {
            smart_table::add(&mut allowed_collections.allowed_collections, collection_addr, true);
        };
    }

    /// Removes a collection from the allowed list for staking (admin only)
    public entry fun remove_allowed_collection(
        admin: &signer,
        collection_obj: Object<Collection>,
    ) acquires AllowedCollectionsRegistry {
        let admin_addr = signer::address_of(admin);
        let collection_addr = object::object_address(&collection_obj);
        let allowed_collections = borrow_global_mut<AllowedCollectionsRegistry>(@movement_staking);
        assert!(allowed_collections.admin == admin_addr, ENOT_ADMIN);
        
        if (smart_table::contains(&allowed_collections.allowed_collections, collection_addr)) {
            smart_table::remove(&mut allowed_collections.allowed_collections, collection_addr);
        };
    }

    #[view]
    /// Checks if a collection is allowed for staking
    public fun is_collection_allowed(collection_obj: Object<Collection>): bool acquires AllowedCollectionsRegistry {
        let collection_addr = object::object_address(&collection_obj);
        let allowed_collections = borrow_global<AllowedCollectionsRegistry>(@movement_staking);
        smart_table::contains(&allowed_collections.allowed_collections, collection_addr)
    }

    #[view]
    /// Returns all allowed collection addresses for staking
    public fun get_allowed_collections(): vector<address> acquires AllowedCollectionsRegistry {
        let allowed_collections = borrow_global<AllowedCollectionsRegistry>(@movement_staking);
        let result = vector::empty<address>();
        
        // Iterate through the smart table and collect all allowed collection addresses
        let keys = smart_table::keys(&allowed_collections.allowed_collections);
        let i = 0;
        let len = vector::length(&keys);
        
        while (i < len) {
            let key = vector::borrow(&keys, i);
            vector::push_back(&mut result, *key);
            i = i + 1;
        };
        
        result
    }

    #[view]
    /// Returns accumulated rewards for a user for a specific fungible asset metadata
    public fun get_user_accumulated_rewards(user_address: address, metadata: Object<fungible_asset::Metadata>): u64 acquires StakedNFTsRegistry, MovementReward, MovementStaking, ResourceInfo, SeedResourceInfo {
        // Get user staked NFTs if they exist
        let staked_nfts = get_user_staked_nfts_if_exists(user_address);
        if (vector::is_empty(&staked_nfts)) {
            return 0
        };
        let total_rewards = 0u64;
        let i = 0;
        let len = vector::length(&staked_nfts);
        
        while (i < len) {
            let nft_info = vector::borrow(&staked_nfts, i);
            
            // Calculate seed for the reward treasury using collection address + token address
            // This must match the seed generation in stake_token
            let seed = to_bytes(&nft_info.collection_addr);
            let seed2 = to_bytes(&nft_info.nft_object_address);
            // Concatenate the byte vectors
            let combined_seed = vector::empty<u8>();
            vector::append(&mut combined_seed, seed);
            vector::append(&mut combined_seed, seed2);
            
            // Check if the seed exists in the registry before trying to get the resource address
            if (check_map_by_seed(user_address, combined_seed)) {
                // Get the reward treasury address
                let reward_treasury_address = get_resource_address_by_seed(user_address, combined_seed);
                
                // Check if reward data exists and calculate rewards
                if (exists<MovementReward>(reward_treasury_address)) {
                let reward_data = borrow_global<MovementReward>(reward_treasury_address);
                
                // Get staking pool data to get the daily percentage return
                let creator_addr = token::creator(object::address_to_object<Token>(nft_info.nft_object_address));
                let staking_address = get_resource_address(creator_addr, nft_info.collection_addr);
                
                if (exists<MovementStaking>(staking_address)) {
                    let staking_data = borrow_global<MovementStaking>(staking_address);
                    
                    // Only calculate rewards if this staking pool uses the specified metadata
                    if (object::object_address(&staking_data.metadata) == object::object_address(&metadata)) {
                        // Calculate accumulated rewards
                        let now = timestamp::now_seconds();
                        let time_diff = now - reward_data.start_time;
                        
                        // Calculate rewards: (time_diff * dpr * tokens) / 86400 - withdraw_amount
                        let earned_rewards = ((time_diff * staking_data.dpr * reward_data.tokens) / 86400);
                        let net_rewards = if (earned_rewards > reward_data.withdraw_amount) {
                            earned_rewards - reward_data.withdraw_amount
                        } else {
                            0
                        };
                        
                        total_rewards = total_rewards + net_rewards;
                    };
                };
            };
            };
            
            i = i + 1;
        };
        
        total_rewards
    }

    #[view]
    /// Returns all accumulated rewards for a user across all FA types as a vector of UserRewardInfo
    public fun get_all_user_accumulated_rewards(user_address: address): vector<UserRewardInfo> acquires StakedNFTsRegistry, MovementReward, MovementStaking, ResourceInfo, SeedResourceInfo {
        // Get user staked NFTs if they exist
        let staked_nfts = get_user_staked_nfts_if_exists(user_address);
        if (vector::is_empty(&staked_nfts)) {
            return vector::empty<UserRewardInfo>()
        };
        let all_rewards = vector::empty<UserRewardInfo>();
        let i = 0;
        let len = vector::length(&staked_nfts);
        
        while (i < len) {
            let nft_info = vector::borrow(&staked_nfts, i);
            let token_obj = object::address_to_object<Token>(nft_info.nft_object_address);
            
            // Get staking pool data to get the metadata
            let creator_addr = token::creator(token_obj);
            let staking_address = get_resource_address(creator_addr, nft_info.collection_addr);
            
            if (exists<MovementStaking>(staking_address)) {
                let staking_data = borrow_global<MovementStaking>(staking_address);
                let fa_address = object::object_address(&staking_data.metadata);
                
                // Check if this FA is already in our result vector
                let j = 0;
                let rewards_len = vector::length(&all_rewards);
                let found = false;
                
                while (j < rewards_len) {
                    let existing_reward_info = vector::borrow(&all_rewards, j);
                    if (existing_reward_info.fa_address == fa_address) {
                        found = true;
                        break
                    };
                    j = j + 1;
                };
                
                if (!found) {
                    // Calculate total rewards for this FA type across all user's tokens
                    let total_fa_rewards = 0u64;
                    let k = 0;
                    let staked_len = vector::length(&staked_nfts);
                    
                    while (k < staked_len) {
                        let nft_info_k = vector::borrow(&staked_nfts, k);
                        let token_obj_k = object::address_to_object<Token>(nft_info_k.nft_object_address);
                        let creator_addr_k = token::creator(token_obj_k);
                        let staking_address_k = get_resource_address(creator_addr_k, nft_info_k.collection_addr);
                        
                        if (exists<MovementStaking>(staking_address_k)) {
                            let staking_data_k = borrow_global<MovementStaking>(staking_address_k);
                            let fa_address_k = object::object_address(&staking_data_k.metadata);
                            
                            // Only include tokens from the same FA type
                            if (fa_address_k == fa_address) {
                                let token_addr_k = object::object_address(&token_obj_k);
                                let seed_k = to_bytes(&nft_info_k.collection_addr);
                                let seed2_k = to_bytes(&token_addr_k);
                                let combined_seed_k = vector::empty<u8>();
                                vector::append(&mut combined_seed_k, seed_k);
                                vector::append(&mut combined_seed_k, seed2_k);
                                
                                if (check_map_by_seed(user_address, combined_seed_k)) {
                                    let reward_treasury_address_k = get_resource_address_by_seed(user_address, combined_seed_k);
                                    if (exists<MovementReward>(reward_treasury_address_k)) {
                                        let reward_data_k = borrow_global<MovementReward>(reward_treasury_address_k);
                                        let now = timestamp::now_seconds();
                                        let time_diff = now - reward_data_k.start_time;
                                        let earned_rewards = ((time_diff * staking_data_k.dpr * reward_data_k.tokens) / 86400);
                                        let token_rewards = if (earned_rewards > reward_data_k.withdraw_amount) {
                                            earned_rewards - reward_data_k.withdraw_amount
                                        } else {
                                            0
                                        };
                                        total_fa_rewards = total_fa_rewards + token_rewards;
                                    };
                                };
                            };
                        };
                        k = k + 1;
                    };
                    
                    let reward_info = UserRewardInfo {
                        rewards: total_fa_rewards,
                        fa_address,
                    };
                    vector::push_back(&mut all_rewards, reward_info);
                };
            };
            
            i = i + 1;
        };
        
        all_rewards
    }

    #[view]
    /// Returns all unique fungible asset metadata that a user has staked NFTs for
    public fun get_user_reward_metadata_types(user_address: address): vector<Object<fungible_asset::Metadata>> acquires StakedNFTsRegistry, MovementStaking, ResourceInfo {
        // Get user staked NFTs if they exist
        let staked_nfts = get_user_staked_nfts_if_exists(user_address);
        if (vector::is_empty(&staked_nfts)) {
            return vector::empty<Object<fungible_asset::Metadata>>()
        };
        let metadata_types = vector::empty<Object<fungible_asset::Metadata>>();
        let i = 0;
        let len = vector::length(&staked_nfts);
        
        while (i < len) {
            let nft_info = vector::borrow(&staked_nfts, i);
            
            // Get staking pool data to get the metadata
            let creator_addr = token::creator(object::address_to_object<Token>(nft_info.nft_object_address));
            let staking_address = get_resource_address(creator_addr, nft_info.collection_addr);
            
            if (exists<MovementStaking>(staking_address)) {
                let staking_data = borrow_global<MovementStaking>(staking_address);
                
                // Check if this metadata is already in our result vector
                if (!vector::contains(&metadata_types, &staking_data.metadata)) {
                    vector::push_back(&mut metadata_types, staking_data.metadata);
                };
            };
            
            i = i + 1;
        };
        
        metadata_types
    }

    #[view]
    /// Returns resource addresses of all active staking pools (where state = true)
    public fun view_active_staking_pools(): vector<address> acquires StakingPoolsRegistry, MovementStaking {
        if (!exists<StakingPoolsRegistry>(@movement_staking)) {
            return vector::empty<address>()
        };
        
        let registry = borrow_global<StakingPoolsRegistry>(@movement_staking);
        let active_pools = vector::empty<address>();
        
        // Iterate through all staking pools and filter by state = true
        let keys = smart_table::keys(&registry.staking_pools);
        let i = 0;
        let len = vector::length(&keys);
        
        while (i < len) {
            let collection_addr = vector::borrow(&keys, i);
            let staking_address = smart_table::borrow(&registry.staking_pools, *collection_addr);
            
            // Check if the staking pool is active
            if (exists<MovementStaking>(*staking_address)) {
                let staking_data = borrow_global<MovementStaking>(*staking_address);
                if (staking_data.state) {
                    // Only include active pools
                    vector::push_back(&mut active_pools, *staking_address);
                };
            };
            i = i + 1;
        };
        
        active_pools
    }

    #[view]
    /// Returns resource addresses of all staking pools (active and inactive)
    public fun view_all_staking_pools(): vector<address> acquires StakingPoolsRegistry {
        if (!exists<StakingPoolsRegistry>(@movement_staking)) {
            return vector::empty<address>()
        };
        
        let registry = borrow_global<StakingPoolsRegistry>(@movement_staking);
        let all_pools = vector::empty<address>();
        
        // Iterate through all staking pools
        let keys = smart_table::keys(&registry.staking_pools);
        let i = 0;
        let len = vector::length(&keys);
        
        while (i < len) {
            let collection_addr = vector::borrow(&keys, i);
            let staking_address = smart_table::borrow(&registry.staking_pools, *collection_addr);
            vector::push_back(&mut all_pools, *staking_address);
            i = i + 1;
        };
        
        all_pools
    }




    // -------- Functions for staking and earning rewards -------- 

    /// Internal function containing the core staking logic
    fun stake_token_internal(
        staker: &signer,
        nft: Object<Token>,
    ) acquires MovementStaking, ResourceInfo, MovementReward, StakedNFTsRegistry, SeedResourceInfo {
        let staker_addr = signer::address_of(staker);
        // verify ownership of the token
        assert!(object::owner(nft) == staker_addr, ENO_TOKEN_IN_TOKEN_STORE);
        // derive creator from token (DA standard)
        let creator_addr = token::creator(nft);
        // verify the collection exists by getting the collection address directly
        let collection_addr = token::collection_object(nft);
        let collection_addr = object::object_address(&collection_addr);
        assert!(object::is_object(collection_addr), ENO_COLLECTION);
        // staking pool
        let staking_address = get_resource_address(creator_addr, collection_addr);
        assert!(exists<MovementStaking>(staking_address), ENO_STAKING);
        let staking_data = borrow_global<MovementStaking>(staking_address);
        assert!(staking_data.state, ESTOPPED);
        // seed for reward vault mapping: collection address + token address
        let token_addr = object::object_address(&nft);
        let seed = to_bytes(&collection_addr);
        let seed2 = to_bytes(&token_addr);
        // Concatenate the byte vectors
        let combined_seed = vector::empty<u8>();
        vector::append(&mut combined_seed, seed);
        vector::append(&mut combined_seed, seed2);
        //allowing restaking
        let should_pass_restake = check_map_by_seed(staker_addr, combined_seed);
        if (should_pass_restake) {
            let reward_treasury_address = get_resource_address_by_seed(staker_addr, combined_seed);
            assert!(exists<MovementReward>(reward_treasury_address), ENO_STAKING);
            let reward_data = borrow_global_mut<MovementReward>(reward_treasury_address);
            let now = timestamp::now_seconds();
            reward_data.tokens=1;
            reward_data.start_time=now;
            reward_data.withdraw_amount=0;
            reward_data.token_address = object::object_address(&nft);
            object::transfer(staker, nft, reward_treasury_address);

        } else {
            let (reward_treasury, reward_treasury_cap) = account::create_resource_account(staker, combined_seed); //resource account to store funds and data
            let reward_treasury_signer_from_cap = account::create_signer_with_capability(&reward_treasury_cap);
            let reward_treasury_address = signer::address_of(&reward_treasury);
            assert!(!exists<MovementReward>(reward_treasury_address), ESTAKING_EXISTS);
            create_add_resource_info_by_seed(staker, combined_seed, reward_treasury_address);
            let now = timestamp::now_seconds();
            let token_addr = object::object_address(&nft);
            object::transfer(staker, nft, reward_treasury_address);
            move_to<MovementReward>(&reward_treasury_signer_from_cap , MovementReward{
            staker: staker_addr,
            collection: collection_addr,
            token_address: token_addr,
            withdraw_amount: 0,
            treasury_cap: reward_treasury_cap,
            start_time: now,
            tokens: 1,
            });
        };

        // Register the staked NFT
        let staked_nft_info = StakedNFTInfo {
            nft_object_address: token_addr,
            collection_addr,
            staked_at: timestamp::now_seconds(),
        };
        
        // Get the global registry (must exist)
        let registry = borrow_global_mut<StakedNFTsRegistry>(@movement_staking);
        
        // Get or create the user's staked NFTs vector
        if (!smart_table::contains(&registry.staked_nfts, staker_addr)) {
            smart_table::add(&mut registry.staked_nfts, staker_addr, vector::empty<StakedNFTInfo>());
        };
        
        let staked_nfts = smart_table::borrow_mut(&mut registry.staked_nfts, staker_addr);
        vector::push_back(staked_nfts, staked_nft_info);
    }

    /// Stakes an NFT token to start earning rewards based on the collection's daily percentage return
    public entry fun stake_token(
        staker: &signer,
        nft: Object<Token>,
    ) acquires MovementStaking, ResourceInfo, MovementReward, StakedNFTsRegistry, SeedResourceInfo {
        stake_token_internal(staker, nft);
    }

    /// Stakes multiple NFT tokens in a single transaction for efficiency
    public entry fun batch_stake_tokens(
        staker: &signer,
        nfts: vector<Object<Token>>,
    ) acquires MovementStaking, ResourceInfo, MovementReward, StakedNFTsRegistry, SeedResourceInfo {
        let nft_count = vector::length(&nfts);
        
        // Ensure we have at least one NFT to stake
        assert!(nft_count > 0, ENO_TOKEN_IN_TOKEN_STORE);
        
        // Stake each NFT individually using the existing stake_token logic
        let i = 0;
        while (i < nft_count) {
            let nft = *vector::borrow(&nfts, i);
            stake_token_internal(staker, nft);
            i = i + 1;
        };
    }

    /// Unstakes multiple NFT tokens in a single transaction for efficiency
    public entry fun batch_unstake_tokens(
        staker: &signer,
        nfts: vector<Object<Token>>,
    ) acquires MovementStaking, ResourceInfo, MovementReward, StakedNFTsRegistry, SeedResourceInfo {
        let nft_count = vector::length(&nfts);
        
        // Ensure we have at least one NFT to unstake
        assert!(nft_count > 0, ENO_TOKEN_IN_TOKEN_STORE);
        
        // Unstake each NFT individually using the existing unstake_token logic
        let i = 0;
        while (i < nft_count) {
            let nft = *vector::borrow(&nfts, i);
            unstake_token_internal(staker, nft);
            i = i + 1;
        };
    }




    /// Claims accumulated staking rewards for a specific staked token
    public entry fun claim_reward(
        staker: &signer, 
        token_obj: Object<Token>,
    ) acquires MovementStaking, MovementReward, ResourceInfo, SeedResourceInfo {
        let staker_addr = signer::address_of(staker);
        //verifying whether the creator has started the staking or not
        let collection_obj = token::collection_object(token_obj);
        let collection_addr = object::object_address(&collection_obj);
        let creator_addr = token::creator(token_obj);
        let staking_address = get_and_validate_staking_address(creator_addr, collection_addr);
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        let staking_treasury_signer_from_cap = account::create_signer_with_capability(&staking_data.treasury_cap);
        assert!(staking_data.state, ESTOPPED);
        // Generate seed using collection address + token address
        let token_addr = object::object_address(&token_obj);
        let combined_seed = generate_combined_seed(collection_addr, token_addr);
        let reward_treasury_address = get_resource_address_by_seed(staker_addr, combined_seed);
        assert!(exists<MovementReward>(reward_treasury_address), ENO_STAKING);
        let reward_data = borrow_global_mut<MovementReward>(reward_treasury_address);
        assert!(reward_data.staker==staker_addr, ESTAKER_MISMATCH);
        
        // Calculate rewards consistently with the helper function logic
        let release_amount = calculate_accumulated_rewards(reward_data.start_time, staking_data.dpr, reward_data.tokens, reward_data.withdraw_amount);
        if (staking_data.amount<release_amount)
        {
            staking_data.state=false;
            assert!(staking_data.amount>release_amount, EINSUFFICIENT_FUND);
        };
        
        primary_fungible_store::transfer(&staking_treasury_signer_from_cap, staking_data.metadata, staker_addr, release_amount);
        
        // Conditionally freeze the user's account for the claimed rewards (making them soulbound)
        if (staking_data.is_locked) {
            freeze_user_account(staker, staking_data.metadata);
        };
        
        staking_data.amount=staking_data.amount-release_amount;
        reward_data.withdraw_amount=reward_data.withdraw_amount+release_amount;
    }

    /// Claims accumulated staking rewards for multiple staked tokens in a single transaction
    public entry fun batch_claim_rewards(
        staker: &signer,
        token_objs: vector<Object<Token>>,
    ) acquires MovementStaking, MovementReward, ResourceInfo, SeedResourceInfo {
        let token_count = vector::length(&token_objs);
        
        // Ensure we have at least one token to claim rewards for
        assert!(token_count > 0, ENO_TOKEN_IN_TOKEN_STORE);
        
        // Claim rewards for each token individually
        let i = 0;
        while (i < token_count) {
            let token_obj = *vector::borrow(&token_objs, i);
            claim_reward(staker, token_obj);
            i = i + 1;
        };
    }

    /// Internal function containing the core unstaking logic
    fun unstake_token_internal(
        staker: &signer, 
        token_obj: Object<Token>,
    ) acquires MovementStaking, MovementReward, ResourceInfo, StakedNFTsRegistry, SeedResourceInfo {
        let staker_addr = signer::address_of(staker);
        //verifying whether the creator has started the staking or not
        let creator_addr = token::creator(token_obj);
        let collection_obj = token::collection_object(token_obj);
        let collection_addr = object::object_address(&collection_obj);
        let staking_address = get_resource_address(creator_addr, collection_addr);
        assert!(exists<MovementStaking>(staking_address), ENO_STAKING);// the staking doesn't exists
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        assert!(staking_data.state, ESTOPPED);
        //getting the seeds
        // Generate seed using collection address + token address
        let token_addr = object::object_address(&token_obj);
        let seed = to_bytes(&collection_addr);
        let seed2 = to_bytes(&token_addr);
        // Concatenate the byte vectors
        let combined_seed = vector::empty<u8>();
        vector::append(&mut combined_seed, seed);
        vector::append(&mut combined_seed, seed2);
        //getting reward treasury address which has the tokens
        let reward_treasury_address = get_resource_address_by_seed(staker_addr, combined_seed);
        assert!(exists<MovementReward>(reward_treasury_address), ENO_STAKING);
        let reward_data = borrow_global_mut<MovementReward>(reward_treasury_address);
        let reward_treasury_signer_from_cap = account::create_signer_with_capability(&reward_data.treasury_cap);
        assert!(reward_data.staker==staker_addr, ESTAKER_MISMATCH);
        // verify the reward treasury actually owns the token
        let token_obj = object::address_to_object<Token>(reward_data.token_address);
        assert!(object::owner(token_obj) == reward_treasury_address, EINSUFFICIENT_TOKENS);
        // Just return the NFT, don't transfer any rewards during unstaking
        // Users should claim rewards separately using claim_reward before unstaking
        object::transfer(&reward_treasury_signer_from_cap, token_obj, staker_addr);
        reward_data.tokens=0;
        reward_data.start_time=0;
        reward_data.withdraw_amount=0;

        // Deregister the staked NFT
        if (exists<StakedNFTsRegistry>(@movement_staking)) {
            let registry = borrow_global_mut<StakedNFTsRegistry>(@movement_staking);
            if (smart_table::contains(&registry.staked_nfts, staker_addr)) {
                let staked_nfts = smart_table::borrow_mut(&mut registry.staked_nfts, staker_addr);
                let i = 0;
                let len = vector::length(staked_nfts);
                while (i < len) {
                    let staked_nft = vector::borrow(staked_nfts, i);
                    if (staked_nft.nft_object_address == reward_data.token_address) {
                        vector::remove(staked_nfts, i);
                        break
                    };
                    i = i + 1;
                };
            };
        };
    }

    /// Unstakes an NFT token, claims final rewards, and returns the token to the staker
    public entry fun unstake_token (   
        staker: &signer, 
        token_obj: Object<Token>,
    ) acquires MovementStaking, MovementReward, ResourceInfo, StakedNFTsRegistry, SeedResourceInfo {
        unstake_token_internal(staker, token_obj);
    }

    // Helper functions

    /// Generates a combined seed from collection and token addresses for reward treasury mapping
    fun generate_combined_seed(collection_addr: address, token_addr: address): vector<u8> {
        let seed = to_bytes(&collection_addr);
        let seed2 = to_bytes(&token_addr);
        let combined_seed = vector::empty<u8>();
        vector::append(&mut combined_seed, seed);
        vector::append(&mut combined_seed, seed2);
        combined_seed
    }

    fun create_add_resource_info(account: &signer, collection_addr: address, resource: address) acquires ResourceInfo {
        let account_addr = signer::address_of(account);
        if (!exists<ResourceInfo>(account_addr)) {
            move_to(account, ResourceInfo { resource_map: simple_map::create() })
        };
        let maps = borrow_global_mut<ResourceInfo>(account_addr);
        simple_map::add(&mut maps.resource_map, collection_addr, resource);
    }

    fun create_add_resource_info_by_seed(account: &signer, seed: vector<u8>, resource: address) acquires SeedResourceInfo {
        let account_addr = signer::address_of(account);
        if (!exists<SeedResourceInfo>(account_addr)) {
            move_to(account, SeedResourceInfo { seed_resource_map: simple_map::create() })
        };
        let maps = borrow_global_mut<SeedResourceInfo>(account_addr);
        simple_map::add(&mut maps.seed_resource_map, seed, resource);
    }

    fun get_resource_address(creator_addr: address, collection_addr: address): address acquires ResourceInfo {
        assert!(exists<ResourceInfo>(creator_addr), ENO_STAKING);
        let maps = borrow_global<ResourceInfo>(creator_addr);
        let staking_address = *simple_map::borrow(&maps.resource_map, &collection_addr);
        staking_address

    }

    fun get_resource_address_by_seed(creator_addr: address, seed: vector<u8>): address acquires SeedResourceInfo {
        assert!(exists<SeedResourceInfo>(creator_addr), ENO_STAKING);
        let maps = borrow_global<SeedResourceInfo>(creator_addr);
        let staking_address = *simple_map::borrow(&maps.seed_resource_map, &seed);
        staking_address

    }

    fun check_map(creator_addr: address, collection_addr: address): bool acquires ResourceInfo {
        if (!exists<ResourceInfo>(creator_addr)) {
            false 
        } else {
            let maps = borrow_global_mut<ResourceInfo>(creator_addr);
            simple_map::contains_key(&maps.resource_map, &collection_addr)
        }
    }

    fun check_map_by_seed(creator_addr: address, seed: vector<u8>): bool acquires SeedResourceInfo {
        if (!exists<SeedResourceInfo>(creator_addr)) {
            false 
        } else {
            let maps = borrow_global_mut<SeedResourceInfo>(creator_addr);
            simple_map::contains_key(&maps.seed_resource_map, &seed)
        }
    }

    #[view]
    /// View function to check if staking is enabled for a collection
    public fun is_staking_enabled(creator_addr: address, collection_obj: Object<Collection>): bool acquires ResourceInfo, MovementStaking {
        if (!exists<ResourceInfo>(creator_addr)) {
            return false
        };
        let collection_addr = object::object_address(&collection_obj);
        let staking_address = get_resource_address(creator_addr, collection_addr);
        if (!exists<MovementStaking>(staking_address)) {
            return false
        };
        let staking_data = borrow_global<MovementStaking>(staking_address);
        staking_data.state
    }

    #[view]
    /// Returns all staked NFTs for a specific user address
    public fun get_staked_nfts(user_address: address): vector<StakedNFTInfo> acquires StakedNFTsRegistry {
        get_user_staked_nfts_if_exists(user_address)
    }

    #[view]
    /// Returns the number of staked NFTs for a specific user address
    public fun get_staked_nfts_count(user_address: address): u64 acquires StakedNFTsRegistry {
        let staked_nfts = get_user_staked_nfts_if_exists(user_address);
        vector::length(&staked_nfts)
    }

    /// Helper function to freeze a user's account for a specific FA metadata
    fun freeze_user_account(user: &signer, metadata: Object<fungible_asset::Metadata>) {
        // Delegate freezing logic to the freeze_registry module
        freeze_registry::freeze_user_account(user, metadata);
    }

    #[view]
    public fun get_staking_metadata(
        creator_addr: address, collection_obj: Object<Collection>
    ): Object<fungible_asset::Metadata> acquires MovementStaking, ResourceInfo {
        let collection_addr = object::object_address(&collection_obj);
        let staking_address = get_resource_address(creator_addr, collection_addr);
        assert!(exists<MovementStaking>(staking_address), ENO_STAKING);
        let staking_data = borrow_global<MovementStaking>(staking_address);
        staking_data.metadata
    }

    /// Calculates accumulated rewards for given reward and staking parameters
    fun calculate_accumulated_rewards(start_time: u64, dpr: u64, tokens: u64, withdraw_amount: u64): u64 {
        let now = timestamp::now_seconds();
        let time_diff = now - start_time;
        let earned_rewards = ((time_diff * dpr * tokens) / 86400);
        if (earned_rewards > withdraw_amount) {
            earned_rewards - withdraw_amount
        } else {
            0
        }
    }

    /// Validates and returns staking address for a given creator and collection
    fun get_and_validate_staking_address(creator_addr: address, collection_addr: address): address acquires ResourceInfo {
        let staking_address = get_resource_address(creator_addr, collection_addr);
        assert!(exists<MovementStaking>(staking_address), ENO_STAKING);
        staking_address
    }

    /// Gets user staked NFTs if they exist, returns empty vector if user has no staked NFTs
    fun get_user_staked_nfts_if_exists(user_address: address): vector<StakedNFTInfo> acquires StakedNFTsRegistry {
        if (!exists<StakedNFTsRegistry>(@movement_staking)) {
            return vector::empty<StakedNFTInfo>()
        };
        
        let registry = borrow_global<StakedNFTsRegistry>(@movement_staking);
        if (!smart_table::contains(&registry.staked_nfts, user_address)) {
            return vector::empty<StakedNFTInfo>()
        };
        
        let user_staked_nfts = smart_table::borrow(&registry.staked_nfts, user_address);
        *user_staked_nfts
    }

    #[test_only]
    public fun test_init_registries(token_staking: &signer) {
        // Initialize the global registries for testing
        move_to(token_staking, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
        move_to(token_staking, AllowedCollectionsRegistry {
            allowed_collections: smart_table::new(),
            admin: signer::address_of(token_staking),
        });
        move_to(token_staking, StakingPoolsRegistry {
            staking_pools: smart_table::new(),
        });
    }
    
    #[test_only]
    public fun test_init_registries_with_admin(token_staking: &signer, admin_addr: address) {
        // Initialize the global registries for testing
        move_to(token_staking, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
        move_to(token_staking, AllowedCollectionsRegistry {
            allowed_collections: smart_table::new(),
            admin: admin_addr,
        });
        move_to(token_staking, StakingPoolsRegistry {
            staking_pools: smart_table::new(),
        });
    }
}