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
    use movement_staking::banana_b;
    
    // Test addresses
    const CREATOR_ADDR: address = @0xa11ce;
    const RECEIVER_ADDR: address = @0xb0b;
    const USER1_ADDR: address = @0x123;
    const USER2_ADDR: address = @0x456;
    const USER3_ADDR: address = @0x789;
    const TOKEN_STAKING_ADDR: address = @movement_staking;
    const FRAMEWORK_ADDR: address = @0x1;
    
    // Error codes
    const ESTOPPED: u64 = 4;
    const ECOLLECTION_NOT_ALLOWED: u64 = 9;
    const ENOT_ADMIN: u64 = 10;
    
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
        assert!(!nft_staking::is_collection_allowed(allowed_collection_obj), ECOLLECTION_NOT_ALLOWED);
        assert!(!nft_staking::is_collection_allowed(disallowed_collection_obj), ECOLLECTION_NOT_ALLOWED);
        
        // Add collection to allowed list
        nft_staking::add_allowed_collection(&creator, allowed_collection_obj);
        assert!(nft_staking::is_collection_allowed(allowed_collection_obj), ECOLLECTION_NOT_ALLOWED);
        assert!(!nft_staking::is_collection_allowed(disallowed_collection_obj), ECOLLECTION_NOT_ALLOWED);
        
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
    #[expected_failure(abort_code = ECOLLECTION_NOT_ALLOWED, location = movement_staking::nft_staking)]
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
    #[expected_failure(abort_code = ENOT_ADMIN, location = movement_staking::nft_staking)]
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
        assert!(vector::contains(&allowed_collections, &collection_a_addr), 3);
        
        // Add multiple collections
        nft_staking::add_allowed_collection(&creator, collection_b_obj);
        nft_staking::add_allowed_collection(&creator, collection_c_obj);
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 3, 4);
        assert!(vector::contains(&allowed_collections, &collection_a_addr), 5);
        assert!(vector::contains(&allowed_collections, &collection_b_addr), 6);
        assert!(vector::contains(&allowed_collections, &collection_c_addr), 7);
        
        // Remove a collection
        nft_staking::remove_allowed_collection(&creator, collection_b_obj);
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 2, 8);
        assert!(vector::contains(&allowed_collections, &collection_a_addr), 9);
        assert!(!vector::contains(&allowed_collections, &collection_b_addr), 10);
        assert!(vector::contains(&allowed_collections, &collection_c_addr), 11);
        
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
        let freeze_test_token_obj = object::address_to_object<Token>(token_addr);
        object::transfer(&creator, freeze_test_token_obj, receiver_addr);
        
        // Stake the token
        nft_staking::stake_token(&receiver, freeze_test_token_obj);
        
        // Advance time to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // 1 day in microseconds
        
        // Verify account is not frozen before claiming
        assert!(!primary_fungible_store::is_frozen(receiver_addr, metadata), 1);
        
        // Claim rewards (this should trigger freezing via freeze_registry)
        nft_staking::claim_reward(&receiver, freeze_test_token_obj);
        
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
        nft_staking::claim_reward(&receiver, object::address_to_object<Token>(token_addr));
        
        // Verify rewards were received and account is frozen (soulbound)
        let balance_after = primary_fungible_store::balance(receiver_addr, metadata);
        assert!(balance_after > balance_before, 2);
        assert!(primary_fungible_store::is_frozen(receiver_addr, metadata), 3);
        
        // Unstake the token
        nft_staking::unstake_token(&receiver, object::address_to_object<Token>(token_addr));
        
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
        nft_staking::claim_reward(&receiver, object::address_to_object<Token>(token_addr));
        
        // Verify rewards were received but account is NOT frozen (no soulbound)
        let balance_after = primary_fungible_store::balance(receiver_addr, metadata);
        assert!(balance_after > balance_before, 2);
        assert!(!primary_fungible_store::is_frozen(receiver_addr, metadata), 3);
        
        // Unstake the token
        nft_staking::unstake_token(&receiver, object::address_to_object<Token>(token_addr));
        
        // Verify token is returned to receiver
        assert!(object::owner(object::address_to_object<Token>(token_addr)) == receiver_addr, 4);
    }



    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking)]
    fun test_create_staking(
        creator: signer,
        receiver: signer,
        token_staking: signer
    ) {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, sender_addr);
        
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
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"Movement Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Add collection to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
        nft_staking::create_staking(
            &creator,
            20,
            collection_obj,
            90,
            metadata,
            true);
        nft_staking::update_dpr(
            &creator,
            30,
            collection_obj,
        );
        nft_staking::creator_stop_staking(
            &creator,
            collection_obj,
        );
        
        // Verify staking is stopped
        assert!(!nft_staking::is_staking_enabled(sender_addr, collection_obj), 98);
        
        // Re-enable staking using the proper function
        nft_staking::creator_resume_staking(&creator, collection_obj);
        
        // Verify staking is re-enabled
        assert!(nft_staking::is_staking_enabled(sender_addr, collection_obj), 88);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking)]
    #[expected_failure(abort_code = ESTOPPED, location = movement_staking::nft_staking)]
    fun test_stake_when_stopped(
        creator: signer,
        receiver: signer,
        token_staking: signer,
    ) {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, sender_addr);
        
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
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"Test Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Add collection to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
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
        nft_staking::create_staking(&creator, 10, collection_obj, 90, metadata, true);
        nft_staking::creator_stop_staking(&creator, collection_obj);
        
        // Attempt stake (should abort with ESTOPPED)
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_addr));
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_multiple_fa_staking_with_freezing(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, sender_addr);
        
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
        
        // Get collection objects for operations
        let collection_a_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"Test Collection A"));
        let collection_a_obj = object::address_to_object<Collection>(collection_a_addr);
        let collection_b_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"Test Collection B"));
        let collection_b_obj = object::address_to_object<Collection>(collection_b_addr);
        
        // Add collections to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_a_obj);
        nft_staking::add_allowed_collection(&creator, collection_b_obj);
        
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
        nft_staking::create_staking(&creator, 20, collection_a_obj, 500, banana_a_metadata, true);
        nft_staking::create_staking(&creator, 15, collection_b_obj, 300, banana_b_metadata, true);
        
        // Stake both tokens
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_a_addr));
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_b_addr));
        
        // Advance time by 1 day (86400 seconds) to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Claim rewards for both tokens
        nft_staking::claim_reward(&receiver, object::address_to_object<Token>(token_a_addr));
        nft_staking::claim_reward(&receiver, object::address_to_object<Token>(token_b_addr));
        
        // Verify that both accounts are frozen after claiming rewards (soulbound)
        assert!(primary_fungible_store::is_frozen(receiver_addr, banana_a_metadata), 1);
        assert!(primary_fungible_store::is_frozen(receiver_addr, banana_b_metadata), 2);
        
        // Verify balances increased after time advancement and reward claiming
        let banana_a_balance = primary_fungible_store::balance(receiver_addr, banana_a_metadata);
        let banana_b_balance = primary_fungible_store::balance(receiver_addr, banana_b_metadata);
        assert!(banana_a_balance > 0, 3);
        assert!(banana_b_balance > 0, 4);
        
        // Unstake both tokens (should work even with frozen accounts thanks to transfer_with_ref)
        nft_staking::unstake_token(&receiver, object::address_to_object<Token>(token_a_addr));
        nft_staking::unstake_token(&receiver, object::address_to_object<Token>(token_b_addr));
        
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
    ) {
        let sender_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(sender_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, sender_addr);
        
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
        
        // Get collection objects for operations
        let collection_c_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"Test Collection C"));
        let collection_c_obj = object::address_to_object<Collection>(collection_c_addr);
        let collection_d_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"Test Collection D"));
        let collection_d_obj = object::address_to_object<Collection>(collection_d_addr);
        
        // Add collections to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_c_obj);
        nft_staking::add_allowed_collection(&creator, collection_d_obj);
        
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
        nft_staking::create_staking(&creator, 20, collection_c_obj, 500, banana_a_metadata, false);
        nft_staking::create_staking(&creator, 15, collection_d_obj, 300, banana_b_metadata, false);
        
        // Stake both tokens
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_a_addr));
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_b_addr));
        
        // Advance time by 1 day (86400 seconds) to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Claim rewards for both tokens
        nft_staking::claim_reward(&receiver, object::address_to_object<Token>(token_a_addr));
        nft_staking::claim_reward(&receiver, object::address_to_object<Token>(token_b_addr));
        
        // Verify that both accounts are NOT frozen after claiming rewards (no soulbound)
        assert!(!primary_fungible_store::is_frozen(receiver_addr, banana_a_metadata), 1);
        assert!(!primary_fungible_store::is_frozen(receiver_addr, banana_b_metadata), 2);
        
        // Verify balances increased after time advancement and reward claiming
        let banana_a_balance = primary_fungible_store::balance(receiver_addr, banana_a_metadata);
        let banana_b_balance = primary_fungible_store::balance(receiver_addr, banana_b_metadata);
        assert!(banana_a_balance > 0, 3);
        assert!(banana_b_balance > 0, 4);
        
        // Unstake both tokens (should work normally since accounts are not frozen)
        nft_staking::unstake_token(&receiver, object::address_to_object<Token>(token_a_addr));
        nft_staking::unstake_token(&receiver, object::address_to_object<Token>(token_b_addr));
        
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
    ) {
        let creator_addr = signer::address_of(&creator);
        let user1_addr = signer::address_of(&user1);
        let user2_addr = signer::address_of(&user2);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(creator_addr);
        aptos_framework::account::create_account_for_test(user1_addr);
        aptos_framework::account::create_account_for_test(user2_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
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
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Registry Test Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Add collection to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
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
        nft_staking::create_staking(&creator, 10, collection_obj, 500, metadata, false);
        
        // Verify registry is initially empty using view functions
        assert!(nft_staking::get_staked_nfts_count(user1_addr) == 0, 1);
        assert!(nft_staking::get_staked_nfts_count(user2_addr) == 0, 2);
        
        // User1 stakes 2 tokens
        nft_staking::stake_token(&user1, object::address_to_object<Token>(token1_addr));
        nft_staking::stake_token(&user1, object::address_to_object<Token>(token2_addr));
        
        // User2 stakes 1 token
        nft_staking::stake_token(&user2, object::address_to_object<Token>(token3_addr));
        
        // Verify registry contents after staking using view functions
        assert!(nft_staking::get_staked_nfts_count(user1_addr) == 2, 3);
        assert!(nft_staking::get_staked_nfts_count(user2_addr) == 1, 4);
        
        let user1_nfts = nft_staking::get_staked_nfts(user1_addr);
        let user2_nfts = nft_staking::get_staked_nfts(user2_addr);
        assert!(vector::length(&user1_nfts) == 2, 5);
        assert!(vector::length(&user2_nfts) == 1, 6);
        
        // Unstake one token from user1
        nft_staking::unstake_token(&user1, object::address_to_object<Token>(token1_addr));
        
        // Verify registry is updated after unstaking
        assert!(nft_staking::get_staked_nfts_count(user1_addr) == 1, 7);
        assert!(nft_staking::get_staked_nfts_count(user2_addr) == 1, 8); // User2 unchanged
        
        // Unstake remaining tokens
        nft_staking::unstake_token(&user1, object::address_to_object<Token>(token2_addr));
        nft_staking::unstake_token(&user2, object::address_to_object<Token>(token3_addr));
        
        // Verify registry is properly cleaned up
        assert!(nft_staking::get_staked_nfts_count(user1_addr) == 0, 9);
        assert!(nft_staking::get_staked_nfts_count(user2_addr) == 0, 10);
    }

    #[test(creator = @0x123, user1 = @0x456, token_staking = @0xfee, framework = @0x1)]
    fun test_batch_staking_happy_path_with_freezing(
        creator: signer,
        user1: signer,
        token_staking: signer,
        framework: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        let user1_addr = signer::address_of(&user1);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(creator_addr);
        aptos_framework::account::create_account_for_test(user1_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
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
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Batch Test Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Add collection to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
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
        
        let token1_addr = object::address_from_constructor_ref(&token1_ref);
        let token2_addr = object::address_from_constructor_ref(&token2_ref);
        
        // Transfer tokens to user1
        object::transfer(&creator, object::address_to_object<Token>(token1_addr), user1_addr);
        object::transfer(&creator, object::address_to_object<Token>(token2_addr), user1_addr);
        
        // Create staking pool with freezing enabled (is_locked = true)
        nft_staking::create_staking(&creator, 20, collection_obj, 500, metadata, true);
        
        // Verify registry is initially empty
        assert!(nft_staking::get_staked_nfts_count(user1_addr) == 0, 1);
        
        // Create vector of NFTs to batch stake
        let nfts_to_stake = vector::empty<object::Object<Token>>();
        vector::push_back(&mut nfts_to_stake, object::address_to_object<Token>(token1_addr));
        vector::push_back(&mut nfts_to_stake, object::address_to_object<Token>(token2_addr));
        
        // Batch stake both tokens
        nft_staking::batch_stake_tokens(&user1, nfts_to_stake);
        
        // Verify all tokens are no longer owned by user1 (they've been staked)
        assert!(object::owner(object::address_to_object<Token>(token1_addr)) != user1_addr, 2);
        assert!(object::owner(object::address_to_object<Token>(token2_addr)) != user1_addr, 3);
        
        // Verify registry contains both staked NFTs
        assert!(nft_staking::get_staked_nfts_count(user1_addr) == 2, 4);
        
        // Advance time by 1 day to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Check balance before claiming
        let balance_before = primary_fungible_store::balance(user1_addr, metadata);
        
        // Claim rewards for first token only (account will be frozen after this)
        nft_staking::claim_reward(&user1, object::address_to_object<Token>(token1_addr));
        
        // Verify rewards were received and account is frozen (soulbound)
        let balance_after = primary_fungible_store::balance(user1_addr, metadata);
        assert!(balance_after > balance_before, 5);
        assert!(primary_fungible_store::is_frozen(user1_addr, metadata), 6);
        
        // Create vector of NFTs to batch unstake
        let nfts_to_unstake = vector::empty<object::Object<Token>>();
        vector::push_back(&mut nfts_to_unstake, object::address_to_object<Token>(token1_addr));
        vector::push_back(&mut nfts_to_unstake, object::address_to_object<Token>(token2_addr));
        
        // Batch unstake both tokens
        nft_staking::batch_unstake_tokens(&user1, nfts_to_unstake);
        
        // Verify tokens are returned to user1
        assert!(object::owner(object::address_to_object<Token>(token1_addr)) == user1_addr, 7);
        assert!(object::owner(object::address_to_object<Token>(token2_addr)) == user1_addr, 8);
        
        // Test batch restaking the same tokens (this tests the restaking logic)
        let restake_nfts = vector::empty<object::Object<Token>>();
        vector::push_back(&mut restake_nfts, object::address_to_object<Token>(token1_addr));
        vector::push_back(&mut restake_nfts, object::address_to_object<Token>(token2_addr));
        
        nft_staking::batch_stake_tokens(&user1, restake_nfts);
        
        // Verify tokens are staked again (restaking worked)
        assert!(object::owner(object::address_to_object<Token>(token1_addr)) != user1_addr, 9);
        assert!(object::owner(object::address_to_object<Token>(token2_addr)) != user1_addr, 10);
        assert!(nft_staking::get_staked_nfts_count(user1_addr) == 2, 11);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_staked_nfts_view_functions(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(creator_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
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
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"View Test Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Add collection to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
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
        nft_staking::create_staking(&creator, 10, collection_obj, 500, metadata, false);
        
        // Test view functions before staking
        assert!(nft_staking::get_staked_nfts_count(receiver_addr) == 0, 1);
        let empty_nfts = nft_staking::get_staked_nfts(receiver_addr);
        assert!(vector::length(&empty_nfts) == 0, 2);
        
        // Stake the token
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_addr));
        
        // Advance time to ensure timestamp is set
        timestamp::update_global_time_for_test(1000000); // 1 second in microseconds
        
        // Test view functions after staking
        assert!(nft_staking::get_staked_nfts_count(receiver_addr) == 1, 3);
        let staked_nfts = nft_staking::get_staked_nfts(receiver_addr);
        assert!(vector::length(&staked_nfts) == 1, 4);
        
        // Verify the NFT info is correct (just check that we have the NFT info structure)
        let _nft_info = vector::borrow(&staked_nfts, 0);
        // Note: We can't access struct fields directly from test module, but we can verify the vector contains data
        
        // Unstake the token
        nft_staking::unstake_token(&receiver, object::address_to_object<Token>(token_addr));
        
        // Test view functions after unstaking
        assert!(nft_staking::get_staked_nfts_count(receiver_addr) == 0, 5);
        let final_nfts = nft_staking::get_staked_nfts(receiver_addr);
        assert!(vector::length(&final_nfts) == 0, 6);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_get_user_accumulated_rewards(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(creator_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
        // Initialize both FA modules
        banana_a::test_init(&token_staking);
        banana_b::test_init(&token_staking);
        let banana_a_metadata = banana_a::get_metadata();
        let banana_b_metadata = banana_b::get_metadata();
        banana_a::mint(&token_staking, creator_addr, 1000);
        banana_b::mint(&token_staking, creator_addr, 1000);
        
        // Create collections
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Rewards Test Collection A"),
            string::utf8(b"Rewards Test Collection A"),
            option::none(),
            string::utf8(b"uri"),
        );
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Rewards Test Collection B"),
            string::utf8(b"Rewards Test Collection B"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Get collection objects for operations
        let collection_a_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Rewards Test Collection A"));
        let collection_a_obj = object::address_to_object<Collection>(collection_a_addr);
        let collection_b_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Rewards Test Collection B"));
        let collection_b_obj = object::address_to_object<Collection>(collection_b_addr);
        
        // Add collections to allowed list
        nft_staking::add_allowed_collection(&creator, collection_a_obj);
        nft_staking::add_allowed_collection(&creator, collection_b_obj);
        
        // Create staking pools with different DPRs and different metadata
        nft_staking::create_staking(&creator, 20, collection_a_obj, 500, banana_a_metadata, false);
        nft_staking::create_staking(&creator, 30, collection_b_obj, 300, banana_b_metadata, false);
        
        // Create tokens
        let token_a_ref = token::create_named_token(
            &creator,
            string::utf8(b"Rewards Test Collection A"),
            string::utf8(b"desc"),
            string::utf8(b"Token A"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token_b_ref = token::create_named_token(
            &creator,
            string::utf8(b"Rewards Test Collection B"),
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
        
        // Initially no rewards for either metadata type
        let initial_rewards_a = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_a_metadata);
        let initial_rewards_b = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_b_metadata);
        assert!(initial_rewards_a == 0, 1);
        assert!(initial_rewards_b == 0, 2);
        
        // Stake both tokens
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_a_addr));
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_b_addr));
        
        // Still no rewards immediately after staking
        let rewards_after_staking_a = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_a_metadata);
        let rewards_after_staking_b = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_b_metadata);
        assert!(rewards_after_staking_a == 0, 3);
        assert!(rewards_after_staking_b == 0, 4);
        
        // Advance time by 0.5 days (12 hours = 43200 seconds) to test continuous rewards
        timestamp::update_global_time_for_test(43200 * 1000000); // microseconds
        
        // Calculate expected rewards after 0.5 days (continuous calculation):
        // Collection A (banana_a): 20 DPR * 0.5 days * 1 token = 10
        // Collection B (banana_b): 30 DPR * 0.5 days * 1 token = 15
        let rewards_after_half_day_a = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_a_metadata);
        let rewards_after_half_day_b = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_b_metadata);
        assert!(rewards_after_half_day_a == 10, 5);
        assert!(rewards_after_half_day_b == 15, 6);
        
        // Advance time by another 0.5 days (cumulative: 1 day total)
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Calculate expected rewards after 1 day:
        // Collection A (banana_a): 20 DPR * 1 day * 1 token = 20
        // Collection B (banana_b): 30 DPR * 1 day * 1 token = 30
        let rewards_after_1_day_a = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_a_metadata);
        let rewards_after_1_day_b = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_b_metadata);
        assert!(rewards_after_1_day_a == 20, 7);
        assert!(rewards_after_1_day_b == 30, 8);
        
        // Advance time by another day (cumulative: 2 days total)
        timestamp::update_global_time_for_test(2 * 86400 * 1000000); // microseconds
        
        // After 2 days:
        // Collection A (banana_a): 20 DPR * 2 days * 1 token = 40
        // Collection B (banana_b): 30 DPR * 2 days * 1 token = 60
        let rewards_after_2_days_a = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_a_metadata);
        let rewards_after_2_days_b = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_b_metadata);
        assert!(rewards_after_2_days_a == 40, 9);
        assert!(rewards_after_2_days_b == 60, 10);
        
        // Test the helper function to get metadata types
        let metadata_types = nft_staking::get_user_reward_metadata_types(receiver_addr);
        assert!(vector::length(&metadata_types) == 2, 11); // Should have both banana_a and banana_b
        assert!(vector::contains(&metadata_types, &banana_a_metadata), 12);
        assert!(vector::contains(&metadata_types, &banana_b_metadata), 13);
        
        // Claim rewards from Collection A (banana_a)
        nft_staking::claim_reward(&receiver, object::address_to_object<Token>(token_a_addr));
        
        // After claiming, banana_a rewards should be reduced, banana_b should be unchanged
        let rewards_after_claiming_a = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_a_metadata);
        let rewards_after_claiming_b = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_b_metadata);
        assert!(rewards_after_claiming_a == 0, 14); // Collection A rewards claimed
        assert!(rewards_after_claiming_b == 60, 15); // Collection B rewards unchanged
        
        // Unstake Collection B token (this resets reward data)
        nft_staking::unstake_token(&receiver, object::address_to_object<Token>(token_b_addr));
        
        // After unstaking, rewards are reset to 0 for Collection B
        let rewards_after_unstaking_a = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_a_metadata);
        let rewards_after_unstaking_b = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_b_metadata);
        assert!(rewards_after_unstaking_a == 0, 16); // Collection A still 0
        assert!(rewards_after_unstaking_b == 0, 17); // Collection B reset to 0 after unstaking
        
        // Advance time again - Collection A continues accruing, Collection B doesn't (unstaked)
        timestamp::update_global_time_for_test(3 * 86400 * 1000000); // microseconds (cumulative: 3 days total)
        let rewards_after_more_time_a = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_a_metadata);
        let rewards_after_more_time_b = nft_staking::get_user_accumulated_rewards(receiver_addr, banana_b_metadata);
        // Collection A: 20 DPR * 3 days * 1 token = 60 total, minus 40 withdrawn = 20 remaining
        assert!(rewards_after_more_time_a == 20, 18); // Collection A continues accruing
        assert!(rewards_after_more_time_b == 0, 19); // Collection B still 0 (unstaked)
        
        // Test with user who has no staked NFTs
        let no_stakes_user = @0x999;
        aptos_framework::account::create_account_for_test(no_stakes_user);
        let rewards_no_stakes_a = nft_staking::get_user_accumulated_rewards(no_stakes_user, banana_a_metadata);
        let rewards_no_stakes_b = nft_staking::get_user_accumulated_rewards(no_stakes_user, banana_b_metadata);
        assert!(rewards_no_stakes_a == 0, 20);
        assert!(rewards_no_stakes_b == 0, 21);
        
        // Test the new get_all_user_accumulated_rewards function
        let all_rewards = nft_staking::get_all_user_accumulated_rewards(receiver_addr);
        assert!(vector::length(&all_rewards) == 1, 22); // Only Collection A should have rewards (Collection B was unstaked)
        
        // Check the rewards for Collection A
        let reward_info_a = vector::borrow(&all_rewards, 0);
        assert!(nft_staking::get_rewards(reward_info_a) == 20, 23); // Should be 20 rewards for Collection A
        assert!(nft_staking::get_fa_address(reward_info_a) == object::object_address(&banana_a_metadata), 24); // Should match banana_a metadata address
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    fun test_get_all_user_accumulated_rewards(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(creator_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
        // Initialize both FA modules
        banana_a::test_init(&token_staking);
        banana_b::test_init(&token_staking);
        let banana_a_metadata = banana_a::get_metadata();
        let banana_b_metadata = banana_b::get_metadata();
        banana_a::mint(&token_staking, creator_addr, 1000);
        banana_b::mint(&token_staking, creator_addr, 1000);
        
        // Create collections
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"All Rewards Test Collection A"),
            string::utf8(b"All Rewards Test Collection A"),
            option::none(),
            string::utf8(b"uri"),
        );
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"All Rewards Test Collection B"),
            string::utf8(b"All Rewards Test Collection B"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Get collection objects for operations
        let collection_a_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"All Rewards Test Collection A"));
        let collection_a_obj = object::address_to_object<Collection>(collection_a_addr);
        let collection_b_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"All Rewards Test Collection B"));
        let collection_b_obj = object::address_to_object<Collection>(collection_b_addr);
        
        // Add collections to allowed list
        nft_staking::add_allowed_collection(&creator, collection_a_obj);
        nft_staking::add_allowed_collection(&creator, collection_b_obj);
        
        // Create staking pools with different DPRs
        nft_staking::create_staking(&creator, 20, collection_a_obj, 500, banana_a_metadata, false);
        nft_staking::create_staking(&creator, 30, collection_b_obj, 300, banana_b_metadata, false);
        
        // Create tokens
        let token_a_ref = token::create_named_token(
            &creator,
            string::utf8(b"All Rewards Test Collection A"),
            string::utf8(b"desc"),
            string::utf8(b"Token A"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token_b_ref = token::create_named_token(
            &creator,
            string::utf8(b"All Rewards Test Collection B"),
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
        
        // Initially no rewards
        let initial_all_rewards = nft_staking::get_all_user_accumulated_rewards(receiver_addr);
        assert!(vector::length(&initial_all_rewards) == 0, 1);
        
        // Stake both tokens
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_a_addr));
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token_b_addr));
        
        // Advance time by 1 day
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Get all rewards - should have both FA types
        let all_rewards = nft_staking::get_all_user_accumulated_rewards(receiver_addr);
        assert!(vector::length(&all_rewards) == 2, 2);
        
        // Check that both FA types are present with correct rewards
        let found_a = false;
        let found_b = false;
        let i = 0;
        let rewards_len = vector::length(&all_rewards);
        
        while (i < rewards_len) {
            let reward_info = vector::borrow(&all_rewards, i);
            if (nft_staking::get_fa_address(reward_info) == object::object_address(&banana_a_metadata)) {
                assert!(nft_staking::get_rewards(reward_info) == 20, 3); // 20 DPR * 1 day * 1 token = 20
                found_a = true;
            } else if (nft_staking::get_fa_address(reward_info) == object::object_address(&banana_b_metadata)) {
                assert!(nft_staking::get_rewards(reward_info) == 30, 4); // 30 DPR * 1 day * 1 token = 30
                found_b = true;
            };
            i = i + 1;
        };
        
        assert!(found_a, 5); // Should find banana_a rewards
        assert!(found_b, 6); // Should find banana_b rewards
        
        // Test with user who has no staked NFTs
        let no_stakes_user = @0x888;
        aptos_framework::account::create_account_for_test(no_stakes_user);
        let empty_rewards = nft_staking::get_all_user_accumulated_rewards(no_stakes_user);
        assert!(vector::length(&empty_rewards) == 0, 7);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking, framework = @0x1)]
    /// Tests the batch_claim_rewards function to ensure it can claim rewards for multiple tokens
    /// in a single transaction, which is more efficient than multiple individual claim calls.
    fun test_batch_claim_rewards(
        creator: signer,
        receiver: signer,
        token_staking: signer,
        framework: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Set up global time for testing
        timestamp::set_time_has_started_for_testing(&framework);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(creator_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
        // Initialize FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        banana_a::mint(&token_staking, creator_addr, 1000);
        
        // Create collection
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Batch Claim Test Collection"),
            string::utf8(b"Batch Claim Test Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Batch Claim Test Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Add collection to allowed list
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
        // Create multiple tokens
        let token1_ref = token::create_named_token(
            &creator,
            string::utf8(b"Batch Claim Test Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Batch Claim Token 1"),
            option::none(),
            string::utf8(b"uri"),
        );
        let token2_ref = token::create_named_token(
            &creator,
            string::utf8(b"Batch Claim Test Collection"),
            string::utf8(b"desc"),
            string::utf8(b"Batch Claim Token 2"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        let token1_addr = object::address_from_constructor_ref(&token1_ref);
        let token2_addr = object::address_from_constructor_ref(&token2_ref);
        
        // Transfer tokens to receiver
        object::transfer(&creator, object::address_to_object<Token>(token1_addr), receiver_addr);
        object::transfer(&creator, object::address_to_object<Token>(token2_addr), receiver_addr);
        
        // Create staking pool
        nft_staking::create_staking(&creator, 20, collection_obj, 500, metadata, false);
        
        // Stake both tokens
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token1_addr));
        nft_staking::stake_token(&receiver, object::address_to_object<Token>(token2_addr));
        
        // Advance time by 1 day to accrue rewards
        timestamp::update_global_time_for_test(86400 * 1000000); // microseconds
        
        // Check balance before claiming
        let balance_before = primary_fungible_store::balance(receiver_addr, metadata);
        
        // Create vector of tokens to batch claim
        let tokens_to_claim = vector::empty<object::Object<Token>>();
        vector::push_back(&mut tokens_to_claim, object::address_to_object<Token>(token1_addr));
        vector::push_back(&mut tokens_to_claim, object::address_to_object<Token>(token2_addr));
        
        // Batch claim rewards for both tokens
        nft_staking::batch_claim_rewards(&receiver, tokens_to_claim);
        
        // Check balance after claiming
        let balance_after = primary_fungible_store::balance(receiver_addr, metadata);
        
        // Verify rewards were received (should be 20 * 2 = 40 total rewards)
        assert!(balance_after > balance_before, 1);
        assert!(balance_after - balance_before == 40, 2); // 20 DPR * 1 day * 2 tokens = 40
        
        // Verify both tokens are still staked (not unstaked)
        assert!(object::owner(object::address_to_object<Token>(token1_addr)) != receiver_addr, 3);
        assert!(object::owner(object::address_to_object<Token>(token2_addr)) != receiver_addr, 4);
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
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, sender_addr);
        
        // Initialize FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        banana_a::mint(&token_staking, sender_addr, 100);
        
        // Create collection
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Enhanced Test Collection"),
            string::utf8(b"Enhanced Test Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"Enhanced Test Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // No staking resources exist yet
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
        
        // Re-enable staking using the proper function
        nft_staking::creator_resume_staking(&creator, collection_obj);
        
        // Staking pool re-enabled
        assert!(nft_staking::is_staking_enabled(sender_addr, collection_obj), 4);
    }

    #[test(creator = @0xa11ce, token_staking = @movement_staking)]
    fun test_update_dpr_functionality(
        creator: signer,
        token_staking: signer,
    ) {
        let sender_addr = signer::address_of(&creator);
        
        // Create account
        aptos_framework::account::create_account_for_test(sender_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, sender_addr);
        
        // Initialize FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        banana_a::mint(&token_staking, sender_addr, 100);
        
        // Create collection
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"DPR Test Collection"),
            string::utf8(b"DPR Test Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"DPR Test Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Add collection to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
        // Create staking pool with initial DPR=20
        nft_staking::create_staking(&creator, 20, collection_obj, 90, metadata, true);
        
        // Update DPR to 30
        nft_staking::update_dpr(&creator, 30, collection_obj);
        
        // Verify the update worked by testing the pool is still active with new settings
        assert!(nft_staking::is_staking_enabled(sender_addr, collection_obj), 1);
        
        // Update DPR again to 15
        nft_staking::update_dpr(&creator, 15, collection_obj);
        
        // Verify the pool is still active
        assert!(nft_staking::is_staking_enabled(sender_addr, collection_obj), 2);
    }

    #[test(creator = @0xa11ce, token_staking = @movement_staking)]
    fun test_deposit_rewards_functionality(
        creator: signer,
        token_staking: signer,
    ) {
        let sender_addr = signer::address_of(&creator);
        
        // Create account
        aptos_framework::account::create_account_for_test(sender_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, sender_addr);
        
        // Initialize FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        banana_a::mint(&token_staking, sender_addr, 1000);
        
        // Create collection
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Rewards Deposit Collection"),
            string::utf8(b"Rewards Deposit Collection"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Get collection object for operations
        let collection_addr = collection::create_collection_address(&sender_addr, &string::utf8(b"Rewards Deposit Collection"));
        let collection_obj = object::address_to_object<Collection>(collection_addr);
        
        // Add collection to allowed list before creating staking
        nft_staking::add_allowed_collection(&creator, collection_obj);
        
        // Create staking pool
        nft_staking::create_staking(&creator, 20, collection_obj, 100, metadata, true);
        
        // Verify pool is enabled
        assert!(nft_staking::is_staking_enabled(sender_addr, collection_obj), 1);
        
        // Stop the pool
        nft_staking::creator_stop_staking(&creator, collection_obj);
        assert!(!nft_staking::is_staking_enabled(sender_addr, collection_obj), 2);
        
        // Re-enable the pool using the proper function
        nft_staking::creator_resume_staking(&creator, collection_obj);
        
        // Verify pool is re-enabled
        assert!(nft_staking::is_staking_enabled(sender_addr, collection_obj), 3);
        
        // Deposit more rewards while pool is active
        nft_staking::deposit_staking_rewards(&creator, collection_obj, 25);
        
        // Verify pool is still enabled
        assert!(nft_staking::is_staking_enabled(sender_addr, collection_obj), 4);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking)]
    fun test_admin_functions(
        creator: signer,
        receiver: signer,
        token_staking: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(creator_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
        // Create collections for testing
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Admin Test Collection A"),
            string::utf8(b"Admin Test Collection A"),
            option::none(),
            string::utf8(b"uri"),
        );
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Admin Test Collection B"),
            string::utf8(b"Admin Test Collection B"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        // Get collection objects for operations
        let collection_a_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Admin Test Collection A"));
        let collection_a_obj = object::address_to_object<Collection>(collection_a_addr);
        let collection_b_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Admin Test Collection B"));
        let collection_b_obj = object::address_to_object<Collection>(collection_b_addr);
        
        // Test initial state - no collections allowed
        assert!(!nft_staking::is_collection_allowed(collection_a_obj), 1);
        assert!(!nft_staking::is_collection_allowed(collection_b_obj), 2);
        
        // Test adding collections to allowed list (admin function)
        nft_staking::add_allowed_collection(&creator, collection_a_obj);
        assert!(nft_staking::is_collection_allowed(collection_a_obj), 3);
        assert!(!nft_staking::is_collection_allowed(collection_b_obj), 4);
        
        // Add second collection
        nft_staking::add_allowed_collection(&creator, collection_b_obj);
        assert!(nft_staking::is_collection_allowed(collection_a_obj), 5);
        assert!(nft_staking::is_collection_allowed(collection_b_obj), 6);
        
        // Test removing collections from allowed list (admin function)
        nft_staking::remove_allowed_collection(&creator, collection_a_obj);
        assert!(!nft_staking::is_collection_allowed(collection_a_obj), 7);
        assert!(nft_staking::is_collection_allowed(collection_b_obj), 8);
        
        // Remove second collection
        nft_staking::remove_allowed_collection(&creator, collection_b_obj);
        assert!(!nft_staking::is_collection_allowed(collection_a_obj), 9);
        assert!(!nft_staking::is_collection_allowed(collection_b_obj), 10);
        
        // Test get_allowed_collections function
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 0, 11);
        
        // Add collections back and test get_allowed_collections
        nft_staking::add_allowed_collection(&creator, collection_a_obj);
        nft_staking::add_allowed_collection(&creator, collection_b_obj);
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 2, 12);
        assert!(vector::contains(&allowed_collections, &collection_a_addr), 13);
        assert!(vector::contains(&allowed_collections, &collection_b_addr), 14);
    }

    #[test(creator = @0xa11ce, receiver = @0xb0b, token_staking = @movement_staking)]
    fun test_staking_pools_view_functions(
        creator: signer,
        receiver: signer,
        token_staking: signer,
    ) {
        let creator_addr = signer::address_of(&creator);
        let receiver_addr = signer::address_of(&receiver);
        
        // Create accounts
        aptos_framework::account::create_account_for_test(creator_addr);
        aptos_framework::account::create_account_for_test(receiver_addr);
        
        // Initialize global registries for testing with creator as admin
        nft_staking::test_init_registries_with_admin(&token_staking, creator_addr);
        
        // Initialize FA module
        banana_a::test_init(&token_staking);
        let metadata = banana_a::get_metadata();
        banana_a::mint(&token_staking, creator_addr, 1000);
        
        // Test initial state - no staking pools
        let initial_active_pools = nft_staking::view_active_staking_pools();
        let initial_all_pools = nft_staking::view_all_staking_pools();
        assert!(vector::length(&initial_active_pools) == 0, 1);
        assert!(vector::length(&initial_all_pools) == 0, 2);
        
        // Create first collection and staking pool
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Test Collection A"),
            string::utf8(b"Test Collection A"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        let collection_a_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Test Collection A"));
        let collection_a_obj = object::address_to_object<Collection>(collection_a_addr);
        
        nft_staking::add_allowed_collection(&creator, collection_a_obj);
        nft_staking::create_staking(&creator, 20, collection_a_obj, 500, metadata, true);
        
        // Test after creating first pool
        let active_pools_after_first = nft_staking::view_active_staking_pools();
        let all_pools_after_first = nft_staking::view_all_staking_pools();
        assert!(vector::length(&active_pools_after_first) == 1, 3);
        assert!(vector::length(&all_pools_after_first) == 1, 4);
        
        // Verify first pool info exists (we can't access individual fields from tests)
        let _first_pool = vector::borrow(&active_pools_after_first, 0);
        
        // Create second collection and staking pool
        collection::create_unlimited_collection(
            &creator,
            string::utf8(b"Test Collection B"),
            string::utf8(b"Test Collection B"),
            option::none(),
            string::utf8(b"uri"),
        );
        
        let collection_b_addr = collection::create_collection_address(&creator_addr, &string::utf8(b"Test Collection B"));
        let collection_b_obj = object::address_to_object<Collection>(collection_b_addr);
        
        nft_staking::add_allowed_collection(&creator, collection_b_obj);
        nft_staking::create_staking(&creator, 15, collection_b_obj, 300, metadata, false);
        
        // Test after creating second pool
        let active_pools_after_second = nft_staking::view_active_staking_pools();
        let all_pools_after_second = nft_staking::view_all_staking_pools();
        assert!(vector::length(&active_pools_after_second) == 2, 5);
        assert!(vector::length(&all_pools_after_second) == 2, 6);
        
        // Stop the first staking pool
        nft_staking::creator_stop_staking(&creator, collection_a_obj);
        
        // Test after stopping first pool
        let active_pools_after_stop = nft_staking::view_active_staking_pools();
        let all_pools_after_stop = nft_staking::view_all_staking_pools();
        assert!(vector::length(&active_pools_after_stop) == 1, 7); // Only second pool active
        assert!(vector::length(&all_pools_after_stop) == 2, 8); // Both pools still exist
        
        // Re-enable the first pool using the proper function
        nft_staking::creator_resume_staking(&creator, collection_a_obj);
        
        // Test after re-enabling
        let active_pools_after_reenable = nft_staking::view_active_staking_pools();
        let all_pools_after_reenable = nft_staking::view_all_staking_pools();
        assert!(vector::length(&active_pools_after_reenable) == 2, 9); // Both active again
        assert!(vector::length(&all_pools_after_reenable) == 2, 10); // Still 2 total
        
        // Update DPR of second pool (test that it doesn't crash)
        nft_staking::update_dpr(&creator, 25, collection_b_obj);
        
        // Verify pools are still there after DPR update
        let updated_pools = nft_staking::view_active_staking_pools();
        assert!(vector::length(&updated_pools) == 2, 11);
    }
} 