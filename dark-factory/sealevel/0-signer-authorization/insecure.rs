//! coral-xyz/sealevel-attacks — lesson 0, signer-authorization (INSECURE).
//! Modernized verbatim from the upstream anchor-lang 0.20.0 source to anchor-lang 0.31
//! (only toolchain syntax changed: `ProgramResult` -> `Result<()>`, the anchor>=0.24
//! `/// CHECK:` doc on the unchecked account). The vulnerability is untouched: `authority`
//! is an unchecked `AccountInfo`, never required to sign, so the handler runs for a caller
//! that never signed. Detection (V3/V5) runs on the verbatim upstream source; this file is
//! the toolchain-compatible target the PoC executes against the real SVM.
use anchor_lang::prelude::*;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

#[program]
pub mod signer_authorization_insecure {
    use super::*;

    pub fn log_message(ctx: Context<LogMessage>) -> Result<()> {
        msg!("GM {}", ctx.accounts.authority.key().to_string());
        Ok(())
    }
}

#[derive(Accounts)]
pub struct LogMessage<'info> {
    /// CHECK: VULNERABILITY — the authority is an unchecked AccountInfo and is never
    /// required to sign. A correct program types this as `Signer<'info>`.
    authority: AccountInfo<'info>,
}
