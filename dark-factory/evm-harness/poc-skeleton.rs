//! Fixed two-sided revm PoC skeleton for the dark-factory EVM colony's DECOMPOSED synthesis
//! (#982). All the revm-14 boilerplate + helpers live here so the LLM never regenerates them;
//! synthesis fills only two small slots (the CONTROL and EXPLOIT blocks) — each ~15 lines,
//! which keeps each generation small + fast (a whole-PoC one-shot stalls on a big contract). The
//! two-sided gate is unchanged: a vulnerable target prints `CONTROL OK:` AND `INVARIANT VIOLATED:`
//! and exits 101; exit 101 is reserved EXCLUSIVELY for a genuine violation (setup failures -> exit 2).
//!
//! argv[1] = target creation-bytecode (.bin hex). argv[2] = optional attacker .bin (reentrancy).
//!
//! Helpers the slots may call (do NOT redefine them):
//!   deploy(&mut evm, deployer, &target_code, &ctor_args) -> Address   // fresh target; append abi args
//!   call(&mut evm, from, to, data) -> Vec<u8>                         // non-payable call; DIES on revert
//!   call_value(&mut evm, from, to, value, data) -> Vec<u8>            // payable call (sends ETH)
//!   try_call(&mut evm, from, to, data) -> Option<Vec<u8>>             // non-payable; None on revert
//!   try_call_value(&mut evm, from, to, value, data) -> Option<Vec<u8>> // payable; None on revert
//!   selector("f(uint256)") -> Vec<u8>   abi_addr(a) -> Vec<u8>   abi_u256(n: u128) -> Vec<u8>
//!   eth_balance(&mut evm, a) -> U256     storage(&mut evm, a, slot_u64) -> U256     u256(&bytes) -> U256
//!   die(msg) -> !   (HARNESS ERROR + exit 2)
//! Vars in scope: evm, target_code: Vec<u8>, attacker_code: Vec<u8> (argv[2], may be empty),
//!   deployer/attacker/user: Address (each funded 100 ETH). U256/TxKind/Address are imported.
use revm::db::{CacheDB, EmptyDB};
use revm::primitives::{keccak256, AccountInfo, Address, Bytes, ExecutionResult, Output, TxKind, U256};
use revm::{Database, Evm};
use std::process::exit;

type Db = CacheDB<EmptyDB>;

fn die(msg: String) -> ! {
    eprintln!("HARNESS ERROR: {msg}");
    exit(2);
}
fn selector(sig: &str) -> Vec<u8> {
    keccak256(sig.as_bytes())[..4].to_vec()
}
fn abi_addr(a: Address) -> Vec<u8> {
    let mut v = vec![0u8; 12];
    v.extend_from_slice(a.as_slice());
    v
}
// The LLM passes amounts as either a U256 or a plain integer (u128/u64); ruint's `U256::from`
// is an inherent method, NOT std `From`, so a `T: Into<U256>` bound would reject the integers.
// A local trait impl'd for exactly those types accepts whatever the fill writes.
trait Word {
    fn word(self) -> [u8; 32];
}
impl Word for U256 {
    fn word(self) -> [u8; 32] { self.to_be_bytes::<32>() }
}
impl Word for u128 {
    fn word(self) -> [u8; 32] { U256::from(self).to_be_bytes::<32>() }
}
impl Word for u64 {
    fn word(self) -> [u8; 32] { U256::from(self).to_be_bytes::<32>() }
}
fn abi_u256<T: Word>(n: T) -> Vec<u8> {
    n.word().to_vec()
}
fn load_bin(path: &str) -> Vec<u8> {
    let s = std::fs::read_to_string(path).unwrap_or_else(|e| die(format!("read {path}: {e}")));
    hex::decode(s.trim()).unwrap_or_else(|e| die(format!("bad hex {path}: {e}")))
}
fn fund(evm: &mut Evm<'_, (), Db>, a: Address, wei: U256) {
    evm.db_mut().insert_account_info(a, AccountInfo { balance: wei, ..Default::default() });
}
fn run(evm: &mut Evm<'_, (), Db>, from: Address, to: TxKind, value: U256, data: Vec<u8>) -> ExecutionResult {
    {
        let tx = evm.tx_mut();
        tx.caller = from;
        tx.transact_to = to;
        tx.value = value;
        tx.data = Bytes::from(data);
        tx.gas_limit = 30_000_000;
        tx.gas_price = U256::ZERO;
        tx.nonce = None;
    }
    evm.transact_commit().unwrap_or_else(|e| die(format!("EVM transact failed: {e:?}")))
}
fn deploy(evm: &mut Evm<'_, (), Db>, from: Address, code: &[u8], ctor_args: &[u8]) -> Address {
    let mut c = code.to_vec();
    c.extend_from_slice(ctor_args);
    match run(evm, from, TxKind::Create, U256::ZERO, c) {
        ExecutionResult::Success { output: Output::Create(_, Some(a)), .. } => a,
        o => die(format!("deploy failed: {o:?}")),
    }
}
#[allow(dead_code)]
fn call(evm: &mut Evm<'_, (), Db>, from: Address, to: Address, data: Vec<u8>) -> Vec<u8> {
    call_value(evm, from, to, U256::ZERO, data) // non-payable (value 0) — the common case
}
#[allow(dead_code)]
fn call_value(evm: &mut Evm<'_, (), Db>, from: Address, to: Address, value: U256, data: Vec<u8>) -> Vec<u8> {
    match run(evm, from, TxKind::Call(to), value, data) {
        ExecutionResult::Success { output: Output::Call(b), .. } => b.to_vec(),
        o => die(format!("call reverted: {o:?}")),
    }
}
#[allow(dead_code)]
fn try_call(evm: &mut Evm<'_, (), Db>, from: Address, to: Address, data: Vec<u8>) -> Option<Vec<u8>> {
    try_call_value(evm, from, to, U256::ZERO, data) // non-payable
}
#[allow(dead_code)]
fn try_call_value(evm: &mut Evm<'_, (), Db>, from: Address, to: Address, value: U256, data: Vec<u8>) -> Option<Vec<u8>> {
    match run(evm, from, TxKind::Call(to), value, data) {
        ExecutionResult::Success { output: Output::Call(b), .. } => Some(b.to_vec()),
        _ => None,
    }
}
#[allow(dead_code)]
fn eth_balance(evm: &mut Evm<'_, (), Db>, a: Address) -> U256 {
    evm.db_mut().accounts.get(&a).map(|x| x.info.balance).unwrap_or(U256::ZERO)
}
#[allow(dead_code)]
fn storage(evm: &mut Evm<'_, (), Db>, a: Address, slot: u64) -> U256 {
    evm.db_mut().storage(a, U256::from(slot)).unwrap_or(U256::ZERO)
}
#[allow(dead_code)]
fn u256(v: &[u8]) -> U256 {
    U256::from_be_slice(v)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        die("usage: poc <target.bin> [attacker.bin]".into());
    }
    let target_code = load_bin(&args[1]);
    let attacker_code: Vec<u8> = if args.len() > 2 {
        std::fs::read_to_string(&args[2]).ok().and_then(|s| hex::decode(s.trim()).ok()).unwrap_or_default()
    } else {
        Vec::new()
    };
    let deployer = Address::from([0x11u8; 20]);
    let attacker = Address::from([0x44u8; 20]);
    let user = Address::from([0x22u8; 20]);
    let mut evm = Evm::builder().with_db(CacheDB::new(EmptyDB::default())).build();
    for a in [deployer, attacker, user] {
        fund(&mut evm, a, U256::from(100_000_000_000_000_000_000u128)); // 100 ETH
    }
    // keep the skeleton compiling before the slots are filled
    let _ = (&target_code, &attacker_code, deployer, attacker, user);

    // <<CONTROL>>

    // <<EXPLOIT>>

    println!("invariant held: exploit did not violate the invariant on this target");
    exit(0);
}
