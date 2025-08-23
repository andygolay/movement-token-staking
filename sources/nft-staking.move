/// Contract to stake NFTs (aka tokens) and earn FA rewards
/// Adapted from a contract created by Mokshya Protocol

module movement_staking::nft_staking
{
    use std::signer;
    use std::string::{String, append};
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::fungible_asset;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self as object, Object};
    use aptos_framework::timestamp;
    use aptos_token_objects::collection::{Self, Collection};
    use aptos_token_objects::token::{Self, Token};

    use movement_staking::freeze_registry;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::smart_table::{Self, SmartTable};
    use std::bcs::to_bytes;

    // Staking resource for collection
    struct MovementStaking has key {
        collection: String,
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
        //token_name
        token_name: String,
        //name of the collection
        collection: String,
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

    // Resource info for mapping collection name to staking address
    struct ResourceInfo has key {
        resource_map: SimpleMap< String, address>,
    }

    // Registry to track staked NFTs per user
    struct StakedNFTsRegistry has key {
        staked_nfts: SmartTable<address, vector<StakedNFTInfo>>,
    }

    // Registry of allowed collection IDs for staking
    struct AllowedCollectionsRegistry has key {
        allowed_collections: SmartTable<String, bool>,
        admin: address,
    }

    // Global registry of all staking pools for easy discovery
    struct StakingPoolsRegistry has key {
        staking_pools: SmartTable<address, StakingPoolReference>, // collection_addr -> lookup info
    }

    // Reference info to locate the actual MovementStaking data
    struct StakingPoolReference has store, drop, copy {
        creator: address,               // Who created the pool
        collection_name: String,        // Collection name for lookup
    }

    // Info about each staked NFT
    struct StakedNFTInfo has store, drop, copy {
        nft_object_address: address,
        collection_name: String,
        token_name: String,
        staked_at: u64,
    }

    // Error codes
    const ENO_NO_COLLECTION: u64=0;
    const ENO_STAKING_EXISTS: u64=1;
    const ENO_NO_STAKING: u64=2;
    const ENO_NO_TOKEN_IN_TOKEN_STORE: u64=3;
    const ENO_STOPPED: u64=4;
    const ENO_METADATA_MISMATCH: u64=5;
    const ENO_STAKER_MISMATCH: u64=6;
    const ENO_INSUFFICIENT_FUND: u64=7;
    const ENO_INSUFFICIENT_TOKENS: u64=8;
    const ENO_COLLECTION_NOT_ALLOWED: u64=9;
    const ENO_NOT_ADMIN: u64=10;


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
        let collection_name = collection::name(collection_obj);
        let collection_addr = object::object_address(&collection_obj);
        assert!(object::is_object(collection_addr), ENO_NO_COLLECTION);
        
        // Check if collection is allowed for staking
        let allowed_collections = borrow_global<AllowedCollectionsRegistry>(@movement_staking);
        assert!(smart_table::contains(&allowed_collections.allowed_collections, collection_name), ENO_COLLECTION_NOT_ALLOWED);
        //
        let (staking_treasury, staking_treasury_cap) = account::create_resource_account(creator, to_bytes(&collection_name)); //resource account to store funds and data
        let staking_treasury_signer_from_cap = account::create_signer_with_capability(&staking_treasury_cap);
        let staking_address = signer::address_of(&staking_treasury);
        assert!(!exists<MovementStaking>(staking_address), ENO_STAKING_EXISTS);
        create_add_resource_info(creator, collection_name, staking_address);
        // the creator needs to transfer FA into the staking treasury
        primary_fungible_store::transfer(creator, metadata, staking_address, total_amount);
        move_to<MovementStaking>(&staking_treasury_signer_from_cap, MovementStaking{
        collection: collection_name,
        dpr: dpr,
        state: true,
        amount: total_amount,
        metadata: metadata, 
        treasury_cap: staking_treasury_cap,
        is_locked: is_locked,
        });
        
        // Add to global staking pools registry
        let staking_pool_ref = StakingPoolReference {
            creator: signer::address_of(creator),
            collection_name: collection_name,
        };
        
        let global_registry = borrow_global_mut<StakingPoolsRegistry>(@movement_staking);
        smart_table::add(&mut global_registry.staking_pools, collection_addr, staking_pool_ref);
    }

    /// Updates the daily percentage return rate for an existing staking pool
    public entry fun update_dpr(
        creator: &signer,
        dpr: u64, //rate of payment,
        collection_obj: Object<Collection>, //the collection object owned by Creator 
    ) acquires MovementStaking, ResourceInfo {
        let creator_addr = signer::address_of(creator);
        //verify the creator has the collection
        let collection_name = collection::name(collection_obj);
        let staking_address = get_resource_address(creator_addr, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);// the staking doesn't exists
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
        let collection_name = collection::name(collection_obj);
        let staking_address = get_resource_address(creator_addr, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);// the staking doesn't exists
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
         assert!(exists<ResourceInfo>(creator_addr), ENO_NO_STAKING);
        let collection_name = collection::name(collection_obj);
        let staking_address = get_resource_address(creator_addr, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);// the staking doesn't exists       
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
        assert!(exists<ResourceInfo>(creator_addr), ENO_NO_STAKING);
        let collection_name = collection::name(collection_obj);
        let staking_address = get_resource_address(creator_addr, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);
        
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
        let collection_name = collection::name(collection_obj);
        let allowed_collections = borrow_global_mut<AllowedCollectionsRegistry>(@movement_staking);
        assert!(allowed_collections.admin == admin_addr, ENO_NOT_ADMIN);
        
        if (!smart_table::contains(&allowed_collections.allowed_collections, collection_name)) {
            smart_table::add(&mut allowed_collections.allowed_collections, collection_name, true);
        };
    }

    /// Removes a collection from the allowed list for staking (admin only)
    public entry fun remove_allowed_collection(
        admin: &signer,
        collection_obj: Object<Collection>,
    ) acquires AllowedCollectionsRegistry {
        let admin_addr = signer::address_of(admin);
        let collection_name = collection::name(collection_obj);
        let allowed_collections = borrow_global_mut<AllowedCollectionsRegistry>(@movement_staking);
        assert!(allowed_collections.admin == admin_addr, ENO_NOT_ADMIN);
        
        if (smart_table::contains(&allowed_collections.allowed_collections, collection_name)) {
            smart_table::remove(&mut allowed_collections.allowed_collections, collection_name);
        };
    }

    #[view]
    /// Checks if a collection is allowed for staking
    public fun is_collection_allowed(collection_obj: Object<Collection>): bool acquires AllowedCollectionsRegistry {
        let collection_name = collection::name(collection_obj);
        let allowed_collections = borrow_global<AllowedCollectionsRegistry>(@movement_staking);
        smart_table::contains(&allowed_collections.allowed_collections, collection_name)
    }

    #[view]
    /// Returns all allowed collections for staking
    public fun get_allowed_collections(): vector<String> acquires AllowedCollectionsRegistry {
        let allowed_collections = borrow_global<AllowedCollectionsRegistry>(@movement_staking);
        let result = vector::empty<String>();
        
        // Iterate through the smart table and collect all allowed collection names
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
    public fun get_user_accumulated_rewards(user_address: address, metadata: Object<fungible_asset::Metadata>): u64 acquires StakedNFTsRegistry, MovementReward, MovementStaking, ResourceInfo {
        // Check if user has any staked NFTs
        let registry = borrow_global<StakedNFTsRegistry>(@movement_staking);
        if (!smart_table::contains(&registry.staked_nfts, user_address)) {
            return 0
        };
        
        let staked_nfts = smart_table::borrow(&registry.staked_nfts, user_address);
        let total_rewards = 0u64;
        let i = 0;
        let len = vector::length(staked_nfts);
        
        while (i < len) {
            let nft_info = vector::borrow(staked_nfts, i);
            
            // Calculate seed for the reward treasury
            let seed = nft_info.collection_name;
            let seed2 = nft_info.token_name;
            append(&mut seed, seed2);
            
            // Get the reward treasury address
            let reward_treasury_address = get_resource_address(user_address, seed);
            
            // Check if reward data exists and calculate rewards
            if (exists<MovementReward>(reward_treasury_address)) {
                let reward_data = borrow_global<MovementReward>(reward_treasury_address);
                
                // Get staking pool data to get the daily percentage return
                let creator_addr = token::creator(object::address_to_object<Token>(nft_info.nft_object_address));
                let staking_address = get_resource_address(creator_addr, nft_info.collection_name);
                
                if (exists<MovementStaking>(staking_address)) {
                    let staking_data = borrow_global<MovementStaking>(staking_address);
                    
                    // Only calculate rewards if this staking pool uses the specified metadata
                    if (object::object_address(&staking_data.metadata) == object::object_address(&metadata)) {
                        // Calculate accumulated rewards
                        let now = aptos_framework::timestamp::now_seconds();
                        let time_diff = now - reward_data.start_time;
                        let days = time_diff / 86400; // Convert seconds to days
                        
                        // Calculate rewards: (dpr * days * tokens) - withdraw_amount
                        let earned_rewards = (staking_data.dpr * days * reward_data.tokens);
                        let net_rewards = if (earned_rewards > reward_data.withdraw_amount) {
                            earned_rewards - reward_data.withdraw_amount
                        } else {
                            0
                        };
                        
                        total_rewards = total_rewards + net_rewards;
                    };
                };
            };
            
            i = i + 1;
        };
        
        total_rewards
    }

    #[view]
    /// Returns all unique fungible asset metadata that a user has staked NFTs for
    public fun get_user_reward_metadata_types(user_address: address): vector<Object<fungible_asset::Metadata>> acquires StakedNFTsRegistry, MovementStaking, ResourceInfo {
        // Check if user has any staked NFTs
        let registry = borrow_global<StakedNFTsRegistry>(@movement_staking);
        if (!smart_table::contains(&registry.staked_nfts, user_address)) {
            return vector::empty<Object<fungible_asset::Metadata>>()
        };
        
        let staked_nfts = smart_table::borrow(&registry.staked_nfts, user_address);
        let metadata_types = vector::empty<Object<fungible_asset::Metadata>>();
        let i = 0;
        let len = vector::length(staked_nfts);
        
        while (i < len) {
            let nft_info = vector::borrow(staked_nfts, i);
            
            // Get staking pool data to get the metadata
            let creator_addr = token::creator(object::address_to_object<Token>(nft_info.nft_object_address));
            let staking_address = get_resource_address(creator_addr, nft_info.collection_name);
            
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
    /// Returns all active staking pools (where state = true)
    public fun view_active_staking_pools(): vector<StakingPoolReference> acquires StakingPoolsRegistry, MovementStaking, ResourceInfo {
        if (!exists<StakingPoolsRegistry>(@movement_staking)) {
            return vector::empty<StakingPoolReference>()
        };
        
        let registry = borrow_global<StakingPoolsRegistry>(@movement_staking);
        let active_pools = vector::empty<StakingPoolReference>();
        
        // Iterate through all staking pools and filter by state = true
        let keys = smart_table::keys(&registry.staking_pools);
        let i = 0;
        let len = vector::length(&keys);
        
        while (i < len) {
            let collection_addr = vector::borrow(&keys, i);
            let pool_ref = smart_table::borrow(&registry.staking_pools, *collection_addr);
            
            // Get the actual MovementStaking data to check state
            let staking_address = get_resource_address(pool_ref.creator, pool_ref.collection_name);
            if (exists<MovementStaking>(staking_address)) {
                let staking_data = borrow_global<MovementStaking>(staking_address);
                if (staking_data.state) {
                    // Only include active pools
                    vector::push_back(&mut active_pools, *pool_ref);
                };
            };
            i = i + 1;
        };
        
        active_pools
    }

    #[view]
    /// Returns all staking pools (active and inactive)
    public fun view_all_staking_pools(): vector<StakingPoolReference> acquires StakingPoolsRegistry {
        if (!exists<StakingPoolsRegistry>(@movement_staking)) {
            return vector::empty<StakingPoolReference>()
        };
        
        let registry = borrow_global<StakingPoolsRegistry>(@movement_staking);
        let all_pools = vector::empty<StakingPoolReference>();
        
        // Iterate through all staking pools
        let keys = smart_table::keys(&registry.staking_pools);
        let i = 0;
        let len = vector::length(&keys);
        
        while (i < len) {
            let collection_addr = vector::borrow(&keys, i);
            let pool_ref = smart_table::borrow(&registry.staking_pools, *collection_addr);
            vector::push_back(&mut all_pools, *pool_ref);
            i = i + 1;
        };
        
        all_pools
    }




    // -------- Functions for staking and earning rewards -------- 

    /// Stakes an NFT token to start earning rewards based on the collection's daily percentage return
    public entry fun stake_token(
        staker: &signer,
        nft: Object<Token>,
    ) acquires MovementStaking, ResourceInfo, MovementReward, StakedNFTsRegistry {
        let staker_addr = signer::address_of(staker);
        // verify ownership of the token
        assert!(object::owner(nft) == staker_addr, ENO_NO_TOKEN_IN_TOKEN_STORE);
        // derive creator and collection name from token (DA standard)
        let creator_addr = token::creator(nft);
        let collection_name = token::collection_name(nft);
        // verify the collection exists
        let collection_addr = collection::create_collection_address(&creator_addr, &collection_name);
        assert!(object::is_object(collection_addr), ENO_NO_COLLECTION);
        // staking pool
        let staking_address = get_resource_address(creator_addr, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);
        let staking_data = borrow_global<MovementStaking>(staking_address);
        assert!(staking_data.state, ENO_STOPPED);
        // seed for reward vault mapping: collection + token name
        let token_name = token::name(nft);
        let seed = collection_name;
        let seed2 = token_name;
        append(&mut seed, seed2);
        //allowing restaking
        let should_pass_restake = check_map(staker_addr, seed);
        if (should_pass_restake) {
            let reward_treasury_address = get_resource_address(staker_addr, seed);
            assert!(exists<MovementReward>(reward_treasury_address), ENO_STAKING_EXISTS);
            let reward_data = borrow_global_mut<MovementReward>(reward_treasury_address);
            let now = aptos_framework::timestamp::now_seconds();
            reward_data.tokens=1;
            reward_data.start_time=now;
            reward_data.withdraw_amount=0;
            reward_data.token_address = object::object_address(&nft);
            object::transfer(staker, nft, reward_treasury_address);

        } else {
            let (reward_treasury, reward_treasury_cap) = account::create_resource_account(staker, to_bytes(&seed)); //resource account to store funds and data
            let reward_treasury_signer_from_cap = account::create_signer_with_capability(&reward_treasury_cap);
            let reward_treasury_address = signer::address_of(&reward_treasury);
            assert!(!exists<MovementReward>(reward_treasury_address), ENO_STAKING_EXISTS);
            create_add_resource_info(staker, seed, reward_treasury_address);
            let now = aptos_framework::timestamp::now_seconds();
            let token_addr = object::object_address(&nft);
            object::transfer(staker, nft, reward_treasury_address);
            move_to<MovementReward>(&reward_treasury_signer_from_cap , MovementReward{
            staker: staker_addr,
            token_name: token::name(object::address_to_object<Token>(token_addr)),
            collection: token::collection_name(object::address_to_object<Token>(token_addr)),
            token_address: token_addr,
            withdraw_amount: 0,
            treasury_cap: reward_treasury_cap,
            start_time: now,
            tokens: 1,
            });
        };

        // Register the staked NFT
        let staked_nft_info = StakedNFTInfo {
            nft_object_address: object::object_address(&nft),
            collection_name: collection_name,
            token_name: token_name,
            staked_at: aptos_framework::timestamp::now_seconds(),
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

    /// Stakes multiple NFT tokens in a single transaction for efficiency
    public entry fun batch_stake_tokens(
        staker: &signer,
        nfts: vector<Object<Token>>,
    ) acquires StakedNFTsRegistry, MovementStaking, ResourceInfo {
        let staker_addr = signer::address_of(staker);
        let nft_count = vector::length(&nfts);
        
        // Ensure we have at least one NFT to stake
        assert!(nft_count > 0, ENO_NO_TOKEN_IN_TOKEN_STORE);
        
        // Get the global registry (must exist)
        let registry = borrow_global_mut<StakedNFTsRegistry>(@movement_staking);
        
        // Get or create the user's staked NFTs vector
        if (!smart_table::contains(&registry.staked_nfts, staker_addr)) {
            smart_table::add(&mut registry.staked_nfts, staker_addr, vector::empty<StakedNFTInfo>());
        };
        
        // Stake each NFT individually with full staking logic
        let i = 0;
        while (i < nft_count) {
            let nft = *vector::borrow(&nfts, i);
            
            // Validate ownership
            assert!(object::owner(nft) == staker_addr, ENO_NO_TOKEN_IN_TOKEN_STORE);
            
            // Get NFT metadata
            let creator_addr = token::creator(nft);
            let collection_name = token::collection_name(nft);
            let token_name = token::name(nft);
            
            // Validate collection exists
            let collection_addr = collection::create_collection_address(&creator_addr, &collection_name);
            assert!(object::is_object(collection_addr), ENO_NO_COLLECTION);
            
            // Validate staking pool exists
            let staking_address = get_resource_address(creator_addr, collection_name);
            assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);
            let staking_data = borrow_global<MovementStaking>(staking_address);
            assert!(staking_data.state, ENO_STOPPED);
            
            // Create seed for reward vault
            let seed = collection_name;
            let seed2 = token_name;
            append(&mut seed, seed2);
            
            // Create reward treasury for this token
            let (reward_treasury, reward_treasury_cap) = account::create_resource_account(staker, to_bytes(&seed));
            let reward_treasury_signer_from_cap = account::create_signer_with_capability(&reward_treasury_cap);
            let reward_treasury_address = signer::address_of(&reward_treasury);
            assert!(!exists<MovementReward>(reward_treasury_address), ENO_STAKING_EXISTS);
            create_add_resource_info(staker, seed, reward_treasury_address);
            let now = timestamp::now_seconds();
            let token_addr = object::object_address(&nft);
            object::transfer(staker, nft, reward_treasury_address);
            move_to<MovementReward>(&reward_treasury_signer_from_cap, MovementReward {
                staker: staker_addr,
                token_name: token::name(object::address_to_object<Token>(token_addr)),
                collection: token::collection_name(object::address_to_object<Token>(token_addr)),
                token_address: token_addr,
                withdraw_amount: 0,
                treasury_cap: reward_treasury_cap,
                start_time: now,
                tokens: 1,
            });
            
            // Add to registry
            let staked_nft_info = StakedNFTInfo {
                nft_object_address: object::object_address(&nft),
                collection_name,
                token_name,
                staked_at: timestamp::now_seconds(),
            };
            
            let registry = borrow_global_mut<StakedNFTsRegistry>(@movement_staking);
            if (!smart_table::contains(&registry.staked_nfts, staker_addr)) {
                smart_table::add(&mut registry.staked_nfts, staker_addr, vector::empty<StakedNFTInfo>());
            };
            let staked_nfts = smart_table::borrow_mut(&mut registry.staked_nfts, staker_addr);
            vector::push_back(staked_nfts, staked_nft_info);
            
            i = i + 1;
        };
    }




    /// Claims accumulated staking rewards for a specific staked token
    public entry fun claim_reward(
        staker: &signer, 
        collection_obj: Object<Collection>, //the collection object owned by Creator 
        token_name: String,
        creator: address,
    ) acquires MovementStaking, MovementReward, ResourceInfo {
        let staker_addr = signer::address_of(staker);
        //verifying whether the creator has started the staking or not
        let collection_name = collection::name(collection_obj);
        let staking_address = get_resource_address(creator, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);// the staking doesn't exists
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        let staking_treasury_signer_from_cap = account::create_signer_with_capability(&staking_data.treasury_cap);
        assert!(staking_data.state, ENO_STOPPED);
        let seed = collection_name;
        let seed2 = token_name;
        append(&mut seed, seed2);
        let reward_treasury_address = get_resource_address(staker_addr, seed);
        assert!(exists<MovementReward>(reward_treasury_address), ENO_STAKING_EXISTS);
        let reward_data = borrow_global_mut<MovementReward>(reward_treasury_address);
        assert!(reward_data.staker==staker_addr, ENO_STAKER_MISMATCH);
        let dpr = staking_data.dpr;
        let now = aptos_framework::timestamp::now_seconds();
        let reward = (((now-reward_data.start_time)*dpr)/86400)*reward_data.tokens;
        let release_amount = reward - reward_data.withdraw_amount;
        if (staking_data.amount<release_amount)
        {
            staking_data.state=false;
            assert!(staking_data.amount>release_amount, ENO_INSUFFICIENT_FUND);
        };
        primary_fungible_store::transfer(&staking_treasury_signer_from_cap, staking_data.metadata, staker_addr, release_amount);
        
        // Conditionally freeze the user's account for the claimed rewards (making them soulbound)
        if (staking_data.is_locked) {
            freeze_user_account(staker, staking_data.metadata);
        };
        
        staking_data.amount=staking_data.amount-release_amount;
        reward_data.withdraw_amount=reward_data.withdraw_amount+release_amount;
    }

    /// Unstakes an NFT token, claims final rewards, and returns the token to the staker
    public entry fun unstake_token (   
        staker: &signer, 
        creator: address,
        collection_obj: Object<Collection>,
        token_name: String,
    )acquires MovementStaking, MovementReward, ResourceInfo, StakedNFTsRegistry {
        let staker_addr = signer::address_of(staker);
        //verifying whether the creator has started the staking or not
        let collection_name = collection::name(collection_obj);
        let staking_address = get_resource_address(creator, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);// the staking doesn't exists
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        assert!(staking_data.state, ENO_STOPPED);
        //getting the seeds
        let seed = collection_name;
        let seed2 = token_name;
        append(&mut seed, seed2);
        //getting reward treasury address which has the tokens
        let reward_treasury_address = get_resource_address(staker_addr, seed);
        assert!(exists<MovementReward>(reward_treasury_address), ENO_STAKING_EXISTS);
        let reward_data = borrow_global_mut<MovementReward>(reward_treasury_address);
        let reward_treasury_signer_from_cap = account::create_signer_with_capability(&reward_data.treasury_cap);
        assert!(reward_data.staker==staker_addr, ENO_STAKER_MISMATCH);
        // verify the reward treasury actually owns the token
        let token_obj = object::address_to_object<Token>(reward_data.token_address);
        assert!(object::owner(token_obj) == reward_treasury_address, ENO_INSUFFICIENT_TOKENS);
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

    // Helper functions

    fun create_add_resource_info(account: &signer, string: String, resource: address) acquires ResourceInfo {
        let account_addr = signer::address_of(account);
        if (!exists<ResourceInfo>(account_addr)) {
            move_to(account, ResourceInfo { resource_map: simple_map::create() })
        };
        let maps = borrow_global_mut<ResourceInfo>(account_addr);
        simple_map::add(&mut maps.resource_map, string, resource);
    }

    fun get_resource_address(add1: address, string: String): address acquires ResourceInfo {
        assert!(exists<ResourceInfo>(add1), ENO_NO_STAKING);
        let maps = borrow_global<ResourceInfo>(add1);
        let staking_address = *simple_map::borrow(&maps.resource_map, &string);
        staking_address

    }

    fun check_map(add1: address, string: String): bool acquires ResourceInfo {
        if (!exists<ResourceInfo>(add1)) {
            false 
        } else {
            let maps = borrow_global_mut<ResourceInfo>(add1);
            simple_map::contains_key(&maps.resource_map, &string)
        }
    }

    #[view]
    /// View function to check if staking is enabled for a collection
    public fun is_staking_enabled(creator_addr: address, collection_obj: Object<Collection>): bool acquires ResourceInfo, MovementStaking {
        if (!exists<ResourceInfo>(creator_addr)) {
            return false
        };
        let collection_name = collection::name(collection_obj);
        let staking_address = get_resource_address(creator_addr, collection_name);
        if (!exists<MovementStaking>(staking_address)) {
            return false
        };
        let staking_data = borrow_global<MovementStaking>(staking_address);
        staking_data.state
    }

    #[view]
    /// Returns all staked NFTs for a specific user address
    public fun get_staked_nfts(user_address: address): vector<StakedNFTInfo> acquires StakedNFTsRegistry {
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

    #[view]
    /// Returns the number of staked NFTs for a specific user address
    public fun get_staked_nfts_count(user_address: address): u64 acquires StakedNFTsRegistry {
        if (!exists<StakedNFTsRegistry>(@movement_staking)) {
            return 0
        };
        
        let registry = borrow_global<StakedNFTsRegistry>(@movement_staking);
        if (!smart_table::contains(&registry.staked_nfts, user_address)) {
            return 0
        };
        
        let user_staked_nfts = smart_table::borrow(&registry.staked_nfts, user_address);
        vector::length(user_staked_nfts)
    }

    /// Helper function to freeze a user's account for a specific FA metadata
    fun freeze_user_account(user: &signer, metadata: Object<fungible_asset::Metadata>) {
        // Delegate freezing logic to the freeze_registry module
        freeze_registry::freeze_user_account(user, metadata);
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

    // Helper functions to get detailed staking pool information
    #[view]
    /// Get the resource address for a staking pool
    public fun get_staking_resource_address(creator: address, collection_name: String): address acquires ResourceInfo {
        get_resource_address(creator, collection_name)
    }

    #[view]
    /// Get the DPR for a staking pool
    public fun get_staking_dpr(creator: address, collection_name: String): u64 acquires MovementStaking, ResourceInfo {
        let staking_address = get_resource_address(creator, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);
        let staking_data = borrow_global<MovementStaking>(staking_address);
        staking_data.dpr
    }

    #[view]
    /// Get the current state for a staking pool
    public fun get_staking_state(creator: address, collection_name: String): bool acquires MovementStaking, ResourceInfo {
        let staking_address = get_resource_address(creator, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);
        let staking_data = borrow_global<MovementStaking>(staking_address);
        staking_data.state
    }

    #[view]
    /// Get the current amount for a staking pool
    public fun get_staking_amount(creator: address, collection_name: String): u64 acquires MovementStaking, ResourceInfo {
        let staking_address = get_resource_address(creator, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);
        let staking_data = borrow_global<MovementStaking>(staking_address);
        staking_data.amount
    }

    #[view]
    /// Get the metadata for a staking pool
    public fun get_staking_metadata(creator: address, collection_name: String): Object<fungible_asset::Metadata> acquires MovementStaking, ResourceInfo {
        let staking_address = get_resource_address(creator, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);
        let staking_data = borrow_global<MovementStaking>(staking_address);
        staking_data.metadata
    }

    #[view]
    /// Get the locked status for a staking pool
    public fun get_staking_is_locked(creator: address, collection_name: String): bool acquires MovementStaking, ResourceInfo {
        let staking_address = get_resource_address(creator, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);
        let staking_data = borrow_global<MovementStaking>(staking_address);
        staking_data.is_locked
    }
}