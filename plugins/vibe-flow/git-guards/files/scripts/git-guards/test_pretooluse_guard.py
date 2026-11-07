#!/usr/bin/env python3
"""Tests for the PreToolUse guard: what it blocks and what it MUST let through.

A false rejection here is worse than a miss — people rip out the whole guard
because of it, real value included. The first version of the hook rejected
`echo "…"` with these words inside and blocked its own fix, so most of the
cases below are about what it MUST let through.

Run: python3 scripts/git-guards/test_pretooluse_guard.py
"""

import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOOK = os.path.join(ROOT, ".claude", "hooks", "monitorex-git-guard.sh")

STAGE = "git" + " add"          # assembled from pieces, otherwise the hook blocks
COMMIT = "git" + " commit"      # running the tests themselves

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
    (f"cd {ROOT} && ./scripts/git-confirm.sh commit", True),
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


def hook(body: dict, project: str | None) -> bool:
    env = dict(os.environ)
    env.pop("CLAUDE_PROJECT_DIR", None)
    if project:
        env["CLAUDE_PROJECT_DIR"] = project
    out = subprocess.run(["bash", HOOK], input=json.dumps(body), capture_output=True,
                         text=True, timeout=20, env=env).stdout.strip()
    return bool(out)


def run(cmd: str, cwd: str = ROOT, agent_type: str | None = None) -> bool:
    body = {
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "cwd": cwd,
    }
    if agent_type:
        body.update(agent_id="test-agent", agent_type=agent_type)
    return hook(body, cwd)


def write_cases(tmp: str, main: str):
    """Write/Edit/MultiEdit/NotebookEdit: nothing inside .git or the project's
    common dir (M5), wherever the session's cwd is; memory files stay writable."""
    sep_wt = os.path.join(tmp, "sep")
    sep_git = os.path.join(tmp, "sep-gitdir")          # common dir without a `.git` component
    subprocess.run(["git", "init", "-q", "--separate-git-dir", sep_git, sep_wt],
                   capture_output=True, check=True)
    os.makedirs(os.path.join(main, ".git", "monitorex-locks"), exist_ok=True)
    link = os.path.join(tmp, "lnk")
    if not os.path.lexists(link):
        os.symlink(os.path.join(main, ".git", "monitorex-locks"), link)
    locks = os.path.join(main, ".git", "monitorex-locks")
    nonrepo = os.path.join(tmp, "nonrepo")
    os.makedirs(nonrepo, exist_ok=True)
    W = lambda tool, inp, cwd, proj=main: ({"tool_name": tool, "tool_input": inp, "cwd": cwd}, proj)
    return [
        # (label, (body, CLAUDE_PROJECT_DIR), expect deny)
        ("Write release-gate verdict", W("Write", {"file_path": f"{locks}/release-gate/abc", "content": "verdict=pass"}, main), True),
        ("Write verdict, cwd=/private/tmp", W("Write", {"file_path": f"{locks}/release-gate/abc"}, "/private/tmp"), True),
        ("Write CONFIRM relative", W("Write", {"file_path": ".git/monitorex-locks/CONFIRM"}, main), True),
        ("Edit plan-approved mark", W("Edit", {"file_path": f"{locks}/plan-approved/p.md"}, main), True),
        ("MultiEdit installed hook", W("MultiEdit", {"file_path": f"{main}/.git/monitorex-hooks/pre-push"}, main), True),
        ("NotebookEdit notebook_path in .git", W("NotebookEdit", {"notebook_path": ".git/monitorex-locks/x.ipynb"}, main), True),
        ("NotebookEdit notebook_path, cwd=/private/tmp", W("NotebookEdit", {"notebook_path": f"{locks}/x.ipynb"}, "/private/tmp"), True),
        ("Write .GIT (case-insensitive FS)", W("Write", {"file_path": f"{main}/.GIT/monitorex-locks/CONFIRM"}, main), True),
        ("Write through a symlink into .git", W("Write", {"file_path": f"{link}/CONFIRM"}, "/private/tmp"), True),
        ("Write into a separate git dir, cwd=/private/tmp", W("Write", {"file_path": f"{sep_git}/monitorex-locks/CONFIRM"}, "/private/tmp", sep_wt), True),
        ("Write .git/config of a worktree", W("Write", {"file_path": f"{tmp}/wt/.git"}, main), True),
        ("Write without file_path", W("Write", {"content": "x"}, main), True),
        # MEDIUM-3: no project / not a repository → nothing to protect, allow; `.git` still denied
        ("Write without CLAUDE_PROJECT_DIR — allow", W("Write", {"file_path": f"{main}/lib/x.ts"}, main, None), False),
        ("Write, project is not a repository — allow", W("Write", {"file_path": "/private/tmp/x.txt"}, "/private/tmp", nonrepo), False),
        ("Write into .git without CLAUDE_PROJECT_DIR — deny", W("Write", {"file_path": f"{locks}/CONFIRM"}, main, None), True),
        ("Write into .git, project is not a repository — deny", W("Write", {"file_path": f"{locks}/CONFIRM"}, "/private/tmp", nonrepo), True),
        ("Write src/a.ts — allow", W("Write", {"file_path": f"{main}/src/a.ts"}, main), False),
        ("Write lib/x.ts", W("Write", {"file_path": f"{main}/lib/x.ts"}, main), False),
        ("Edit relative src/a.ts", W("Edit", {"file_path": "src/a.ts"}, main), False),
        ("MultiEdit in a worktree", W("MultiEdit", {"file_path": f"{tmp}/wt/a.ts"}, main), False),
        ("NotebookEdit a notebook", W("NotebookEdit", {"notebook_path": f"{main}/n.ipynb"}, main), False),
        ("Write .github/workflows/ci.yml", W("Write", {"file_path": f"{main}/.github/workflows/ci.yml"}, main), False),
        ("Write memory/x.md", W("Write", {"file_path": f"{tmp}/home/.claude/projects/-p/memory/x.md"}, "/private/tmp"), False),
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
    for n in ("pre-commit", "pre-push", "plan-gate.sh"):
        with open(os.path.join(src, "githooks", n), "w") as fh:
            fh.write(f"#!/bin/sh\n# {n}\nexit 0\n")
    sh("git", "-C", src, "add", "-A")
    sh("git", "-C", src, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "hooks")
    sh("git", "-C", src, "push", "-q", origin, "main")
    sh("git", "clone", "-q", origin, c)
    common = os.path.join(c, ".git")
    dest = os.path.join(common, "monitorex-hooks")
    os.makedirs(dest)
    for n in ("pre-commit", "pre-push", "plan-gate.sh"):
        with open(os.path.join(src, "githooks", n)) as a, open(os.path.join(dest, n), "w") as b:
            b.write(a.read())
        os.chmod(os.path.join(dest, n), 0o755)
    sh("git", "-C", c, "config", "core.hooksPath", dest)
    pp = os.path.join(dest, "pre-push")
    good = open(pp).read()

    def state(name):
        with open(pp, "w") as fh:
            fh.write(good)
        os.chmod(pp, 0o755)
        subprocess.run(["git", "-C", c, "config", "core.hooksPath", dest], check=True)
        if name == "edited":
            with open(pp, "a") as fh:
                fh.write("# rolled back\n")
        elif name == "noexec":
            os.chmod(pp, 0o644)
        elif name == "nohookspath":
            subprocess.run(["git", "-C", c, "config", "--unset", "core.hooksPath"], check=True)
        elif name == "missing":
            os.remove(pp)
    # (label, state, command, cwd, expect deny)
    return state, [
        ("hooks match origin", "ok", "git push origin HEAD", c, False),
        ("installed pre-push edited", "edited", "git push origin HEAD", c, True),
        ("installed pre-push edited, git -C", "edited", f"git -C {c} push", "/private/tmp", True),
        ("installed pre-push edited, cd &&", "edited", f"cd {c} && git push -u origin HEAD", "/private/tmp", True),
        ("installed pre-push not executable", "noexec", "git push origin HEAD", c, True),
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
    return main, [
        (f"git -C {wt} add f.ts", False),
        (f"git -C {wt} commit --no-edit", False),
        (f"cd {wt} && {STAGE} f.ts", False),
        (f"cd {wt} && npm test && {COMMIT} -m x", False),
        (f"cd {wt}; {STAGE} -A", False),
        (f"git -C {tmp} -C wt add f.ts", False),           # -C values stack
        (f"git -C {main} add f.ts", True),
        (f"{STAGE} f.ts", True),                           # session cwd = main
        (f"(cd {wt}) && {STAGE} f.ts", True),              # a subshell does not change cwd
        (f"cd $WT && {STAGE} f.ts", True),                 # cannot resolve → deny
        (f"git --git-dir={wt}/.git add f.ts", True),       # an explicit git-dir is not guessed
        (f"git -C {tmp}/nope add f.ts", True),             # directory does not exist
        (f"cd {wt} && {STAGE} f && cd {main} && {COMMIT} -m x", True),
    ]


def main() -> int:
    ok = fail = 0
    tmp = tempfile.mkdtemp(prefix="guard-wt-")
    main_repo, wt_cases = worktree_cases(os.path.realpath(tmp))
    # The base cases also run against the temporary MAIN tree: cwd used to be
    # ROOT, and when run from a project worktree they falsely "failed".
    cases = [(c.replace("{MAIN}", main_repo), d, main_repo, None) for c, d in CASES]
    cases += [(c, d, main_repo, None) for c, d in wt_cases]
    cases += [(c, d, main_repo, a) for c, a, d in AGENT_CASES]
    for cmd, want_deny, cwd, agent in cases:
        got = run(cmd, cwd, agent)
        label = ("deny " if want_deny else "allow") + (f" [{agent}]" if agent else "")
        if got == want_deny:
            ok += 1
            print(f"  ok   - {label} | {cmd}")
        else:
            fail += 1
            print(f"  FAIL - expected {label}, got "
                  f"{'deny' if got else 'allow'} | {cmd}")
    checks = [(lbl, body, proj, d) for lbl, (body, proj), d
              in write_cases(os.path.realpath(tmp), main_repo)]
    for lbl, body, proj, want_deny in checks:
        got = hook(body, proj)
        label = ("deny " if want_deny else "allow")
        if got == want_deny:
            ok += 1
            print(f"  ok   - {label} | {lbl}")
        else:
            fail += 1
            print(f"  FAIL - expected {label}, got {'deny' if got else 'allow'} | {lbl}")
    state, pcases = push_cases(os.path.realpath(tmp))
    for lbl, st, cmd, cwd, want_deny in pcases:
        state(st)
        got = hook({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd}, cwd)
        label = ("deny " if want_deny else "allow")
        if got == want_deny:
            ok += 1
            print(f"  ok   - {label} | {lbl}")
        else:
            fail += 1
            print(f"  FAIL - expected {label}, got {'deny' if got else 'allow'} | {lbl}")
    print(f"\n  passed: {ok}   failed: {fail}")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
