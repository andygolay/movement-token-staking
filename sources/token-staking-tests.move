#[test_only]
module movement_staking::tokenstaking_tests {
    use std::signer;
    use std::string;
    use std::vector;
    use std::option;
    
    use aptos_framework::account;
    
    use aptos_token_objects::collection;
    
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
        
        // Test initial state - no collections allowed
        assert!(!nft_staking::is_collection_allowed(string::utf8(b"Allowed Collection")), 1);
        assert!(!nft_staking::is_collection_allowed(string::utf8(b"Disallowed Collection")), 2);
        
        // Add collection to allowed list
        nft_staking::add_allowed_collection(&creator, string::utf8(b"Allowed Collection"));
        assert!(nft_staking::is_collection_allowed(string::utf8(b"Allowed Collection")), 3);
        assert!(!nft_staking::is_collection_allowed(string::utf8(b"Disallowed Collection")), 4);
        
        // Test that only allowed collection can create staking
        nft_staking::create_staking(&creator, 10, string::utf8(b"Allowed Collection"), 500, metadata, false);
        
        // Remove collection from allowed list
        nft_staking::remove_allowed_collection(&creator, string::utf8(b"Allowed Collection"));
        assert!(!nft_staking::is_collection_allowed(string::utf8(b"Allowed Collection")), 5);
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
        
        // Try to create staking for disallowed collection - should fail
        nft_staking::create_staking(&creator, 10, string::utf8(b"Disallowed Collection"), 500, metadata, false);
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
        
        // Try to add collection as non-admin - should fail
        nft_staking::add_allowed_collection(&receiver, string::utf8(b"Test Collection"));
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
        
        // Add one collection
        nft_staking::add_allowed_collection(&creator, string::utf8(b"Collection A"));
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 1, 2);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection A")), 3);
        
        // Add multiple collections
        nft_staking::add_allowed_collection(&creator, string::utf8(b"Collection B"));
        nft_staking::add_allowed_collection(&creator, string::utf8(b"Collection C"));
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 3, 4);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection A")), 5);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection B")), 6);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection C")), 7);
        
        // Remove a collection
        nft_staking::remove_allowed_collection(&creator, string::utf8(b"Collection B"));
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 2, 8);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection A")), 9);
        assert!(!vector::contains(&allowed_collections, &string::utf8(b"Collection B")), 10);
        assert!(vector::contains(&allowed_collections, &string::utf8(b"Collection C")), 11);
        
        // Remove all collections
        nft_staking::remove_allowed_collection(&creator, string::utf8(b"Collection A"));
        nft_staking::remove_allowed_collection(&creator, string::utf8(b"Collection C"));
        let allowed_collections = nft_staking::get_allowed_collections();
        assert!(vector::length(&allowed_collections) == 0, 12);
    }
} 