// SPDX-License-Identifier: MIT
// Copyright (c) 2015 The Rust Project Developers
// Exact source excerpts retained for review; this file is not compiled.
// gimli-rs/gimli@478f07ad90e91bb8b061ec33ef4bd3a8448839e1
// src/read/cfi.rs (Git blob f1c3ead9d7bfff9df1354de498ae51742153a6f8)
// See LICENSE-MIT and README.md in this directory.

// Upstream lines 2215-2231
    fn push_row(&mut self) -> Result<()> {
        let new_row = self.row().clone();
        self.stack.try_push(new_row).map_err(|_| Error::StackFull)
    }

    fn pop_row(&mut self) -> Result<()> {
        let min_size = if self.is_initialized && self.initial_rule.is_none() {
            2
        } else {
            1
        };
        if self.stack.len() <= min_size {
            return Err(Error::PopWithEmptyStack);
        }
        self.stack.pop().unwrap();
        Ok(())
    }

// Upstream lines 2568-2577
            // Row push and pop instructions.
            RememberState => {
                self.ctx.push_row()?;
            }
            RestoreState => {
                // Pop state while preserving current location.
                let start_address = self.ctx.start_address();
                self.ctx.pop_row()?;
                self.ctx.set_start_address(start_address);
            }

// Upstream lines 3392-3410
            constants::DW_CFA_advance_loc1 => {
                let delta = input.read_u8()?;
                Ok(CallFrameInstruction::AdvanceLoc {
                    delta: u32::from(delta),
                })
            }

            constants::DW_CFA_advance_loc2 => {
                let delta = input.read_u16()?;
                Ok(CallFrameInstruction::AdvanceLoc {
                    delta: u32::from(delta),
                })
            }

            constants::DW_CFA_advance_loc4 => {
                let delta = input.read_u32()?;
                Ok(CallFrameInstruction::AdvanceLoc { delta })
            }


// Upstream lines 3444-3446
            constants::DW_CFA_remember_state => Ok(CallFrameInstruction::RememberState),

            constants::DW_CFA_restore_state => Ok(CallFrameInstruction::RestoreState),
