#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/input.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static bool parse_uint(const char *text, unsigned int maximum, unsigned int *value) {
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed > maximum) return false;
    *value = (unsigned int)parsed;
    return true;
}

static long long monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (long long)now.tv_sec * 1000LL + now.tv_nsec / 1000000LL;
}

static bool read_name(const char *path, char *name, size_t capacity) {
    FILE *source = fopen(path, "r");
    if (source == NULL) return false;
    bool ok = fgets(name, (int)capacity, source) != NULL;
    fclose(source);
    if (!ok) return false;
    name[strcspn(name, "\r\n")] = '\0';
    return true;
}

static bool find_event(const char *needle, char *device, size_t device_capacity,
                       char *found_name, size_t name_capacity) {
    glob_t matches;
    memset(&matches, 0, sizeof(matches));
    if (glob("/sys/class/input/event*/device/name", 0, NULL, &matches) != 0) {
        globfree(&matches);
        return false;
    }
    bool found = false;
    for (size_t index = 0; index < matches.gl_pathc && !found; ++index) {
        char name[256];
        if (!read_name(matches.gl_pathv[index], name, sizeof(name)) || strstr(name, needle) == NULL) {
            continue;
        }
        const char *event = strstr(matches.gl_pathv[index], "/event");
        if (event == NULL) continue;
        event++;
        const char *slash = strchr(event, '/');
        if (slash == NULL) continue;
        size_t event_length = (size_t)(slash - event);
        if (event_length == 0 || event_length > 40) continue;
        int written = snprintf(device, device_capacity, "/dev/input/%.*s", (int)event_length, event);
        if (written < 0 || (size_t)written >= device_capacity) continue;
        snprintf(found_name, name_capacity, "%s", name);
        found = true;
    }
    globfree(&matches);
    return found;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 4) {
        fprintf(stderr, "usage: %s NAME_SUBSTRING [TIMEOUT_MS] [EVENT_COUNT]\n", argv[0]);
        return 64;
    }
    unsigned int timeout_ms = 5000;
    unsigned int event_count = 4;
    if (argc >= 3 && !parse_uint(argv[2], 300000, &timeout_ms)) {
        fprintf(stderr, "invalid timeout: %s\n", argv[2]);
        return 64;
    }
    if (argc >= 4 && (!parse_uint(argv[3], 10000, &event_count) || event_count == 0)) {
        fprintf(stderr, "invalid event count: %s\n", argv[3]);
        return 64;
    }

    char device[128];
    char name[256];
    if (!find_event(argv[1], device, sizeof(device), name, sizeof(name))) {
        fprintf(stderr, "input device not found: %s\n", argv[1]);
        return 66;
    }
    int input = open(device, O_RDONLY | O_NONBLOCK);
    if (input < 0) {
        perror("open input device");
        return 1;
    }
    printf("device=%s name=%s\n", device, name);
    fflush(stdout);

    long long deadline = monotonic_ms() + timeout_ms;
    unsigned int observed = 0;
    while (observed < event_count) {
        long long remaining = deadline - monotonic_ms();
        if (remaining <= 0) {
            fprintf(stderr, "timed out after %u ms with %u events\n", timeout_ms, observed);
            close(input);
            return 124;
        }
        struct pollfd descriptor = {.fd = input, .events = POLLIN, .revents = 0};
        int status = poll(&descriptor, 1, remaining > 2147483647LL ? 2147483647 : (int)remaining);
        if (status < 0) {
            if (errno == EINTR) continue;
            perror("poll input device");
            close(input);
            return 1;
        }
        if (status == 0) continue;
        struct input_event event;
        ssize_t bytes = read(input, &event, sizeof(event));
        if (bytes < 0 && (errno == EAGAIN || errno == EINTR)) continue;
        if (bytes != (ssize_t)sizeof(event)) {
            fprintf(stderr, "short input event read\n");
            close(input);
            return 1;
        }
        printf("event type=%u code=%u value=%d\n", event.type, event.code, event.value);
        fflush(stdout);
        observed++;
    }
    close(input);
    return 0;
}
