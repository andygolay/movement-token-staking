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
const aptos_1 = require("aptos");
const NODE_URL = process.env.APTOS_NODE_URL || "https://full.testnet.movementinfra.xyz/v1";
const FAUCET_URL = process.env.APTOS_FAUCET_URL || "https://faucet.testnet.movementinfra.xyz";
const client = new aptos_1.AptosClient(NODE_URL);
const faucetClient = new aptos_1.FaucetClient(NODE_URL, FAUCET_URL);
// GraphQL indexer endpoint (Movement testnet)
const INDEXER_URL = "https://indexer.testnet.movementnetwork.xyz/v1/graphql";
function getNftObjectIdByIndexer(ownerHex, collectionName, tokenName) {
    var _a, _b;
    return __awaiter(this, void 0, void 0, function* () {
        const query = `
		query GetAccountNfts($address: String!) {
			current_token_ownerships_v2(
				where: { owner_address: { _eq: $address }, amount: { _gt: "0" }, token_standard: { _eq: "v2" } }
			) {
				token_object_id
				current_token_data {
					token_name
					current_collection { collection_name creator_address }
				}
			}
		}
	`;
        const res = yield fetch(INDEXER_URL, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ query, variables: { address: ownerHex } }),
        });
        const json = yield res.json();
        const list = (_b = (_a = json === null || json === void 0 ? void 0 : json.data) === null || _a === void 0 ? void 0 : _a.current_token_ownerships_v2) !== null && _b !== void 0 ? _b : [];
        const match = list.find((it) => { var _a, _b, _c; return ((_b = (_a = it === null || it === void 0 ? void 0 : it.current_token_data) === null || _a === void 0 ? void 0 : _a.current_collection) === null || _b === void 0 ? void 0 : _b.collection_name) === collectionName && ((_c = it === null || it === void 0 ? void 0 : it.current_token_data) === null || _c === void 0 ? void 0 : _c.token_name) === tokenName; });
        if (!(match === null || match === void 0 ? void 0 : match.token_object_id)) {
            throw new Error("NFT object not found in indexer for owner; ensure mint completed and indexer is correct network");
        }
        return match.token_object_id;
    });
}
// Deployed package ID (module address)
const pid = "0xc2525f0bfcdfa2580d5e306698aab47c4fa952f21427063bc51754b7068a6b80";
// Accounts
const account1 = new aptos_1.AptosAccount(new Uint8Array(Buffer.from("218d8906d9afac435c683b12a19fbb14a082460fa86c05554108069c1c173d19", "hex"))); // creator
console.log("account1", account1.address());
const account2 = new aptos_1.AptosAccount(); // staker
console.log("account2", account2.address());
// NFT metadata
const collection = "Whale Collection";
const tokenname = "Whale Token #2";
const description = "Whale Token for DA test";
const uri = "https://cdn.pixabay.com/photo/2025/05/24/12/40/whale-9619752_1280.png";
// Placeholders you must fill using your FA / DA creation flows or indexer:
// - REWARD_METADATA_OBJECT_ADDRESS: Object<fungible_asset::Metadata> for the reward coin
// - NFT_OBJECT_ADDRESS: Object<aptos_token_objects::token::Token> for the NFT to stake (owner must be account2)
const REWARD_METADATA_OBJECT_ADDRESS = "0xa";
// This will be updated after the NFT is transferred to account2
let NFT_OBJECT_ADDRESS = "0xNFT_OBJECT"; // Will be updated dynamically
function main() {
    return __awaiter(this, void 0, void 0, function* () {
        console.log("Funding accounts...");
        yield faucetClient.fundAccount(account1.address(), 1000000000);
        yield faucetClient.fundAccount(account2.address(), 1000000000);
        // Example: Create a DA collection using aptos_token_objects::aptos_token (0x4)
        // This is optional if you already have a collection.
        console.log("Creating DA collection (0x4::aptos_token::create_collection)...");
        const createCollection = {
            type: "entry_function_payload",
            function: "0x4::aptos_token::create_collection",
            type_arguments: [],
            // description, max_supply, name, uri, mutability flags..., royalty_numerator, royalty_denominator
            arguments: [
                description,
                1000,
                collection,
                uri,
                true,
                true,
                true,
                true,
                true,
                true,
                true,
                true,
                true,
                0,
                1 // royalty_denominator
            ],
        };
        let tx = yield client.generateTransaction(account1.address(), createCollection);
        let bcs = aptos_1.AptosClient.generateBCSTransaction(account1, tx);
        const createCollectionTx = yield client.submitSignedBCSTransaction(bcs);
        console.log("Create collection transaction result:", createCollectionTx.hash);
        // Wait for transaction to be confirmed by polling
        console.log("Waiting for collection creation to be confirmed...");
        let confirmed = false;
        yield new Promise(resolve => setTimeout(resolve, 800));
        while (!confirmed) {
            try {
                const txInfo = yield client.getTransactionByHash(createCollectionTx.hash);
                if (txInfo.type === "user_transaction") {
                    // Check if transaction actually succeeded
                    const txData = txInfo;
                    if (txData.success && txData.vm_status === "Executed successfully") {
                        confirmed = true;
                        console.log("Collection creation confirmed and successful!");
                    }
                    else {
                        console.log("Collection creation failed:", txData.vm_status);
                        throw new Error(`Collection creation failed: ${txData.vm_status}`);
                    }
                }
                else {
                    console.log("Transaction not yet confirmed, waiting...");
                    yield new Promise(resolve => setTimeout(resolve, 1000));
                }
            }
            catch (e) {
                console.log("Transaction not yet confirmed, waiting...");
                yield new Promise(resolve => setTimeout(resolve, 1000));
            }
        }
        console.log("Proceeding to mint...");
        // Example: Mint a DA token to creator (0x4::aptos_token::mint)
        // Note: You'll need to transfer it to account2 (staker) later via 0x1::object::transfer
        console.log("Minting DA token (0x4::aptos_token::mint)...");
        const mintToken = {
            type: "entry_function_payload",
            function: "0x4::aptos_token::mint",
            type_arguments: [],
            arguments: [
                collection,
                description,
                tokenname,
                uri,
                [],
                [],
                [] // property_values: vector<vector<u8>>
            ],
        };
        tx = yield client.generateTransaction(account1.address(), mintToken);
        bcs = aptos_1.AptosClient.generateBCSTransaction(account1, tx);
        console.log("Generated BCS transaction");
        const mintTx = yield client.submitSignedBCSTransaction(bcs);
        console.log("Mint transaction result:", mintTx.hash);
        // Wait for mint transaction to be confirmed before proceeding
        console.log("Waiting for mint transaction to be confirmed...");
        let mintConfirmed = false;
        yield new Promise(resolve => setTimeout(resolve, 800));
        while (!mintConfirmed) {
            try {
                const mintTxInfo = yield client.getTransactionByHash(mintTx.hash);
                if (mintTxInfo.type === "user_transaction") {
                    // Check if transaction actually succeeded
                    const txInfo = mintTxInfo; // Type assertion to access properties
                    if (txInfo.success && txInfo.vm_status === "Executed successfully") {
                        mintConfirmed = true;
                        console.log("Mint transaction confirmed and successful!");
                    }
                    else {
                        console.log("Mint transaction failed:", txInfo.vm_status);
                        throw new Error(`Mint transaction failed: ${txInfo.vm_status}`);
                    }
                }
                else {
                    console.log("Mint transaction not yet confirmed, waiting...");
                    yield new Promise(resolve => setTimeout(resolve, 1000));
                }
            }
            catch (e) {
                console.log("Mint transaction error:", e);
                yield new Promise(resolve => setTimeout(resolve, 800));
            }
        }
        // Transfer the minted NFT from account1 to account2 so account2 can stake it
        console.log("Transferring NFT from account1 to account2...");
        // Get the actual NFT object address using the GraphQL indexer
        console.log("Getting actual NFT object address from GraphQL indexer...");
        let nftObjectAddress = yield getNftObjectIdByIndexer(account1.address().hex(), collection, tokenname);
        console.log("NFT object address:", nftObjectAddress);
        const transferNft = {
            type: "entry_function_payload",
            function: "0x1::object::transfer",
            type_arguments: ["0x4::aptos_token_objects::token::Token"],
            arguments: [nftObjectAddress, account2.address().hex()],
        };
        console.log("Transfer NFT payload:", JSON.stringify(transferNft, null, 2));
        tx = yield client.generateTransaction(account1.address(), transferNft);
        bcs = aptos_1.AptosClient.generateBCSTransaction(account1, tx);
        const transferTx = yield client.submitSignedBCSTransaction(bcs);
        console.log("Transfer transaction result:", transferTx.hash);
        // Wait for transfer transaction to be confirmed
        console.log("Waiting for transfer transaction to be confirmed...");
        let transferConfirmed = false;
        yield new Promise(resolve => setTimeout(resolve, 800));
        while (!transferConfirmed) {
            try {
                const transferTxInfo = yield client.getTransactionByHash(transferTx.hash);
                if (transferTxInfo.type === "user_transaction") {
                    const txData = transferTxInfo;
                    if (txData.success && txData.vm_status === "Executed successfully") {
                        transferConfirmed = true;
                        console.log("Transfer transaction confirmed and successful!");
                    }
                    else {
                        console.log("Transfer transaction failed:", txData.vm_status);
                        throw new Error(`Transfer transaction failed: ${txData.vm_status}`);
                    }
                }
                else {
                    console.log("Transfer transaction not yet confirmed, waiting...");
                    yield new Promise(resolve => setTimeout(resolve, 1000));
                }
            }
            catch (e) {
                console.log("Transfer transaction error:", e);
                yield new Promise(resolve => setTimeout(resolve, 800));
            }
        }
        console.log("Proceeding to create staking...");
        // Update the NFT_OBJECT_ADDRESS with the actual transferred NFT address
        NFT_OBJECT_ADDRESS = nftObjectAddress;
        console.log("Updated NFT_OBJECT_ADDRESS:", NFT_OBJECT_ADDRESS);
        // Create staking (new signature: dpr, collection, total_amount, metadata)
        console.log("Creating staking...");
        const createStaking = {
            type: "entry_function_payload",
            function: `${pid}::tokenstaking::create_staking`,
            type_arguments: [],
            arguments: [
                86400,
                collection,
                1000000,
                REWARD_METADATA_OBJECT_ADDRESS, // FA metadata object address
            ],
        };
        console.log("Create staking payload:", JSON.stringify(createStaking, null, 2));
        console.log("Function path:", createStaking.function);
        console.log("Package ID:", pid);
        tx = yield client.generateTransaction(account1.address(), createStaking);
        bcs = aptos_1.AptosClient.generateBCSTransaction(account1, tx);
        const createStakingTx = yield client.submitSignedBCSTransaction(bcs);
        console.log("Create staking transaction result:", createStakingTx.hash);
        // Wait for create staking transaction to be confirmed before proceeding
        console.log("Waiting for create staking transaction to be confirmed...");
        let stakingConfirmed = false;
        yield new Promise(resolve => setTimeout(resolve, 800));
        while (!stakingConfirmed) {
            try {
                const stakingTxInfo = yield client.getTransactionByHash(createStakingTx.hash);
                if (stakingTxInfo.type === "user_transaction") {
                    // Check if transaction actually succeeded
                    const txData = stakingTxInfo;
                    if (txData.success && txData.vm_status === "Executed successfully") {
                        stakingConfirmed = true;
                        console.log("Create staking transaction confirmed and successful!");
                    }
                    else {
                        console.log("Create staking transaction failed:", txData.vm_status);
                        throw new Error(`Create staking transaction failed: ${txData.vm_status}`);
                    }
                }
                else {
                    console.log("Create staking transaction not yet confirmed, waiting...");
                    yield new Promise(resolve => setTimeout(resolve, 1000));
                }
            }
            catch (e) {
                console.log("Create staking transaction not yet confirmed, waiting...");
                yield new Promise(resolve => setTimeout(resolve, 800));
            }
        }
        console.log("Proceeding to stake token...");
        // Stake token (new signature: nft Object<Token>)
        console.log("Staking NFT...");
        const stake = {
            type: "entry_function_payload",
            function: `${pid}::tokenstaking::stake_token`,
            type_arguments: [],
            arguments: [NFT_OBJECT_ADDRESS],
        };
        tx = yield client.generateTransaction(account2.address(), stake);
        bcs = aptos_1.AptosClient.generateBCSTransaction(account2, tx);
        yield client.submitSignedBCSTransaction(bcs);
        // Claim reward (collection, token_name, creator)
        console.log("Claiming rewards...");
        const claim = {
            type: "entry_function_payload",
            function: `${pid}::tokenstaking::claim_reward`,
            type_arguments: [],
            arguments: [collection, tokenname, account1.address().hex()],
        };
        tx = yield client.generateTransaction(account2.address(), claim);
        bcs = aptos_1.AptosClient.generateBCSTransaction(account2, tx);
        yield client.submitSignedBCSTransaction(bcs);
        // Unstake token (creator, collection, token_name)
        console.log("Unstaking NFT...");
        const unstake = {
            type: "entry_function_payload",
            function: `${pid}::tokenstaking::unstake_token`,
            type_arguments: [],
            arguments: [account1.address().hex(), collection, tokenname],
        };
        tx = yield client.generateTransaction(account2.address(), unstake);
        bcs = aptos_1.AptosClient.generateBCSTransaction(account2, tx);
        yield client.submitSignedBCSTransaction(bcs);
        console.log("Done");
    });
}
main().catch((e) => {
    console.error(e);
    process.exit(1);
});
//# sourceMappingURL=staking.js.map