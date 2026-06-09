// Bounty audit fixture: vulnerable Anchor-shaped vault program (walking skeleton).
//
// Models a Solana/Anchor `withdraw` instruction with a PLANTED vulnerability:
// the handler never verifies that the `authority` account signed the transaction
// (`is_signer`) nor that it matches the vault's stored authority, so any caller
// can drain the vault. std-only (no anchor/solana deps) so the generated PoC
// compiles + runs offline with plain `rustc`.
//
// For the walking skeleton, auditor.ag embeds a copy of this handler as its
// hardcoded "ingest" stage; reading real target files is the file-ingest path.

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

// VULNERABILITY (planted): no `ctx.authority.is_signer` check and no
// `ctx.authority.key == ctx.vault.authority` check.
pub fn withdraw(ctx: WithdrawCtx, amount: u64) -> Result<(), String> {
    if ctx.vault.balance < amount {
        return Err("insufficient funds".to_string());
    }
    ctx.vault.balance -= amount;
    Ok(())
}
