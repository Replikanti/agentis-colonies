// Bounty audit fixture: vulnerable vault deposit with unchecked arithmetic
// (the second detection class — IntegerOverflow).
//
// The deposit handler IS signer-guarded (so MissingSignerCheck must NOT fire),
// but it adds to the balance with an unchecked `+=` — a u64 overflow wraps the
// balance, so a large `amount` can corrupt accounting. The detector must fire
// IntegerOverflow (Medium) here and MissingSignerCheck nowhere. As of V5 (#843) this
// class ROUTES to prompt-driven synthesis with the IntegerOverflow-specific invariant
// (value-carrying arithmetic must not wrap); offline/mock has no deterministic overflow
// template (the built-in template is signer-shaped), so the run is `inconclusive` rather
// than falsely VERIFIED — only a real LLM-generated two-sided PoC can drive it to VERIFIED.

pub struct AccountInfo {
    pub key: u64,
    pub is_signer: bool,
}

pub struct Vault {
    pub authority: u64,
    pub balance: u64,
}

pub struct DepositCtx<'a> {
    pub vault: &'a mut Vault,
    pub authority: &'a AccountInfo,
}

pub fn deposit(ctx: DepositCtx, amount: u64) -> Result<(), String> {
    if !ctx.authority.is_signer {
        return Err("missing signer".to_string());
    }
    ctx.vault.balance += amount;
    Ok(())
}
