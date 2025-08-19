
import { AptosAccount, AptosClient, FaucetClient, Types } from "aptos";

const NODE_URL = process.env.APTOS_NODE_URL || "https://full.testnet.movementinfra.xyz/v1";
const FAUCET_URL = process.env.APTOS_FAUCET_URL || "https://faucet.testnet.movementinfra.xyz";

const client = new AptosClient(NODE_URL);
const faucetClient = new FaucetClient(NODE_URL, FAUCET_URL);

// Deployed package ID (module address)
const pid = "6f09ba2b5a6d2e2990a92485cc81198d9392e6849494a580360ecd4b2c73307b";

// Accounts
const account1 = new AptosAccount(); // creator
console.log("account1", account1.address());

const account2 = new AptosAccount(); // staker
console.log("account2", account2.address());

// NFT metadata
const collection = "Movement Collection";
const tokenname = "Movement Token #1";
const description = "Movement Token for DA test";
const uri = "https://github.com/movementprotocol";

// Placeholders you must fill using your FA / DA creation flows or indexer:
// - REWARD_METADATA_OBJECT_ADDRESS: Object<fungible_asset::Metadata> for the reward coin
// - NFT_OBJECT_ADDRESS: Object<aptos_token_objects::token::Token> for the NFT to stake (owner must be account2)
const REWARD_METADATA_OBJECT_ADDRESS = "0xREWARD_METADATA_OBJECT"; // TODO
const NFT_OBJECT_ADDRESS = "0xNFT_OBJECT"; // TODO

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
  await client.submitSignedBCSTransaction(bcs);

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
  await client.submitSignedBCSTransaction(bcs);

  // TODO: Derive or fetch the NFT_OBJECT_ADDRESS of the minted token
  // Recommended: use an indexer query to find the object address for (account1, collection, tokenname),
  // then transfer it to account2 so account2 can stake it:
  // const transferNft: Types.TransactionPayload = {
  //   type: "entry_function_payload",
  //   function: "0x1::object::transfer",
  //   type_arguments: ["0x4::token::Token"],
  //   arguments: [NFT_OBJECT_ADDRESS, account2.address().hex()],
  // };
  // await submit(account1, transferNft)

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
  tx = await client.generateTransaction(account1.address(), createStaking);
  bcs = AptosClient.generateBCSTransaction(account1, tx);
  await client.submitSignedBCSTransaction(bcs);

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
