/* OGG Vorbis and MP3 decoding for importing Mechvibes / MechvibesDX / Thock sound packs
 * (src/pack_import.zig). Vendored, unmodified: stb_vorbis.c v1.22 (github.com/nothings/stb
 * @ f58f558, public domain / MIT) and minimp3.h + minimp3_ex.h (github.com/lieff/minimp3
 * @ afb604c, CC0 1.0). Both return interleaved 16-bit samples allocated with malloc; free
 * them with tb_decoder_free. */
#include <stdlib.h>
#include <string.h>

#define STB_VORBIS_NO_STDIO
#define STB_VORBIS_NO_PUSHDATA_API
#include "stb_vorbis.c"

/* Returns frames (samples per channel), or -1 on error. */
int tb_decode_ogg(const unsigned char *data, int len, int *channels, int *rate, short **out) {
    int frames = stb_vorbis_decode_memory(data, len, channels, rate, out);
    return frames < 0 ? -1 : frames;
}

void tb_decoder_free(void *p) { free(p); }
