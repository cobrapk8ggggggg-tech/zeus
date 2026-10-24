"""Execute the actual patched C function with an overlong hostname and ASan."""
from pathlib import Path
import shutil
import os
import sys
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
            for name in ["fs/fd.h", "fs/fake.c"]:
                target = root / "deps/ish" / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source.parent.parent / name, target)
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
static int zeus_fixture_uname(struct utsname *value) { memset(value,0,sizeof(*value)); return -1; }
#define uname(value) zeus_fixture_uname(value)
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
            # AddressSanitizer's runtime hangs before this tiny executable exits
            # on the current macOS ARM runner. Darwin's fortified strcpy (the
            # actual failing runtime check) plus bounds/UBSan exercise the same
            # assertions there; Linux also runs the AddressSanitizer regression.
            sanitizer = "-fsanitize=undefined,bounds" if sys.platform == "darwin" else "-fsanitize=address"
            subprocess.run([compiler, "-DGUEST_ARM64", "-D_FORTIFY_SOURCE=2", "-O1", sanitizer, str(c), "-o", str(binary)], check=True, capture_output=True, timeout=30)
            subprocess.run([str(binary)], check=True, capture_output=True, timeout=30, env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0:symbolize=0", "UBSAN_OPTIONS": "halt_on_error=1:print_stacktrace=0"})

    def test_hook_file_type_and_chmod_ignore_colliding_guest_inode(self):
        upstream = Path(os.environ.get("ZEUS_OPENMINIS_SOURCE", Path(__file__).parent.parent / "Vendor/OpenMinis")) / "deps/ish"
        compiler = shutil.which("clang") or shutil.which("cc")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ["kernel/uname.c", "fs/fd.h", "fs/fake.c"]:
                target = root / "deps/ish" / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(upstream / name, target)
            with patch.object(patch_ish.subprocess, "check_output", return_value=patch_ish.ISH_COMMIT + "\n"):
                patch_ish.patch(root)
                patch_ish.patch(root)
            source = (root / "deps/ish/fs/fake.c").read_text()
            self.assertIn("fd->fakefs_hook_routed = true;", source)
            fstat = source[source.index("static int fakefs_fstat("):source.index("static void fake_stat_setattr(")]
            fsetattr = source[source.index("static int fakefs_fsetattr("):source.index("static int fakefs_mkdir(")]
            check = root / "check.c"
            check.write_text('''#include <stdbool.h>
#include <stdint.h>
#include <sys/stat.h>
#include <errno.h>
#include <assert.h>
#define MAX_PATH 4096
#define PATH_MAX 4096
#define _ENOENT (-ENOENT)
typedef uint32_t mode_t_;
struct fakefs_db { int dummy; };
struct mount { struct fakefs_db fakefs; };
struct statbuf { uint64_t inode; uint32_t mode,uid,gid,rdev; };
struct ish_stat { uint32_t mode,uid,gid,rdev; };
struct fd { struct mount *mount; int real_fd; uint64_t fake_inode; bool fakefs_hook_routed;
 struct {uint32_t mode,uid,gid,rdev;bool valid;} fake_open_stat; };
enum {attr_size,attr_mode,attr_uid,attr_gid};
struct attr {int type; uint32_t mode;};
static int reads,writes,chmods,host_error;
static bool row_exists=true;
static uint32_t host_mode=S_IFREG|0600;
static int host_fstat(struct fd *fd,struct statbuf *s) { (void)fd; if(host_error)return host_error; *s=(struct statbuf){.inode=42,.mode=host_mode};return 0; }
static int host_fsetattr(struct fd *f,struct attr a) {(void)f;(void)a;return 0;}
static struct {int (*fstat)(struct fd *,struct statbuf *);int (*fsetattr)(struct fd *,struct attr);} realfs={host_fstat,host_fsetattr};
static void db_begin_read(struct fakefs_db *f){(void)f;} static void db_begin_write(struct fakefs_db *f){(void)f;}
static void db_commit(struct fakefs_db *f){(void)f;} static void db_rollback(struct fakefs_db *f){(void)f;}
static bool inode_read_stat_if_exist(struct fakefs_db *f,uint64_t i,struct ish_stat *s){(void)f;assert(i==42);reads++;*s=(struct ish_stat){.mode=S_IFDIR|0700};return row_exists;}
static int realfs_getpath(struct fd *f,char *p){(void)f;(void)p;return -1;}
static bool bind_mount_translate_path_ex(const char *p,char *b,int n,bool *h){(void)p;(void)b;(void)n;*h=false;return false;}
static void fake_stat_setattr(struct ish_stat *s,struct attr a){(void)s;(void)a;}
static void inode_write_stat(struct fakefs_db *f,uint64_t i,struct ish_stat *s){(void)f;(void)i;(void)s;writes++;}
static int mock_chmod(int f,uint32_t m){assert(f==7);assert(m==0600);chmods++;return 0;}
#define fchmod mock_chmod
static int errno_map(void){return -EIO;}
''' + fstat + fsetattr + '''
int main(void){
 struct mount mount={0}; struct fd fd={.mount=&mount,.real_fd=7,.fake_inode=42,.fakefs_hook_routed=true}; struct statbuf st;
 /* The guest directory's inode deliberately equals the host regular file's. */
 fd.fake_open_stat.valid=false;fd.fake_open_stat.mode=S_IFDIR|0700;
 assert(fakefs_fstat(&fd,&st)==0); assert(S_ISREG(st.mode));assert(st.inode==42);assert(reads==0);
 assert(fakefs_fsetattr(&fd,(struct attr){.type=attr_mode,.mode=0600})==0);assert(chmods==1&&writes==0&&reads==0);
 host_mode=S_IFDIR|0700;assert(fakefs_fstat(&fd,&st)==0);assert(S_ISDIR(st.mode));
 /* Ordinary guest descriptors must still obey their guest metadata. */
 fd.fakefs_hook_routed=false;fd.fake_open_stat.valid=false;host_mode=S_IFREG|0600;
 assert(fakefs_fstat(&fd,&st)==0);assert(S_ISDIR(st.mode));assert(reads==1);
 row_exists=false;assert(fakefs_fstat(&fd,&st)==_ENOENT);
 fd.fakefs_hook_routed=true;assert(fakefs_fstat(&fd,&st)==0);assert(S_ISREG(st.mode));
 host_error=-EIO;assert(fakefs_fstat(&fd,&st)==-EIO);
 return 0;
}
''')
            binary=root/"check"
            sanitizer="-fsanitize=undefined,bounds" if sys.platform=="darwin" else "-fsanitize=address"
            subprocess.run([compiler,"-D_DEFAULT_SOURCE","-O1",sanitizer,str(check),"-o",str(binary)],check=True,capture_output=True,timeout=30)
            subprocess.run([str(binary)],check=True,capture_output=True,timeout=30,env={**os.environ,"ASAN_OPTIONS":"detect_leaks=0:symbolize=0","UBSAN_OPTIONS":"halt_on_error=1"})
            if sys.platform != "darwin":
                # Negative control: the real unpatched functions misclassify
                # this same regular host file as the colliding guest directory.
                original=(upstream/"fs/fake.c").read_text()
                old_stat=original[original.index("static int fakefs_fstat("):original.index("static void fake_stat_setattr(")]
                old_attr=original[original.index("static int fakefs_fsetattr("):original.index("static int fakefs_mkdir(")]
                broken=root/"unpatched.c"
                broken.write_text(check.read_text().replace(fstat+fsetattr,old_stat+old_attr))
                unpatched=root/"unpatched"
                subprocess.run([compiler,"-D_DEFAULT_SOURCE","-O1",str(broken),"-o",str(unpatched)],check=True,capture_output=True,timeout=30)
                result=subprocess.run([str(unpatched)],capture_output=True,timeout=30,cwd=root)
                self.assertNotEqual(result.returncode,0,"The collision must reproduce on the actual upstream functions")
                self.assertIn(b"S_ISREG", result.stderr)
