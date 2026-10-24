// Kiri is a GUI application. Windows builds use the Windows subsystem in every
// profile so launching the executable never opens a console window. Rust logs
// still go to %LOCALAPPDATA%\io.yuxino.kiri\logs\kiri.log (see diagnostics.rs);
// tail that file when running a development build.
#![cfg_attr(windows, windows_subsystem = "windows")]

fn main() {
    kiri_lib::run()
}
