//! The `harfbuzz` import when zss is built with `-Dsystem-harfbuzz`: the same
//! C surface the vendored package exposes (`.c`), taken from the host's
//! HarfBuzz and FreeType headers instead. The host supplies the include
//! directories (`-Dsystem-include-dir`) and links the libraries.
//!
//! Why not the package's module: its build script runs `test_exe.linkLibrary`
//! on the shared module, so importing the module links the vendored static
//! HarfBuzz + FreeType into every consumer — a FreeType built without brotli,
//! which cannot open WOFF2 web fonts.

pub const c = @cImport({
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
});
