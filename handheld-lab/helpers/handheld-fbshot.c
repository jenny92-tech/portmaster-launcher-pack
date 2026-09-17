// INPUT:  Linux framebuffer ioctl/mmap、标准 C 库与输出路径
// OUTPUT: main()；OUTPUT.ppm 帧缓冲截图
// POS:    为缺少图形桌面截图工具的掌机读取实际帧缓冲
#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static uint8_t component(uint32_t pixel, struct fb_bitfield field) {
    if (field.length == 0) return 0;
    uint32_t mask = field.length >= 32 ? UINT32_MAX : ((1U << field.length) - 1U);
    uint32_t value = (pixel >> field.offset) & mask;
    return (uint8_t)((value * 255U + mask / 2U) / mask);
}

static uint32_t load_pixel(const uint8_t *source, unsigned int bytes_per_pixel) {
    uint32_t pixel = 0;
    for (unsigned int index = 0; index < bytes_per_pixel; ++index) {
        pixel |= (uint32_t)source[index] << (index * 8U);
    }
    return pixel;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s OUTPUT.ppm\n", argv[0]);
        return 64;
    }
    int framebuffer = open("/dev/fb0", O_RDONLY);
    if (framebuffer < 0) {
        perror("open /dev/fb0");
        return 1;
    }

    struct fb_fix_screeninfo fixed;
    struct fb_var_screeninfo variable;
    if (ioctl(framebuffer, FBIOGET_FSCREENINFO, &fixed) != 0 ||
        ioctl(framebuffer, FBIOGET_VSCREENINFO, &variable) != 0) {
        perror("framebuffer info");
        close(framebuffer);
        return 1;
    }
    unsigned int bytes_per_pixel = (variable.bits_per_pixel + 7U) / 8U;
    if (bytes_per_pixel < 2 || bytes_per_pixel > 4 || variable.xres == 0 || variable.yres == 0) {
        fprintf(stderr, "unsupported framebuffer: %ux%u %u bpp\n",
                variable.xres, variable.yres, variable.bits_per_pixel);
        close(framebuffer);
        return 69;
    }
    if (fixed.smem_len == 0) {
        fprintf(stderr, "framebuffer reports zero memory\n");
        close(framebuffer);
        return 69;
    }

    uint8_t *memory = mmap(NULL, fixed.smem_len, PROT_READ, MAP_SHARED, framebuffer, 0);
    if (memory == MAP_FAILED) {
        perror("mmap framebuffer");
        close(framebuffer);
        return 1;
    }
    FILE *output = fopen(argv[1], "wb");
    if (output == NULL) {
        perror("open output");
        munmap(memory, fixed.smem_len);
        close(framebuffer);
        return 1;
    }
    if (fprintf(output, "P6\n%u %u\n255\n", variable.xres, variable.yres) < 0) {
        perror("write output header");
        fclose(output);
        munmap(memory, fixed.smem_len);
        close(framebuffer);
        return 1;
    }

    int status = 0;
    for (unsigned int y = 0; y < variable.yres && status == 0; ++y) {
        size_t row = (size_t)(y + variable.yoffset) * fixed.line_length;
        size_t column = (size_t)variable.xoffset * bytes_per_pixel;
        for (unsigned int x = 0; x < variable.xres; ++x) {
            size_t offset = row + column + (size_t)x * bytes_per_pixel;
            if (offset + bytes_per_pixel > fixed.smem_len) {
                fprintf(stderr, "framebuffer bounds exceeded\n");
                status = 1;
                break;
            }
            uint32_t pixel = load_pixel(memory + offset, bytes_per_pixel);
            uint8_t rgb[3] = {
                component(pixel, variable.red),
                component(pixel, variable.green),
                component(pixel, variable.blue),
            };
            if (fwrite(rgb, 1, sizeof(rgb), output) != sizeof(rgb)) {
                perror("write output pixels");
                status = 1;
                break;
            }
        }
    }
    if (fclose(output) != 0) status = 1;
    munmap(memory, fixed.smem_len);
    close(framebuffer);
    return status;
}
