// INPUT:  Linux uinput、信号/FIFO 接口与模式/按键参数
// OUTPUT: main()；probe/tap/serve 虚拟输入命令
// POS:    以短时按键或持久虚拟设备为掌机提供原生输入注入
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int device_fd = -1;

static void sleep_ms(unsigned int milliseconds) {
    struct timespec duration = {
        .tv_sec = milliseconds / 1000,
        .tv_nsec = (long)(milliseconds % 1000) * 1000000L,
    };
    while (nanosleep(&duration, &duration) != 0 && errno == EINTR) {
    }
}

static void destroy_device(void) {
    if (device_fd >= 0) {
        ioctl(device_fd, UI_DEV_DESTROY);
        close(device_fd);
        device_fd = -1;
    }
}

static void handle_signal(int signal_number) {
    (void)signal_number;
    destroy_device();
    _exit(128);
}

static void enable_key(int fd, int code) {
    if (ioctl(fd, UI_SET_KEYBIT, code) != 0) {
        perror("UI_SET_KEYBIT");
        destroy_device();
        exit(1);
    }
}

static int create_device(const char *mode) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("open /dev/uinput");
        return -1;
    }
    device_fd = fd;
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) != 0) {
        perror("UI_SET_EVBIT");
        destroy_device();
        return -1;
    }

    if (strcmp(mode, "keyboard") == 0) {
        const int keys[] = {
            KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_ENTER, KEY_ESC,
            KEY_SPACE, KEY_TAB, KEY_BACKSPACE, KEY_POWER, KEY_VOLUMEUP,
            KEY_VOLUMEDOWN,
        };
        for (size_t index = 0; index < sizeof(keys) / sizeof(keys[0]); ++index) {
            enable_key(fd, keys[index]);
        }
    } else if (strcmp(mode, "gamepad") == 0) {
        const int keys[] = {
            BTN_SOUTH, BTN_EAST, BTN_NORTH, BTN_WEST,
            BTN_DPAD_UP, BTN_DPAD_DOWN, BTN_DPAD_LEFT, BTN_DPAD_RIGHT,
            BTN_TL, BTN_TR, BTN_TL2, BTN_TR2, BTN_SELECT, BTN_START,
            BTN_MODE, BTN_THUMBL, BTN_THUMBR, KEY_POWER, KEY_VOLUMEUP,
            KEY_VOLUMEDOWN,
        };
        for (size_t index = 0; index < sizeof(keys) / sizeof(keys[0]); ++index) {
            enable_key(fd, keys[index]);
        }
    } else {
        fprintf(stderr, "unsupported input mode: %s\n", mode);
        destroy_device();
        return -1;
    }

    struct uinput_user_dev setup;
    memset(&setup, 0, sizeof(setup));
    snprintf(setup.name, sizeof(setup.name), "Handheld DevTools Virtual %s", mode);
    setup.id.bustype = BUS_USB;
    setup.id.vendor = 0x1209;
    setup.id.product = strcmp(mode, "keyboard") == 0 ? 0x0002 : 0x0001;
    setup.id.version = 1;
    if (write(fd, &setup, sizeof(setup)) != (ssize_t)sizeof(setup)) {
        perror("write uinput setup");
        destroy_device();
        return -1;
    }
    if (ioctl(fd, UI_DEV_CREATE) != 0) {
        perror("UI_DEV_CREATE");
        destroy_device();
        return -1;
    }
    sleep_ms(300);
    return fd;
}

static int probe_device(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        perror("open /dev/uinput");
        return 1;
    }
    if (ioctl(fd, UI_SET_EVBIT, EV_KEY) != 0) {
        perror("UI_SET_EVBIT");
        close(fd);
        return 1;
    }
    close(fd);
    printf("uinput-ready\n");
    return 0;
}

static int gamepad_code(const char *button) {
    if (strcmp(button, "south") == 0 || strcmp(button, "confirm") == 0) return BTN_SOUTH;
    if (strcmp(button, "east") == 0 || strcmp(button, "cancel") == 0) return BTN_EAST;
    if (strcmp(button, "north") == 0) return BTN_NORTH;
    if (strcmp(button, "west") == 0) return BTN_WEST;
    if (strcmp(button, "dpad_up") == 0 || strcmp(button, "up") == 0) return BTN_DPAD_UP;
    if (strcmp(button, "dpad_down") == 0 || strcmp(button, "down") == 0) return BTN_DPAD_DOWN;
    if (strcmp(button, "dpad_left") == 0 || strcmp(button, "left") == 0) return BTN_DPAD_LEFT;
    if (strcmp(button, "dpad_right") == 0 || strcmp(button, "right") == 0) return BTN_DPAD_RIGHT;
    if (strcmp(button, "l1") == 0) return BTN_TL;
    if (strcmp(button, "r1") == 0) return BTN_TR;
    if (strcmp(button, "l2") == 0) return BTN_TL2;
    if (strcmp(button, "r2") == 0) return BTN_TR2;
    if (strcmp(button, "select") == 0) return BTN_SELECT;
    if (strcmp(button, "start") == 0) return BTN_START;
    if (strcmp(button, "guide") == 0) return BTN_MODE;
    if (strcmp(button, "l3") == 0) return BTN_THUMBL;
    if (strcmp(button, "r3") == 0) return BTN_THUMBR;
    if (strcmp(button, "power") == 0) return KEY_POWER;
    if (strcmp(button, "volume_up") == 0) return KEY_VOLUMEUP;
    if (strcmp(button, "volume_down") == 0) return KEY_VOLUMEDOWN;
    return -1;
}

static int keyboard_code(const char *button) {
    if (strcmp(button, "dpad_up") == 0 || strcmp(button, "up") == 0) return KEY_UP;
    if (strcmp(button, "dpad_down") == 0 || strcmp(button, "down") == 0) return KEY_DOWN;
    if (strcmp(button, "dpad_left") == 0 || strcmp(button, "left") == 0) return KEY_LEFT;
    if (strcmp(button, "dpad_right") == 0 || strcmp(button, "right") == 0) return KEY_RIGHT;
    if (strcmp(button, "south") == 0 || strcmp(button, "confirm") == 0) return KEY_ENTER;
    if (strcmp(button, "east") == 0 || strcmp(button, "cancel") == 0) return KEY_ESC;
    if (strcmp(button, "start") == 0) return KEY_ENTER;
    if (strcmp(button, "select") == 0) return KEY_SPACE;
    if (strcmp(button, "guide") == 0) return KEY_TAB;
    if (strcmp(button, "power") == 0) return KEY_POWER;
    if (strcmp(button, "volume_up") == 0) return KEY_VOLUMEUP;
    if (strcmp(button, "volume_down") == 0) return KEY_VOLUMEDOWN;
    return -1;
}

static int button_code(const char *mode, const char *button) {
    return strcmp(mode, "keyboard") == 0 ? keyboard_code(button) : gamepad_code(button);
}

static int emit_event(uint16_t type, uint16_t code, int32_t value) {
    struct input_event event;
    memset(&event, 0, sizeof(event));
    event.type = type;
    event.code = code;
    event.value = value;
    if (write(device_fd, &event, sizeof(event)) != (ssize_t)sizeof(event)) {
        perror("write input event");
        return -1;
    }
    return 0;
}

static int tap_button(const char *mode, const char *button, unsigned int hold_ms) {
    int code = button_code(mode, button);
    if (code < 0) {
        fprintf(stderr, "unsupported %s button: %s\n", mode, button);
        return 65;
    }
    if (emit_event(EV_KEY, (uint16_t)code, 1) != 0 || emit_event(EV_SYN, SYN_REPORT, 0) != 0) {
        return 1;
    }
    sleep_ms(hold_ms);
    if (emit_event(EV_KEY, (uint16_t)code, 0) != 0 || emit_event(EV_SYN, SYN_REPORT, 0) != 0) {
        return 1;
    }
    return 0;
}

static bool parse_hold(const char *text, unsigned int *value) {
    char *end = NULL;
    errno = 0;
    unsigned long parsed = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed > 10000) return false;
    *value = (unsigned int)parsed;
    return true;
}

static int serve_fifo(const char *fifo_path, const char *mode) {
    if (mkfifo(fifo_path, 0600) != 0 && errno != EEXIST) {
        perror("mkfifo");
        return 1;
    }
    if (create_device(mode) < 0) return 1;
    printf("ready mode=%s fifo=%s\n", mode, fifo_path);
    fflush(stdout);

    bool running = true;
    while (running) {
        FILE *fifo = fopen(fifo_path, "r");
        if (fifo == NULL) {
            if (errno == EINTR) continue;
            perror("open input fifo");
            destroy_device();
            return 1;
        }
        char line[256];
        while (running && fgets(line, sizeof(line), fifo) != NULL) {
            char button[80];
            char hold_text[32];
            if (sscanf(line, "%79s %31s", button, hold_text) == 2) {
                unsigned int hold_ms;
                if (!parse_hold(hold_text, &hold_ms)) {
                    fprintf(stderr, "invalid hold time: %s\n", hold_text);
                    continue;
                }
                int status = tap_button(mode, button, hold_ms);
                if (status != 0) fprintf(stderr, "tap failed: %s status=%d\n", button, status);
            } else if (strncmp(line, "QUIT", 4) == 0) {
                running = false;
            } else {
                fprintf(stderr, "invalid input command: %s", line);
            }
        }
        fclose(fifo);
    }
    destroy_device();
    return 0;
}

static void usage(const char *program) {
    fprintf(stderr,
            "usage: %s probe\n"
            "       %s tap BUTTON [HOLD_MS] [gamepad|keyboard]\n"
            "       %s serve FIFO [gamepad|keyboard]\n",
            program, program, program);
}

int main(int argc, char **argv) {
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGHUP, handle_signal);

    if (argc == 2 && strcmp(argv[1], "probe") == 0) {
        return probe_device();
    }
    if (argc >= 3 && strcmp(argv[1], "tap") == 0) {
        const char *mode = argc >= 5 ? argv[4] : "gamepad";
        unsigned int hold_ms = 80;
        if (argc >= 4 && !parse_hold(argv[3], &hold_ms)) {
            fprintf(stderr, "invalid hold time: %s\n", argv[3]);
            return 64;
        }
        if (create_device(mode) < 0) return 1;
        int status = tap_button(mode, argv[2], hold_ms);
        sleep_ms(50);
        destroy_device();
        return status;
    }
    if (argc >= 3 && strcmp(argv[1], "serve") == 0) {
        const char *mode = argc >= 4 ? argv[3] : "gamepad";
        return serve_fifo(argv[2], mode);
    }
    usage(argv[0]);
    return 64;
}
