// Bounty audit fixture: SAFE (guarded) vault withdraw (detection negative case).
//
// The withdraw handler verifies the authority signed the transaction AND matches
// the stored vault authority BEFORE mutating state. The signer guard dominates
// the `balance -=` sink, so the detector must NOT fire MissingSignerCheck here —
// this is the false-positive regression case for the dataflow dominance check.

pub struct AccountInfo {
    pub key: u64,
    pub is_signer: bool,
}

pub struct Vault {
    pub authority: u64,
    pub balance: u64,
}

pub struct WithdrawCtx<'a> {
    pub vault: &'a mut Vault,
    pub authority: &'a AccountInfo,
}

pub fn withdraw(ctx: WithdrawCtx, amount: u64) -> Result<(), String> {
    if !ctx.authority.is_signer {
        return Err("missing signer".to_string());
    }
    if ctx.authority.key != ctx.vault.authority {
        return Err("authority mismatch".to_string());
    }
    if ctx.vault.balance < amount {
        return Err("insufficient funds".to_string());
    }
    ctx.vault.balance -= amount;
    Ok(())
}
