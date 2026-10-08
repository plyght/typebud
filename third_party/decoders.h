int tb_decode_ogg(const unsigned char *data, int len, int *channels, int *rate, short **out);
int tb_decode_mp3(const unsigned char *data, int len, int *channels, int *rate, short **out);
void tb_decoder_free(void *p);
