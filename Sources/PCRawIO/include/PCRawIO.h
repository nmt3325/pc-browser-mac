#ifndef PC_RAW_IO_H
#define PC_RAW_IO_H
#include <stdint.h>
#include <sys/types.h>
// Privilege boundary: the helper opens one external whole disk O_RDONLY and
// transfers the descriptor to the requesting UID. It never writes to a disk.
int pc_create_listener(const char *socket_path);
int pc_receive_readonly_fd(int listener, const char *expected_device, int timeout_ms);
int pc_send_raw_fd(const char *bsd_name, const char *socket_path, uid_t requesting_uid);
uint64_t pc_device_size(int fd);
#endif
