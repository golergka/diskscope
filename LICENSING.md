# Licensing

`diskscope` is primarily an MIT-licensed open-source project. All crates under `crates/` (core, cli, egui, ffi) plus the native `DiskscopeNative` target are covered by the [MIT license](LICENSE).

The optional paid monitoring daemon is kept in a separate private submodule located at `pro/diskscope-pro-daemon`. That submodule is not part of the MIT distribution and instead ships under a source-available commercial license. It is distributed only to authorized parties and must not be used or redistributed without a valid purchase or license agreement.

Builds that do not include the submodule (OSS builds, CLI-only distributions) remain fully functional for the free scanning UI and still compile against the MIT-licensed core.
