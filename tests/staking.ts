
import { AptosAccount, AptosClient, FaucetClient, Types } from "aptos";

const NODE_URL = process.env.APTOS_NODE_URL || "https://full.testnet.movementinfra.xyz/v1";
const FAUCET_URL = process.env.APTOS_FAUCET_URL || "https://faucet.testnet.movementinfra.xyz";

const client = new AptosClient(NODE_URL);
const faucetClient = new FaucetClient(NODE_URL, FAUCET_URL);

// GraphQL indexer endpoint (Movement testnet)
const INDEXER_URL = "https://indexer.testnet.movementnetwork.xyz/v1/graphql";

async function getNftObjectIdByIndexer(ownerHex: string, collectionName: string, tokenName: string): Promise<string> {

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
  const res = await fetch(INDEXER_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables: { address: ownerHex } }),
  });
  const json = await res.json();
  const list = json?.data?.current_token_ownerships_v2 ?? [];
  const match = list.find((it: any) => it?.current_token_data?.current_collection?.collection_name === collectionName && it?.current_token_data?.token_name === tokenName);
  if (!match?.token_object_id) {
    throw new Error("NFT object not found in indexer for owner; ensure mint completed and indexer is correct network");
  }
  return match.token_object_id as string;
}

// Deployed package ID (module address)
const pid = "0xc2525f0bfcdfa2580d5e306698aab47c4fa952f21427063bc51754b7068a6b80";

// Accounts
const account1 = new AptosAccount(); // creator
console.log("account1", account1.address());

const account2 = new AptosAccount(); // staker
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

async function main() {
  console.log("Funding accounts...");
  await faucetClient.fundAccount(account1.address(), 1_000_000_000);
  await faucetClient.fundAccount(account2.address(), 1_000_000_000);

  // Example: Create a DA collection using aptos_token_objects::aptos_token (0x4)
  // This is optional if you already have a collection.
  console.log("Creating DA collection (0x4::aptos_token::create_collection)...");
  const createCollection: Types.TransactionPayload = {
    type: "entry_function_payload",
    function: "0x4::aptos_token::create_collection",
    type_arguments: [],
    // description, max_supply, name, uri, mutability flags..., royalty_numerator, royalty_denominator
    arguments: [
      description,
      1000, // max_supply
      collection,
      uri,
      true,  // mutable_description
      true,  // mutable_royalty
      true,  // mutable_uri
      true,  // mutable_token_description
      true,  // mutable_token_name
      true,  // mutable_token_properties
      true,  // mutable_token_uri
      true,  // tokens_burnable_by_creator
      true,  // tokens_freezable_by_creator
      0,     // royalty_numerator
      1      // royalty_denominator
    ],
  };
  let tx = await client.generateTransaction(account1.address(), createCollection);
  let bcs = AptosClient.generateBCSTransaction(account1, tx);
  const createCollectionTx = await client.submitSignedBCSTransaction(bcs);
  console.log("Create collection transaction result:", createCollectionTx.hash);

  // Wait for transaction to be confirmed by polling
  console.log("Waiting for collection creation to be confirmed...");
  let confirmed = false;
  await new Promise(resolve => setTimeout(resolve, 800));
  while (!confirmed) {
    try {
      const txInfo = await client.getTransactionByHash(createCollectionTx.hash);
      if (txInfo.type === "user_transaction") {
        // Check if transaction actually succeeded
        const txData = txInfo as any;
        if (txData.success && txData.vm_status === "Executed successfully") {
          confirmed = true;
          console.log("Collection creation confirmed and successful!");
        } else {
          console.log("Collection creation failed:", txData.vm_status);
          throw new Error(`Collection creation failed: ${txData.vm_status}`);
        }
      } else {
        console.log("Transaction not yet confirmed, waiting...");
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    } catch (e) {
      console.log("Transaction not yet confirmed, waiting...");
      await new Promise(resolve => setTimeout(resolve, 1000));
    }
  }
  console.log("Proceeding to mint...");

  // Example: Mint a DA token to creator (0x4::aptos_token::mint)
  // Note: You'll need to transfer it to account2 (staker) later via 0x1::object::transfer
  console.log("Minting DA token (0x4::aptos_token::mint)...");
  const mintToken: Types.TransactionPayload = {
    type: "entry_function_payload",
    function: "0x4::aptos_token::mint",
    type_arguments: [],
    arguments: [
      collection,
      description,
      tokenname,
      uri,
      [],      // property_keys: vector<String>
      [],      // property_types: vector<String>
      []       // property_values: vector<vector<u8>>
    ],
  };
  tx = await client.generateTransaction(account1.address(), mintToken);
  bcs = AptosClient.generateBCSTransaction(account1, tx);
  console.log("Generated BCS transaction");
  const mintTx = await client.submitSignedBCSTransaction(bcs);
  console.log("Mint transaction result:", mintTx.hash);

  // Wait for mint transaction to be confirmed before proceeding
  console.log("Waiting for mint transaction to be confirmed...");
  let mintConfirmed = false;
  await new Promise(resolve => setTimeout(resolve, 800));
  while (!mintConfirmed) {
    try {
      const mintTxInfo = await client.getTransactionByHash(mintTx.hash);
      if (mintTxInfo.type === "user_transaction") {
        // Check if transaction actually succeeded
        const txInfo = mintTxInfo as any; // Type assertion to access properties
        if (txInfo.success && txInfo.vm_status === "Executed successfully") {
          mintConfirmed = true;
          console.log("Mint transaction confirmed and successful!");
        } else {
          console.log("Mint transaction failed:", txInfo.vm_status);
          throw new Error(`Mint transaction failed: ${txInfo.vm_status}`);
        }
      } else {
        console.log("Mint transaction not yet confirmed, waiting...");
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    } catch (e) {
      console.log("Mint transaction error:", e);
      await new Promise(resolve => setTimeout(resolve, 800));
    }
  }

  // Transfer the minted NFT from account1 to account2 so account2 can stake it
  console.log("Transferring NFT from account1 to account2...");

  // Get the actual NFT object address using the GraphQL indexer
  console.log("Getting actual NFT object address from GraphQL indexer...");
  let nftObjectAddress = await getNftObjectIdByIndexer(account1.address().hex(), collection, tokenname);
  console.log("NFT object address:", nftObjectAddress);

  const transferNft: Types.TransactionPayload = {
    type: "entry_function_payload",
    function: "0x1::object::transfer",
    type_arguments: ["0x4::aptos_token_objects::token::Token"],
    arguments: [nftObjectAddress, account2.address().hex()],
  };

  console.log("Transfer NFT payload:", JSON.stringify(transferNft, null, 2));
  tx = await client.generateTransaction(account1.address(), transferNft);
  bcs = AptosClient.generateBCSTransaction(account1, tx);
  const transferTx = await client.submitSignedBCSTransaction(bcs);
  console.log("Transfer transaction result:", transferTx.hash);

  // Wait for transfer transaction to be confirmed
  console.log("Waiting for transfer transaction to be confirmed...");
  let transferConfirmed = false;
  await new Promise(resolve => setTimeout(resolve, 800));
  while (!transferConfirmed) {
    try {
      const transferTxInfo = await client.getTransactionByHash(transferTx.hash);
      if (transferTxInfo.type === "user_transaction") {
        const txData = transferTxInfo as any;
        if (txData.success && txData.vm_status === "Executed successfully") {
          transferConfirmed = true;
          console.log("Transfer transaction confirmed and successful!");
        } else {
          console.log("Transfer transaction failed:", txData.vm_status);
          throw new Error(`Transfer transaction failed: ${txData.vm_status}`);
        }
      } else {
        console.log("Transfer transaction not yet confirmed, waiting...");
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    } catch (e) {
      console.log("Transfer transaction error:", e);
      await new Promise(resolve => setTimeout(resolve, 800));
    }
  }
  console.log("Proceeding to create staking...");

  // Update the NFT_OBJECT_ADDRESS with the actual transferred NFT address
  NFT_OBJECT_ADDRESS = nftObjectAddress;
  console.log("Updated NFT_OBJECT_ADDRESS:", NFT_OBJECT_ADDRESS);

  // Create staking (new signature: dpr, collection, total_amount, metadata)
  console.log("Creating staking...");
  const createStaking: Types.TransactionPayload = {
    type: "entry_function_payload",
    function: `${pid}::tokenstaking::create_staking`,
    type_arguments: [],
    arguments: [
      86400,                 // dpr
      collection,            // collection name
      1_000_000,             // initial FA funding (u64)
      REWARD_METADATA_OBJECT_ADDRESS, // FA metadata object address
    ],
  };
  console.log("Create staking payload:", JSON.stringify(createStaking, null, 2));
  console.log("Function path:", createStaking.function);
  console.log("Package ID:", pid);
  tx = await client.generateTransaction(account1.address(), createStaking);
  bcs = AptosClient.generateBCSTransaction(account1, tx);
  const createStakingTx = await client.submitSignedBCSTransaction(bcs);
  console.log("Create staking transaction result:", createStakingTx.hash);

  // Wait for create staking transaction to be confirmed before proceeding
  console.log("Waiting for create staking transaction to be confirmed...");
  let stakingConfirmed = false;
  await new Promise(resolve => setTimeout(resolve, 800));
  while (!stakingConfirmed) {
    try {
      const stakingTxInfo = await client.getTransactionByHash(createStakingTx.hash);
      if (stakingTxInfo.type === "user_transaction") {
        // Check if transaction actually succeeded
        const txData = stakingTxInfo as any;
        if (txData.success && txData.vm_status === "Executed successfully") {
          stakingConfirmed = true;
          console.log("Create staking transaction confirmed and successful!");
        } else {
          console.log("Create staking transaction failed:", txData.vm_status);
          throw new Error(`Create staking transaction failed: ${txData.vm_status}`);
        }
      } else {
        console.log("Create staking transaction not yet confirmed, waiting...");
        await new Promise(resolve => setTimeout(resolve, 1000));
      }
    } catch (e) {
      console.log("Create staking transaction not yet confirmed, waiting...");
      await new Promise(resolve => setTimeout(resolve, 800));
    }
  }
  console.log("Proceeding to stake token...");

  // Stake token (new signature: nft Object<Token>)
  console.log("Staking NFT...");
  const stake: Types.TransactionPayload = {
    type: "entry_function_payload",
    function: `${pid}::tokenstaking::stake_token`,
    type_arguments: [],
    arguments: [NFT_OBJECT_ADDRESS],
  };
  tx = await client.generateTransaction(account2.address(), stake);
  bcs = AptosClient.generateBCSTransaction(account2, tx);
  await client.submitSignedBCSTransaction(bcs);

  // Claim reward (collection, token_name, creator)
  console.log("Claiming rewards...");
  const claim: Types.TransactionPayload = {
    type: "entry_function_payload",
    function: `${pid}::tokenstaking::claim_reward`,
    type_arguments: [],
    arguments: [collection, tokenname, account1.address().hex()],
  };
  tx = await client.generateTransaction(account2.address(), claim);
  bcs = AptosClient.generateBCSTransaction(account2, tx);
  await client.submitSignedBCSTransaction(bcs);

  // Unstake token (creator, collection, token_name)
  console.log("Unstaking NFT...");
  const unstake: Types.TransactionPayload = {
    type: "entry_function_payload",
    function: `${pid}::tokenstaking::unstake_token`,
    type_arguments: [],
    arguments: [account1.address().hex(), collection, tokenname],
  };
  tx = await client.generateTransaction(account2.address(), unstake);
  bcs = AptosClient.generateBCSTransaction(account2, tx);
  await client.submitSignedBCSTransaction(bcs);

  console.log("Done");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
