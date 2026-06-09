//! Two-sided PoC driving the modernized Anchor program through the REAL solana-runtime
//! SVM (solana-program-test). Lesson 1, account-data-matching.
//!
//! The handler `log_message` takes accounts `[token, authority]`, unpacks the SPL token
//! account from `token`, and logs `token.amount`. The vulnerability: it never checks the
//! token account belongs to `authority` (no `authority.key == token.owner`). The fix
//! asserts that equality.
//!
//! CONTROL: a real SPL token account (owner = spl_token::ID) whose SPL `owner` field equals
//! the signed authority -> must be accepted by both variants.
//!
//! EXPLOIT: a real SPL token account (owner = spl_token::ID) whose SPL `owner` field is a
//! DIFFERENT key (not the authority). The INSECURE handler still reads it (the
//! account-data-matching invariant is violated) -> `INVARIANT VIOLATED:` + exit(101).
//! The SECURE handler rejects it -> `invariant held`.
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

/// Build the on-chain bytes of an initialized SPL token account whose stored `owner`
/// field is `token_owner`, holding `amount` tokens of `mint`.
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

    // CONTROL token: a real SPL token account whose SPL `owner` field == the authority.
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

    // EXPLOIT token: a real SPL token account (still owned by the SPL Token program) whose
    // SPL `owner` field is some OTHER key, not the signing authority.
    let other_owner = Pubkey::new_unique();
    let token_exploit = Pubkey::new_unique();
    pt.add_account(
        token_exploit,
        Account {
            lamports: 1_000_000,
            data: spl_token_account_data(mint, other_owner, 4242),
            owner: spl_token::ID,
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

    // CONTROL: token account whose SPL owner == the signed authority -> must be accepted.
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
        println!("CONTROL OK: token account owned by the signing authority accepted");
    } else {
        println!("control anomaly: legitimately-owned token account rejected ({:?})", ctrl);
    }

    // EXPLOIT: token account whose SPL owner is a DIFFERENT key than the signing authority.
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
            "INVARIANT VIOLATED: read a token account not owned by the authority (account-data-matching)"
        );
        std::process::exit(101);
    } else {
        println!("invariant held: token account not owned by the authority rejected ({:?})", exp);
    }
}
