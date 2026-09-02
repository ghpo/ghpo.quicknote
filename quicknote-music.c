/* quicknote-music.c — self-contained software MIDI synthesizer.
 *
 * Parses a Standard MIDI File, synthesizes PCM (square/saw/triangle + a small
 * drum kit) and plays it through ALSA. No timidity/fluidsynth/soundfont
 * packages are required — only the system C compiler and alsa-lib, which are
 * standard on Arch/Omarchy. The synth is intentionally retro/chiptune: it is
 * a lightweight music box, not a GM renderer.
 *
 * Usage: quicknote-music <file.mid>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <alsa/asoundlib.h>

#define SR        44100
#define BLOCK     512
#define MAX_VOICES 48
#define MAX_EVENTS 60000
#define CHANNELS  2

/* --------------------------------------------------------------- midi model */

typedef struct {
    long long tick;
    unsigned char type;    /* 0 note-on, 1 note-off, 2 program, 3 tempo */
    int ch, note, vel, program;
    int tempo;             /* microseconds per quarter note */
} MEvent;

static MEvent events[MAX_EVENTS];
static long long abs_us[MAX_EVENTS];
static int nevents = 0;

static long long read_varint(const unsigned char **p, const unsigned char *end) {
    long long v = 0;
    while (*p < end) {
        unsigned char b = *(*p)++;
        v = (v << 7) | (b & 0x7f);
        if (!(b & 0x80)) break;
    }
    return v;
}

static void parse_track(const unsigned char *data, long len) {
    const unsigned char *p = data, *end = data + len;
    long long tick = 0;
    unsigned char running = 0;
    while (p < end) {
        tick += read_varint(&p, end);
        if (p >= end) break;
        unsigned char status = *p++;
        if (status < 0x80) { p--; status = running; }
        else running = status;
        int ch = status & 0x0f;
        switch (status & 0xf0) {
            case 0x80:
                if (p + 2 > end) return;
                if (nevents < MAX_EVENTS) events[nevents++] = (MEvent){tick,1,ch,p[0],0,0,0};
                p += 2;
                break;
            case 0x90: {
                if (p + 2 > end) return;
                int note = p[0], vel = p[1];
                if (nevents < MAX_EVENTS)
                    events[nevents++] = vel == 0
                        ? (MEvent){tick,1,ch,note,0,0,0}
                        : (MEvent){tick,0,ch,note,vel,0,0};
                p += 2;
                break;
            }
            case 0xc0:
                if (p + 1 > end) return;
                if (nevents < MAX_EVENTS) events[nevents++] = (MEvent){tick,2,ch,0,0,*p,0};
                p += 1;
                break;
            case 0xe0: if (p + 2 <= end) p += 2; break;
            case 0xb0: if (p + 2 <= end) p += 2; break;
            case 0xa0: if (p + 2 <= end) p += 2; break;
            case 0xd0: if (p + 1 <= end) p += 1; break;
            default:
                if (status == 0xff) {
                    if (p >= end) return;
                    unsigned char mt = *p++;
                    long long ml = read_varint(&p, end);
                    if (mt == 0x51 && ml == 3 && p + 3 <= end) {
                        int us = (p[0] << 16) | (p[1] << 8) | p[2];
                        if (nevents < MAX_EVENTS) events[nevents++] = (MEvent){tick,3,0,0,0,0,us};
                    }
                    p += ml;
                } else {
                    long long sl = read_varint(&p, end);
                    p += sl;
                }
        }
        if (p > end) return;
    }
}

static int cmp_ev(const void *a, const void *b) {
    const MEvent *x = a, *y = b;
    return (x->tick > y->tick) - (x->tick < y->tick);
}

/* ------------------------------------------------------------- voice engine */

typedef struct {
    int active;
    int program, note, drum;
    int kmax;
    double phase;
    double freq;
    double vel;
    double env;
    int stage;             /* 0 attack, 1 decay, 2 sustain, 3 release, 4 done */
    double t, rt;
} Voice;

static Voice voices[MAX_VOICES];
static int programs[16];

static double note_freq(int n) { return 440.0 * pow(2.0, (n - 69) / 12.0); }

/* Band-limited waveforms: sum harmonics only up to the highest that fits
 * below Nyquist (kmax), so nothing aliases and the sound stays clean. */
static double wave(int program, double phase, int kmax) {
    double ph = phase - floor(phase);
    double sum = 0;
    if (program >= 96 && program < 112) return sin(2.0 * M_PI * ph) * 0.9;      /* pad: sine */
    if (program >= 112) return ((rand() & 0xffff) / 32768.0 - 0.5) * 2.0;       /* fx: noise */
    if (program >= 0 && program < 8) {          /* piano: triangle-ish (k^-2) */
        for (int k = 1; k <= kmax; k += 2) {
            int s = (((k - 1) / 2) & 1) ? -1 : 1;
            sum += s * sin(2 * M_PI * k * ph) / (k * k);
        }
        return (8.0 / (M_PI * M_PI)) * sum;
    }
    if (program >= 80 && program < 96) {        /* synth lead: pulse 25% duty */
        for (int k = 1; k <= kmax; k++)
            sum += sin(M_PI * k * 0.5) * sin(2 * M_PI * k * ph) / k;
        return (2.0 / M_PI) * sum;
    }
    if (program >= 24 && program < 40) {        /* bass/guitar: saw */
        for (int k = 1; k <= kmax; k++) {
            int s = (k & 1) ? 1 : -1;
            sum += s * sin(2 * M_PI * k * ph) / k;
        }
        return (2.0 / M_PI) * sum;
    }
    for (int k = 1; k <= kmax; k += 2) {        /* organ/strings/default: square */
        sum += sin(2 * M_PI * k * ph) / k;
    }
    return (4.0 / M_PI) * sum;
}

static void env_step(Voice *v, double dt) {
    v->t += dt;
    switch (v->stage) {
        case 0: v->env += dt / 0.004; if (v->env >= 1.0) { v->env = 1.0; v->stage = 1; } break;
        case 1: v->env -= dt / 0.10; if (v->env <= 0.65) { v->env = 0.65; v->stage = 2; } break;
        case 2: break;
        case 3: v->rt += dt; v->env -= dt / 0.08; if (v->env <= 0.0) { v->env = 0; v->stage = 4; v->active = 0; } break;
    }
}

/* 2nd-order low-pass (RBJ), fc ~7.5 kHz, applied to the mix to kill aliasing hiss */
static double lpf_z1 = 0, lpf_z2 = 0;
static double lpf_b0, lpf_b1, lpf_b2, lpf_a1, lpf_a2;
static void lpf_init(void) {
    double fc = 6000.0, Q = 0.7071, w0 = 2.0 * M_PI * fc / SR;
    double alpha = sin(w0) / (2.0 * Q);
    double a0 = 1.0 + alpha;
    lpf_b0 = (1.0 - cos(w0)) / 2.0 / a0;
    lpf_b1 = (1.0 - cos(w0)) / a0;
    lpf_b2 = (1.0 - cos(w0)) / 2.0 / a0;
    lpf_a1 = -2.0 * cos(w0) / a0;
    lpf_a2 = (1.0 - alpha) / a0;
}
static double lpf_run(double x) {
    double y = lpf_b0 * x + lpf_z1;
    lpf_z1 = lpf_b1 * x - lpf_a1 * y + lpf_z2;
    lpf_z2 = lpf_b2 * x - lpf_a2 * y;
    return y;
}

static double noise_lp = 0;   /* shared one-pole to darken drum noise */

static double render_sample(void) {
    double out = 0;
    for (int i = 0; i < MAX_VOICES; i++) {
        Voice *v = &voices[i];
        if (!v->active) continue;
        double w = wave(v->program, v->phase, v->kmax);
        if (v->drum) {
            if (v->note <= 36) {
                v->freq *= (1.0 - 22.0 / SR);
                if (v->freq < 40) v->freq = 40;
                w = (v->phase < 0.5 ? 1.0 : -1.0) * 0.9;
            } else {
                double n = ((rand() & 0xffff) / 32768.0 - 0.5) * 2.0;
                double a = (v->note >= 42 && v->note <= 46) ? 0.35 : 0.20;  /* hats brighter, snare darker */
                noise_lp += a * (n - noise_lp);
                w = noise_lp * 0.55;
            }
        }
        v->phase += v->freq / SR;
        out += w * v->vel * v->env;
    }
    return out;
}

/* ------------------------------------------------------------------- main */

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: quicknote-music <file.mid> [--wav out.wav]\n"); return 2; }
    const char *wav_out = NULL;
    if (argc >= 4 && strcmp(argv[2], "--wav") == 0) wav_out = argv[3];
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    fseek(f, 0, SEEK_END);
    long fsz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *data = malloc(fsz ? fsz : 1);
    if (fsz != (long)fread(data, 1, fsz, f)) return 2;
    fclose(f);

    if (fsz < 14 || memcmp(data, "MThd", 4) != 0) { fprintf(stderr, "not a MIDI file\n"); return 2; }
    int division = (data[12] << 8) | data[13];
    if (division <= 0) division = 480;

    long pos = 14;
    while (pos + 8 <= fsz) {
        if (memcmp(data + pos, "MTrk", 4) == 0) {
            long len = ((long)data[pos+4] << 24) | ((long)data[pos+5] << 16)
                     | ((long)data[pos+6] << 8) | data[pos+7];
            pos += 8;
            if (pos + len <= fsz) parse_track(data + pos, len);
            pos += len;
        } else break;
    }

    qsort(events, nevents, sizeof(MEvent), cmp_ev);

    /* absolute time in microseconds for every event, integrating tempo */
    int cur_tempo = 500000;
    double us_per_tick = (double)cur_tempo / division;
    long long prev_tick = 0;
    long long acc = 0;
    for (int i = 0; i < nevents; i++) {
        acc += (long long)((events[i].tick - prev_tick) * us_per_tick);
        prev_tick = events[i].tick;
        abs_us[i] = acc;
        if (events[i].type == 3) {
            cur_tempo = events[i].tempo;
            us_per_tick = (double)cur_tempo / division;
        }
    }

    for (int i = 0; i < 16; i++) programs[i] = 0;
    lpf_init();

    snd_pcm_t *pcm = NULL;
    FILE *wf = NULL;
    long wav_bytes = 0;
    if (wav_out) {
        wf = fopen(wav_out, "wb");
        if (!wf) return 1;
        fwrite("RIFF", 1, 4, wf);
        fwrite("\x00\x00\x00\x00", 1, 4, wf);
        fwrite("WAVE", 1, 4, wf);
        fwrite("fmt ", 1, 4, wf);
        unsigned char fmt[20] = {
            16,0,0,0,            /* fmt chunk size */
            1,0,                 /* PCM */
            CHANNELS,0,          /* channels */
            0x44,0xAC,0x00,0x00, /* 44100 */
            0x10,0xB1,0x02,0x00, /* byte rate 176400 */
            4,0,                 /* block align */
            16,0                 /* bits per sample */
        };
        fwrite(fmt, 1, sizeof fmt, wf);
        fwrite("data", 1, 4, wf);
        fwrite("\x00\x00\x00\x00", 1, 4, wf);
    } else {
        if (snd_pcm_open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0) {
            fprintf(stderr, "cannot open ALSA default\n");
            return 1;
        }
        if (snd_pcm_set_params(pcm, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED,
                               CHANNELS, SR, 1, 500000) < 0) {
            fprintf(stderr, "cannot set ALSA params\n");
            return 1;
        }
    }
    fprintf(stderr, "events=%d\n", nevents);

    int16_t buf[BLOCK * CHANNELS];
    long long block_us = (long long)(BLOCK * 1000000LL / SR);
    long long render_us = 0;
    long long cur_ev = 0;
    double dt = BLOCK / (double)SR;

    for (;;) {
        long long block_end = render_us + block_us;

        /* process every event that falls inside this block */
        while (cur_ev < nevents && abs_us[cur_ev] <= block_end) {
            MEvent *e = &events[cur_ev];
            if (e->type == 2) { if (e->ch != 9) programs[e->ch] = e->program; }
            else if (e->type == 0) {
                for (int vi = 0; vi < MAX_VOICES; vi++) {
                    Voice *v = &voices[vi];
                    if (v->active) continue;
                    v->active = 1;
                    v->program = e->ch == 9 ? 128 : programs[e->ch];
                    v->note = e->note;
                    v->drum = (e->ch == 9);
                    v->freq = v->drum ? 90.0 : note_freq(e->note);
                    v->kmax = v->drum ? 24 : (int)((SR / 2.0) / (v->freq > 0 ? v->freq : 440.0));
                    if (v->kmax < 1) v->kmax = 1;
                    if (v->kmax > 24) v->kmax = 24;
                    v->phase = 0;
                    v->vel = e->vel / 127.0;
                    v->env = 0;
                    v->stage = 0;
                    v->t = 0; v->rt = 0;
                    break;
                }
            } else if (e->type == 1) {
                for (int vi = 0; vi < MAX_VOICES; vi++) {
                    Voice *v = &voices[vi];
                    if (v->active && v->note == e->note && v->stage != 3 && v->stage != 4)
                        v->stage = 3;
                }
            }
            cur_ev++;
        }

        /* render block */
        for (int i = 0; i < BLOCK; i++) {
            double s = tanh(lpf_run(render_sample()));   /* soft-clip, no harsh peaks */
            int16_t v = (int16_t)(s * 16000.0);
            if (v > 32767) v = 32767; if (v < -32768) v = -32768;
            buf[i * CHANNELS] = v;
            buf[i * CHANNELS + 1] = v;
        }

        for (int vi = 0; vi < MAX_VOICES; vi++)
            if (voices[vi].active) env_step(&voices[vi], dt);

        if (wf) {
            fwrite(buf, 1, BLOCK * CHANNELS * 2, wf);
            wav_bytes += BLOCK * CHANNELS * 2;
        } else if (snd_pcm_writei(pcm, buf, BLOCK) < 0) {
            break;
        }
        render_us = block_end;

        if (cur_ev >= nevents) {
            int any = 0;
            for (int vi = 0; vi < MAX_VOICES; vi++) if (voices[vi].active) { any = 1; break; }
            if (!any) break;
        }
    }

    if (wf) {
        fseek(wf, 4, SEEK_SET);
        unsigned int sz = 36 + wav_bytes;
        fwrite(&sz, 1, 4, wf);
        fseek(wf, 40, SEEK_SET);
        unsigned int ds = wav_bytes;
        fwrite(&ds, 1, 4, wf);
        fclose(wf);
    } else {
        snd_pcm_drain(pcm);
        snd_pcm_close(pcm);
    }
    free(data);
    return 0;
}
