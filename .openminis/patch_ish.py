"""Adapt pinned iSH hostname bounds and host/guest inode namespace handling.

Applied to the separate pinned dependency checkout before compiling either SDK.
Never disable fortified libc checks: a macOS/iOS hostname can exceed Linux's
64-byte field (and the simulator otherwise traps in __strcpy_chk/sys_uname).
"""
from pathlib import Path
import subprocess

ISH_COMMIT = "e6521d9cfe9cd48f19917fc3b23aea622ba358b4"


def patch(root: Path):
    ish = root / "deps/ish"
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ish, text=True).strip()
    if revision != ISH_COMMIT:
        raise RuntimeError("iSH dependency revision changed; review native dependency fixes")
    file = ish / "kernel/uname.c"
    code = file.read_text()
    changes = [("    struct utsname real_uname;", "    struct utsname real_uname = {0};"),
               ("    strcpy(uts->hostname, hostname);", '    snprintf(uts->hostname, sizeof(uts->hostname), "%s", hostname);')]
    for before, after in changes:
        if after in code:
            continue
        if code.count(before) != 1:
            raise RuntimeError("iSH uname source anchor changed")
        code = code.replace(before, after)
    file.write_text(code)

    # Hook-routed descriptors use HOST inode numbers. A matching numeric row in
    # the guest database is unrelated and must never replace their real type.
    # In particular it can turn a newly created regular file into a directory.
    def replace_once(path, before, after):
        text = path.read_text()
        if after in text: return
        if text.count(before) != 1: raise RuntimeError("iSH hook inode anchor changed: " + str(path))
        path.write_text(text.replace(before, after))
    replace_once(ish / "fs/fd.h", "    ino_t fake_inode;\n",
                 "    ino_t fake_inode;\n    bool fakefs_hook_routed; // Host inode namespace; never consult guest metadata.\n")
    fake = ish / "fs/fake.c"
    replace_once(fake, "    if (via_hook) {\n        struct stat host_stat;",
                 "    if (via_hook) {\n        fd->fakefs_hook_routed = true;\n        struct stat host_stat;")
    replace_once(fake, '''    // [T-ish-exec-fewer-meta-txns] The row fakefs_open read a moment ago,
''', '''    // The descriptor's host inode may equal an unrelated guest directory's
    // inode. Check provenance before BOTH the stat cache and meta.db lookup.
    if (fd->fakefs_hook_routed) {
        mode_t_ type = fake_stat->mode & S_IFMT;
        fake_stat->mode = type | (S_ISDIR(fake_stat->mode) ? 0755 : 0644);
        fake_stat->uid = 0;
        fake_stat->gid = 0;
        fake_stat->rdev = 0;
        return 0;
    }
    // [T-ish-exec-fewer-meta-txns] The row fakefs_open read a moment ago,
''')
    replace_once(fake, '''    db_begin_read(fs);
    struct ish_stat ishstat;
    bool in_meta = inode_read_stat_if_exist(fs, fd->fake_inode, &ishstat);
    db_commit(fs);
    if (!in_meta) {''', '''    struct ish_stat ishstat;
    bool in_meta = false;
    if (!fd->fakefs_hook_routed) {
        db_begin_read(fs);
        in_meta = inode_read_stat_if_exist(fs, fd->fake_inode, &ishstat);
        db_commit(fs);
    }
    if (!in_meta) {''')
