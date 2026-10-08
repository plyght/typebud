/* MP3 half of decoders.c (minimp3 and stb_vorbis both define get_bits, so they live in
 * separate translation units). */
#include <stdlib.h>
#include <string.h>

#define MINIMP3_IMPLEMENTATION
#define MINIMP3_NO_STDIO
#include "minimp3_ex.h"

int tb_decode_mp3(const unsigned char *data, int len, int *channels, int *rate, short **out) {
    mp3dec_t dec;
    mp3dec_file_info_t info;
    memset(&info, 0, sizeof info);
    if (mp3dec_load_buf(&dec, data, (size_t)len, &info, NULL, NULL) != 0 || info.channels <= 0 || info.samples == 0) {
        free(info.buffer);
        return -1;
    }
    *channels = info.channels;
    *rate = info.hz;
    *out = info.buffer;
    return (int)(info.samples / (size_t)info.channels);
}
