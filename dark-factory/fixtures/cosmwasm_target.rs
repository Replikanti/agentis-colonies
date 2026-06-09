// CosmWasm-shaped execute-handler fixture for node-stream ingestion.
//
// Demonstrates that the exec-driven reference node-extractor produces a canonical
// node stream from a CosmWasm target as well as an Anchor/Solana one — the parser is
// language-agnostic (it scans Rust `fn` / `struct` / `impl` items). std-only so it
// compiles offline; used only to exercise ingestion, not detection.

pub struct DepsMut {
    pub balance: u64,
}

pub struct MessageInfo {
    pub sender: u64,
    pub authorized: bool,
}

pub struct ExecuteCtx<'a> {
    pub deps: &'a mut DepsMut,
    pub info: &'a MessageInfo,
}

pub fn execute(ctx: ExecuteCtx, amount: u64) -> Result<(), String> {
    if ctx.deps.balance < amount {
        return Err("insufficient funds".to_string());
    }
    ctx.deps.balance -= amount;
    Ok(())
}
