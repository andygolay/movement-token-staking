module movement_staking::freeze_registry {
    use aptos_framework::fungible_asset;
    use aptos_framework::object::{Self, Object};
    
    // Import all FA modules that support freezing
    use movement_staking::banana_a;
    use movement_staking::banana_b;
    // Add new FAs here as needed
    
    /// Freezes a user's account for a specific FA metadata
    /// This function handles all FA-specific freezing logic
    /// When adding new FAs with freezing capability, just add them here
    public fun freeze_user_account(user: &signer, metadata: Object<fungible_asset::Metadata>) {
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
        // Add more FAs here as needed:
        // if (metadata_addr == object::object_address(&new_fa::get_metadata())) {
        //     new_fa::freeze_user(user);
        //     return
        // };
    }
} 