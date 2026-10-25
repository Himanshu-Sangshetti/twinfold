// meta: prints everything about a file that a person or app could notice, except its inode and ctime,
// so the safety tests can prove a fold or undo changed nothing. With -p, prints where its data lives on disk.
//   meta FILE...      mode uid gid flags created modified added acl xattrs(name=sha256)
//   meta -p FILE...   physical offset of the first block (equal for two files = shared storage)
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/acl.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

static int cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

static void hex(const unsigned char *d, int n) { for (int i = 0; i < n; i++) printf("%02x", d[i]); }

static int physical(const char *path) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) { printf("%s\tERROR\n", path); return 1; }
    struct log2phys l = {0};
    l.l2p_contigbytes = 1;
    l.l2p_devoffset = 0;
    int r = fcntl(fd, F_LOG2PHYS_EXT, &l);
    close(fd);
    printf("%s\t%lld\n", path, r == -1 ? -1LL : (long long)l.l2p_devoffset);
    return 0;
}

static int describe(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) { printf("%s\tMISSING%c", path, 0); return 1; }
    struct attrlist al = {0};
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_ADDEDTIME;
    struct __attribute__((packed)) { uint32_t len; struct timespec cr, mod, added; } t = {0};
    getattrlist(path, &al, &t, sizeof t, FSOPT_NOFOLLOW);
    printf("%s\tmode=%o uid=%u gid=%u flags=%x created=%ld modified=%ld.%09ld added=%ld", path, st.st_mode,
           st.st_uid, st.st_gid, st.st_flags, t.cr.tv_sec, t.mod.tv_sec, t.mod.tv_nsec, t.added.tv_sec);

    acl_t acl = acl_get_link_np(path, ACL_TYPE_EXTENDED);
    if (acl) {
        char *text = acl_to_text(acl, NULL);
        for (char *c = text; c && *c; c++) if (*c == '\n') *c = ';';
        printf(" acl=[%s]", text ? text : "");
        if (text) acl_free(text);
        acl_free(acl);
    }

    ssize_t size = listxattr(path, NULL, 0, XATTR_NOFOLLOW);
    if (size > 0) {
        char *names = malloc(size);
        listxattr(path, names, size, XATTR_NOFOLLOW);
        char *list[256]; int n = 0;
        for (char *p = names; p < names + size && n < 256; p += strlen(p) + 1) list[n++] = p;
        qsort(list, n, sizeof *list, cmp);
        for (int i = 0; i < n; i++) {
            // macOS stamps every new file with the creating app (com.apple.provenance) and no app can set it,
            // so a clone always gets the cloning app's. Twinfold leaves it out of "unchanged"; so does this.
            if (strcmp(list[i], "com.apple.provenance") == 0) continue;
            ssize_t len = getxattr(path, list[i], NULL, 0, 0, XATTR_NOFOLLOW);
            unsigned char *v = malloc(len > 0 ? len : 1), digest[CC_SHA256_DIGEST_LENGTH];
            getxattr(path, list[i], v, len, 0, XATTR_NOFOLLOW);
            CC_SHA256(v, (CC_LONG)(len > 0 ? len : 0), digest);
            printf(" x:%s=", list[i]);
            hex(digest, 6);
            free(v);
        }
        free(names);
    }
    putchar(0);  // records end in NUL, so file names with newlines stay parseable
    return 0;
}

int main(int argc, char **argv) {
    int phys = argc > 1 && strcmp(argv[1], "-p") == 0, bad = 0;
    for (int i = 1 + phys; i < argc; i++) bad |= phys ? physical(argv[i]) : describe(argv[i]);
    return bad;
}
