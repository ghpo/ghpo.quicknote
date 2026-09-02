/* quicknote-audio.c — plays a raw G.711 mu-law file through ALSA.
 *
 * The embedded music is pre-rendered (no real-time synthesis), so there is
 * no aliasing/hiss and no timidity/soundfont dependency at runtime — only
 * gcc + alsa-lib are needed to build it.
 *
 * Usage: quicknote-audio <file.ulaw>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <alsa/asoundlib.h>

#define SR       16000

/* G.711 mu-law expansion (standard ITU-T G.711 decode). */
static int16_t ulaw2linear(unsigned char u) {
    u = ~u;
    int sign = (u & 0x80) ? -1 : 1;
    int exponent = (u >> 4) & 0x07;
    int mantissa = ((u & 0x0F) << 3) + 0x84;
    int sample = (mantissa << exponent) - 0x84;
    return (int16_t)(sign * sample);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: quicknote-audio <file.ulaw>\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    fseek(f, 0, SEEK_END);
    long nbytes = ftell(f);
    fseek(f, 0, SEEK_SET);

    snd_pcm_t *pcm;
    if (snd_pcm_open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0) return 1;
    if (snd_pcm_set_params(pcm, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
                           1, SR, 1, 500000) < 0) return 1;

    unsigned char in[4096];
    int16_t out[4096];
    long done = 0;
    while (done < nbytes) {
        size_t want = sizeof in;
        if (nbytes - done < (long)want) want = (size_t)(nbytes - done);
        size_t got = fread(in, 1, want, f);
        if (got == 0) break;
        for (size_t i = 0; i < got; i++) {
            int32_t v = (int32_t)ulaw2linear(in[i]) * 5 / 3;   /* gain */
            if (v > 32767) v = 32767; if (v < -32768) v = -32768;
            out[i] = (int16_t)v;
        }
        size_t off = 0;
        while (off < got) {
            snd_pcm_sframes_t w = snd_pcm_writei(pcm, out + off, got - off);
            if (w < 0) { snd_pcm_recover(pcm, (int)w, 1); continue; }
            off += (size_t)w;
        }
        done += (long)got;
    }

    snd_pcm_drain(pcm);
    snd_pcm_close(pcm);
    fclose(f);
    return 0;
}
