module woosh4::woosh4 {
    use aptos_framework::event;
    use std::error;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::table::{Self, Table};
    use aptos_framework::aptos_coin::AptosCoin;
    use std::signer;

    //// ERROR CODES
    /// Contract initialization error , Vault does not exist
    const VAULT_DOESNT_EXIST: u64 = 1;
    /// Vault is empty
    const INSUFFICIENT_VAULT_BALANCE: u64 = 2;
    /// User trying to unstake more than what staked or unstake amount is zero
    const INVALID_UNSTAKE_AMOUNT: u64 = 3;
    /// User is trying to stake 0 amount
    const INVALID_STAKE_AMOUNT: u64 = 4;
    /// User is trying to unstake while don't have unstake record
    const USER_HAS_NO_STAKE_RECORD: u64 = 5;
    /// User is trying to transfer low amount
    const TRANSFER_AMOUNT_IS_VERY_LOW: u64 = 6;
    /// Signer must be the Vault owner
    const SIGNER_IS_NOT_VAULT_OWNER: u64 = 7;

    //COSTANTS
    const MINIMUM_TRANSFER_AMOUNT: u64 = 50000;

    const MINIMUM_SERVICE_FEE: u64 = 5000;

    const SERVICE_FEE_DIVIDED_BY_10000: u64 = 10;

    // Resource to store the user's deposited coins
    struct Vault has key {
        balance: Coin<AptosCoin>,
        staked_by_users: Table<address, u64>,
        total_staked: u64
    }

    #[event]
    struct BridgeMessage has drop, store {
        source_account: address,
        source_amount: u64,
        dest_account: vector<u8>,
        dest_chain: u16
    }

    // The module initializer
    public entry fun init_module_entry(account: signer) {
        init_module(&account);
    }

    // Automatically initialize the vault when the module is published
    fun init_module(account: &signer) {
        if (!exists<Vault>(signer::address_of(account))) {
            initialize_vault(account);
        }
    }

    // Initialize the Vault for the user
    public fun initialize_vault(vault_owner: &signer) {
        let vault = Vault {
            balance: coin::zero<AptosCoin>(),
            staked_by_users: table::new<address, u64>(),
            total_staked: 0
        };

        move_to(vault_owner, vault);
    }

    // Stake function - user deposits APT tokens into the Vault
    entry fun stake(user_account: &signer, amount: u64) acquires Vault {
        assert!(amount > 0, error::invalid_argument(INVALID_STAKE_AMOUNT)); // Invalid stake amount

        let vault = borrow_global_mut<Vault>(@woosh4);
        let deposit_coins =
            aptos_framework::coin::withdraw<AptosCoin>(user_account, amount);
        aptos_framework::coin::merge(&mut vault.balance, deposit_coins);

        vault.total_staked = vault.total_staked + amount;

        let user_addr = signer::address_of(user_account);

        if (table::contains(&vault.staked_by_users, user_addr)) {
            let user_staked_amount =
                table::borrow_mut(&mut vault.staked_by_users, user_addr);
            *user_staked_amount = *user_staked_amount + amount;
        } else {
            table::add(&mut vault.staked_by_users, user_addr, amount);
        }
    }

    // Unstake function - user withdraws APT tokens from the Vault
    entry fun unstake(user_account: &signer, amount: u64) acquires Vault {
        assert!(amount > 0, error::invalid_argument(INVALID_UNSTAKE_AMOUNT)); // Invalid unstake amount
        assert!(
            exists<Vault>(@woosh4),
            error::not_found(VAULT_DOESNT_EXIST)
        ); // Vault must exist

        let vault = borrow_global_mut<Vault>(@woosh4);
        // Ensure that user has staked before
        assert!(
            table::contains(&vault.staked_by_users, signer::address_of(user_account)),
            USER_HAS_NO_STAKE_RECORD
        );

        let user_addr = signer::address_of(user_account);
        let user_staked_amount = table::borrow_mut(&mut vault.staked_by_users, user_addr);
        assert!(
            amount <= *user_staked_amount, error::invalid_argument(INVALID_UNSTAKE_AMOUNT)
        ); // User requested more than staked
        *user_staked_amount = *user_staked_amount - amount;

        // Ensure that there are enough coins in the Vault
        assert!(
            aptos_framework::coin::value(&vault.balance) >= amount,
            error::invalid_argument(INSUFFICIENT_VAULT_BALANCE)
        ); // Error if insufficient funds

        let withdraw_coins = aptos_framework::coin::extract(&mut vault.balance, amount);
        aptos_framework::coin::deposit<AptosCoin>(
            signer::address_of(user_account), withdraw_coins
        );

        vault.total_staked = vault.total_staked - amount;
    }

    #[view]
    public fun get_users_staked_amount(user_addr: address): u64 acquires Vault {
        assert!(exists<Vault>(@woosh4), error::not_found(VAULT_DOESNT_EXIST)); // Vault must exist
        let vault = borrow_global<Vault>(@woosh4);
        assert!(
            table::contains(&vault.staked_by_users, user_addr),
            USER_HAS_NO_STAKE_RECORD
        );
        let user_staked_amount = table::borrow(&vault.staked_by_users, user_addr);
        return *user_staked_amount
    }

    #[view]
    public fun get_vault_balance(): u64 acquires Vault {
        assert!(exists<Vault>(@woosh4), error::not_found(VAULT_DOESNT_EXIST)); // Vault must exist
        let vault = borrow_global<Vault>(@woosh4);
        let balance = aptos_framework::coin::value(&vault.balance);
        balance
    }

    entry fun transfer_to_chain(
        user_account: &signer,
        source_amount: u64,
        dest_account: vector<u8>,
        dest_chain: u16
    ) acquires Vault {
        assert!(
            source_amount > MINIMUM_TRANSFER_AMOUNT,
            error::invalid_argument(TRANSFER_AMOUNT_IS_VERY_LOW)
        ); // Invalid stake amount

        let service_fee = source_amount / SERVICE_FEE_DIVIDED_BY_10000;
        if (service_fee < MINIMUM_SERVICE_FEE) {
            service_fee = MINIMUM_SERVICE_FEE;
        };

        let vault = borrow_global_mut<Vault>(@woosh4);
        let deposit_coins =
            aptos_framework::coin::withdraw<AptosCoin>(
                user_account, source_amount + service_fee
            );
        aptos_framework::coin::merge(&mut vault.balance, deposit_coins);

        event::emit(
            BridgeMessage {
                source_account: signer::address_of(user_account),
                source_amount,
                dest_account,
                dest_chain
            }
        );
    }

    entry fun vault_withdrawal(
        vault_owner: &signer, user_addr: address, amount: u64
    ) acquires Vault {
        assert!(
            exists<Vault>(@woosh4),
            error::not_found(VAULT_DOESNT_EXIST)
        ); // Vault must exist
        assert!(signer::address_of(vault_owner) == @woosh4, error::invalid_argument(SIGNER_IS_NOT_VAULT_OWNER));

        let vault = borrow_global_mut<Vault>(@woosh4);

        // Ensure that there are enough coins in the Vault
        assert!(
            aptos_framework::coin::value(&vault.balance) >= amount,
            error::invalid_argument(INSUFFICIENT_VAULT_BALANCE)
        ); // Error if insufficient funds

        let withdraw_coins = aptos_framework::coin::extract(&mut vault.balance, amount);
        aptos_framework::coin::deposit<AptosCoin>(user_addr, withdraw_coins);
    }

    // Tests
    #[test_only]
    use aptos_framework::account::create_account_for_test;        

    #[test(user_account = @woosh4)]
    fun test_stake(user_account: &signer) acquires Vault {
        let account_addr = signer::address_of(user_account);
        account::create_account_for_test(account_addr);
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize_and_register_fake_money(user_account, 1, true);

        stake(user_account, 500);
    }
}
