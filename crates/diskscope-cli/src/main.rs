use diskscope_core::scanner;
use diskscope_egui::app::{self, UiLaunchOptions};
use std::env;
use std::fs;
use std::path::PathBuf;
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
        "clean-native" => clean_native(args.iter().skip(1).cloned().collect()),
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
    pro_unlocked: bool,
}

fn run_native_ui(args: Vec<String>) {
    let native_args = parse_native_args(&args);

    if env::var("DISKSCOPE_NATIVE_APP").is_err() {
        ensure_native_app_built();
    }

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
    eprintln!("launching native app: {}", app_path.display());

    let mut cmd = Command::new("open");
    // Force launching the exact bundle path selected above, even if another
    // copy with the same bundle identifier is installed or already running.
    cmd.arg("-n");
    cmd.arg(&app_path);
    if native_args.start || native_args.path.is_some() || native_args.pro_unlocked {
        cmd.arg("--args");
        if native_args.start {
            cmd.arg("--start");
        }
        if let Some(path) = native_args.path {
            cmd.arg("--path");
            cmd.arg(path);
        }
        if native_args.pro_unlocked {
            cmd.arg("--pro-unlocked");
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

fn clean_native(args: Vec<String>) {
    if let Some(other) = args
        .iter()
        .find(|arg| arg.as_str() != "-h" && arg.as_str() != "--help")
    {
        eprintln!("unknown clean-native flag: {other}");
        std::process::exit(1);
    }
    if args.iter().any(|arg| arg == "-h" || arg == "--help") {
        print_top_usage();
        return;
    }

    let mut removed_any = false;
    for path in native_clean_paths() {
        if !path.exists() {
            continue;
        }
        let remove_result = if path.is_dir() {
            fs::remove_dir_all(&path)
        } else {
            fs::remove_file(&path)
        };
        match remove_result {
            Ok(()) => {
                removed_any = true;
                println!("removed {}", path.display());
            }
            Err(error) => {
                eprintln!("failed to remove {}: {error}", path.display());
                std::process::exit(1);
            }
        }
    }

    if !removed_any {
        println!("native artifacts already clean");
    }

    if cfg!(target_os = "macos") {
        reset_macos_icon_cache();
    }
}

fn parse_native_args(args: &[String]) -> NativeArgs {
    let mut parsed = NativeArgs::default();
    let mut iter = args.iter();

    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--start" => parsed.start = true,
            "--pro-unlocked" => parsed.pro_unlocked = true,
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
        eprintln!(
            "DISKSCOPE_NATIVE_APP points to missing path: {}",
            path.display()
        );
        std::process::exit(1);
    }

    candidate_native_app_paths()
        .into_iter()
        .find(|path| path.exists())
}

fn candidate_native_app_paths() -> Vec<PathBuf> {
    let workspace_root = workspace_root();

    vec![
        workspace_root
            .join("native/macos/DiskscopeNative/build/Build/Products/Debug/DiskscopeNative.app"),
        workspace_root
            .join("native/macos/DiskscopeNative/build/Build/Products/Release/DiskscopeNative.app"),
        workspace_root.join("native/macos/DiskscopeNative/build/Release/DiskscopeNative.app"),
        workspace_root.join("native/macos/DiskscopeNative/build/Debug/DiskscopeNative.app"),
    ]
}

fn native_clean_paths() -> Vec<PathBuf> {
    let workspace_root = workspace_root();
    vec![
        workspace_root.join("native/macos/DiskscopeNative/build"),
        workspace_root.join("native/macos/DiskscopeNative/DiskscopeNative.app"),
    ]
}

fn ensure_native_app_built() {
    let workspace_root = workspace_root();
    let project = workspace_root.join("native/macos/DiskscopeNative/DiskscopeNative.xcodeproj");
    let derived_data = workspace_root.join("native/macos/DiskscopeNative/build");

    eprintln!(
        "building native app: xcodebuild -project {} -scheme DiskscopeNative -configuration Debug -derivedDataPath {} build",
        project.display(),
        derived_data.display()
    );

    let status = Command::new("xcodebuild")
        .arg("-project")
        .arg(project)
        .arg("-scheme")
        .arg("DiskscopeNative")
        .arg("-configuration")
        .arg("Debug")
        .arg("-derivedDataPath")
        .arg(derived_data)
        .arg("build")
        .status();

    match status {
        Ok(code) if code.success() => {}
        Ok(code) => {
            eprintln!("xcodebuild failed with status: {code}");
            std::process::exit(1);
        }
        Err(error) => {
            eprintln!("failed to run xcodebuild: {error}");
            std::process::exit(1);
        }
    }
}

fn workspace_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.."))
}

fn reset_macos_icon_cache() {
    println!("resetting macOS icon caches...");

    for pattern in [
        "com.apple.dock.iconcache",
        "com.apple.iconservices",
        "com.apple.iconservicesagent",
    ] {
        let output = match Command::new("find")
            .args(["/private/var/folders", "-name", pattern])
            .output()
        {
            Ok(output) => output,
            Err(error) => {
                eprintln!("warning: failed to scan icon cache pattern {pattern}: {error}");
                continue;
            }
        };

        let stdout = String::from_utf8_lossy(&output.stdout);
        for raw in stdout.lines() {
            let path = PathBuf::from(raw);
            if path.as_os_str().is_empty() {
                continue;
            }
            let remove_result = if path.is_dir() {
                fs::remove_dir_all(&path)
            } else {
                fs::remove_file(&path)
            };
            if let Err(error) = remove_result {
                eprintln!(
                    "warning: failed to remove icon cache {}: {error}",
                    path.display()
                );
            } else {
                println!("removed {}", path.display());
            }
        }
    }

    let _ = Command::new("qlmanage").args(["-r", "cache"]).status();
    for process in ["iconservicesagent", "Dock", "Finder"] {
        let _ = Command::new("killall").arg(process).status();
    }
}

fn print_top_usage() {
    println!("Usage:");
    println!("  diskscope scan [PATH] [options]           Run CLI scanner");
    println!("  diskscope ui [--start] [--path PATH]      Launch egui frontend");
    println!(
        "  diskscope ui-native [--start] [--path PATH] [--pro-unlocked] Launch native macOS app"
    );
    println!("  diskscope clean-native                     Remove native macOS build artifacts");
    println!();
    println!("CLI scan options:");
    scanner::print_legacy_usage();
}
