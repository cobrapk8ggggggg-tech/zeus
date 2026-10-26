"""Apply the same structured patch syntax used by the native tool."""
from .files import relative_path, open_regular, write_regular, contained


def apply_patch(root, text):
    lines = text.splitlines(); changes = {}; index = 0
    if not lines or lines[0] != "*** Begin Patch" or lines[-1] != "*** End Patch": raise ValueError("Expected Begin Patch and End Patch")
    index = 1
    while index < len(lines)-1:
        header = lines[index]; index += 1
        if header.startswith("*** Add File: "):
            path = header[len("*** Add File: "):]; relative_path(path)
            try:
                with open_regular(root, path): pass
            except FileNotFoundError: pass
            else: raise ValueError("Add File target already exists")
            added = []
            while index < len(lines) and not lines[index].startswith("*** "):
                if not lines[index].startswith("+"): raise ValueError("Added lines must start with +")
                added.append(lines[index][1:]); index += 1
            changes[path] = (None, ("\n".join(added)+"\n").encode())
        elif header.startswith(("*** Update File: ", "*** Delete File: ")):
            delete = header.startswith("*** Delete")
            path = header.split(": ", 1)[1]; relative_path(path)
            with open_regular(root, path) as source: original = source.read(1024*1024+1)
            if len(original)>1024*1024: raise ValueError("Patch file exceeds 1 MiB; use a script")
            if delete: changes[path] = (original, None); continue
            old = original.decode(); trailing = old.endswith("\n"); rows = old.splitlines()
            while index < len(lines) and not lines[index].startswith("*** "):
                if lines[index].startswith("@@"): index += 1
                before, after = [], []
                while index < len(lines) and not lines[index].startswith(("*** ", "@@")):
                    row = lines[index]; index += 1
                    if not row or row[0] not in " +-": raise ValueError("Invalid patch context")
                    if row[0] in " -": before.append(row[1:])
                    if row[0] in " +": after.append(row[1:])
                if not before: raise ValueError("An update needs unique context")
                matches = [i for i in range(len(rows)-len(before)+1) if rows[i:i+len(before)]==before]
                if len(matches)!=1: raise ValueError("Patch context must match exactly once; no files changed")
                start = matches[0]; rows[start:start+len(before)] = after
            changes[path] = (original, ("\n".join(rows)+("\n" if trailing else "")).encode())
        else: raise ValueError("Unsupported patch directive")
    # Validate the whole patch before any write. Restore originals on an I/O
    # failure; no shell interpolation, symlinks or paths outside the workspace.
    written = []
    try:
        for path, (_, data) in changes.items():
            if data is None: contained(root, path).unlink()
            else: write_regular(root, path, data)
            written.append(path)
    except BaseException:
        for path in reversed(written):
            original, _ = changes[path]
            if original is None: contained(root, path).unlink(missing_ok=True)
            else: write_regular(root, path, original)
        raise
    return "Patched: " + ", ".join(changes)
