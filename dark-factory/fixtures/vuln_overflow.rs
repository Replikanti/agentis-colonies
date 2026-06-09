// Bounty audit fixture: vulnerable vault deposit with unchecked arithmetic
// (the second detection class — IntegerOverflow).
//
// The deposit handler IS signer-guarded (so MissingSignerCheck must NOT fire),
// but it adds to the balance with an unchecked `+=` — a u64 overflow wraps the
// balance, so a large `amount` can corrupt accounting. The detector must fire
// IntegerOverflow (Medium) here and MissingSignerCheck nowhere. PoC synthesis for
// this class is deferred to the prompt-driven path; detection only proves it is DETECTED.

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
