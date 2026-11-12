#include "PCRawIO.h"
#include <DiskArbitration/DiskArbitration.h>
#include <CoreFoundation/CoreFoundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/disk.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <limits.h>

static int address(const char *path, struct sockaddr_un *a) {
    if (!path || strlen(path) >= sizeof(a->sun_path)) {errno=ENAMETOOLONG; return -1;}
    memset(a,0,sizeof(*a)); a->sun_family=AF_UNIX; a->sun_len=sizeof(*a);
    strcpy(a->sun_path,path); return 0;
}
int pc_create_listener(const char *path) {
    struct sockaddr_un a;
    if(address(path,&a)<0) return -1;
    int fd=socket(AF_UNIX,SOCK_STREAM,0); if(fd<0) return -1;
    fcntl(fd,F_SETFD,FD_CLOEXEC);
    // No unlink: pre-existing names, including symlinks, cause a safe failure.
    mode_t previous=umask(0077);
    int r=bind(fd,(struct sockaddr*)&a,sizeof(a)); int e=errno; umask(previous);
    if(r<0 || listen(fd,1)<0) {if(r<0)errno=e; e=errno;close(fd);errno=e;return -1;}
    return fd;
}
int pc_receive_readonly_fd(int listener,const char *expected,int timeout_ms) {
    struct pollfd p={.fd=listener,.events=POLLIN};
    int pr; do {pr=poll(&p,1,timeout_ms);} while(pr<0&&errno==EINTR);
    if(pr<=0) {if(pr==0)errno=ETIMEDOUT;return -1;}
    int c=accept(listener,NULL,NULL);if(c<0)return -1;
    uid_t uid;gid_t gid;
    if(getpeereid(c,&uid,&gid)<0 || (uid!=0&&uid!=getuid())) {close(c);errno=EACCES;return -1;}
    struct timeval timeout={.tv_sec=5};setsockopt(c,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    char byte=0;struct iovec io={&byte,1};
    union {struct cmsghdr align;char data[CMSG_SPACE(sizeof(int))];} control;
    memset(&control,0,sizeof(control));struct msghdr msg={0};
    msg.msg_iov=&io;msg.msg_iovlen=1;msg.msg_control=control.data;msg.msg_controllen=sizeof(control.data);
    ssize_t n=recvmsg(c,&msg,0);int e=errno;close(c);errno=e;
    struct cmsghdr *h=CMSG_FIRSTHDR(&msg);
    if(n!=1||byte!='R'||(msg.msg_flags&MSG_CTRUNC)||!h||h->cmsg_level!=SOL_SOCKET||h->cmsg_type!=SCM_RIGHTS||h->cmsg_len!=CMSG_LEN(sizeof(int))) {errno=EPROTO;return -1;}
    int fd;memcpy(&fd,CMSG_DATA(h),sizeof(fd));
    struct stat actual,wanted;int flags=fcntl(fd,F_GETFL);
    if(flags<0||(flags&O_ACCMODE)!=O_RDONLY||fstat(fd,&actual)<0||stat(expected,&wanted)<0||actual.st_rdev!=wanted.st_rdev||(!S_ISCHR(actual.st_mode)&&!S_ISBLK(actual.st_mode))) {close(fd);errno=EACCES;return -1;}
    fcntl(fd,F_SETFD,FD_CLOEXEC);return fd;
}
static int external_whole(const char *bsd) {
    DASessionRef s=DASessionCreate(NULL);if(!s)return 0;
    DADiskRef d=DADiskCreateFromBSDName(NULL,s,bsd);if(!d){CFRelease(s);return 0;}
    CFDictionaryRef desc=DADiskCopyDescription(d);int ok=0;
    if(desc) {
        CFTypeRef internal=CFDictionaryGetValue(desc,kDADiskDescriptionDeviceInternalKey);
        CFTypeRef whole=CFDictionaryGetValue(desc,kDADiskDescriptionMediaWholeKey);
        ok=internal==kCFBooleanFalse && whole==kCFBooleanTrue;
        CFRelease(desc);
    }
    CFRelease(d);CFRelease(s);return ok;
}
int pc_send_raw_fd(const char *bsd,const char *socket_path,uid_t requesting_uid) {
    if(!bsd||strncmp(bsd,"disk",4)||!bsd[4]||strlen(bsd)>8) {errno=EINVAL;return -1;}
    for(size_t i=4;bsd[i];i++)if(bsd[i]<'0'||bsd[i]>'9'){errno=EINVAL;return -1;}
    if(requesting_uid<500 || (geteuid()!=0&&getuid()!=requesting_uid)) {errno=EACCES;return -1;}
    // Only connect to a socket inside a private directory owned by the requester.
    char parent[PATH_MAX];if(!socket_path||strlen(socket_path)>=sizeof(parent)){errno=EINVAL;return -1;}
    strcpy(parent,socket_path);char *slash=strrchr(parent,'/');if(!slash){errno=EINVAL;return -1;}*slash=0;
    struct stat st;if(lstat(parent,&st)<0||!S_ISDIR(st.st_mode)||st.st_uid!=requesting_uid||(st.st_mode&0077)){errno=EACCES;return -1;}
    if(lstat(socket_path,&st)<0||!S_ISSOCK(st.st_mode)||st.st_uid!=requesting_uid){errno=EACCES;return -1;}
    struct sockaddr_un a;if(address(socket_path,&a)<0)return -1;
    int c=socket(AF_UNIX,SOCK_STREAM,0);if(c<0)return -1;
    if(connect(c,(struct sockaddr*)&a,sizeof(a))<0){int e=errno;close(c);errno=e;return -1;}
    uid_t peer;gid_t group;
    if(getpeereid(c,&peer,&group)<0||peer!=requesting_uid||!external_whole(bsd)){close(c);errno=EACCES;return -1;}
    char device[64];snprintf(device,sizeof(device),"/dev/r%s",bsd);
    // This is the only device open in the privileged helper.
    int fd=open(device,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);if(fd<0){int e=errno;close(c);errno=e;return -1;}
    char byte='R';struct iovec io={&byte,1};
    union {struct cmsghdr align;char data[CMSG_SPACE(sizeof(int))];} control;
    memset(&control,0,sizeof(control));struct msghdr msg={0};
    msg.msg_iov=&io;msg.msg_iovlen=1;msg.msg_control=control.data;msg.msg_controllen=sizeof(control.data);
    struct cmsghdr *h=CMSG_FIRSTHDR(&msg);h->cmsg_level=SOL_SOCKET;h->cmsg_type=SCM_RIGHTS;h->cmsg_len=CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(h),&fd,sizeof(fd));
    int n=(int)sendmsg(c,&msg,0);int e=errno;close(fd);close(c);errno=e;return n==1?0:-1;
}
uint64_t pc_device_size(int fd) {
    uint64_t blocks=0;uint32_t size=0;
    if(ioctl(fd,DKIOCGETBLOCKCOUNT,&blocks)<0||ioctl(fd,DKIOCGETBLOCKSIZE,&size)<0||!size||blocks>UINT64_MAX/size)return 0;
    return blocks*size;
}
