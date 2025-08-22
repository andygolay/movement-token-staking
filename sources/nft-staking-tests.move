#[test_only]
module movement_staking::nft_staking_tests {
    use std::signer;
    use std::string;
    use std::vector;
    use std::option;
    
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_framework::primary_fungible_store;
    
    use aptos_token_objects::collection::{Self, Collection};
    use aptos_token_objects::token::{Self, Token};
    use aptos_framework::object;
    
    use movement_staking::nft_staking;
    
    // Test modules for fungible assets
    use movement_staking::banana_a;
    
    // Test addresses
    const CREATOR_ADDR: address = @0xa11ce;
    const RECEIVER_ADDR: address = @0xb0b;
    const USER1_ADDR: address = @0x123;
    const USER2_ADDR: address = @0x456;
    const USER3_ADDR: address = @0x789;
    const TOKEN_STAKING_ADDR: address = @movement_staking;
    const FRAMEWORK_ADDR: address = @0x1;
    
    // Error codes
    const ENO_NO_COLLECTION: u64 = 0;
    const ENO_STAKING_EXISTS: u64 = 1;
    const ENO_NO_STAKING: u64 = 2;
    const ENO_NO_TOKEN_IN_TOKEN_STORE: u64 = 3;
    const ENO_STOPPED: u64 = 4;
    const ENO_COLLECTION_NOT_ALLOWED: u64 = 9;
    const ENO_NOT_ADMIN: u64 = 10;
    
    #[test(creator = @0xa11ce, token_staking = @movement_staking)]
    fun test_allowed_collections_functionality(
        creator: signer,
        token_staking: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        
        // Create account
        account::create_account_for_test(creator_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
        // Initialize FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        
        // Mint some tokens to creator for staking pool deposit
        banana_a::mint(&token_staking, creator_addr, 1000);
        
        // Create collections
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Allowed Collection"),
            string::utf8(b"Allowed Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Disallowed Collection"),
            string::utf8(b"Disallowed Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Get collection objects for testing
        let allowed_collection_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Allowed Collection"));
        let allowed_collection_obj = object::address_to_object<Collection>(allowed_collection_addr);
        let disallowed_collection_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Disallowed Collection"));
        let disallowed_collection_obj = object::address_to_object<Collection>(disallowed_collection_addr);
        
        // Test initial state - no collections allowed
        assert!(!nft_staking::is_collection_allowed(allowed_collection_obj), 1);
        assert!(!nft_staking::is_collection_allowed(disallowed_collection_obj), 2);
        
        // Add collection to allowed list
        nft_staking::add_allowed_collection(&creator, allowed_collection_obj);
        assert!(nft_staking::is_collection_allowed(allowed_collection_obj), 3);
        assert!(!nft_staking::is_collection_allowed(disallowed_collection_obj), 4);
        
        // Get collection object for staking
        let collection_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Allowed Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Test that only allowed collection can create staking
        nft_staking::create_staking(&creator, 10, collection_obj, 500, metadata, false);
        
        // Remove collection from allowed list
        nft_staking::remove_allowed_collection(&creator, allowed_collection_obj);
        assert!(!nft_staking::is_collection_allowed(allowed_collection_obj), 5);
    }
    
    #[test(creator = @0xa11ce, token_staking = @movement_staking)]
    #[expected_failure(abort_code = ENO_COLLECTION_NOT_ALLOWED, location = movement_staking::nft_staking)]
    fun test_create_staking_disallowed_collection(
        creator: signer,
        token_staking: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        
        // Create account
        account::create_account_for_test(creator_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
        // Initialize FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        
        // Mint some tokens to creator for staking pool deposit
        banana_a::mint(&token_staking, creator_addr, 1000);
        
        // Create collection
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Disallowed Collection"),
            string::utf8(b"Disallowed Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Get collection object for staking
        let collection_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Disallowed Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Try to create staking for disallowed collection - should fail
        nft_staking::create_staking(&creator, 10, collection_obj, 500, metadata, false);
    }
    
    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking)]
    #[expected_failure(abort_code = ENO_NOT_ADMIN, location = movement_staking::nft_staking)]
    fun test_non_admin_cannot_manage_collections(
        creator: signer,
        receiver: signer,
        token_staking: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Create accounts
        account::create_account_for_test(creator_addr);
        account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin (receiver is NOT admin)
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
        // Create a dummy collection to get collection object
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Test Collection"),
            string::utf8(b"Test Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        let collection_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Test Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Try to add collection as non-admin - should fail
        nft_staking::add_allowed_collection(&receiver, collection_obj);
    }
    
    #[test(creator = @0xa11ce, token_staking = @movement_staking)]
    fun test_get_allowed_collections(
        creator: signer,
        token_staking: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        
        // Create account
        account::create_account_for_test(creator_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
        // Initially empty list
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 0, 1);
        
        // Create collections for testing
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Collection A"),
            string::utf8(b"Collection A"),
            option::none(),
            string::utf8(b"uri"),
        );
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Collection B"),
            string::utf8(b"Collection B"),
            option::none(),
            string::utf8(b"uri"),
        );
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Collection C"),
            string::utf8(b"Collection C"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Get collection objects for operations
        let collection_a_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Collection A"));
        let collection_a_obj = object::address_to_object<Collection>(collection_a_addr);
        let collection_b_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Collection B"));
        let collection_b_obj = object::address_to_object<Collection>(collection_b_addr);
        let collection_c_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Collection C"));
        let collection_c_obj = object::address_to_object<Collection>(collection_c_addr);
        
        // Add one collection
        nft_staking::add_allowed_collection(&creator, collection_a_obj);
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 1, 2);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection A")), 3);
        
        // Add multiple collections
        nft_staking::add_allowed_collection(&creator, collection_b_obj);
        nft_staking::add_allowed_collection(&creator, collection_c_obj);
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 3, 4);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection A")), 5);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection B")), 6);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection C")), 7);
        
        // Remove a collection
        nft_staking::remove_allowed_collection(&creator, collection_b_obj);
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 2, 8);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection A")), 9);
        assert!(!vector::contains(&allowed_collections, &string::utf8(b"Collection B")), 10);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection C")), 11);
        
        // Remove all collections
        nft_staking::remove_allowed_collection(&creator, collection_a_obj);
        nft_staking::remove_allowed_collection(&creator, collection_c_obj);
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 0, 12);
    }
    
    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_freeze_registry_functionality(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Initialize timestamp for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        account::create_account_for_test(creator_addr);
        account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
        // Initialize FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        
        // Mint some tokens to creator for staking pool deposit
        banana_a::mint(&token_staking, creator_addr, 1000);
        
        // Create collection
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Freeze Test Collection"),
            string::utf8(b"Freeze Test Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Freeze Test Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Add collection to allowed list
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
        // Get collection object for staking
        let collection_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Freeze Test Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Create staking pool with freezing enabled
        nft_staking::create_staking(&creator, 10, collection_obj, 500, metadata, true);
        
        // Create and transfer token to receiver
        let token_ref = token::create_named_token(
            &creator,
            string::utf8(b"Freeze Test Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Freeze Test Token"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token_addr = object::address_from_constructor_ref(&token_ref);
        object::transfer(&creator, object::address_to_object<Token>(token_addr), receiver_addr);
        
        // Stake the token
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_addr));
        
        // Advance time to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // 1 day in microseconds
        
        // Verify account is not frozen before claiming
        assert!(!primary_fungible_store::is_frozen(receiver_addr, metadata), 1);
        
        // Claim rewards (this should trigger freezing via freeze_registry)
        nft_staking::claim_reward(&receiver, collection_obj, string::utf8(b"Freeze Test Token"), creator_addr);
        
        // Verify account is frozen after claiming (freeze_registry should have been called)
        assert!(primary_fungible_store::is_frozen(receiver_addr, metadata), 2);
        
        // Verify rewards were actually received
        let balance = primary_fungible_store::balance(receiver_addr, metadata);
        assert!(balance > 0, 3);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_staking_happy_path_with_freezing(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        timestamp::set_time_has_started_for_testing(&framework);
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, sender_addr);
        
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
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"Movement Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Add collection to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
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
        nft_staking::create_staking(&creator, 20, collection_obj, 90, metadata, true);
        
        // Stake the token
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_addr));
        
        // Verify token is no longer owned by receiver (it's been staked)
        assert!(object::owner(object::address_to_object<Token>(token_addr)) != receiver_addr, 1);
        
        // Advance time by 1 day to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Check balance before claiming
        let balance_before = primary_fungible_store::balance(receiver_addr, metadata);
        
        // Claim rewards
        nft_staking::claim_reward(&receiver, collection_obj, string::utf8(b"Movement Token #1"), sender_addr);
        
        // Verify rewards were received and account is frozen (soulbound)
        let balance_after = primary_fungible_store::balance(receiver_addr, metadata);
        assert!(balance_after > balance_before, 2);
        assert!(primary_fungible_store::is_frozen(receiver_addr, metadata), 3);
        
        // Unstake the token
        nft_staking::unstake_token(&receiver, sender_addr, collection_obj, string::utf8(b"Movement Token #1"));
        
        // Verify token is returned to receiver
        assert!(object::owner(object::address_to_object<Token>(token_addr)) == receiver_addr, 4);
        
        // Test restaking the same token
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_addr));
        assert!(object::owner(object::address_to_object<Token>(token_addr)) != receiver_addr, 5);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_staking_happy_path_without_freezing(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        timestamp::set_time_has_started_for_testing(&framework);
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, sender_addr);
        
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
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"Freezing Disabled Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Add collection to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
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
        nft_staking::create_staking(&creator, 20, collection_obj, 90, metadata, false);
        
        // Stake the token
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_addr));
        
        // Verify token is no longer owned by receiver (it's been staked)
        assert!(object::owner(object::address_to_object<Token>(token_addr)) != receiver_addr, 1);
        
        // Advance time by 1 day to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Check balance before claiming
        let balance_before = primary_fungible_store::balance(receiver_addr, metadata);
        
        // Claim rewards
        nft_staking::claim_reward(&receiver, collection_obj, string::utf8(b"Freezing Disabled Token"), sender_addr);
        
        // Verify rewards were received but account is NOT frozen (no soulbound)
        let balance_after = primary_fungible_store::balance(receiver_addr, metadata);
        assert!(balance_after > balance_before, 2);
        assert!(!primary_fungible_store::is_frozen(receiver_addr, metadata), 3);
        
        // Unstake the token
        nft_staking::unstake_token(&receiver, sender_addr, collection_obj, string::utf8(b"Freezing Disabled Token"));
        
        // Verify token is returned to receiver
        assert!(object::owner(object::address_to_object<Token>(token_addr)) == receiver_addr, 4);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking)]
    fun test_is_staking_enabled(
        creator: signer,
        receiver: signer,
        token_staking: signer,
    ) {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize the global registries for testing
        nft_staking::test_init_registries_with_admin(&token_staking, sender_addr);
        
        // Initialize FA module
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
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"Test Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Collection exists but no staking pool yet
        assert!(!nft_staking::is_staking_enabled(sender_addr, collection_obj), 1);
        
        // Add collection to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
        // Create staking pool
        nft_staking::create_staking(&creator, 20, collection_obj, 90, metadata, true);
        
        // Staking pool exists and is enabled by default
        assert!(nft_staking::is_staking_enabled(sender_addr, collection_obj), 2);
        
        // Stop staking
        nft_staking::creator_stop_staking(&creator, collection_obj);
        
        // Staking pool exists but is stopped
        assert!(!nft_staking::is_staking_enabled(sender_addr, collection_obj), 3);
        
        // Re-enable staking by depositing rewards
        nft_staking::deposit_staking_rewards(&creator, collection_obj, 10);
        
        // Staking pool re-enabled after deposit
        assert!(nft_staking::is_staking_enabled(sender_addr, collection_obj), 4);
    }
} 