//! Two-sided PoC driving the modernized Anchor program through the REAL solana-runtime
//! SVM (solana-program-test). CONTROL: the authority signs -> accepted. EXPLOIT: the
//! authority does NOT sign -> for the INSECURE program the handler still runs (the
//! MissingSignerCheck invariant is violated) -> `INVARIANT VIOLATED:` + exit(101).
use anchor_lang::InstructionData;
use solana_harness_anchor::instruction as spike_ix;
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

#[tokio::main]
async fn main() {
    let program_id: Pubkey = solana_harness_anchor::ID;
    let mut pt = ProgramTest::new("solana_harness_anchor", program_id, processor!(process_instruction));
    let authority = Keypair::new();
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
    let (mut banks, payer, recent) = pt.start().await;
    let data = spike_ix::LogMessage {}.data();

    // CONTROL: the authority signs the transaction -> must be accepted.
    let ix_ctrl = Instruction {
        program_id,
        accounts: vec![AccountMeta::new_readonly(authority.pubkey(), true)],
        data: data.clone(),
    };
    let mut tx_ctrl = Transaction::new_with_payer(&[ix_ctrl], Some(&payer.pubkey()));
    tx_ctrl.sign(&[&payer, &authority], recent);
    let ctrl = banks.process_transaction(tx_ctrl).await;
    if ctrl.is_ok() {
        println!("CONTROL OK: signed authority accepted");
    } else {
        println!("control anomaly: signed authority rejected ({:?})", ctrl);
    }

    // EXPLOIT: the authority does NOT sign (is_signer = false).
    let ix_exp = Instruction {
        program_id,
        accounts: vec![AccountMeta::new_readonly(authority.pubkey(), false)],
        data,
    };
    let mut tx_exp = Transaction::new_with_payer(&[ix_exp], Some(&payer.pubkey()));
    tx_exp.sign(&[&payer], recent);
    let exp = banks.process_transaction(tx_exp).await;
    if exp.is_ok() {
        eprintln!("INVARIANT VIOLATED: handler executed for a NON-signer authority (MissingSignerCheck)");
        std::process::exit(101);
    } else {
        println!("invariant held: non-signer rejected ({:?})", exp);
    }
}
