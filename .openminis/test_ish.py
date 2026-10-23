"""Execute the actual patched C function with an overlong hostname and ASan."""
from pathlib import Path
import shutil
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import patch_ish


class ISHHostnameTests(unittest.TestCase):
    def test_actual_uname_truncates_without_corrupting_adjacent_fields(self):
        source = Path(os.environ.get("ZEUS_OPENMINIS_SOURCE", Path(__file__).parent.parent / "Vendor/OpenMinis")) / "deps/ish/kernel/uname.c"
        if not source.exists():
            self.skipTest("Initialize the pinned deps/ish submodule to run its C regression")
        compiler = shutil.which("clang") or shutil.which("cc")
        self.assertIsNotNone(compiler)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file = root / "deps/ish/kernel/uname.c"
            file.parent.mkdir(parents=True)
            shutil.copyfile(source, file)
            with patch.object(patch_ish.subprocess, "check_output", return_value=patch_ish.ISH_COMMIT + "\n"):
                patch_ish.patch(root)
                patch_ish.patch(root)  # repeated SDK preparation stays idempotent
            body = file.read_text().split("void do_uname(", 1)[1].split("\ndword_t sys_uname", 1)[0]
            c = root / "check.c"
            c.write_text('''#include <sys/utsname.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>
struct uname { char system[65],hostname[65],release[65],version[65],arch[65],domain[65]; };
const char *uname_version="fixture", *uname_hostname_override;
int uname(struct utsname *value) { memset(value,0,sizeof(*value)); return -1; }
void do_uname(''' + body + '''
int main(void) {
 char long_name[600]; memset(long_name,'a',599); long_name[599]=0;
 uname_hostname_override=long_name; struct uname result; do_uname(&result);
 assert(strlen(result.hostname)==64); assert(strcmp(result.release,"4.20.69-ish")==0);
 assert(strcmp(result.arch,"aarch64")==0); assert(strcmp(result.domain,"(none)")==0);
 uname_hostname_override=0; do_uname(&result); assert(result.hostname[0]==0);
 return 0;
}
''')
            binary = root / "check"
            subprocess.run([compiler, "-DGUEST_ARM64", "-D_FORTIFY_SOURCE=2", "-O1", "-fsanitize=address", str(c), "-o", str(binary)], check=True, capture_output=True)
            subprocess.run([str(binary)], check=True, capture_output=True)
