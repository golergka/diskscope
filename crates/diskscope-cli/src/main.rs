use diskscope_core::scanner;
use diskscope_egui::app::{self, UiLaunchOptions};
use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();

    if args.is_empty() {
        let code = scanner::run_legacy_from_iter(Vec::<String>::new());
        if code != 0 {
            std::process::exit(code);
        }
        return;
    }

    match args[0].as_str() {
        "ui" => run_egui_ui(args.iter().skip(1).cloned().collect()),
        "ui-native" => run_native_ui(args.iter().skip(1).cloned().collect()),
        "scan" => {
            let code = scanner::run_legacy_from_iter(args.into_iter().skip(1));
            if code != 0 {
                std::process::exit(code);
            }
        }
        "-h" | "--help" | "help" => print_top_usage(),
        _ => {
            let code = scanner::run_legacy_from_iter(args);
            if code != 0 {
                std::process::exit(code);
            }
        }
    }
}

fn run_egui_ui(args: Vec<String>) {
    let launch = parse_ui_launch_options(&args);
    if let Err(error) = app::run_native_app(launch) {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn parse_ui_launch_options(args: &[String]) -> UiLaunchOptions {
    let mut launch = UiLaunchOptions::default();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--start" => launch.auto_start = true,
            "--path" => {
                let value = iter.next().unwrap_or_else(|| {
                    eprintln!("missing value for --path");
                    std::process::exit(1);
                });
                launch.root_override = Some(PathBuf::from(value));
            }
            "-h" | "--help" => {
                print_top_usage();
                std::process::exit(0);
            }
            other => {
                eprintln!("unknown ui flag: {other}");
                std::process::exit(1);
            }
        }
    }
    launch
}

#[derive(Default)]
struct NativeArgs {
    start: bool,
    path: Option<PathBuf>,
}

fn run_native_ui(args: Vec<String>) {
    let native_args = parse_native_args(&args);

    let app_path = match discover_native_app_path() {
        Some(path) => path,
        None => {
            eprintln!("native app bundle was not found.");
            eprintln!("expected one of:");
            for path in candidate_native_app_paths() {
                eprintln!("  - {}", path.display());
            }
            eprintln!();
            eprintln!("build it with:");
            eprintln!("  xcodebuild -project native/macos/DiskscopeNative/DiskscopeNative.xcodeproj -scheme DiskscopeNative -configuration Release -derivedDataPath native/macos/DiskscopeNative/build build");
            std::process::exit(1);
        }
    };

    let mut cmd = Command::new("open");
    cmd.arg(&app_path);
    if native_args.start || native_args.path.is_some() {
        cmd.arg("--args");
        if native_args.start {
            cmd.arg("--start");
        }
        if let Some(path) = native_args.path {
            cmd.arg("--path");
            cmd.arg(path);
        }
    }

    match cmd.status() {
        Ok(status) if status.success() => {}
        Ok(status) => {
            eprintln!("failed to launch native app (status: {status})");
            std::process::exit(1);
        }
        Err(error) => {
            eprintln!("failed to launch native app: {error}");
            std::process::exit(1);
        }
    }
}

fn parse_native_args(args: &[String]) -> NativeArgs {
    let mut parsed = NativeArgs::default();
    let mut iter = args.iter();

    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--start" => parsed.start = true,
            "--path" => {
                let value = iter.next().unwrap_or_else(|| {
                    eprintln!("missing value for --path");
                    std::process::exit(1);
                });
                parsed.path = Some(PathBuf::from(value));
            }
            "-h" | "--help" => {
                print_top_usage();
                std::process::exit(0);
            }
            other => {
                eprintln!("unknown ui-native flag: {other}");
                std::process::exit(1);
            }
        }
    }

    parsed
}

fn discover_native_app_path() -> Option<PathBuf> {
    if let Ok(override_path) = env::var("DISKSCOPE_NATIVE_APP") {
        let path = PathBuf::from(override_path);
        if path.exists() {
            return Some(path);
        }
    }

    candidate_native_app_paths()
        .into_iter()
        .find(|path| path.exists())
}

fn candidate_native_app_paths() -> Vec<PathBuf> {
    let workspace_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."));

    vec![
        workspace_root.join("native/macos/DiskscopeNative/build/Release/DiskscopeNative.app"),
        workspace_root.join("native/macos/DiskscopeNative/build/Debug/DiskscopeNative.app"),
        workspace_root
            .join("native/macos/DiskscopeNative/build/Build/Products/Release/DiskscopeNative.app"),
        workspace_root
            .join("native/macos/DiskscopeNative/build/Build/Products/Debug/DiskscopeNative.app"),
        workspace_root.join("native/macos/DiskscopeNative/DiskscopeNative.app"),
        Path::new("/Applications/DiskscopeNative.app").to_path_buf(),
    ]
}

fn print_top_usage() {
    println!("Usage:");
    println!("  diskscope scan [PATH] [options]           Run CLI scanner");
    println!("  diskscope ui [--start] [--path PATH]      Launch egui frontend");
    println!("  diskscope ui-native [--start] [--path PATH] Launch native macOS app");
    println!();
    println!("CLI scan options:");
    scanner::print_legacy_usage();
}
