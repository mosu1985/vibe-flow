#!/usr/bin/env python3
"""session-store.py check | fix --yes [--to DIR]

Claude Code keeps session data (auto memory, saved tool outputs, transcripts) in
<config dir>/projects, the config dir being $CLAUDE_CONFIG_DIR or ~/.claude.

What it detects: a launcher that gives each profile its own CLAUDE_CONFIG_DIR and
links the profile's `projects` back to ~/.claude/projects. The path Claude asks for
then does not name `.claude`, but the file it resolves to sits under `.claude`, a
protected directory. For such a write Claude Code does not let the auto-mode
classifier decide: it stops and asks a person, and neither allow rules nor
auto-mode rules change that. Every Bash write an agent makes to its memory or to a
saved tool output waits for a click, so agents cannot work unattended.

The fix: rename the real directory, on the same disk, to a place outside `.claude`
and leave a link in its old place. The launcher's link keeps working and now
resolves to a path that is not protected. Memory and history stay shared. `fix`
prints the exact undo command for the paths it used.

  check       exit 0: fine or nothing to do · exit 3: affected (prints the fix)
  fix --yes   exit 0: fixed or nothing to do · exit 4: refused or rolled back, nothing
              changed (says why) · exit 5: moved but not linked (prints recovery steps)
"""
import os
import sys

EXIT_AFFECTED, EXIT_REFUSED, EXIT_RACE = 3, 4, 5


def config_dir():
    return os.path.abspath(os.path.expanduser(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join("~", ".claude")))


def names_claude(path):
    """True when a component of the path is a `.claude` directory."""
    parts = os.path.normcase(os.path.abspath(path)).replace("\\", "/").split("/")
    return ".claude" in parts


def diagnose():
    """(status, store, real) with status: absent | ok | affected."""
    store = os.path.join(config_dir(), "projects")
    if not os.path.exists(store):
        return "absent", store, None
    real = os.path.realpath(store)
    # A store path that itself names `.claude` (plain ~/.claude) is the default: its
    # writes go to the classifier in auto mode. Only the link case forces a prompt.
    if names_claude(store) or not names_claude(real):
        return "ok", store, real
    return "affected", store, real


def default_target():
    return os.path.join(os.path.expanduser("~"), "claude-projects")


def check(target):
    status, store, real = diagnose()
    if status == "absent":
        print("status=ok (no session store yet: %s)" % store)
        return 0
    if status == "ok":
        print("status=ok (%s)" % real)
        return 0
    print("status=affected")
    print("store:       %s" % store)
    print("resolves to: %s  (under a protected .claude directory)" % real)
    print("effect:      in auto mode every Bash write to agent memory or saved tool outputs stops for a person's click")
    print("fix:         session-store.py fix --yes  (renames %s to %s and leaves a link)" % (real, target))
    return EXIT_AFFECTED


def refuse(msg):
    print("refused: %s" % msg)
    return EXIT_REFUSED


def fix(target):
    status, store, real = diagnose()
    if status != "affected":
        print("status=ok (nothing to fix)")
        return 0
    if os.name == "nt":
        return refuse("on Windows a link needs extra rights; move %s out of .claude by hand" % real)
    # Move only the session store itself: a link to `.claude` as a whole would carry
    # settings, hooks and plugins out of the protected directory too.
    if os.path.basename(real) != "projects":
        return refuse("%s is not a `projects` folder; move only the session store, by hand" % real)
    parent = os.path.dirname(target)
    if not os.path.isdir(parent):
        return refuse("the folder %s does not exist" % parent)
    if names_claude(target) or names_claude(os.path.realpath(parent)):
        return refuse("the target %s is itself under .claude" % target)
    if os.path.lexists(target):
        return refuse("%s already exists; pick another place with --to" % target)
    if os.path.islink(real) or not os.path.isdir(real):
        return refuse("%s is not a plain directory" % real)
    # Same disk only: a rename is instant and atomic for sessions that are writing; a
    # cross-disk move copies gigabytes while they keep writing to the old place.
    if os.stat(real).st_dev != os.stat(parent).st_dev:
        return refuse("%s and %s are on different disks; pick a target on the same disk with --to" % (real, parent))
    os.rename(real, target)
    try:
        os.symlink(target, real)
    except FileExistsError:
        print("race: a running session recreated %s between the move and the link." % real)
        print("Your data is in %s. Move what is in %s into it, then replace %s with a link to it." % (target, real, real))
        return EXIT_RACE
    except OSError as e:
        try:
            os.rename(target, real)
        except OSError:
            print("moved but not linked (%s), and moving back failed." % e)
            print("Your data is in %s. Sessions need %s: make it a link to %s, or move the folder back." % (target, real, target))
            return EXIT_RACE
        return refuse("could not create the link (%s); moved back, nothing changed" % e)
    print("status=fixed")
    print("moved:  %s -> %s" % (real, target))
    print("linked: %s -> %s" % (real, target))
    print("store now resolves to %s" % os.path.realpath(store))
    print("undo, while no session is writing: rm '%s' && mv '%s' '%s'" % (real, target, real))
    return 0


def main(argv):
    args = list(argv)
    target = default_target()
    if "--to" in args:
        i = args.index("--to")
        if i + 1 >= len(args):
            print("usage: session-store.py check | fix --yes [--to DIR]", file=sys.stderr)
            return 2
        target = os.path.abspath(os.path.expanduser(args[i + 1]))
        del args[i:i + 2]
    if args == ["check"]:
        return check(target)
    if args and args[0] == "fix":
        if "--yes" not in args[1:]:
            print("fix moves the session data folder: run it only after the user's explicit yes, with --yes", file=sys.stderr)
            return 2
        return fix(target)
    print("usage: session-store.py check | fix --yes [--to DIR]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
