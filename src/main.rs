mod core;
mod ui;

use std::env;
use std::path::PathBuf;

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();

    if args.is_empty() {
        let code = core::scanner::run_legacy_from_iter(Vec::<String>::new());
        if code != 0 {
            std::process::exit(code);
        }
        return;
    }

    match args[0].as_str() {
        "ui" => {
            let mut launch = ui::app::UiLaunchOptions::default();
            let mut iter = args.iter().skip(1);
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
                        return;
                    }
                    other => {
                        eprintln!("unknown ui flag: {other}");
                        std::process::exit(1);
                    }
                }
            }

            if let Err(error) = ui::app::run_native_app(launch) {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
        "scan" => {
            let code = core::scanner::run_legacy_from_iter(args.into_iter().skip(1));
            if code != 0 {
                std::process::exit(code);
            }
        }
        "-h" | "--help" | "help" => {
            print_top_usage();
        }
        _ => {
            let code = core::scanner::run_legacy_from_iter(args);
            if code != 0 {
                std::process::exit(code);
            }
        }
    }
}

fn print_top_usage() {
    println!("Usage:");
    println!("  diskscope scan [PATH] [options]   Run CLI scanner");
    println!("  diskscope ui [--start] [--path PATH]   Launch native UI");
    println!();
    println!("CLI scan options:");
    core::scanner::print_legacy_usage();
}
