// system_update_helper — JSON-event driver for pacman + AUR updates.
//
// One process, one stdout stream, one event per line. Replaces stdout-regex
// state tracking in the QML popup with structured callbacks from libalpm and
// minimal makepkg-phase markers. The legacy TerminalBackend + PackageUpdate-
// Parser path stays untouched; this is a parallel implementation that hosts
// can opt into.
//
// CLI:
//
//     system_update_helper sysupgrade           # native pacman -Syu via libalpm
//     system_update_helper aur-upgrade          # AUR-only (existing pacman pkgs ignored)
//     system_update_helper update               # sysupgrade + aur-upgrade in one run
//     system_update_helper aur-build <pkgname>  # one-shot AUR build (testing)
//
// Stdin / stdout protocol:
//
//   - stdout: one JSON line per event. Events tagged with `event` field
//     (snake.dot.case). Schema documented in event.rs.
//   - stdin:  one JSON line per question response. Helper pauses on a
//     `question.*` event and resumes when the matching `id` is answered.
//   - stderr: human-readable diagnostic logging. Not parsed by the host.
//
// Privilege:
//
//   The helper runs as root (invoked via sudo from quickshell). libalpm
//   transactions need root for /var/lib/pacman locks; makepkg children are
//   spawned as $SUDO_USER so AUR builds happen in a normal user context.

use anyhow::Result;
use clap::{Parser, Subcommand};

mod aur;
mod event;
mod pacman;
mod proto;
mod sink;

#[derive(Parser, Debug)]
#[command(
    name = "system_update_helper",
    version,
    about = "JSON-event driver for pacman + AUR updates"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,

    /// Skip the database refresh step (`pacman -Sy`). Useful for tests
    /// against an already-synced state.
    #[arg(long, global = true)]
    no_sync: bool,

    /// Pretend mode — emit events for what *would* happen without
    /// actually invoking the transaction. Helpful for QML mockups.
    #[arg(long, global = true)]
    dry_run: bool,
}

#[derive(Subcommand, Debug)]
enum Cmd {
    /// Native `pacman -Syu` driven through libalpm, every callback
    /// emitted as a structured event.
    Sysupgrade,
    /// AUR-only upgrade run. Walks installed AUR packages, queries
    /// aurweb for newer versions, fetches+builds+installs each.
    AurUpgrade,
    /// Sysupgrade then AUR-upgrade in one run.
    Update,
    /// Build + install one named AUR package. Used for tests and ad-hoc
    /// installs from the popup's "Run yay -Syu" entry point when an
    /// argument is supplied.
    AurBuild { name: String },
}

fn main() {
    let cli = Cli::parse();
    let mut sink = sink::EventSink::new(std::io::stdout().lock());
    let stdin = std::io::stdin();
    let mut prompt = proto::PromptStream::new(stdin.lock());

    sink.emit(event::Event::HelperStart {
        version: env!("CARGO_PKG_VERSION").into(),
        mode: format!("{:?}", cli.cmd).to_lowercase(),
        dry_run: cli.dry_run,
    });

    let result = run(cli, &mut sink, &mut prompt);
    match &result {
        Ok(()) => sink.emit(event::Event::HelperExit { code: 0 }),
        Err(e) => {
            sink.emit(event::Event::LogError {
                msg: format!("{e:#}"),
            });
            sink.emit(event::Event::HelperExit { code: 1 });
        }
    }
    std::process::exit(if result.is_ok() { 0 } else { 1 });
}

fn run(
    cli: Cli,
    sink: &mut sink::EventSink,
    prompt: &mut proto::PromptStream<std::io::StdinLock<'_>>,
) -> Result<()> {
    match cli.cmd {
        Cmd::Sysupgrade => pacman::sysupgrade(sink, prompt, cli.no_sync, cli.dry_run),
        Cmd::AurUpgrade => aur::upgrade(sink, prompt, cli.dry_run),
        Cmd::Update => {
            pacman::sysupgrade(sink, prompt, cli.no_sync, cli.dry_run)?;
            aur::upgrade(sink, prompt, cli.dry_run)
        }
        Cmd::AurBuild { name } => aur::build_and_install_one(sink, prompt, &name, cli.dry_run),
    }
}
