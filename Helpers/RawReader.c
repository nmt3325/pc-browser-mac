#include "PCRawIO.h"
#include <stdlib.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <limits.h>
int main(int argc,char **argv) {
    if(argc!=7||strcmp(argv[1],"--device")||strcmp(argv[3],"--socket")||strcmp(argv[5],"--uid")) {
        fprintf(stderr,"Usage: PCBrowserRawReader --device diskN --socket PATH --uid UID\n");return 64;
    }
    char *end;unsigned long uid=strtoul(argv[6],&end,10);
    if(*end||uid<500||uid>UINT_MAX)return 64;
    if(pc_send_raw_fd(argv[2],argv[4],(uid_t)uid)<0){fprintf(stderr,"Read-only SD access: %s\n",strerror(errno));return 1;}
    return 0;
}
