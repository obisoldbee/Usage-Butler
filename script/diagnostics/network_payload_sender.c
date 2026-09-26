#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* Isolated loopback fixture. The orchestrator allocates ports; the sender
 * waits on stdin with both sockets open so a real source baseline is possible.
 * No traffic outside 127.0.0.1, no user configuration or inherited sockets. */
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int tcp = socket(AF_INET, SOCK_STREAM, 0), udp = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in address = { .sin_family = AF_INET };
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    address.sin_port = htons(atoi(argv[1]));
    if (connect(tcp, (void *)&address, sizeof(address))) return 3;
    address.sin_port = htons(atoi(argv[2]));
    if (connect(udp, (void *)&address, sizeof(address))) return 4;
    printf("ready %d\n", getpid()); fflush(stdout);
    if (getchar() != 'g') return 5;
    char buffer[32768]; memset(buffer, 'x', sizeof(buffer));
    for (int i = 0; i < 256; i++) {
        size_t sent = 0;
        while (sent < sizeof(buffer)) {
            ssize_t n = send(tcp, buffer + sent, sizeof(buffer) - sent, 0);
            if (n <= 0) return 6;
            sent += n;
        }
        usleep(8000);
    }
    size_t received = 0;
    while (received < 2097152) {
        ssize_t n = recv(tcp, buffer, sizeof(buffer), 0);
        if (n <= 0) return 7;
        received += n;
    }
    for (int i = 0; i < 512; i++) {
        if (send(udp, buffer, 1024, 0) != 1024) return 8;
        if (recv(udp, buffer, 64, 0) != 64) return 9;
        usleep(2000);
    }
    puts("complete"); fflush(stdout);
    /* Keep counters alive until source shutdown/restart checks complete. */
    getchar();
    close(tcp); close(udp); return 0;
}
