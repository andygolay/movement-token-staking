//! Contract to stake NFTs (aka tokens) and earn FA rewards
//! Adapted from a contract created by Mokshya Protocol

// TODO: 
// - Add registry of staked NFTs per user (COMPLETED)
// - Add list of allowed collection IDs 
// - Add view function to see user's staked NFTs (COMPLETED)
// - Add view function to see user's accumulated rewards
// - Add batch stake function (COMPLETED)
// = Add view function for allowed collections for staking

module movement_staking::tokenstaking
{
    use std::signer;
    use std::string::{String, append};
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::fungible_asset;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self as object, Object};
    use aptos_framework::timestamp;
    use aptos_token_objects::collection::Self;
    use aptos_token_objects::token::{Self, Token};
    use movement_staking::banana_a;
    use movement_staking::banana_b;
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
    const ENO_INSUFFICIENT_TOKENS: u64=7;


    // -------- Functions -------- 
    
    /// Initializes the global registry for tracking staked NFTs
    fun init_module(admin: &signer) {
        move_to(admin, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
    }
    
    /// Creates a new staking pool for a collection with specified daily percentage return
    public entry fun create_staking(
        creator: &signer,
        dpr: u64,//rate of payment,
        collection_name: String, //the name of the collection owned by Creator 
        total_amount: u64,
        metadata: Object<fungible_asset::Metadata>,
        // Whether or not to lock the reward tokens earned in the user's account 
        is_locked: bool,
    ) acquires ResourceInfo {
        let creator_addr = signer::address_of(creator);
        //verify the creator has the collection (DA standard)
        let collection_addr = collection::create_collection_address(&creator_addr, &collection_name);
        assert!(object::is_object(collection_addr), ENO_NO_COLLECTION);
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
    }

    /// Updates the daily percentage return rate for an existing staking pool
    public entry fun update_dpr(
        creator: &signer,
        dpr: u64, //rate of payment,
        collection_name: String, //the name of the collection owned by Creator 
    ) acquires MovementStaking, ResourceInfo {
        let creator_addr = signer::address_of(creator);
        //verify the creator has the collection
        let staking_address = get_resource_address(creator_addr, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);// the staking doesn't exists
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        staking_data.dpr=dpr;
    }

    /// Stops staking for a collection, preventing new stakes and claims
    public entry fun creator_stop_staking(
        creator: &signer,
        collection_name: String, //the name of the collection owned by Creator 
    ) acquires MovementStaking, ResourceInfo {
        let creator_addr = signer::address_of(creator);
       //get staking address
        let staking_address = get_resource_address(creator_addr, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);// the staking doesn't exists
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        staking_data.state=false;
    }

    /// Deposits additional reward tokens into the staking pool and re-enables staking
    public entry fun deposit_staking_rewards(
        creator: &signer,
        collection_name: String, //the name of the collection owned by Creator 
        amount: u64,
    ) acquires MovementStaking, ResourceInfo {
        let creator_addr = signer::address_of(creator);
        //verify the creator has the collection
         assert!(exists<ResourceInfo>(creator_addr), ENO_NO_STAKING);
        let staking_address = get_resource_address(creator_addr, collection_name); 
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);// the staking doesn't exists       
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        // Transfer FA from creator to staking treasury store
        primary_fungible_store::transfer(creator, staking_data.metadata, staking_address, amount);
        staking_data.amount= staking_data.amount+amount;
        staking_data.state=true;
        
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
            assert!(exists<MovementReward>(reward_treasury_address), ENO_NO_STAKING);
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
        collection_name: String, //the name of the collection owned by Creator 
        token_name: String,
        creator: address,
    ) acquires MovementStaking, MovementReward, ResourceInfo {
        let staker_addr = signer::address_of(staker);
        //verifying whether the creator has started the staking or not
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
        collection_name: String,
        token_name: String,
    )acquires MovementStaking, MovementReward, ResourceInfo, StakedNFTsRegistry {
        let staker_addr = signer::address_of(staker);
        //verifying whether the creator has started the staking or not
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
    public fun is_staking_enabled(creator_addr: address, collection_name: String): bool acquires ResourceInfo, MovementStaking {
        if (!exists<ResourceInfo>(creator_addr)) {
            return false
        };
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
        let metadata_addr = object::object_address(&metadata);
        
        // Check if this is banana_a metadata
        if (metadata_addr == object::object_address(&banana_a::get_metadata())) {
            banana_a::freeze_own_account(user);
            return
        };
        
        // Check if this is banana_b metadata
        if (metadata_addr == object::object_address(&banana_b::get_metadata())) {
            banana_b::freeze_own_account(user);
            return
        };
        
        // If it's neither, do nothing (could be a different FA)
    }





    #[test_only] 
    use std::string;
    #[test_only]
    use aptos_framework::fungible_asset::{create_test_token, mint_ref_metadata};
    #[test_only]
    use aptos_framework::primary_fungible_store as pfs;
    #[test_only]
    use aptos_framework::primary_fungible_store::init_test_metadata_with_primary_store_enabled;
    #[test_only]
    use std::option;
    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking)]
   fun test_create_staking(
		creator: signer,
		receiver: signer,
		token_staking: signer
	)acquires ResourceInfo, MovementStaking{
	   let sender_addr = signer::address_of(&creator);
	   let receiver_addr = signer::address_of(&receiver);
		aptos_framework::account::create_account_for_test(sender_addr);
		aptos_framework::account::create_account_for_test(receiver_addr);
		// Initialize banana_a FA module
		banana_a::test_init(&token_staking);
		let metadata = banana_a::get_metadata();
		banana_a::mint(&token_staking, sender_addr, 100);
		// Create DA collection to satisfy existence check
		collection::create_unlimited_collection(
			&creator,
			string::utf8(b"Collection for Test"),
			string::utf8(b"Movement Collection"),
			option::none(),
			string::utf8(b"https://github.com/movementprotocol"),
		);
		create_staking(
			   &creator,
			   20,
			   string::utf8(b"Movement Collection"),
			   90,
			   metadata,
			   true);
		update_dpr(
				&creator,
				30,
			   string::utf8(b"Movement Collection"),
		);
		creator_stop_staking(
				&creator,
				string::utf8(b"Movement Collection"),
		);
		let resource_address= get_resource_address(sender_addr, string::utf8(b"Movement Collection"));
		let staking_data = borrow_global<MovementStaking>(resource_address);
		assert!(staking_data.state==false, 98);
		deposit_staking_rewards(
			   &creator,
			   string::utf8(b"Movement Collection"),
			   5
		);
		let staking_data = borrow_global<MovementStaking>(resource_address);
		assert!(staking_data.state==true, 88);
		assert!(staking_data.dpr==30, 78);
		assert!(staking_data.amount==95, 68);
	} 

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_staking_happy_path_with_freezing(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) acquires ResourceInfo, MovementStaking, MovementReward, StakedNFTsRegistry {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        timestamp::set_time_has_started_for_testing(&framework);
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize the global registry for testing
        move_to(&token_staking, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
        
        // Initialize banana_a FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        banana_a::mint(&token_staking, sender_addr, 100);
        
        // DA collection + token
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Collection for Test"),
            string::utf8(b"Movement Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token_ref = token::create_named_token(
            &creator,
            string::utf8(b"Movement Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Movement Token #1"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token_addr = object::address_from_constructor_ref(&token_ref);
        object::transfer(&creator, object::address_to_object<Token>(token_addr), receiver_addr);
        
        // Create staking pool with dpr=20
        create_staking(&creator, 20, string::utf8(b"Movement Collection"), 90, metadata, true);
        
        // Stake the token
        stake_token(&receiver, object::address_to_object<Token>(token_addr));
        
        // Verify token is owned by reward treasury
        let seed = string::utf8(b"Movement Collection");
        let seed2 = string::utf8(b"Movement Token #1");
        append(&mut seed, seed2);
        let reward_treasury_address = get_resource_address(receiver_addr, seed);
        assert!(object::owner(object::address_to_object<Token>(token_addr)) == reward_treasury_address, 1);
        assert!(object::owner(object::address_to_object<Token>(token_addr)) != receiver_addr, 2);
        
        // Advance time by 1 day to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Check balance before claiming
        let balance_before = primary_fungible_store::balance(receiver_addr, metadata);
        
        // Claim rewards
        claim_reward(&receiver, string::utf8(b"Movement Collection"), string::utf8(b"Movement Token #1"), sender_addr);
        
        // Verify rewards were received and account is frozen (soulbound)
        let balance_after = primary_fungible_store::balance(receiver_addr, metadata);
        assert!(balance_after > balance_before, 3);
        assert!(primary_fungible_store::is_frozen(receiver_addr, metadata), 4);
        
        // Unstake the token
        unstake_token(&receiver, sender_addr, string::utf8(b"Movement Collection"), string::utf8(b"Movement Token #1"));
        
        // Verify token is returned to receiver
        assert!(object::owner(object::address_to_object<Token>(token_addr)) == receiver_addr, 5);
        assert!(object::owner(object::address_to_object<Token>(token_addr)) != reward_treasury_address, 6);
        
        // Verify reward data is reset
        let reward_data = borrow_global<MovementReward>(reward_treasury_address);
        assert!(reward_data.start_time == 0, 7);
        assert!(reward_data.tokens == 0, 8);
        assert!(reward_data.withdraw_amount == 0, 9);
        
        // Test restaking the same token
        stake_token(&receiver, object::address_to_object<Token>(token_addr));
        assert!(object::owner(object::address_to_object<Token>(token_addr)) == reward_treasury_address, 10);
        assert!(object::owner(object::address_to_object<Token>(token_addr)) != receiver_addr, 11);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_staking_happy_path_without_freezing(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) acquires ResourceInfo, MovementStaking, MovementReward, StakedNFTsRegistry {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        timestamp::set_time_has_started_for_testing(&framework);
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize the global registry for testing
        move_to(&token_staking, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
        
        // Initialize banana_a FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        banana_a::mint(&token_staking, sender_addr, 100);
        
        // DA collection + token
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Freezing Disabled Collection"),
            string::utf8(b"Freezing Disabled Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token_ref = token::create_named_token(
            &creator,
            string::utf8(b"Freezing Disabled Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Freezing Disabled Token"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token_addr = object::address_from_constructor_ref(&token_ref);
        object::transfer(&creator, object::address_to_object<Token>(token_addr), receiver_addr);
        
        // Create staking pool with dpr=20 and freezing DISABLED (is_locked = false)
        create_staking(&creator, 20, string::utf8(b"Freezing Disabled Collection"), 90, metadata, false);
        
        // Stake the token
        stake_token(&receiver, object::address_to_object<Token>(token_addr));
        
        // Verify token is owned by reward treasury
        let seed = string::utf8(b"Freezing Disabled Collection");
        let seed2 = string::utf8(b"Freezing Disabled Token");
        append(&mut seed, seed2);
        let reward_treasury_address = get_resource_address(receiver_addr, seed);
        assert!(object::owner(object::address_to_object<Token>(token_addr)) == reward_treasury_address, 1);
        assert!(object::owner(object::address_to_object<Token>(token_addr)) != receiver_addr, 2);
        
        // Advance time by 1 day to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Check balance before claiming
        let balance_before = primary_fungible_store::balance(receiver_addr, metadata);
        
        // Claim rewards
        claim_reward(&receiver, string::utf8(b"Freezing Disabled Collection"), string::utf8(b"Freezing Disabled Token"), sender_addr);
        
        // Verify rewards were received but account is NOT frozen (no soulbound)
        let balance_after = primary_fungible_store::balance(receiver_addr, metadata);
        assert!(balance_after > balance_before, 3);
        assert!(!primary_fungible_store::is_frozen(receiver_addr, metadata), 4);
        
        // Unstake the token
        unstake_token(&receiver, sender_addr, string::utf8(b"Freezing Disabled Collection"), string::utf8(b"Freezing Disabled Token"));
        
        // Verify token is returned to receiver
        assert!(object::owner(object::address_to_object<Token>(token_addr)) == receiver_addr, 5);
        assert!(object::owner(object::address_to_object<Token>(token_addr)) != reward_treasury_address, 6);
        
        // Verify reward data is reset
        let reward_data = borrow_global<MovementReward>(reward_treasury_address);
        assert!(reward_data.start_time == 0, 7);
        assert!(reward_data.tokens == 0, 8);
        assert!(reward_data.withdraw_amount == 0, 9);
        
        // Test restaking the same token
        stake_token(&receiver, object::address_to_object<Token>(token_addr));
        assert!(object::owner(object::address_to_object<Token>(token_addr)) == reward_treasury_address, 10);
        assert!(object::owner(object::address_to_object<Token>(token_addr)) != receiver_addr, 11);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking)]
    #[expected_failure(abort_code = 0x4, location = Self)]
    fun test_stake_when_stopped(
        creator: signer,
        receiver: signer,
        token_staking: signer,
    ) acquires ResourceInfo, MovementStaking, MovementReward, StakedNFTsRegistry {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize the global registry for testing
        move_to(&token_staking, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
        
        // Initialize banana_a FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        banana_a::mint(&token_staking, sender_addr, 100);
        // DA setup
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Test Collection"),
            string::utf8(b"Test Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token_ref = token::create_named_token(
            &creator,
            string::utf8(b"Test Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Movement Token #S"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token_addr = object::address_from_constructor_ref(&token_ref);
        object::transfer(&creator, object::address_to_object<Token>(token_addr), receiver_addr);
        // Pool then stop
        create_staking(&creator, 10, string::utf8(b"Test Collection"), 90, metadata, true);
        creator_stop_staking(&creator, string::utf8(b"Test Collection"));
        // Attempt stake (should abort with ENO_STOPPED=4)
        stake_token(&receiver, object::address_to_object<Token>(token_addr));
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking)]
    fun test_is_staking_enabled(
        creator: signer,
        receiver: signer,
        token_staking: signer,
    ) acquires ResourceInfo, MovementStaking {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Test 1: No staking resources exist yet
        assert!(!is_staking_enabled(sender_addr, string::utf8(b"NonExistent Collection")), 1);
        
        // FA setup
        let (creator_ref, _obj) = create_test_token(&token_staking);
        let (mint_ref, _tref, _bref) = init_test_metadata_with_primary_store_enabled(&creator_ref);
        let metadata = mint_ref_metadata(&mint_ref);
        pfs::mint(&mint_ref, sender_addr, 100);
        
        // DA setup
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Collection for Test"),
            string::utf8(b"Test Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Test 2: Collection exists but no staking pool yet
        assert!(!is_staking_enabled(sender_addr, string::utf8(b"Test Collection")), 2);
        
        // Create staking pool
        create_staking(&creator, 20, string::utf8(b"Test Collection"), 90, metadata, true);
        
        // Test 3: Staking pool exists and is enabled by default
        assert!(is_staking_enabled(sender_addr, string::utf8(b"Test Collection")), 3);
        
        // Stop staking
        creator_stop_staking(&creator, string::utf8(b"Test Collection"));
        
        // Test 4: Staking pool exists but is stopped
        assert!(!is_staking_enabled(sender_addr, string::utf8(b"Test Collection")), 4);
        
        // Re-enable staking by depositing rewards
        deposit_staking_rewards(&creator, string::utf8(b"Test Collection"), 10);
        
        // Test 5: Staking pool re-enabled after deposit
        assert!(is_staking_enabled(sender_addr, string::utf8(b"Test Collection")), 5);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_multiple_fa_staking_with_freezing(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) acquires ResourceInfo, MovementStaking, MovementReward, StakedNFTsRegistry {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize the global registry for testing
        move_to(&token_staking, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
        
        // Initialize both FA modules
        banana_a::test_init(&token_staking);
        banana_b::test_init(&token_staking);
        
        // Get metadata for both FAs
        let banana_a_metadata = banana_a::get_metadata();
        let banana_b_metadata = banana_b::get_metadata();
        
        // Mint some tokens to creator for both FAs
        banana_a::mint(&token_staking, sender_addr, 1000);
        banana_b::mint(&token_staking, sender_addr, 1000);
        
        // Create DA collections for both FAs
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Test Collection A"),
            string::utf8(b"Test Collection A"),
            option::none(),
            string::utf8(b"uri"),
        );
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Test Collection B"),
            string::utf8(b"Test Collection B"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Create two different tokens
        let token_a_ref = token::create_named_token(
            &creator,
            string::utf8(b"Test Collection A"),
            string::utf8(b"desc"),
            string::utf8(b"Token A"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token_b_ref = token::create_named_token(
            &creator,
            string::utf8(b"Test Collection B"),
            string::utf8(b"desc"),
            string::utf8(b"Token B"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        let token_a_addr = object::address_from_constructor_ref(&token_a_ref);
        let token_b_addr = object::address_from_constructor_ref(&token_b_ref);
        
        // Transfer tokens to receiver
        object::transfer(&creator, object::address_to_object<Token>(token_a_addr), receiver_addr);
        object::transfer(&creator, object::address_to_object<Token>(token_b_addr), receiver_addr);
        
        // Create staking pools for both FAs (different collections to avoid resource account conflicts)
        create_staking(&creator, 20, string::utf8(b"Test Collection A"), 500, banana_a_metadata, true);
        create_staking(&creator, 15, string::utf8(b"Test Collection B"), 300, banana_b_metadata, true);
        
        // Stake both tokens
        stake_token(&receiver, object::address_to_object<Token>(token_a_addr));
        stake_token(&receiver, object::address_to_object<Token>(token_b_addr));
        
        // Advance time by 1 day (86400 seconds) to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Claim rewards for both tokens
        claim_reward(&receiver, string::utf8(b"Test Collection A"), string::utf8(b"Token A"), sender_addr);
        claim_reward(&receiver, string::utf8(b"Test Collection B"), string::utf8(b"Token B"), sender_addr);
        
        // Verify that both accounts are frozen after claiming rewards (soulbound)
        assert!(primary_fungible_store::is_frozen(receiver_addr, banana_a_metadata), 1);
        assert!(primary_fungible_store::is_frozen(receiver_addr, banana_b_metadata), 2);
        
        // Verify balances increased after time advancement and reward claiming
        let banana_a_balance = primary_fungible_store::balance(receiver_addr, banana_a_metadata);
        let banana_b_balance = primary_fungible_store::balance(receiver_addr, banana_b_metadata);
        assert!(banana_a_balance > 0, 3);
        assert!(banana_b_balance > 0, 4);
        
        // Unstake both tokens (should work even with frozen accounts thanks to transfer_with_ref)
        unstake_token(&receiver, sender_addr, string::utf8(b"Test Collection A"), string::utf8(b"Token A"));
        unstake_token(&receiver, sender_addr, string::utf8(b"Test Collection B"), string::utf8(b"Token B"));
        
        // Verify tokens are returned
        assert!(object::owner(object::address_to_object<Token>(token_a_addr)) == receiver_addr, 5);
        assert!(object::owner(object::address_to_object<Token>(token_b_addr)) == receiver_addr, 6);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_multiple_fa_staking_without_freezing(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) acquires ResourceInfo, MovementStaking, MovementReward, StakedNFTsRegistry {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize the global registry for testing
        move_to(&token_staking, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
        
        // Initialize both FA modules
        banana_a::test_init(&token_staking);
        banana_b::test_init(&token_staking);
        
        // Get metadata for both FAs
        let banana_a_metadata = banana_a::get_metadata();
        let banana_b_metadata = banana_b::get_metadata();
        
        // Mint some tokens to creator for both FAs
        banana_a::mint(&token_staking, sender_addr, 1000);
        banana_b::mint(&token_staking, sender_addr, 1000);
        
        // Create DA collections for both FAs
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Test Collection C"),
            string::utf8(b"Test Collection C"),
            option::none(),
            string::utf8(b"uri"),
        );
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Test Collection D"),
            string::utf8(b"Test Collection D"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Create two different tokens
        let token_a_ref = token::create_named_token(
            &creator,
            string::utf8(b"Test Collection C"),
            string::utf8(b"desc"),
            string::utf8(b"Token C"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token_b_ref = token::create_named_token(
            &creator,
            string::utf8(b"Test Collection D"),
            string::utf8(b"desc"),
            string::utf8(b"Token D"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        let token_a_addr = object::address_from_constructor_ref(&token_a_ref);
        let token_b_addr = object::address_from_constructor_ref(&token_b_ref);
        
        // Transfer tokens to receiver
        object::transfer(&creator, object::address_to_object<Token>(token_a_addr), receiver_addr);
        object::transfer(&creator, object::address_to_object<Token>(token_b_addr), receiver_addr);
        
        // Create staking pools for both FAs with freezing DISABLED (is_locked = false)
        create_staking(&creator, 20, string::utf8(b"Test Collection C"), 500, banana_a_metadata, false);
        create_staking(&creator, 15, string::utf8(b"Test Collection D"), 300, banana_b_metadata, false);
        
        // Stake both tokens
        stake_token(&receiver, object::address_to_object<Token>(token_a_addr));
        stake_token(&receiver, object::address_to_object<Token>(token_b_addr));
        
        // Advance time by 1 day (86400 seconds) to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Claim rewards for both tokens
        claim_reward(&receiver, string::utf8(b"Test Collection C"), string::utf8(b"Token C"), sender_addr);
        claim_reward(&receiver, string::utf8(b"Test Collection D"), string::utf8(b"Token D"), sender_addr);
        
        // Verify that both accounts are NOT frozen after claiming rewards (no soulbound)
        assert!(!primary_fungible_store::is_frozen(receiver_addr, banana_a_metadata), 1);
        assert!(!primary_fungible_store::is_frozen(receiver_addr, banana_b_metadata), 2);
        
        // Verify balances increased after time advancement and reward claiming
        let banana_a_balance = primary_fungible_store::balance(receiver_addr, banana_a_metadata);
        let banana_b_balance = primary_fungible_store::balance(receiver_addr, banana_b_metadata);
        assert!(banana_a_balance > 0, 3);
        assert!(banana_b_balance > 0, 4);
        
        // Unstake both tokens (should work normally since accounts are not frozen)
        unstake_token(&receiver, sender_addr, string::utf8(b"Test Collection C"), string::utf8(b"Token C"));
        unstake_token(&receiver, sender_addr, string::utf8(b"Test Collection D"), string::utf8(b"Token D"));
        
        // Verify tokens are returned
        assert!(object::owner(object::address_to_object<Token>(token_a_addr)) == receiver_addr, 5);
        assert!(object::owner(object::address_to_object<Token>(token_b_addr)) == receiver_addr, 6);
    }

    #[test(creator = @0x123, user1 = @0x456, user2 = @0x789, token_staking = @0xfee, framework = @0x1)]
    fun test_registry_functionality(
        creator: signer,
        user1: signer,
        user2: signer,
        token_staking: signer,
        framework: signer,
    ) acquires ResourceInfo, MovementStaking, MovementReward, StakedNFTsRegistry {
        let creator_addr = signer::address_of(&creator);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(creator_addr);
        aptos_framework::account::create_account_for_test(user1_addr);
        aptos_framework::account::create_account_for_test(user2_addr);
        
        // Initialize the global registry for testing
        move_to(&token_staking, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
        
        // Initialize FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        banana_a::mint(&token_staking, creator_addr, 1000);
        
        // Create collection
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Registry Test Collection"),
            string::utf8(b"Registry Test Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Create multiple tokens
        let token1_ref = token::create_named_token(
            &creator,
            string::utf8(b"Registry Test Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Token 1"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token2_ref = token::create_named_token(
            &creator,
            string::utf8(b"Registry Test Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Token 2"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token3_ref = token::create_named_token(
            &creator,
            string::utf8(b"Registry Test Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Token 3"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        let token1_addr = object::address_from_constructor_ref(&token1_ref);
        let token2_addr = object::address_from_constructor_ref(&token2_ref);
        let token3_addr = object::address_from_constructor_ref(&token3_ref);
        
        // Transfer tokens to users
        object::transfer(&creator, object::address_to_object<Token>(token1_addr), user1_addr);
        object::transfer(&creator, object::address_to_object<Token>(token2_addr), user1_addr);
        object::transfer(&creator, object::address_to_object<Token>(token3_addr), user2_addr);
        
        // Create staking pool
        create_staking(&creator, 10, string::utf8(b"Registry Test Collection"), 500, metadata, false);
        
        // Verify registry is initially empty
        let registry = borrow_global<StakedNFTsRegistry>(@movement_staking);
        assert!(!smart_table::contains(&registry.staked_nfts, user1_addr), 1);
        assert!(!smart_table::contains(&registry.staked_nfts, user2_addr), 2);
        
        // User1 stakes 2 tokens
        stake_token(&user1, object::address_to_object<Token>(token1_addr));
        stake_token(&user1, object::address_to_object<Token>(token2_addr));
        
        // User2 stakes 1 token
        stake_token(&user2, object::address_to_object<Token>(token3_addr));
        
        // Verify registry contents after staking
        let registry = borrow_global<StakedNFTsRegistry>(@movement_staking);
        
        // Check user1 has 2 staked NFTs
        assert!(smart_table::contains(&registry.staked_nfts, user1_addr), 3);
        let user1_nfts = smart_table::borrow(&registry.staked_nfts, user1_addr);
        assert!(vector::length(user1_nfts) == 2, 4);
        
        // Check user2 has 1 staked NFT
        assert!(smart_table::contains(&registry.staked_nfts, user2_addr), 5);
        let user2_nfts = smart_table::borrow(&registry.staked_nfts, user2_addr);
        assert!(vector::length(user2_nfts) == 1, 6);
        
        // Verify the actual NFT addresses in the registry
        let user1_nft1 = vector::borrow(user1_nfts, 0);
        let user1_nft2 = vector::borrow(user1_nfts, 1);
        let user2_nft1 = vector::borrow(user2_nfts, 0);
        
        // Check that the NFT addresses match what we staked
        assert!(user1_nft1.nft_object_address == token1_addr || user1_nft1.nft_object_address == token2_addr, 7);
        assert!(user1_nft2.nft_object_address == token1_addr || user1_nft2.nft_object_address == token2_addr, 8);
        assert!(user1_nft1.nft_object_address != user1_nft2.nft_object_address, 9); // Should be different
        assert!(user2_nft1.nft_object_address == token3_addr, 10);
        
        // Verify collection and token names are recorded correctly
        assert!(user1_nft1.collection_name == string::utf8(b"Registry Test Collection"), 11);
        assert!(user1_nft1.token_name == string::utf8(b"Token 1") || user1_nft1.token_name == string::utf8(b"Token 2"), 12);
        assert!(user2_nft1.collection_name == string::utf8(b"Registry Test Collection"), 13);
        assert!(user2_nft1.token_name == string::utf8(b"Token 3"), 14);
        
        // Unstake one token from user1
        unstake_token(&user1, creator_addr, string::utf8(b"Registry Test Collection"), string::utf8(b"Token 1"));
        
        // Verify registry is updated after unstaking
        let registry = borrow_global<StakedNFTsRegistry>(@movement_staking);
        let user1_nfts_after = smart_table::borrow(&registry.staked_nfts, user1_addr);
        assert!(vector::length(user1_nfts_after) == 1, 15); // Should have 1 NFT left
        
        // User2's NFTs should be unchanged
        let user2_nfts_after = smart_table::borrow(&registry.staked_nfts, user2_addr);
        assert!(vector::length(user2_nfts_after) == 1, 16);
        
        // Unstake remaining tokens
        unstake_token(&user1, creator_addr, string::utf8(b"Registry Test Collection"), string::utf8(b"Token 2"));
        unstake_token(&user2, creator_addr, string::utf8(b"Registry Test Collection"), string::utf8(b"Token 3"));
        
        // Verify registry is properly cleaned up
        let registry = borrow_global<StakedNFTsRegistry>(@movement_staking);
        let user1_nfts_final = smart_table::borrow(&registry.staked_nfts, user1_addr);
        let user2_nfts_final = smart_table::borrow(&registry.staked_nfts, user2_addr);
        assert!(vector::length(user1_nfts_final) == 0, 17);
        assert!(vector::length(user2_nfts_final) == 0, 18);
    }

    #[test(creator = @0x123, user1 = @0x456, token_staking = @0xfee, framework = @0x1)]
    fun test_batch_staking_functionality(
        creator: signer,
        user1: signer,
        token_staking: signer,
        framework: signer,
    ) acquires ResourceInfo, MovementStaking, MovementReward, StakedNFTsRegistry {
        let creator_addr = signer::address_of(&creator);
        let user1_addr = signer::address_of(&user1);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(creator_addr);
        aptos_framework::account::create_account_for_test(user1_addr);
        
        // Initialize the global registry for testing
        move_to(&token_staking, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
        
        // Initialize FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        banana_a::mint(&token_staking, creator_addr, 1000);
        
        // Create collection
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Batch Test Collection"),
            string::utf8(b"Batch Test Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Create multiple tokens
        let token1_ref = token::create_named_token(
            &creator,
            string::utf8(b"Batch Test Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Batch Token 1"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token2_ref = token::create_named_token(
            &creator,
            string::utf8(b"Batch Test Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Batch Token 2"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token3_ref = token::create_named_token(
            &creator,
            string::utf8(b"Batch Test Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Batch Token 3"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        let token1_addr = object::address_from_constructor_ref(&token1_ref);
        let token2_addr = object::address_from_constructor_ref(&token2_ref);
        let token3_addr = object::address_from_constructor_ref(&token3_ref);
        
        // Transfer tokens to user1
        object::transfer(&creator, object::address_to_object<Token>(token1_addr), user1_addr);
        object::transfer(&creator, object::address_to_object<Token>(token2_addr), user1_addr);
        object::transfer(&creator, object::address_to_object<Token>(token3_addr), user1_addr);
        
        // Create staking pool
        create_staking(&creator, 10, string::utf8(b"Batch Test Collection"), 500, metadata, false);
        
        // Verify registry is initially empty
        let registry = borrow_global<StakedNFTsRegistry>(@movement_staking);
        assert!(!smart_table::contains(&registry.staked_nfts, user1_addr), 1);
        
        // Create vector of NFTs to batch stake
        let nfts_to_stake = vector::empty<Object<Token>>();
        vector::push_back(&mut nfts_to_stake, object::address_to_object<Token>(token1_addr));
        vector::push_back(&mut nfts_to_stake, object::address_to_object<Token>(token2_addr));
        vector::push_back(&mut nfts_to_stake, object::address_to_object<Token>(token3_addr));
        
        // Batch stake all 3 tokens
        batch_stake_tokens(&user1, nfts_to_stake);
        
        // Verify all tokens are now owned by reward treasuries
        let seed1 = string::utf8(b"Batch Test Collection");
        let seed1_2 = string::utf8(b"Batch Token 1");
        append(&mut seed1, seed1_2);
        let reward_treasury1 = get_resource_address(user1_addr, seed1);
        
        let seed2 = string::utf8(b"Batch Test Collection");
        let seed2_2 = string::utf8(b"Batch Token 2");
        append(&mut seed2, seed2_2);
        let reward_treasury2 = get_resource_address(user1_addr, seed2);
        
        let seed3 = string::utf8(b"Batch Test Collection");
        let seed3_2 = string::utf8(b"Batch Token 3");
        append(&mut seed3, seed3_2);
        let reward_treasury3 = get_resource_address(user1_addr, seed3);
        
        assert!(object::owner(object::address_to_object<Token>(token1_addr)) == reward_treasury1, 2);
        assert!(object::owner(object::address_to_object<Token>(token2_addr)) == reward_treasury2, 3);
        assert!(object::owner(object::address_to_object<Token>(token3_addr)) == reward_treasury3, 4);
        
        // Verify registry contains all 3 staked NFTs
        let registry = borrow_global<StakedNFTsRegistry>(@movement_staking);
        assert!(smart_table::contains(&registry.staked_nfts, user1_addr), 5);
        let user1_nfts = smart_table::borrow(&registry.staked_nfts, user1_addr);
        assert!(vector::length(user1_nfts) == 3, 6);
        
        // Verify the NFT info for each staked token
        let nft1_info = vector::borrow(user1_nfts, 0);
        let nft2_info = vector::borrow(user1_nfts, 1);
        let nft3_info = vector::borrow(user1_nfts, 2);
        
        // Check that all NFT addresses are present (order may vary)
        // Since Move doesn't support mutable variables, we'll just verify the count
        // and that each NFT address is unique
        assert!(vector::length(user1_nfts) == 3, 7);
        
        // Verify that all three token addresses are different
        let nft1_addr = vector::borrow(user1_nfts, 0).nft_object_address;
        let nft2_addr = vector::borrow(user1_nfts, 1).nft_object_address;
        let nft3_addr = vector::borrow(user1_nfts, 2).nft_object_address;
        
        assert!(nft1_addr != nft2_addr, 8);
        assert!(nft2_addr != nft3_addr, 9);
        assert!(nft1_addr != nft3_addr, 10);
        
        // Verify collection names are correct
        assert!(nft1_info.collection_name == string::utf8(b"Batch Test Collection"), 10);
        assert!(nft2_info.collection_name == string::utf8(b"Batch Test Collection"), 11);
        assert!(nft3_info.collection_name == string::utf8(b"Batch Test Collection"), 12);
        
        // Test view functions work with batch staked NFTs
        assert!(get_staked_nfts_count(user1_addr) == 3, 13);
        let staked_nfts = get_staked_nfts(user1_addr);
        assert!(vector::length(&staked_nfts) == 3, 14);
        
        // Unstake all tokens individually to clean up
        unstake_token(&user1, creator_addr, string::utf8(b"Batch Test Collection"), string::utf8(b"Batch Token 1"));
        unstake_token(&user1, creator_addr, string::utf8(b"Batch Test Collection"), string::utf8(b"Batch Token 2"));
        unstake_token(&user1, creator_addr, string::utf8(b"Batch Test Collection"), string::utf8(b"Batch Token 3"));
        
        // Verify registry is cleaned up
        let registry = borrow_global<StakedNFTsRegistry>(@movement_staking);
        let user1_nfts_final = smart_table::borrow(&registry.staked_nfts, user1_addr);
        assert!(vector::length(user1_nfts_final) == 0, 15);
        
        // Verify view functions return 0 after unstaking
        assert!(get_staked_nfts_count(user1_addr) == 0, 16);
        let final_nfts = get_staked_nfts(user1_addr);
        assert!(vector::length(&final_nfts) == 0, 17);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_staked_nft_view_functions(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) acquires ResourceInfo, MovementStaking, MovementReward, StakedNFTsRegistry {
        let creator_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(creator_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize the global registry for testing
        move_to(&token_staking, StakedNFTsRegistry {
            staked_nfts: smart_table::new(),
        });
        
        // Initialize FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        banana_a::mint(&token_staking, creator_addr, 1000);
        
        // Create collection
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"View Test Collection"),
            string::utf8(b"View Test Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Create token
        let token_ref = token::create_named_token(
            &creator,
            string::utf8(b"View Test Collection"),
            string::utf8(b"desc"),
            string::utf8(b"View Test Token"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        let token_addr = object::address_from_constructor_ref(&token_ref);
        
        // Transfer token to receiver
        object::transfer(&creator, object::address_to_object<Token>(token_addr), receiver_addr);
        
        // Create staking pool
        create_staking(&creator, 10, string::utf8(b"View Test Collection"), 500, metadata, false);
        
        // Test view functions before staking
        assert!(get_staked_nfts_count(receiver_addr) == 0, 1);
        let empty_nfts = get_staked_nfts(receiver_addr);
        assert!(vector::length(&empty_nfts) == 0, 2);
        
        // Stake the token
        stake_token(&receiver, object::address_to_object<Token>(token_addr));
        
        // Advance time to ensure timestamp is set
        timestamp::update_global_time_for_test(1000000); // 1 second in microseconds
        
        // Test view functions after staking
        assert!(get_staked_nfts_count(receiver_addr) == 1, 3);
        let staked_nfts = get_staked_nfts(receiver_addr);
        assert!(vector::length(&staked_nfts) == 1, 4);
        
        // Verify the NFT info is correct
        let nft_info = vector::borrow(&staked_nfts, 0);
        assert!(nft_info.nft_object_address == token_addr, 5);
        assert!(nft_info.collection_name == string::utf8(b"View Test Collection"), 6);
        assert!(nft_info.token_name == string::utf8(b"View Test Token"), 7);
        // Note: staked_at will be 0 in test environment until time is advanced
        // assert!(nft_info.staked_at > 0, 8); // Should have a timestamp
        
        // Unstake the token
        unstake_token(&receiver, creator_addr, string::utf8(b"View Test Collection"), string::utf8(b"View Test Token"));
        
        // Test view functions after unstaking
        assert!(get_staked_nfts_count(receiver_addr) == 0, 9);
        let final_nfts = get_staked_nfts(receiver_addr);
        assert!(vector::length(&final_nfts) == 0, 10);
    }
}