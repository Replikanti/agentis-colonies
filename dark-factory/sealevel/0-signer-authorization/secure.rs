//! coral-xyz/sealevel-attacks — lesson 0, signer-authorization (SECURE).
//! Modernized verbatim from the upstream anchor-lang 0.20.0 source to anchor-lang 0.31.
//! The fix: `authority` is typed `Signer<'info>`, so anchor rejects any call where the
//! authority did not sign. The auditor MUST NOT report this as VERIFIED (zero
//! false-VERIFIED on secure variants is a hard blocker).
use anchor_lang::prelude::*;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

#[program]
pub mod signer_authorization_secure {
    use super::*;

    pub fn log_message(ctx: Context<LogMessage>) -> Result<()> {
        msg!("GM {}", ctx.accounts.authority.key().to_string());
        Ok(())
    }
}

#[derive(Accounts)]
pub struct LogMessage<'info> {
    authority: Signer<'info>,
}
