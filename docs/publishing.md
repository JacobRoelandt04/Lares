# Publishing: the public copy of Lares

This repository stays private. What goes public is an **export**: one squashed commit of `main` without the agents' notes,
judged by a leak check, on a local branch `public` that you push to a separate public repository. You work in this
repository as always. The public one only receives exports: you never clone or edit it.

## Why a separate repository

The history is not published: it holds everything the privacy scrub took out (2026-11-23). Making this repository public
after rewriting its history is not enough. GitHub keeps commits reachable by their SHA after a force-push (cached pages,
pull-request refs, forks). A new repository that has only ever received exports has none of that history.

## What is left out, and what is checked

- **Left out**: the paths of `tools/publish/exclude.txt`: `CLAUDE.md`, `feedback/`, `docs/agent_added_files_and_folders/`.
  Comments that cite "CLAUDE.md" stay in the code; in the public copy they point at a file that is not there.
- **Never tracked at all**: everything `.gitignore` names, your `config/` above all (your settings, keys and the private list).
- **The leak check**, `tools/publish/privacy_check.py`, judges every file the export holds, the export commit's identity
  included, against two kinds of rule:
  - **Your private list**, `config/privacy.jsonc` (the template is `.examples/privacy.jsonc`). `replace` maps each real
    value to a stand-in, which the fixture scrubbers use. `forbid` holds values with no stand-in. Every real value is
    forbidden in any case and spelling, a MAC address included.
  - **Rules that catch what nobody listed**: e-mail addresses off the example domains, MAC addresses that are not stand-ins,
    public IPv4 and IPv6 addresses, home-directory names, private keys and tokens, claude.ai artifact links, and image
    metadata (GPS, serial, owner).

  `tools/publish/privacy_allow.txt` lists the exceptions, each with its reason: your name in `LICENSE`, `README.md` and a
  plugin's author field, PipeWire's authors in a fixture.
- The quick tier runs the same check on `HEAD` (`privacy`) and its cases (`privacy_cases`, `publish_cases`), so `main` stays
  publishable between exports.

## The first time

1. Create an **empty public repository** on GitHub (no README, no licence: the export brings its own).
2. In `config/privacy.jsonc`, set `"publish": { "name": "...", "email": "..." }`. Use your GitHub **no-reply** address
   (Settings > Emails, `12345678+name@users.noreply.github.com`). Every public commit shows it, and the export refuses any
   other address.
3. `git remote add public git@github.com:<you>/<public repo>.git`

## Each export

    lares publish check     # what would go out, judged; builds nothing
    lares publish build     # the next commit of the local branch `public`
    git push public public:main

`build` refuses (exit 1, `public` unchanged) when the check finds anything. It says "nothing new" when the tree has not changed
since the last export. Each export is dated in UTC, because your time zone would say where you live. Push only `public`:
never your other branches or tags, never `git push --all` to that remote, and never merge `public` into `main` or back.

## A finding

Each finding line names the rule, the file and line, and a masked value. To see the values:

    python3 -B tools/publish/privacy_check.py --show

For each one, either replace the value with a stand-in in the tracked file (a fixture keeps its shape: a MAC stays a MAC from
the `02:AE:00:00:..` range, an IPv6 address comes from `2001:db8::/32`, a place becomes another real town), or, if it is
public, add an exact line to `privacy_allow.txt` with a comment saying why. A new real value you find (a new device, a new
network) goes into `config/privacy.jsonc`.

## A pull request from a stranger

It arrives on the public repository, which has no history you work in. Apply its patch to `main` here
(`curl -L <PR URL>.patch | git am`), check it like any change, and let the next export carry it. Then close the pull request
with a note saying where the change landed.

## Not handled here

Third-party art inside the README's showcase shots and a few fixtures (an album cover, wallpapers) is not checked by any
rule. Whether those may be shown publicly is a licensing question, not a privacy one.
