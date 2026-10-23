#!/usr/bin/env python3
"""One git worktree per ticket session: isolated branch and files, shared history, big folders linked.

Usage:
  wt.py new TICKET [--repo DIR] [--base REF] [--branch NAME] [--link PATH ...] [--no-fetch]
  wt.py list [--repo DIR]
  wt.py done TICKET [--repo DIR] [--force]

new   creates <main>/.claude/worktrees/<TICKET> on branch NAME (default feature/<TICKET>; an existing local
      branch is checked out instead of created), starting from --base (default: <repo>.base in
      worktrees.conf, else the remote default branch (origin's, or the only remote's)). Links the
      configured untracked folders from the main checkout, copies hookify rules and
      .claude/settings.local.json, and prints the path for Claude Code's EnterWorktree tool.
list  shows every worktree of the repository with size, branch, uncommitted changes and merge state.
done  removes a finished ticket's worktree. First its PLAN_*.md files are archived to
      <git-common-dir>/concord/plans/<TICKET>/ and removed from the worktree; then it unlinks the links
      wt.py made (targets untouched) and runs `git worktree remove`, which deletes the folder with its ignored
      files. Before touching anything it
      refuses while (a) tracked or untracked work is uncommitted, (b) ignored files other than caches/build
      output and wt.py's own copies would be lost (listed with sizes), or (c) this session's sandbox
      write-protects files inside (Claude Code protects .claude/settings*.json of a worktree it entered:
      run `done` unsandboxed then). --force skips (a) and (b). Branches and commits are never deleted.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONF = HERE / "worktrees.conf"
MARK = ".wt-links"          # inside the worktree's git dir: the links this tool created
PLAN_GLOB = "PLAN_*.md"     # untracked plan files at the worktree top level; archived on `done`


def die(msg, code=2):
    print(f"wt: {msg}", file=sys.stderr)
    sys.exit(code)


def git(repo, *args, check=True):
    res = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and res.returncode != 0:
        die(f"git {' '.join(args)} failed: {res.stderr.strip()}")
    return res.stdout.strip()


def main_checkout(start):
    """Top level of the MAIN checkout, also when called from inside a linked worktree."""
    common = Path(git(start, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    return common.parent if common.name == ".git" else Path(git(start, "rev-parse", "--show-toplevel"))


def load_conf():
    conf = {}
    if CONF.exists():
        for raw in CONF.read_text().splitlines():
            line = raw.split("#", 1)[0].strip()
            if "=" in line:
                k, v = line.split("=", 1)
                conf[k.strip()] = v.strip()
    return conf


def safe_name(ticket):
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", ticket):
        die("TICKET may contain only letters, digits, dot, underscore and dash (max 64)")
    return ticket


def default_base(repo, conf):
    base = conf.get(f"{repo.name}.base")
    if base:
        return base
    head = git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD", check=False)
    if head:
        return head
    heads = [l for l in git(repo, "for-each-ref", "--format=%(symref:short)", "refs/remotes/",
                            check=False).splitlines() if l.strip()]
    return heads[0] if len(heads) == 1 else "HEAD"


def tracked_under(repo, rel):
    return bool(git(repo, "ls-files", "--", rel, check=False))


def link_patterns(repo, rels):
    """Patterns that hide each worktree symlink from git (status, `add -A`) without changing how the main checkout
    sees the real folder. Git treats a symlink as a file, so `name/` patterns never match it: `/name` hides the link,
    and `!/name/` (directories only) re-includes the real folder where the main checkout shows it as untracked."""
    pats = []
    for rel in rels:
        ignored = subprocess.run(["git", "-C", str(repo), "check-ignore", "-q", rel]).returncode == 0
        pats += [f"/{rel}"] + ([] if ignored else [f"!/{rel}/"])
    return pats


def exclude_add(repo, patterns):
    """Append missing patterns to the shared info/exclude (local to this machine, never committed)."""
    exclude = Path(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")) / "info" / "exclude"
    text = exclude.read_text() if exclude.exists() else ""
    have = {l.strip() for l in text.splitlines()}
    new = [p for p in dict.fromkeys(patterns) if p not in have and not (p == ".claude/worktrees/" and
                                                                      re.search(r"^/?\.claude/worktrees/?$", text, re.M))]
    if new:
        exclude.parent.mkdir(parents=True, exist_ok=True)
        exclude.write_text(text + ("" if text.endswith("\n") or not text else "\n") + "\n".join(new) + "\n")


def cmd_new(args):
    repo = main_checkout(args.repo or os.getcwd())
    conf = load_conf()
    ticket = safe_name(args.ticket)
    wt = repo / ".claude" / "worktrees" / ticket
    if wt.exists():
        die(f"{wt} already exists; enter it with EnterWorktree path={wt}, or `wt.py done {ticket}` first")
    branch = args.branch or f"feature/{ticket}"
    name = git(repo, "check-ref-format", "--branch", branch)   # option-like names refused before any other git call
    if name != branch:
        die(f"--branch {branch} is git's shorthand for {name}; give the branch name itself")
    if not args.no_fetch:
        res = subprocess.run(["git", "-C", str(repo), "fetch", "--quiet", "origin"], capture_output=True, text=True)
        if res.returncode != 0:
            print(f"wt: note: fetch failed ({res.stderr.strip()[:120]}); using the local refs", file=sys.stderr)
    exists = subprocess.run(["git", "-C", str(repo), "show-ref", "--verify", "--quiet", f"refs/heads/{branch}"]).returncode == 0
    base = args.base or default_base(repo, conf)
    wt.parent.mkdir(parents=True, exist_ok=True)
    sha = git(repo, "rev-parse", "--verify",
              f"refs/heads/{branch}^{{commit}}" if exists else f"{base}^{{commit}}")
    if not exists:
        git(repo, "branch", "--no-track", branch, sha)   # a branch another run just made dies here, before the add
    add_args = ["worktree", "add", str(wt), branch]
    res = subprocess.run(["git", "-C", str(repo), *add_args], capture_output=True, text=True)
    if res.returncode != 0:
        held = any(w.get("branch") == f"refs/heads/{branch}" for w in worktrees(repo))
        if not exists and not held:   # git keeps the branch while it still points at that commit; a held one stays
            git(repo, "update-ref", "-d", f"refs/heads/{branch}", sha, check=False)
        try:
            wt.rmdir()                # nothing left behind; a folder with content is kept
        except OSError:
            pass
        die(f"git {' '.join(add_args)} failed: {res.stderr.strip()}")
    links = (conf.get(f"{repo.name}.links", "").split()) + list(args.link or [])
    made, skipped = [], []
    for rel in links:
        rel = rel.strip("/")
        src, dst = repo / rel, wt / rel
        if not src.exists():
            skipped.append(f"{rel} (absent in the main checkout)")
            continue
        if tracked_under(repo, rel):
            skipped.append(f"{rel} (holds tracked files; link only fully untracked folders)")
            continue
        if dst.exists() or dst.is_symlink():
            skipped.append(f"{rel} (already present in the worktree)")
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(src, dst)
        made.append(rel)
    copied = []
    for f in sorted((repo / ".claude").glob("hookify.*.local.md")) + [repo / ".claude" / "settings.local.json"]:
        if f.is_file() and not f.is_symlink():
            try:
                (wt / ".claude").mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, wt / ".claude" / f.name)
                copied.append(f.name)
            except OSError as e:
                skipped.append(f".claude/{f.name} (not copied: {e.strerror}; a sandbox protects it, copy it unsandboxed)")
    gitdir = Path(git(wt, "rev-parse", "--path-format=absolute", "--git-dir"))
    (gitdir / MARK).write_text("\n".join(made + [f".claude/{c}" for c in copied]) + "\n")
    exclude_add(repo, [".claude/worktrees/", "/PLAN_*.md"] + link_patterns(repo, made))
    state = f"existing at {sha[:7]}" if exists else f"new from {base} at {sha[:7]}"
    print(f"WORKTREE {wt}\nbranch {branch} ({state})\n"
          f"linked: {', '.join(made) or 'none'}\ncopied: {', '.join(copied) or 'none'}"
          + (f"\nskipped: {'; '.join(skipped)}" if skipped else "")
          + f"\nnext: EnterWorktree path={wt}")
    return 0


def worktrees(repo):
    out, cur = [], {}
    for line in git(repo, "worktree", "list", "--porcelain").splitlines() + [""]:
        if not line:
            if cur:
                out.append(cur)
            cur = {}
        elif " " in line:
            k, v = line.split(" ", 1)
            cur[k] = v
        else:
            cur[line] = True
    return out


def du_mb(path):
    res = subprocess.run(["du", "-sk", str(path)], capture_output=True, text=True).stdout.split()
    return int(res[0]) // 1024 if res else 0


def changes_vs_base(repo, path, sha, base):
    """(changed, behind, upstream) for one worktree against `base`, or None when there is no merge base or git
    fails. changed = files committed on top of the branch point plus its uncommitted ones, minus the worktree's
    untracked plans and link markers; behind = commits `base` gained since the branch point; upstream = the
    files `base` moved that this worktree also changed."""
    def failed(what, res):                 # say why the row shows "-" instead of hiding the failure
        print(f"wt: note: {path.name}: git {what} failed (rc {res.returncode}): {res.stderr.strip()[:160]}",
              file=sys.stderr)
        return None

    mb_res = subprocess.run(["git", "-C", str(repo), "merge-base", sha, base], capture_output=True, text=True)
    if mb_res.returncode != 0 or not mb_res.stdout.strip():
        return failed(f"merge-base {base}", mb_res)
    mb = mb_res.stdout.splitlines()[0]
    committed = subprocess.run(["git", "-C", str(repo), "diff", "--name-only", mb, sha],
                               capture_output=True, text=True)
    if committed.returncode != 0:
        return failed("diff (branch)", committed)
    changed = {p for p in committed.stdout.splitlines() if p}
    status = subprocess.run(["git", "-C", str(path), "status", "--porcelain", "--no-renames",
                             "--untracked-files=all"], capture_output=True, text=True)
    if status.returncode != 0:
        return failed("status", status)
    for line in status.stdout.splitlines():
        if len(line) > 3 and line[3:].strip():
            changed.add(line[3:].strip())
    changed = {p for p in changed if not ("/" not in p and Path(p).match(PLAN_GLOB))}
    gitdir = subprocess.run(["git", "-C", str(path), "rev-parse", "--path-format=absolute", "--git-dir"],
                            capture_output=True, text=True)
    if gitdir.returncode == 0:
        mark = Path(gitdir.stdout.strip()) / MARK
        if mark.is_file():
            changed -= {rel.strip() for rel in mark.read_text(errors="replace").splitlines() if rel.strip()}
    behind_res = subprocess.run(["git", "-C", str(repo), "rev-list", "--count", f"{mb}..{base}"],
                                capture_output=True, text=True)
    if behind_res.returncode != 0:
        return failed(f"rev-list {base}", behind_res)
    behind = int(behind_res.stdout.strip() or 0)
    moved = subprocess.run(["git", "-C", str(repo), "diff", "--name-only", mb, base],
                           capture_output=True, text=True)
    if moved.returncode != 0:
        return failed(f"diff ({base})", moved)
    upstream = {p for p in moved.stdout.splitlines() if p} & changed
    return changed, behind, upstream


def cmd_list(args):
    repo = main_checkout(args.repo or os.getcwd())
    conf = load_conf()
    base = default_base(repo, conf)
    print(f"{'worktree':48s} {'branch':40s} {'MB':>6s} {'dirty':>5s} {'behind':>6s}  merged into {base}")
    rows = []
    for w in worktrees(repo):
        path = Path(w["worktree"])
        branch = w.get("branch", "(detached)").replace("refs/heads/", "")
        dirty = len([l for l in git(path, "status", "--porcelain", check=False).splitlines() if l.strip()])
        info = changes_vs_base(repo, path, w["HEAD"], base) if (path != repo and w.get("HEAD")) else None
        merged = "-"
        if branch != "(detached)" and path != repo:
            r = subprocess.run(["git", "-C", str(repo), "merge-base", "--is-ancestor", branch, base])
            merged = "yes" if r.returncode == 0 else "no"
        name = "(main checkout)" if path == repo else str(path.relative_to(repo)) if repo in path.parents else str(path)
        behind = "-" if info is None else str(info[1])
        print(f"{name[:48]:48s} {branch[:40]:40s} {du_mb(path) if path != repo else 0:6d} {dirty:5d} "
              f"{behind:>6s}  {merged}")
        if path != repo:
            rows.append((path.name, info))
    overlaps = {}
    for name, info in rows:
        for p in (info[0] if info else ()):
            overlaps.setdefault(p, set()).add(name)
    for p in sorted(overlaps):
        if len(overlaps[p]) >= 2:
            print(f"OVERLAP {p}: {', '.join(sorted(overlaps[p]))}")
    for name, info in rows:
        if info is None or info[1] <= 0:
            continue
        upstream = "; also changed upstream: " + ", ".join(sorted(info[2])) if info[2] else ""
        print(f"DRIFT {name}: {base} moved {info[1]} commit(s) since the branch point{upstream}")
    return 0


def plan_files(wt):
    """Sorted names of the untracked or ignored PLAN_*.md files at the worktree top level (a tracked plan is
    the ticket's own work and is never touched)."""
    out = []
    for p in sorted(wt.glob(PLAN_GLOB)):
        if not p.is_file() or p.is_symlink():
            continue
        res = subprocess.run(["git", "-C", str(wt), "ls-files", "--error-unmatch", "--", p.name],
                             capture_output=True)
        if res.returncode == 1:            # 1 = not in the index (untracked or ignored); 0 = tracked
            out.append(p.name)
    return out


def archive_plans(wt, ticket, plans):
    """Copy each plan to <git-common-dir>/concord/plans/<ticket>/ (never move) and return the destinations.
    An identical archived copy is left as is; a different one gets a timestamp suffix (-2, -3, ... when that
    name is taken too). The destination folder is created inside the error handling so a failure reports
    cleanly rather than as a traceback."""
    if not plans:
        return []
    common = Path(git(wt, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    dest_dir = common / "concord" / "plans" / ticket
    out = []
    for name in plans:
        src, dst = wt / name, dest_dir / name
        try:
            dest_dir.mkdir(parents=True, exist_ok=True)
            if dst.exists() and dst.read_bytes() == src.read_bytes():
                out.append(dst)
                continue
            if dst.exists():
                stamp = f"{datetime.now():%Y%m%d-%H%M%S}"
                stem, suffix = Path(name).stem, Path(name).suffix
                dst = dest_dir / f"{stem}.{stamp}{suffix}"
                n = 2
                while dst.exists():
                    dst = dest_dir / f"{stem}.{stamp}-{n}{suffix}"
                    n += 1
            shutil.copy2(src, dst)
            out.append(dst)
        except OSError as e:
            raise OSError(f"{name}: {e.strerror or e}") from e
    return out


def cmd_done(args):
    repo = main_checkout(args.repo or os.getcwd())
    ticket = safe_name(args.ticket)
    wt = repo / ".claude" / "worktrees" / ticket
    if not wt.exists():
        die(f"no worktree {wt}")
    gitdir = Path(git(wt, "rev-parse", "--path-format=absolute", "--git-dir"))
    mark_path = gitdir / MARK
    made = [rel for rel in mark_path.read_text(errors="replace").splitlines() if rel.strip()] \
        if mark_path.exists() else []
    plans = plan_files(wt)                 # untracked plans are ours to archive, not uncommitted work to commit
    # A link counts as ours only while it is still a symlink; a real file or folder the user put at that path is
    # their work and goes through the uncommitted and ignored-file checks (which refuse, or need --force).
    ours = {rel for rel in made if rel.startswith(".claude/") or (wt / rel).is_symlink()} | set(plans)
    # Every check runs before anything is touched, so a refusal leaves the worktree fully working.
    dirty = [line for line in git(wt, "status", "--porcelain", check=False).splitlines()
             if line.strip() and line[3:].rstrip("/") not in ours]
    if dirty and not args.force:
        die(f"{wt} has uncommitted changes ({len(dirty)}): commit or push them first; nothing removed.\n  "
            + "\n  ".join(dirty[:10]))
    lost = [p for p in (line[3:] for line in git(wt, "status", "--porcelain", "--ignored", check=False).splitlines()
                        if line.startswith("!! "))
            if p.rstrip("/") not in ours and not DISPOSABLE.intersection(p.rstrip("/").split("/"))]
    if lost and not args.force:
        die(f"{wt} holds ignored files that `git worktree remove` would delete; move what you need, then rerun "
            f"(--force deletes them):\n  " + "\n  ".join(f"{du_mb(wt / p):6d} MB  {p}" for p in lost[:15]))
    blocked = protected(wt)
    if blocked:
        die("this session's sandbox write-protects files inside the worktree (Claude Code protects the .claude "
            "settings of a worktree it entered), so removal would stop halfway; nothing removed. Run this command "
            "unsandboxed or from a terminal:\n  " + "\n  ".join(blocked))
    try:
        archived = archive_plans(wt, ticket, plans)
    except OSError as e:
        die(f"could not archive {e}; nothing removed")
    for name in plans:                     # the archive holds them now
        try:
            (wt / name).unlink(missing_ok=True)
        except OSError as e:
            die(f"could not remove {name} from the worktree ({e.strerror or e}); the archived copies are in "
                f"{archived[0].parent}; worktree not removed")
    for rel in made:                       # only the symlinks this tool created; their targets stay untouched
        if (wt / rel).is_symlink():
            (wt / rel).unlink()
    # The plans live in the archive now, so git's own cleanliness check applies and --force stays the user's call.
    res = subprocess.run(["git", "-C", str(repo), "worktree", "remove",
                          *(["--force"] if args.force else []), str(wt)], capture_output=True, text=True)
    if res.returncode != 0:
        restore_failed = []
        for name, dst in zip(plans, archived):   # put back what the failed removal would otherwise have cost
            try:
                shutil.copy2(dst, wt / name)
            except OSError:
                restore_failed.append(f"{name} (archive: {dst})")
        relink_failed = cmd_relink(repo, wt, made)
        detail = ""
        if restore_failed or relink_failed:
            parts = []
            if restore_failed:
                parts.append("plans not restored: " + ", ".join(restore_failed))
            if relink_failed:
                parts.append("links not restored: " + ", ".join(relink_failed))
            detail = " (" + "; ".join(parts) + ")"
        die(f"git worktree remove refused: {res.stderr.strip()}{detail}")
    git(repo, "worktree", "prune", check=False)
    for dst in archived:
        print(f"archived: {dst}")
    print(f"removed {wt} (branch kept; linked folders in the main checkout untouched)")
    return 0


DISPOSABLE = {"__pycache__", ".pytest_cache", ".ruff_cache", ".mypy_cache", "build", ".DS_Store", ".claude"}


def protected(wt):
    """Paths under the worktree that this process may not delete (sandbox): probe each file under .claude/ by
    opening it for append (writes nothing) and each directory by creating and removing a probe file."""
    out, base = [], wt / ".claude"
    if not base.is_dir():
        return out
    for dirpath, dirnames, filenames in os.walk(base):
        d = Path(dirpath)
        probe = d / ".wt-probe"
        try:
            os.close(os.open(probe, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
            probe.unlink()
        except FileExistsError:
            pass
        except OSError:
            out.append(str(d.relative_to(wt)) + "/")
            dirnames[:] = []
            continue
        for name in filenames:
            p = d / name
            if p.is_symlink():
                continue
            try:
                with open(p, "a"):
                    pass
            except OSError:
                out.append(str(p.relative_to(wt)))
    return out


def cmd_relink(repo, wt, made):
    """Recreate the worktree links this tool made; returns the names it could not restore (never raises)."""
    failed = []
    for rel in made:
        src, dst = repo / rel, wt / rel
        if not rel.startswith(".claude/") and src.exists() and not dst.exists() and not dst.is_symlink():
            try:
                os.symlink(src, dst)
            except OSError:
                failed.append(rel)
    return failed


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    n = sub.add_parser("new"); n.add_argument("ticket"); n.add_argument("--repo"); n.add_argument("--base")
    n.add_argument("--branch"); n.add_argument("--link", action="append"); n.add_argument("--no-fetch", action="store_true")
    l = sub.add_parser("list"); l.add_argument("--repo")
    d = sub.add_parser("done"); d.add_argument("ticket"); d.add_argument("--repo"); d.add_argument("--force", action="store_true")
    args = ap.parse_args()
    return {"new": cmd_new, "list": cmd_list, "done": cmd_done}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
