//! Contract to stake NFTs (aka tokens) and earn FA rewards
//! Adapted from a contract created by Mokshya Protocol
module movement_staking::tokenstaking
{
    use std::signer;
    use std::string::{String, append};
    use aptos_framework::account;
    use aptos_framework::fungible_asset;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self as object, Object};
    use aptos_token_objects::collection::Self;
    use aptos_token_objects::token::{Self, Token};
    use aptos_std::simple_map::{Self, SimpleMap};
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


    //Functions    
    //Function for creating and modifying staking
    public entry fun create_staking(
        creator: &signer,
        dpr: u64,//rate of payment,
        collection_name: String, //the name of the collection owned by Creator 
        total_amount: u64,
        metadata: Object<fungible_asset::Metadata>,
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
        });
    }
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
    // Functions for staking and earning rewards
    public entry fun stake_token(
        staker: &signer,
        nft: Object<Token>,
    ) acquires MovementStaking, ResourceInfo, MovementReward {
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
    }

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
        staking_data.amount=staking_data.amount-release_amount;
        reward_data.withdraw_amount=reward_data.withdraw_amount+release_amount;
    }

    // Function to unstake a token
    public entry fun unstake_token (   
        staker: &signer, 
        creator: address,
        collection_name: String,
        token_name: String,
    )acquires MovementStaking, MovementReward, ResourceInfo {
        let staker_addr = signer::address_of(staker);
        //verifying whether the creator has started the staking or not
        let staking_address = get_resource_address(creator, collection_name);
        assert!(exists<MovementStaking>(staking_address), ENO_NO_STAKING);// the staking doesn't exists
        let staking_data = borrow_global_mut<MovementStaking>(staking_address);
        let staking_treasury_signer_from_cap = account::create_signer_with_capability(&staking_data.treasury_cap);
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
        let dpr = staking_data.dpr;
        let now = aptos_framework::timestamp::now_seconds();
        let reward = ((now-reward_data.start_time)*dpr*reward_data.tokens)/86400;
        let release_amount = reward - reward_data.withdraw_amount;
        // verify the reward treasury actually owns the token
        let token_obj = object::address_to_object<Token>(reward_data.token_address);
        assert!(object::owner(token_obj) == reward_treasury_address, ENO_INSUFFICIENT_TOKENS);
        if (staking_data.amount<release_amount)
        {
            staking_data.state=false;
        };
        if (staking_data.amount>release_amount)
        {
            primary_fungible_store::transfer(&staking_treasury_signer_from_cap, staking_data.metadata, staker_addr, release_amount);
            staking_data.amount=staking_data.amount-release_amount;
            object::transfer(&reward_treasury_signer_from_cap, token_obj, staker_addr);
        };
        reward_data.tokens=0;
        reward_data.start_time=0;
        reward_data.withdraw_amount=0;
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

    #[test_only] 
    use std::string;
    #[test_only] 
    use aptos_framework::timestamp;
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
		let (creator_ref, _token_obj) = create_test_token(&token_staking);
		let (mint_ref, _transfer_ref, _burn_ref) = init_test_metadata_with_primary_store_enabled(&creator_ref);
		let metadata = mint_ref_metadata(&mint_ref);
		pfs::mint(&mint_ref, sender_addr, 100);
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
			   metadata);
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
	fun test_staking_token(
		creator: signer,
		receiver: signer,
		token_staking: signer,
		framework: signer,
	)acquires ResourceInfo, MovementStaking, MovementReward{
	    let sender_addr = signer::address_of(&creator);
	    let receiver_addr = signer::address_of(&receiver);
	    // set up global time for testing purpose
	    timestamp::set_time_has_started_for_testing(&framework);
	    // create accounts 
		aptos_framework::account::create_account_for_test(sender_addr);
		aptos_framework::account::create_account_for_test(receiver_addr);
		// create fungible asset with primary store enabled and mint to creator
		let (creator_ref, _token_obj_seed) = create_test_token(&token_staking);
		let (mint_ref, _transfer_ref, _burn_ref) = init_test_metadata_with_primary_store_enabled(&creator_ref);
		let metadata = mint_ref_metadata(&mint_ref);
		pfs::mint(&mint_ref, sender_addr, 100);
		//create DA collection  
		collection::create_unlimited_collection(
			&creator,
			string::utf8(b"Collection for Test"),
			string::utf8(b"Movement Collection"),
			option::none(),
			string::utf8(b"https://github.com/movementprotocol"),
		);
		//create DA token
		let token_name = string::utf8(b"Movement Token #1");
		let token_ref = token::create_named_token(
			&creator,
			string::utf8(b"Movement Collection"),
			string::utf8(b"Token for Test"),
			token_name,
			option::none(),
			string::utf8(b"https://aptos.dev"),
		);
		let token_addr = object::address_from_constructor_ref(&token_ref);
		let token_obj = object::address_to_object<Token>(token_addr);
		// transfer to receiver
		object::transfer(&creator, token_obj, receiver_addr);
		// create staking
		create_staking(
			   &creator,
			   20,
			   string::utf8(b"Movement Collection"),
			   90,
			   metadata);
		// receiver stakes their token
		let token_for_stake = object::address_to_object<Token>(token_addr);
		stake_token(
			&receiver,
			token_for_stake,
		);
		let seed = string::utf8(b"Movement Collection");
		let seed2 = string::utf8(b"Movement Token #1");
		append(&mut seed, seed2);
		let reward_treasury_address = get_resource_address(receiver_addr, seed);
		assert!(object::owner(object::address_to_object<Token>(token_addr)) == reward_treasury_address, 99);
		assert!(object::owner(object::address_to_object<Token>(token_addr)) != receiver_addr, 89);
		claim_reward(
			&receiver,
			string::utf8(b"Movement Collection"),
			string::utf8(b"Movement Token #1"),
			sender_addr,
		);
		unstake_token( 
			&receiver,
			sender_addr,
			string::utf8(b"Movement Collection"),
			string::utf8(b"Movement Token #1"));
		assert!(object::owner(object::address_to_object<Token>(token_addr)) == receiver_addr, 79);
		assert!(object::owner(object::address_to_object<Token>(token_addr)) != reward_treasury_address, 69);
		let reward_data = borrow_global<MovementReward>(reward_treasury_address);
		assert!(reward_data.start_time==0, 59);
		assert!(reward_data.tokens==0, 59);
		assert!(reward_data.withdraw_amount==0, 59);

		//testing restake of token
		let token_for_restake = object::address_to_object<Token>(token_addr);
		stake_token(
			&receiver,
			token_for_restake,
		);
		assert!(object::owner(object::address_to_object<Token>(token_addr)) == reward_treasury_address, 49);
		assert!(object::owner(object::address_to_object<Token>(token_addr)) != receiver_addr, 49);
	} 
}