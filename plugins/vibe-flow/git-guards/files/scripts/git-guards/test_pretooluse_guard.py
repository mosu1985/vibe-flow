#!/usr/bin/env python3
"""Tests for the PreToolUse guard: what it blocks and what it MUST let through.

A false rejection here is worse than a miss — people rip out the whole guard
because of it, real value included. The first version of the hook rejected
`echo "…"` with these words inside and blocked its own fix, so most of the
cases below are about what it MUST let through.

Run: python3 scripts/git-guards/test_pretooluse_guard.py
(in the kit: python3 files/scripts/git-guards/test_pretooluse_guard.py)

The guard runs through THIS interpreter (sys.executable), never through a `bash`
found on PATH: on Windows that can be the WSL launcher, and the floor job runs
this file under Python 3.9 precisely to run the guard under 3.9. Stays
3.9-compatible itself. A decision is read by the hook protocol (rc 2 or a JSON
"deny"); a crash or unparsable output is a failure, never an "allow".
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))   # the project, or the kit's files/
WINDOWS = os.name == "nt"


def _hooks_dir() -> str:
    # A project keeps the hooks in .claude/hooks; the kit in files/claude/hooks.
    for d in (os.path.join(ROOT, ".claude", "hooks"), os.path.join(ROOT, "claude", "hooks")):
        if os.path.isfile(os.path.join(d, "monitorex_git_guard.py")):
            return d
    return os.path.join(ROOT, ".claude", "hooks")


HOOKS = _hooks_dir()
GUARD = os.path.join(HOOKS, "monitorex_git_guard.py")
# A cwd outside every repository (was /private/tmp; kept as is on POSIX).
OUTSIDE = os.path.realpath(tempfile.gettempdir()) if WINDOWS else "/private/tmp"

STAGE = "git" + " add"          # assembled from pieces, otherwise the hook blocks
COMMIT = "git" + " commit"      # running the tests themselves


def fwd(path: str) -> str:
    """A path inside a shell command string: forward slashes on every OS."""
    return path.replace("\\", "/")


CASES = [
    # (command, whether we expect deny)
    (f"{STAGE} lib/x.ts", True),
    (f"{COMMIT} -m x", True),
    ("git -C {MAIN} add f.ts", True),
    (f"MONITOREX_ACTOR=x {STAGE} f.ts", True),
    (f"npm test && {STAGE} f.ts", True),
    # --- bypass marks are set only by a human ---
    ("scripts/git-allow-delete.sh add a.txt", True),
    ("echo yes | scripts/git-allow-delete.sh add a.txt", True),
    ("bash scripts/git-allow-push.sh add abc123", True),
    (f"cd {fwd(ROOT)} && ./scripts/git-confirm.sh commit", True),
    ("sh -c 'echo yes | scripts/git-confirm.sh commit'", True),
    ("MONITOREX_ACTOR=x scripts/git-allow-delete.sh add --yes a.txt", True),
    # --- must pass ---
    (f'echo "=== {COMMIT} right now ==="', False),
    (f"echo {STAGE} | grep git", False),
    ("git status", False),
    ("git log --oneline -5", False),
    ("git diff --cached", False),
    ("git rev-parse HEAD", False),
    ("ls -la", False),
    (f"grep -rn '{STAGE}' docs/", False),
    ("scripts/git-allow-delete.sh list", False),
    ("scripts/git-allow-push.sh", False),
    ("scripts/git-confirm.sh status", False),
    ("scripts/git-confirm.sh clear", False),
    ("grep -n add scripts/git-allow-delete.sh", False),
    ("bash -n scripts/git-allow-push.sh", False),
    ("echo 'scripts/git-confirm.sh commit'", False),
    # --- release-gate: only the release-gate agent sets the verdict ---
    ("scripts/release-gate.sh override", True),
    ("scripts/release-gate.sh override --yes", True),
    ("scripts/release-gate.sh pass --report /tmp/r.md", True),       # main session
    ("bash scripts/release-gate.sh pass --report r.md", True),
    ("echo pass > .git/monitorex-locks/release-gate/abc", True),
    ("touch .git/monitorex-locks/release-gate/abc", True),
    ("scripts/release-gate.sh", False),
    ("scripts/release-gate.sh scope", False),
    ("scripts/release-gate.sh status", False),
    ("ls .git/monitorex-locks/release-gate", False),
    ("cat .git/monitorex-locks/release-gate/abc", False),
    ("grep -n pass scripts/release-gate.sh", False),
    # wrappers and writes that bypass the script (release-gate findings, round 1)
    ("env X=1 scripts/release-gate.sh pass --head HEAD --report r.md", True),
    ("command scripts/release-gate.sh pass --head HEAD --report r.md", True),
    ("nohup scripts/release-gate.sh pass --head HEAD --report r.md", True),
    ("scripts/release-gate.sh status > .git/monitorex-locks/release-gate/abc", True),
    ("cp r.md .git/monitorex-locks/release-gate/abc", True),
    ("printf x >> .git/monitorex-locks/release-gate/abc", True),
    # reading with stderr/stdout redirection is NOT a write to the gate
    ("ls .git/monitorex-locks/release-gate 2>/dev/null", False),
    ("ls .git/monitorex-locks/release-gate 2>&1 | head", False),
    ("cat .git/monitorex-locks/release-gate/abc > /tmp/copy", False),
    ("echo 'see monitorex-locks/release-gate dir'", False),
    ("cp a.ts /Users/x/bomond-wt/release-gate/lib/a.ts", False),   # a tree with that name
    # human-only bypass via wrappers (release-gate findings, round 2)
    ("env X=1 scripts/release-gate.sh override --yes", True),
    ("nohup scripts/release-gate.sh override --yes", True),
    ("command scripts/release-gate.sh override --yes", True),
    ("env -u HOME scripts/release-gate.sh override --yes", True),
    ("nohup scripts/git-confirm.sh commit", True),
    ("env scripts/git-allow-push.sh add abc123", True),
    ("echo r.md | xargs scripts/release-gate.sh pass --head HEAD --report", True),
    ("printf x >| .git/monitorex-locks/release-gate/abc", True),
    ("env scripts/release-gate.sh status", False),
    # push bypassing pre-push is for humans only
    ("git push --no-verify origin HEAD", True),
    ("git push origin HEAD --no-verify", True),
    ("git -C /tmp/wt push --no-verify", True),
    ("env X=1 git push --no-verify", True),
    ("git -c core.hooksPath=/dev/null push origin HEAD", True),
    ("git -ccore.hooksPath=/dev/null push", True),
    ("git push origin HEAD", False),
    ("git push -u origin wt/x", False),
    ("git push -n origin HEAD", False),
    ('echo "git push --no-verify"', False),
    # release-gate findings, round 3
    ("scripts/release-gate.sh --report scope pass --head abc --report r.md", True),
    ("scripts/release-gate.sh --report status override --yes", True),
    ("scripts/release-gate.sh --report r.md status", False),
    ("git push --no-verif origin HEAD", True),
    ("git push --no-veri", True),
    ("GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/x git push", True),
    ("export GIT_CONFIG_PARAMETERS=x; git push", True),
    ("git --config-env=core.hooksPath=HP push", True),
    ("git config core.hooksPath /dev/null", True),
    ("git config --local core.hookspath /tmp/none", True),
    ("git config --unset core.hooksPath", True),
    ("git config --get core.hooksPath", False),
    ("git config core.hooksPath", False),
    ("git push --no-thin origin HEAD", False),
    # release-gate findings (hardening, round 1): writing the verdict with redirects
    ("cp /tmp/v .git/monitorex-locks/release-gate/abc 2>/dev/null", True),
    ("tee < /tmp/v .git/monitorex-locks/release-gate/abc", True),
    ("tee <<< 'verdict=pass' .git/monitorex-locks/release-gate/abc", True),
    ("cat /tmp/v | tee '' .git/monitorex-locks/release-gate/abc", True),
    ("mv /tmp/v .git/monitorex-locks/release-gate/abc 2>&1", True),
    ("cp /tmp/v .git/monitorex-locks/release-gate/abc &>/dev/null", True),
    ("cp /tmp/v .git/monitorex-locks/release-gate/abc 2> /dev/null", True),
    ('X="a override"; scripts/release-gate.sh --head $X scope --yes', True),
    ("scripts/release-gate.sh --head `echo a override` scope", True),
    ("scripts/release-gate.sh --head {a,override} scope --yes", True),
    ("scripts/release-gate.sh --report {r.md,pass} --head abc", True),
    ("scripts/release-gate.sh --report * status", True),
    ("scripts/release-gate.sh --report /tmp/claude-501/r_3.md status", False),
    ("git config get core.hooksPath", False),
    ("git config --file .git/config --get core.hooksPath", False),
    ("git config -f .git/config.worktree --get core.hooksPath", False),
    ("git config --type path --get core.hooksPath", False),
    ("git config --list --show-origin", False),
    ("grep -rn GIT_CONFIG_GLOBAL scripts && git push origin HEAD", False),
    ("git push origin HEAD; echo GIT_CONFIG_SYSTEM", False),
    ("git -C /tmp/webhookpath-fix push origin HEAD", False),
    ("GIT_CONFIG_GLOBAL=/tmp/g git push", True),
    ("cp /tmp/x .git/monitorex-locks/release-gate/abc", True),
    ("tee .git/monitorex-locks/release-gate/abc < /tmp/x", True),
    ("grep -n no-verify CLAUDE.md", False),
    # --- more wrappers: source / . / nice / sudo / caffeinate / arch / stdbuf (L6) ---
    ("nice scripts/git-confirm.sh feat", True),
    ("nice -n 5 scripts/git-confirm.sh feat --yes", True),
    ("source scripts/release-gate.sh pass --report r.md", True),
    (". scripts/git-confirm.sh feat", True),
    ("sudo -u root scripts/git-allow-push.sh add abc123", True),
    ("caffeinate -i scripts/git-confirm.sh feat", True),
    ("arch -arm64 scripts/git-confirm.sh feat", True),
    ("stdbuf -o L scripts/git-confirm.sh feat", True),
    ("stdbuf -oL scripts/git-allow-delete.sh add a.txt", True),
    ("env -i scripts/git-confirm.sh feat", True),
    ("source ~/.zshrc", False),
    ("nice -n 5 npm test", False),
    (". ./venv/bin/activate", False),
    # --- rewriting what origin/<protected> means (C1-r2 + refs/remotes) ---
    ("git -c url.X.insteadOf=Y fetch origin", True),
    ("git -c remote.origin.url=/tmp/x fetch", True),
    ("git -curl.X.insteadOf=Y fetch origin", True),
    ("git --config-env=url.X.insteadOf=ENV fetch", True),
    ("git --config-env url.X.pushInsteadOf=ENV push origin HEAD", True),
    ("GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.x.insteadOf GIT_CONFIG_VALUE_0=y git fetch", True),
    ("git remote set-head origin x", True),
    ("git remote set-head origin -a", False),
    ("git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/wt/x", True),
    ("git symbolic-ref -d refs/remotes/origin/HEAD", True),
    ("git update-ref refs/remotes/origin/main HEAD", True),
    ("git update-ref -d refs/remotes/origin/main", True),
    ("git fetch origin wt/x:refs/remotes/origin/main", True),
    ("git fetch . HEAD:refs/remotes/origin/main", True),
    ("git -c core.quotepath=false log -1", False),
    ("git -c color.ui=never diff", False),
    ("git remote -v", False),
    ("git remote get-url origin", False),
    ("git symbolic-ref refs/remotes/origin/HEAD", False),
    ("git symbolic-ref --short -q refs/remotes/origin/HEAD", False),
    ("git fetch origin", False),
    ("git fetch -q --prune origin", False),
    ("git update-ref refs/monitorex/recovery/x HEAD", False),
    # --- any write into monitorex-locks/ and monitorex-hooks/ (M2, H4, M5) ---
    ("rm .git/monitorex-locks/CONFIRM", True),
    ('rm -f "$(git rev-parse --git-common-dir)/monitorex-locks/CONFIRM"', True),
    ('printf "target=feat\\n" > "$(git rev-parse --git-common-dir)"/monitorex-locks/CONFIRM', True),
    ("echo ts=1 >> .git/monitorex-locks/plan-approved/p.md", True),
    ("printf x &> .git/monitorex-locks/allow-push", True),
    ("chmod -x .git/monitorex-hooks/pre-push", True),
    ("cp /tmp/old .git/monitorex-hooks/pre-push", True),
    ("unlink .git/monitorex-hooks/pre-commit", True),
    ("truncate -s 0 .git/monitorex-hooks/pre-push", True),
    ("sed -i '' 's/a/b/' .git/monitorex-hooks/pre-push", True),
    ("perl -pi -e 's/a/b/' .git/monitorex-hooks/pre-push", True),
    ("cd .git/monitorex-locks && rm CONFIRM", True),
    ("rm -rf .git/monitorex-*/CONFIRM", True),
    ("mkdir -p .git/monitorex-locks/plan-approved/x.md", True),
    ("rmdir .git/monitorex-locks/claims/issue-7", True),
    ("nice rm .git/monitorex-locks/CONFIRM", True),
    ("ls -la .git/monitorex-locks", False),
    ("cat .git/monitorex-hooks/.source", False),
    ("sed -n 1,5p .git/monitorex-hooks/pre-push", False),
    ("grep -rn feat .git/monitorex-locks 2>/dev/null", False),
    ("diff .git/monitorex-hooks/pre-push githooks/pre-push > /tmp/d.txt", False),
    ("shasum -a 256 .git/monitorex-hooks/pre-push 2>&1", False),
    ("echo 'a > .git/monitorex-locks/x'", False),
    ("scripts/git-lock.sh release", False),
    ("bash scripts/install-git-guards.sh", False),
    ("scripts/wt-new.sh my-task", False),
    ("scripts/wt-done.sh my-task", False),
    # --- security review of the code, 07.11 (HIGH-1): cd/pushd/variables + redirects ---
    ("cd .git/monitorex-locks && echo target=feat > CONFIRM", True),
    ("pushd .git/monitorex-locks && echo target=feat > CONFIRM", True),
    ("pushd -q .git/monitorex-locks; printf x >> CONFIRM; popd", True),
    ("D=$(git rev-parse --git-common-dir)/monitorex-locks; echo target=feat > $D/CONFIRM", True),
    ('D="$(git rev-parse --git-common-dir)/monitorex-locks"; printf x > "${D}/CONFIRM"', True),
    ("export D=.git/monitorex-locks && tee $D/CONFIRM < /tmp/x", True),
    ("D=.git/monitorex-locks; cd $D && rm CONFIRM", True),
    ('cd .git/monitorex-locks/release-gate && printf "verdict=pass\\n" > "$(git rev-parse HEAD^{tree})"', True),
    ('cd "$(git rev-parse --git-common-dir)/monitorex-locks" && echo x > CONFIRM', True),
    ("cd .git/monitorex-hooks && cp /tmp/old pre-push", True),
    ("echo x > .git/monitorex-$X/CONFIRM", True),
    ("cd .git/monitorex-locks && ls -la", False),
    ("cd .git/monitorex-locks && cat CONFIRM > /tmp/copy", False),
    ("cd .git/monitorex-locks && cat CONFIRM 2>/dev/null", False),
    ("D=.git/monitorex-locks; ls $D 2>/dev/null", False),
    ("cd /tmp && echo x > notes.txt", False),
    # --- MEDIUM-2: interpreters naming the guard's directories ---
    ("""python3 -c "open('.git/monitorex-locks/CONFIRM','w').write('target=feat')" """, True),
    ("node -e \"require('fs').writeFileSync('.git/monitorex-locks/CONFIRM','x')\"", True),
    ("perl -e 'open F,\">.git/monitorex-locks/CONFIRM\"'", True),
    ("ruby -e 'File.write(\".git/monitorex-locks/CONFIRM\",\"x\")'", True),
    ("""sh -c 'echo target=feat > "$0"' .git/monitorex-locks/CONFIRM""", True),
    ("""bash -c 'printf x > "$1"' _ .git/monitorex-hooks/pre-push""", True),
    ("awk 'BEGIN{print \"x\" > \".git/monitorex-locks/CONFIRM\"}'", True),
    ("python3 -c 'print(1)'", False),
    ("node scripts/build.mjs", False),
    ("bash -c 'echo hi'", False),
    # --- MEDIUM-1 / LOW-5: remote-tracking refs and origin itself ---
    ("git fetch . HEAD:remotes/origin/main", True),
    ("git fetch origin +wt/x:remotes/origin/main", True),
    ("git pull . HEAD:refs/remotes/origin/main", True),
    ("""echo "update refs/remotes/origin/main HEAD" | git update-ref --stdin""", True),
    ("git update-ref --stdin < /tmp/cmds", True),
    ("git remote set-url origin .", True),
    ("git remote rename origin old", True),
    ("git remote remove origin", True),
    ("git remote rm origin", True),
    ("git config remote.origin.url /tmp/fake.git", True),
    ("git config set remote.origin.fetch +refs/heads/*:refs/remotes/origin/*", True),
    ("git config --unset remote.origin.url", True),
    ("git config --remove-section remote.origin", True),
    ("git config url./tmp/fake.git.insteadOf https://github.com/x/y.git", True),
    ("cp /tmp/sha .git/refs/remotes/origin/main", True),
    ("echo abc > .git/refs/remotes/origin/main", True),
    ("git config --get remote.origin.url", False),
    ("git config remote.origin.url", False),
    ("git remote add snapshot .", False),
    ("git fetch origin main:main", False),
    ("git fetch origin", False),
    ("cat .git/refs/remotes/origin/main", False),
    # --- out of the diff: aliases and eval ---
    ("git -c alias.p='push --no-verify' p", True),
    ("git -c alias.st=status st", True),
    ("git --config-env=alias.p=X p", True),
    ("git config alias.p 'push --no-verify'", True),
    ('eval "git push --no-verify"', True),
    ("eval 'git status'", True),
    ('eval "$(ssh-agent -s)"', False),
    ("git config --get alias.st", False),
    # --- HIGH-1′: allowlist of readers instead of a list of writers ---
    ("printf target=feat | sort -o .git/monitorex-locks/CONFIRM", True),
    ("printf 'verdict=pass' | sort -o .git/monitorex-locks/release-gate/abc", True),
    ("cd .git/monitorex-locks && sort -o CONFIRM /tmp/x", True),
    ("cd .git/monitorex-locks && echo x > ~+/CONFIRM", True),
    ("cd .git/monitorex-locks && cd /tmp && echo x > ~-/CONFIRM", True),
    ("curl -o .git/monitorex-locks/x https://example.com", True),
    ("wget -O .git/monitorex-locks/x https://example.com", True),
    ("tar -C .git/monitorex-hooks -xf /tmp/old.tar", True),
    ("vim -es -c 'wq' .git/monitorex-locks/CONFIRM", True),
    ("ex -sc 'wq' .git/monitorex-hooks/pre-push", True),
    ("git -C .git/monitorex-locks archive -o x HEAD", True),
    ("find .git/monitorex-locks -name CONFIRM -delete", True),
    ("find .git/monitorex-hooks -exec chmod -x {} ;", True),
    ("sed -n 'w .git/monitorex-locks/CONFIRM' /tmp/x", True),
    ("X=1 sort -o .git/monitorex-locks/CONFIRM /tmp/x", True),
    ("cp /tmp/x .git/refs/remotes/origin/wt", True),
    ("sort -o .git/refs/remotes/origin/main /tmp/x", True),
    ('CMD="git push --no-verify"; eval $CMD', True),
    ("C='git push origin HEAD --no-verif'; $C", True),
    ("cat .git/monitorex-locks/CONFIRM > /tmp/x", False),
    ("ls .git/monitorex-locks", False),
    ("find .git/monitorex-locks -name x", False),
    ("head -5 .git/monitorex-hooks/pre-push | wc -l", False),
    ("rg -n feat .git/monitorex-locks", False),
    ("stat -f %m .git/monitorex-locks/CONFIRM", False),
    ("test -f .git/monitorex-locks/CONFIRM && echo yes", False),
    ("cd ~ && echo x > notes.txt", False),
    ("echo x > ~/notes.txt", False),
    ("git remote set-head origin --auto", False),
    ("scripts/wt-new.sh --issue 12", False),
    ("scripts/release-gate.sh status", False),
    ("scripts/git-lock.sh status", False),
    ("git-guards/../scripts/git-confirm.sh status", False),
    ("CMD='git status'; $CMD", False),
    ("git push origin HEAD", False),
    # --- vibe-flow 1.3.0: case and .exe forms on EVERY OS (security S2, A1) ---
    # APFS and NTFS are case-insensitive: `.git/MONITOREX-LOCKS` is the guard's
    # directory, and `GIT`/`git.exe` run git. A forged release-gate verdict through
    # an upper-case path used to be accepted by pre-push.
    ("printf x > .git/MONITOREX-LOCKS/release-gate/abc", True),
    ("cp /tmp/v .git/MONITOREX-LOCKS/RELEASE-GATE/t", True),
    ("GIT" + " add .", True),
    ("Git" + " commit -m x", True),
    ("git.exe" + " add f.ts", True),
    ("GIT.EXE" + " commit -m x", True),
    ("/usr/bin/GIT" + " add f.ts", True),
    ("'C:\\Program Files\\Git\\cmd\\git.exe'" + " add f.ts", True),
    ("scripts/Git-Confirm.sh feat --yes", True),
    ("bash scripts/GIT-CONFIRM.SH feat --yes", True),
    ("bash scripts/RELEASE-GATE.sh pass --report r.md", True),
    ("GIT push --no-verify", True),
    ('BASH -c "' + STAGE + ' ."', True),
    ("SED -i '' 's/a/b/' .git/monitorex-hooks/pre-push", True),
    ("FIND .git/monitorex-locks -name CONFIRM -delete", True),
    ("NOHUP scripts/git-confirm.sh feat", True),
    ("bash.exe scripts/git-confirm.sh feat --yes", True),
    ("bash 'scripts\\git-confirm.sh' feat --yes", True),
    ("sh.exe scripts/release-gate.sh override --yes", True),
    ("cd {MAIN}/src && " + STAGE + " .", True),
    # Quotes, escapes and globs inside the path: bash removes them at run time, so
    # `.git/monitorex-"locks"` IS the guard's directory (code review H1 — a forged
    # release-gate verdict and a CONFIRM mark got through on every OS).
    ("printf 'verdict=pass\\n' > .git/monitorex-\"locks\"/release-gate/abc", True),
    ("printf 'target=feat\\n' > .git/monitorex-\"locks\"/CONFIRM", True),
    ("printf x > .git/monitorex-lo''cks/CONFIRM", True),
    ("printf x > .git/monitorex-\\locks/CONFIRM", True),
    ("printf x > .git/monitorex-lock[s]/CONFIRM", True),
    ("printf x > .git/monitorex-l?cks/CONFIRM", True),
    ("tee .git/monitorex-\"locks\"/CONFIRM < /dev/null", True),
    ("rm -rf .git/monitorex-\"hooks\"", True),
    # … and the same forms must not turn reading into a false rejection
    ("CAT .git/monitorex-locks/CONFIRM", False),
    ("cat .git/monitorex-\"locks\"/CONFIRM", False),
    ('echo "GIT' + ' add ."', False),
    ("grep -n 'GIT" + " add' docs/", False),
    ("GIT status", False),
]

# (command, agent_type, whether we expect deny) — calls from inside a subagent
AGENT_CASES = [
    ("scripts/release-gate.sh pass --report r.md", "release-gate", False),
    ("scripts/release-gate.sh pass --report r.md", "general-purpose", True),
    ("scripts/release-gate.sh pass --report r.md", "vibe-flow:release-gate", False),
    ("scripts/release-gate.sh pass --report r.md", "evil:release-gate", True),
    ("scripts/release-gate.sh pass --report r.md", "senior-backend-engineer", True),
    ("scripts/release-gate.sh override --yes", "release-gate", True),   # bypass is for humans
    ("touch .git/monitorex-locks/release-gate/abc", "release-gate", True),  # bypassing the script
    ("ls .git/monitorex-locks/release-gate 2>&1 | head", "release-gate", False),
    ("env scripts/release-gate.sh override --yes", "release-gate", True),
    ("git push --no-verify", "release-gate", True),
    ("cp /tmp/v .git/monitorex-locks/release-gate/abc 2>/dev/null", "release-gate", True),
]


def decide(rc: int, out: str) -> str:
    """The hook protocol: deny ⇔ rc 2, or rc 0 with a JSON permissionDecision "deny";
    allow ⇔ rc 0 with empty stdout or JSON without a deny; anything else = error."""
    if rc == 2:
        return "deny"
    if rc != 0:
        return "error"
    text = out.strip()
    if not text:
        return "allow"
    try:
        data = json.loads(text)
    except ValueError:
        return "error"
    spec = data.get("hookSpecificOutput") if isinstance(data, dict) else None
    if isinstance(spec, dict) and spec.get("permissionDecision") == "deny":
        return "deny"
    return "allow"


def hook(body, project: str | None, guard: str = GUARD, env_extra: dict | None = None) -> str:
    """Run the guard with this interpreter; body is a dict or raw payload bytes."""
    env = dict(os.environ)
    env.pop("CLAUDE_PROJECT_DIR", None)
    if project:
        env["CLAUDE_PROJECT_DIR"] = project
    env.update(env_extra or {})
    data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
    proc = subprocess.run([sys.executable, "-B", guard], input=data, capture_output=True,
                          timeout=30, env=env)
    return decide(proc.returncode, proc.stdout.decode("utf-8", "replace"))


def run(cmd: str, cwd: str = ROOT, agent_type: str | None = None) -> str:
    body = {
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": cwd,
    }
    if agent_type:
        body.update(agent_id="test-agent", agent_type=agent_type)
    return hook(body, cwd)


NA_SYMLINK = "NA:ln -s made a copy"      # Windows without symlink rights
NA_NOEXEC = "NA:noexec"                  # os.access(X_OK) is always true on Windows


def write_cases(tmp: str, main: str):
    """Write/Edit/MultiEdit/NotebookEdit: nothing inside .git or the project's
    common dir (M5), wherever the session's cwd is; memory files stay writable."""
    sep_wt = os.path.join(tmp, "sep")
    sep_git = os.path.join(tmp, "sep-gitdir")          # common dir without a `.git` component
    subprocess.run(["git", "init", "-q", "--separate-git-dir", sep_git, sep_wt],
                   capture_output=True, check=True)
    os.makedirs(os.path.join(main, ".git", "monitorex-locks"), exist_ok=True)
    link = os.path.join(tmp, "lnk")
    linked = True
    if not os.path.lexists(link):
        try:
            os.symlink(os.path.join(main, ".git", "monitorex-locks"), link)
        except OSError:
            if not WINDOWS:
                raise
            linked = False
    locks = os.path.join(main, ".git", "monitorex-locks")
    nonrepo = os.path.join(tmp, "nonrepo")
    os.makedirs(nonrepo, exist_ok=True)
    W = lambda tool, inp, cwd, proj=main: ({"tool_name": tool, "tool_input": inp, "cwd": cwd}, proj)
    return [
        # (label, (body, CLAUDE_PROJECT_DIR), expect deny | "NA:<reason>")
        ("Write release-gate verdict", W("Write", {"file_path": f"{locks}/release-gate/abc", "content": "verdict=pass"}, main), True),
        ("Write verdict, cwd=/private/tmp", W("Write", {"file_path": f"{locks}/release-gate/abc"}, OUTSIDE), True),
        ("Write CONFIRM relative", W("Write", {"file_path": ".git/monitorex-locks/CONFIRM"}, main), True),
        ("Edit plan-approved mark", W("Edit", {"file_path": f"{locks}/plan-approved/p.md"}, main), True),
        ("MultiEdit installed hook", W("MultiEdit", {"file_path": f"{main}/.git/monitorex-hooks/pre-push"}, main), True),
        ("NotebookEdit notebook_path in .git", W("NotebookEdit", {"notebook_path": ".git/monitorex-locks/x.ipynb"}, main), True),
        ("NotebookEdit notebook_path, cwd=/private/tmp", W("NotebookEdit", {"notebook_path": f"{locks}/x.ipynb"}, OUTSIDE), True),
        ("Write .GIT (case-insensitive FS)", W("Write", {"file_path": f"{main}/.GIT/monitorex-locks/CONFIRM"}, main), True),
        ("Write through a symlink into .git", W("Write", {"file_path": f"{link}/CONFIRM"}, OUTSIDE),
         True if linked else NA_SYMLINK),
        ("Write into a separate git dir, cwd=/private/tmp", W("Write", {"file_path": f"{sep_git}/monitorex-locks/CONFIRM"}, OUTSIDE, sep_wt), True),
        ("Write .git/config of a worktree", W("Write", {"file_path": f"{tmp}/wt/.git"}, main), True),
        ("Write without file_path", W("Write", {"content": "x"}, main), True),
        # MEDIUM-3: no project / not a repository → nothing to protect, allow; `.git` still denied
        ("Write without CLAUDE_PROJECT_DIR — allow", W("Write", {"file_path": f"{main}/lib/x.ts"}, main, None), False),
        ("Write, project is not a repository — allow", W("Write", {"file_path": os.path.join(OUTSIDE, "x.txt")}, OUTSIDE, nonrepo), False),
        ("Write into .git without CLAUDE_PROJECT_DIR — deny", W("Write", {"file_path": f"{locks}/CONFIRM"}, main, None), True),
        ("Write into .git, project is not a repository — deny", W("Write", {"file_path": f"{locks}/CONFIRM"}, OUTSIDE, nonrepo), True),
        ("Write src/a.ts — allow", W("Write", {"file_path": f"{main}/src/a.ts"}, main), False),
        ("Write lib/x.ts", W("Write", {"file_path": f"{main}/lib/x.ts"}, main), False),
        ("Edit relative src/a.ts", W("Edit", {"file_path": "src/a.ts"}, main), False),
        ("MultiEdit in a worktree", W("MultiEdit", {"file_path": f"{tmp}/wt/a.ts"}, main), False),
        ("NotebookEdit a notebook", W("NotebookEdit", {"notebook_path": f"{main}/n.ipynb"}, main), False),
        ("Write .github/workflows/ci.yml", W("Write", {"file_path": f"{main}/.github/workflows/ci.yml"}, main), False),
        ("Write memory/x.md", W("Write", {"file_path": f"{tmp}/home/.claude/projects/-p/memory/x.md"}, OUTSIDE), False),
        ("Write in the separate-git-dir worktree", W("Write", {"file_path": f"{sep_wt}/a.ts"}, sep_wt, sep_wt), False),
        ("Read tool is not checked", W("Read", {"file_path": f"{locks}/CONFIRM"}, main), False),
    ]


def push_cases(tmp: str):
    """`git push` with installed hooks that differ from origin → deny (H4)."""
    origin = os.path.join(tmp, "o.git")
    src = os.path.join(tmp, "src")
    c = os.path.join(tmp, "c")
    sh = lambda *a: subprocess.run(a, capture_output=True, check=True)
    sh("git", "init", "-q", "--bare", "-b", "main", origin)
    sh("git", "init", "-q", "-b", "main", src)
    os.makedirs(os.path.join(src, "githooks"))
    # newline="": byte-exact LF on every OS (the guard compares the installed hook
    # with origin's blob byte for byte).
    for n in ("pre-commit", "pre-push", "plan-gate.sh"):
        with open(os.path.join(src, "githooks", n), "w", newline="") as fh:
            fh.write(f"#!/bin/sh\n# {n}\nexit 0\n")
    sh("git", "-C", src, "add", "-A")
    sh("git", "-C", src, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "hooks")
    sh("git", "-C", src, "push", "-q", origin, "main")
    sh("git", "clone", "-q", origin, c)
    common = os.path.join(c, ".git")
    dest = os.path.join(common, "monitorex-hooks")
    os.makedirs(dest)
    for n in ("pre-commit", "pre-push", "plan-gate.sh"):
        with open(os.path.join(src, "githooks", n), newline="") as a, \
                open(os.path.join(dest, n), "w", newline="") as b:
            b.write(a.read())
        os.chmod(os.path.join(dest, n), 0o755)
    sh("git", "-C", c, "config", "core.hooksPath", dest)
    pp = os.path.join(dest, "pre-push")
    with open(pp, newline="") as fh:
        good = fh.read()

    def state(name):
        with open(pp, "w", newline="") as fh:
            fh.write(good)
        os.chmod(pp, 0o755)
        subprocess.run(["git", "-C", c, "config", "core.hooksPath", dest], check=True)
        if name == "edited":
            with open(pp, "a", newline="") as fh:
                fh.write("# rolled back\n")
        elif name == "noexec":
            os.chmod(pp, 0o644)
        elif name == "nohookspath":
            subprocess.run(["git", "-C", c, "config", "--unset", "core.hooksPath"], check=True)
        elif name == "missing":
            os.remove(pp)
    # (label, state, command, cwd, expect deny | "NA:<reason>")
    return state, [
        ("hooks match origin", "ok", "git push origin HEAD", c, False),
        ("installed pre-push edited", "edited", "git push origin HEAD", c, True),
        ("installed pre-push edited, git -C", "edited", f"git -C {fwd(c)} push", OUTSIDE, True),
        ("installed pre-push edited, cd &&", "edited", f"cd {fwd(c)} && git push -u origin HEAD", OUTSIDE, True),
        ("installed pre-push not executable", "noexec", "git push origin HEAD", c,
         NA_NOEXEC if WINDOWS else True),
        ("core.hooksPath unset", "nohookspath", "git push origin HEAD", c, True),
        ("installed pre-push missing", "missing", "git push origin HEAD", c, True),
        ("edited hook does not block other commands", "edited", "git status", c, False),
        ("back to origin's version", "ok", "git push origin HEAD", c, False),
    ]


def worktree_cases(tmp: str):
    """Decide by the tree where git will ACTUALLY run (25.10.2026).

    The session always sits in the main working tree while the work happens in
    its own worktree: `git -C <wt> add` used to be falsely rejected, and the agent
    could not make a merge commit after conflicts. The main working tree stays closed.
    """
    main = os.path.join(tmp, "main")
    wt = os.path.join(tmp, "wt")
    sh = lambda *a: subprocess.run(a, capture_output=True, check=True)
    sh("git", "init", "-q", main)
    sh("git", "-C", main, "-c", "user.email=t@t", "-c", "user.name=t",
       "commit", "-q", "--allow-empty", "-m", "init")
    sh("git", "-C", main, "worktree", "add", "-q", wt, "-b", "wtb")
    os.makedirs(os.path.join(main, "src"), exist_ok=True)
    m, w, t = fwd(main), fwd(wt), fwd(tmp)
    return main, [
        (f"git -C {w} add f.ts", False),
        (f"git -C {w} commit --no-edit", False),
        (f"cd {w} && {STAGE} f.ts", False),
        (f"cd {w} && npm test && {COMMIT} -m x", False),
        (f"cd {w}; {STAGE} -A", False),
        (f"git -C {t} -C wt add f.ts", False),             # -C values stack
        (f"git -C {m} add f.ts", True),
        (f"{STAGE} f.ts", True),                           # session cwd = main
        (f"(cd {w}) && {STAGE} f.ts", True),               # a subshell does not change cwd
        (f"cd $WT && {STAGE} f.ts", True),                 # cannot resolve → deny
        (f"git --git-dir={w}/.git add f.ts", True),        # an explicit git-dir is not guessed
        (f"git -C {t}/nope add f.ts", True),               # directory does not exist
        (f"cd {w} && {STAGE} f && cd {m} && {COMMIT} -m x", True),
    ]


# ── Encodings and payload bytes (vibe-flow 1.3.0, Step 1) ───────────────────
# On Windows stdout/stdin are cp1252: a deny reason starting with "🔴" printed with
# ensure_ascii=False raised UnicodeEncodeError → exit 1 → Claude Code ran the call;
# Cyrillic stdin bytes (`с` = D1 81) raised before any check. PYTHONIOENCODING=cp1252
# reproduces that on any OS. Hook input is UTF-8 bytes; invalid bytes must not crash.
def payload_cases(main: str):
    def raw(cmd_bytes: bytes) -> bytes:
        """A payload whose command carries raw bytes (no quotes or backslashes in them)."""
        head = json.dumps({"tool_name": "Bash", "cwd": main}).encode("utf-8")[:-1]
        return head + b', "tool_input": {"command": "' + cmd_bytes + b'"}}'

    def utf8(cmd: str) -> bytes:
        """Non-ASCII sent as UTF-8 bytes, not as \\u escapes."""
        body = {"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": main}
        return json.dumps(body, ensure_ascii=False).encode("utf-8")
    cp1252 = {"PYTHONIOENCODING": "cp1252"}
    cyr = COMMIT + ' -m "исправление"'
    return [
        # (label, payload, env, expect deny)
        ("cp1252 stdout: the deny is still valid JSON", {"tool_name": "Bash", "tool_input": {"command": f"{STAGE} f.ts"}, "cwd": main}, cp1252, True),
        ("cp1252 stdio: Cyrillic in the command, still a deny", utf8(cyr), cp1252, True),
        ("UTF-8 stdio: Cyrillic in the command, still a deny", utf8(cyr), {}, True),
        ("invalid UTF-8 bytes in the payload: no crash, a deny stays a deny", raw(STAGE.encode() + b" f.ts # \xff\xfe\xc3"), {}, True),
        ("invalid UTF-8 bytes under cp1252: no crash, a deny stays a deny", raw(STAGE.encode() + b" f.ts # \xff\x81"), cp1252, True),
        ("invalid UTF-8 bytes in an allowed command: still an allow", raw(b"ls -la # \xff"), {}, False),
    ]


# ── Fail-closed when the path helper is missing or broken (K13, K14) ─────────
# The guard imports gg_paths from scripts/git-guards the way it imports
# shell_segments. A copy of the guard is laid out next to a missing / raising /
# undecided gg_paths: a Write naming the guard's state is still denied, and a
# linked worktree is believed only on positive evidence.
GG_STUB_RAISING = '''\
WINDOWS = False
def _fail(*args, **kwargs):
    raise RuntimeError("gg_paths stub: broken on purpose")
_configure = home = to_native = is_abs = same_path = posix_rel = cmd_name = _fail
'''
GG_STUB_UNDECIDED = '''\
import os
WINDOWS = False
def _configure(windows, cygpath=None, **kwargs):
    pass
def home():
    return os.environ.get("HOME") or os.path.expanduser("~")
def to_native(p, **kwargs):
    return None
def is_abs(p):
    return os.path.isabs(p)
def same_path(a, b, **kwargs):
    return None
def posix_rel(p, base, **kwargs):
    return None
def cmd_name(word):
    name = word.replace("\\\\", "/").rstrip("/").split("/")[-1].casefold()
    return name[:-4] if name.endswith(".exe") else name
'''


def stub_layout(tmp: str, name: str, stub: str | None) -> str:
    """A copy of the guard whose gg_paths is `stub` (None = no module at all)."""
    root = os.path.join(tmp, "layout-" + name)
    hooks = os.path.join(root, ".claude", "hooks")
    lib = os.path.join(root, "scripts", "git-guards")
    os.makedirs(hooks)
    os.makedirs(lib)
    shutil.copy(GUARD, hooks)
    for n in os.listdir(HERE):
        if n.endswith(".py") and n != "gg_paths.py" and not n.startswith("test_"):
            shutil.copy(os.path.join(HERE, n), lib)
    if stub is not None:
        with open(os.path.join(lib, "gg_paths.py"), "w", newline="") as fh:
            fh.write(stub)
    return os.path.join(hooks, "monitorex_git_guard.py")


def failclosed_cases(tmp: str, main: str, wt: str):
    elsewhere = os.path.join(tmp, "elsewhere")
    os.makedirs(elsewhere, exist_ok=True)
    w = lambda path: {"tool_name": "Write", "tool_input": {"file_path": path}, "cwd": main}
    b = lambda cmd: {"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": main}
    missing = stub_layout(tmp, "missing", None)
    raising = stub_layout(tmp, "raising", GG_STUB_RAISING)
    undecided = stub_layout(tmp, "undecided", GG_STUB_UNDECIDED)
    locks_like = os.path.join(elsewhere, "monitorex-locks", "CONFIRM")
    hooks_like = os.path.join(elsewhere, "monitorex-hooks", "pre-push")
    return [
        # (label, guard, payload, expect deny)
        ("gg_paths missing: Write to …/monitorex-locks/… — deny (K13)", missing, w(locks_like), True),
        ("gg_paths missing: Write into .git — deny (K13)", missing, w(os.path.join(main, ".git", "x")), True),
        ("gg_paths raising: Write to …/monitorex-locks/… — deny, never exit 1 (K13)", raising, w(locks_like), True),
        ("gg_paths to_native → None: Write to …/monitorex-hooks/… — deny (K13)", undecided, w(hooks_like), True),
        ("gg_paths same_path → None: git add in a linked worktree — deny (K14)", undecided, b(f"git -C {fwd(wt)} add f.ts"), True),
        ("gg_paths same_path → None: cd <worktree> && git add — deny (K14)", undecided, b(f"cd {fwd(wt)} && {STAGE} f.ts"), True),
    ]


# ── gg_paths unit tests (K6): the Windows logic through ntpath on any OS ─────
def gg_paths_cases(tmp: str):
    """(label, check) pairs; a check returns True on success. The module is
    imported HERE: a missing module fails these cases, the rest still run."""
    state = {"mod": None, "err": ""}
    try:
        sys.path.insert(0, HERE)
        import gg_paths as gp            # noqa: E402 — imported inside the section on purpose
        state["mod"] = gp
    except Exception as e:               # noqa: BLE001 — any import failure is a test failure
        state["err"] = f"{type(e).__name__}: {e}"
    calls: list[str] = []
    table = {"/tmp/x": "C:/Users/RUNNER~1/AppData/Local/Temp/x", "/cd/x": "C:/msys/cd/x"}

    def cyg(p):
        calls.append(p)
        return table.get(p)

    def cyg_broken(p):
        raise OSError("cygpath: not found")

    def win(cygpath=cyg):
        state["mod"]._configure(windows=True, cygpath=cygpath)
        del calls[:]

    def posix():
        state["mod"]._configure(windows=False)

    def with_home(value, fn):
        old = os.environ.get("HOME")
        os.environ["HOME"] = value
        try:
            return fn()
        finally:
            if old is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old

    g = lambda: state["mod"]
    lnk_dir = os.path.join(tmp, "gp")
    os.makedirs(lnk_dir, exist_ok=True)
    f1, f2, l1 = (os.path.join(lnk_dir, n) for n in ("one", "two", "link"))
    for f in (f1, f2):
        open(f, "w").close()
    try:
        os.symlink(f1, l1)
        have_link = True
    except OSError:
        if not WINDOWS:
            raise
        have_link = False

    def cached():
        win()
        a = g().to_native("/tmp/x")
        b2 = g().to_native("/tmp/x")
        return a == b2 == "C:/Users/RUNNER~1/AppData/Local/Temp/x" and calls.count("/tmp/x") == 1

    cases = [
        ("WINDOWS mirrors sys.platform at import", lambda: g().WINDOWS == (sys.platform == "win32")),
        # Windows mode
        ("win: cmd_name('/usr/bin/GIT') == 'git'", lambda: (win(), g().cmd_name("/usr/bin/GIT"))[1] == "git"),
        ("win: cmd_name('C:\\\\Program Files\\\\Git\\\\cmd\\\\git.exe') == 'git'", lambda: (win(), g().cmd_name("C:\\Program Files\\Git\\cmd\\git.exe"))[1] == "git"),
        ("win: cmd_name('BASH.EXE') == 'bash'", lambda: (win(), g().cmd_name("BASH.EXE"))[1] == "bash"),
        ("win: cmd_name('scripts\\\\Git-Confirm.SH') == 'git-confirm.sh'", lambda: (win(), g().cmd_name("scripts\\Git-Confirm.SH"))[1] == "git-confirm.sh"),
        ("win: cmd_name strips ONE trailing .exe", lambda: (win(), g().cmd_name("git.exe.exe"))[1] == "git.exe"),
        ("win: to_native('/c/Users/x') == 'C:/Users/x'", lambda: (win(), g().to_native("/c/Users/x"))[1] == "C:/Users/x"),
        ("win: to_native('C:\\\\Users\\\\x') == 'C:/Users/x'", lambda: (win(), g().to_native("C:\\Users\\x"))[1] == "C:/Users/x"),
        ("win: to_native('c:/x/../y') == 'C:/y' (normpath first, upper-case drive)", lambda: (win(), g().to_native("c:/x/../y"))[1] == "C:/y"),
        ("win: to_native('/c/x/./y/../z') == 'C:/x/z'", lambda: (win(), g().to_native("/c/x/./y/../z"))[1] == "C:/x/z"),
        ("win: other leading / goes through cygpath", lambda: (win(), g().to_native("/tmp/x"))[1] == "C:/Users/RUNNER~1/AppData/Local/Temp/x"),
        ("win: '/cd/x' is not a drive — cygpath", lambda: (win(), g().to_native("/cd/x"))[1] == "C:/msys/cd/x"),
        ("win: cygpath is cached (one call per distinct path)", cached),
        ("win: cygpath answers nothing → None", lambda: (win(), g().to_native("/nope"))[1] is None),
        ("win: cygpath raising → None, never raises", lambda: (win(cyg_broken), g().to_native("/tmp/y"))[1] is None),
        ("win: '~/x' expands from HOME first", lambda: with_home("/c/Users/me", lambda: (win(), g().to_native("~/x"))[1]) == "C:/Users/me/x"),
        ("win: is_abs('/x')", lambda: (win(), g().is_abs("/x"))[1] is True),
        ("win: is_abs('C:/x')", lambda: (win(), g().is_abs("C:/x"))[1] is True),
        ("win: is_abs('C:\\\\x')", lambda: (win(), g().is_abs("C:\\x"))[1] is True),
        ("win: not is_abs('x/y')", lambda: (win(), g().is_abs("x/y"))[1] is False),
        ("win: not is_abs('C:x') (drive-relative)", lambda: (win(), g().is_abs("C:x"))[1] is False),
        ("win: same_path('C:/X/y', 'c:\\\\x\\\\Y') — case and separators", lambda: (win(), g().same_path("C:/X/y", "c:\\x\\Y"))[1] is True),
        ("win: same_path across drives is False, no ValueError", lambda: (win(), g().same_path("C:/x", "D:/x"))[1] is False),
        ("win: posix_rel('C:/r/src/a.ts', 'C:/r') == 'src/a.ts'", lambda: (win(), g().posix_rel("C:/r/src/a.ts", "C:/r"))[1] == "src/a.ts"),
        ("win: posix_rel with backslashes → forward slashes", lambda: (win(), g().posix_rel("C:\\r\\src\\a.ts", "C:/r"))[1] == "src/a.ts"),
        ("win: posix_rel outside base → None", lambda: (win(), g().posix_rel("C:/other/a", "C:/r"))[1] is None),
        ("win: posix_rel on another drive → None", lambda: (win(), g().posix_rel("D:/r/a", "C:/r"))[1] is None),
        # POSIX mode: identity for paths, cmd_name the same on every OS
        ("posix: to_native is identity", lambda: (posix(), [g().to_native(p) for p in ("/usr/x", "C:\\x", "~/x")])[1] == ["/usr/x", "C:\\x", "~/x"]),
        ("posix: is_abs('/x') and not is_abs('C:/x')", lambda: (posix(), (g().is_abs("/x"), g().is_abs("C:/x")))[1] == (True, False)),
        ("posix: cmd_name('/usr/bin/GIT') == 'git'", lambda: (posix(), g().cmd_name("/usr/bin/GIT"))[1] == "git"),
        ("posix: cmd_name('BASH.EXE') == 'bash'", lambda: (posix(), g().cmd_name("BASH.EXE"))[1] == "bash"),
        ("posix: cmd_name('C:\\\\Program Files\\\\Git\\\\cmd\\\\git.exe') == 'git'", lambda: (posix(), g().cmd_name("C:\\Program Files\\Git\\cmd\\git.exe"))[1] == "git"),
        # posixpath.realpath over a real NTFS path is not a configuration that exists:
        # on Windows the guard always runs in Windows mode, so this POSIX filesystem
        # case runs only off Windows (like the Windows-only cases run only on Windows).
        *([("posix: same_path of a file and a symlink to it",
            (lambda: (posix(), g().same_path(f1, l1))[1] is True) if have_link else NA_SYMLINK)]
          if os.name != "nt" else []),
        ("posix: same_path of two different files is False", lambda: (posix(), g().same_path(f1, f2))[1] is False),
        ("posix: same_path with a NUL byte → None, never raises", lambda: (posix(), g().same_path("a\0b", f1))[1] is None),
        ("posix: posix_rel('/r/src/a.ts', '/r') == 'src/a.ts'", lambda: (posix(), g().posix_rel("/r/src/a.ts", "/r"))[1] == "src/a.ts"),
        ("posix: posix_rel outside base → None", lambda: (posix(), g().posix_rel("/x/a", "/r"))[1] is None),
        ("home() reads HOME first", lambda: with_home("/h", lambda: g().home()) == "/h"),
    ]

    def guarded(check):
        if isinstance(check, str):
            return check
        if state["mod"] is None:
            return "gg_paths not importable: " + state["err"]
        try:
            return bool(check())
        except Exception as e:           # noqa: BLE001 — a raising helper is a failure
            return f"raised {type(e).__name__}: {e}"

    def restore():
        if state["mod"] is not None:
            try:
                state["mod"]._configure(windows=(sys.platform == "win32"))
            except Exception:            # noqa: BLE001
                pass
    return [(lbl, (lambda c=c: guarded(c))) for lbl, c in cases], restore


class Tally:
    def __init__(self):
        self.ok = self.fail = self.na = 0

    def check(self, label: str, want, got: str) -> None:
        """want: True (deny) / False (allow) / "NA:<reason>"."""
        if isinstance(want, str) and want.startswith("NA:"):
            self.na += 1
            print(f"  n/a  - {label}: {want[3:]}")
            return
        expect = "deny" if want else "allow"
        if got == expect:
            self.ok += 1
            print(f"  ok   - {expect} | {label}")
        else:
            self.fail += 1
            print(f"  FAIL - expected {expect}, got {got} | {label}")

    def unit(self, label: str, result) -> None:
        if isinstance(result, str) and result.startswith("NA:"):
            self.na += 1
            print(f"  n/a  - gg_paths: {label}: {result[3:]}")
        elif result is True:
            self.ok += 1
            print(f"  ok   - gg_paths: {label}")
        else:
            self.fail += 1
            print(f"  FAIL - gg_paths: {label}: {result}")


def main() -> int:
    t = Tally()
    tmp = os.path.realpath(tempfile.mkdtemp(prefix="guard-wt-"))
    main_repo, wt_cases = worktree_cases(tmp)
    # The base cases also run against the temporary MAIN tree: cwd used to be
    # ROOT, and when run from a project worktree they falsely "failed".
    cases = [(c.replace("{MAIN}", fwd(main_repo)), d, main_repo, None) for c, d in CASES]
    cases += [(c, d, main_repo, None) for c, d in wt_cases]
    cases += [(c, d, main_repo, a) for c, a, d in AGENT_CASES]
    for cmd, want_deny, cwd, agent in cases:
        label = (f"[{agent}] " if agent else "") + cmd
        t.check(label, want_deny, run(cmd, cwd, agent))
    for lbl, (body, proj), want in write_cases(tmp, main_repo):
        t.check(lbl, want, "" if isinstance(want, str) else hook(body, proj))
    state, pcases = push_cases(tmp)
    for lbl, st, cmd, cwd, want in pcases:
        if isinstance(want, str):
            t.check(lbl, want, "")
            continue
        state(st)
        t.check(lbl, want, hook({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd}, cwd))
    for lbl, payload, env, want in payload_cases(main_repo):
        t.check(lbl, want, hook(payload, main_repo, env_extra=env))
    for lbl, guard, payload, want in failclosed_cases(tmp, main_repo, os.path.join(tmp, "wt")):
        t.check(lbl, want, hook(payload, main_repo, guard=guard))
    units, restore = gg_paths_cases(tmp)
    try:
        for lbl, check in units:
            t.unit(lbl, check())
    finally:
        restore()
    if t.na and not WINDOWS:
        t.fail += 1
        print(f"  FAIL - {t.na} case(s) N/A outside Windows: N/A is allowed only on native Windows")
    print(f"\n  passed: {t.ok}   failed: {t.fail}   n/a: {t.na}")
    return 1 if t.fail else 0


def _utf8_stdio() -> None:
    """The case labels carry dashes and Cyrillic; a Windows pipe is cp1252, and the
    first such label raised UnicodeEncodeError before any verdict was printed. Only
    this runner's own output: the guard under test keeps the inherited environment."""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8", errors="backslashreplace")


if __name__ == "__main__":
    _utf8_stdio()
    sys.exit(main())
