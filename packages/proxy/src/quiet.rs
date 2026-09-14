//! `no_window()`: spawn a console program without a console window.
//!
//! On Windows a console-subsystem child started by a parent that has NO
//! console of its own — the tray after `FreeConsole`, the detached proxy
//! supervisor — gets a brand-new, VISIBLE console window for the few hundred
//! milliseconds it runs. The tray's 5 s status tick spawns `tasklist` (the
//! interceptor PID probe), so users with Claude Desktop set up saw a blank
//! black window flash every few seconds, forever. Every `reg`, `tasklist`,
//! `schtasks`, `certutil`, `taskkill` and `where` this crate runs goes
//! through here. Console handles are real kernel handles on Windows 10+, so
//! a child created this way can still write to an inherited console when the
//! parent has one — the flag costs nothing on the CLI path.
//!
//! A no-op on every other platform, so call sites stay uncluttered.

use std::process::Command;

pub trait QuietCommand {
    fn no_window(&mut self) -> &mut Self;
}

impl QuietCommand for Command {
    fn no_window(&mut self) -> &mut Command {
        #[cfg(windows)]
        {
            const CREATE_NO_WINDOW: u32 = 0x0800_0000;
            std::os::windows::process::CommandExt::creation_flags(self, CREATE_NO_WINDOW);
        }
        self
    }
}
