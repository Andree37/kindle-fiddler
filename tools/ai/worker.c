// noface-ai: runs a small language model over jobs that noface leaves in a folder.
//
//   noface-ai <model.gguf> <jobs dir>
//
// A job is a file "<name>.job": a first line "max <tokens>", then the request, written
// as the user's turn of a chat. For each one the answer goes to "<name>.out" (written
// beside it, then renamed, so noface never reads half of one) and the job is deleted.
// With no jobs left it exits, freeing the model's memory.
//
// It runs at the lowest priority, so the reader always comes first. noface starts it
// only on a charging Kindle that's locked, pauses it the moment the Kindle wakes, and
// kills it when the power goes. Built against llama.cpp by tools/ai/build.sh.
#include "llama.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

#define MAX_CONTEXT 4096
#define MAX_JOB_BYTES (32 * 1024)
// Prompt tokens read per step. The scratch memory grows with it times the vocabulary
// (151k words for Qwen), so a whole prompt at once needs hundreds of MB; 64 needs ~40.
#define STEP 64

static char *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    char *buf = malloc(MAX_JOB_BYTES + 1);
    size_t n = buf ? fread(buf, 1, MAX_JOB_BYTES, f) : 0;
    fclose(f);
    if (!buf) return NULL;
    buf[n] = 0;
    *len = n;
    return buf;
}

static void batch_set_tokens(struct llama_batch_ext *batch, const llama_token *tokens, int32_t n, llama_pos pos_0) {
    llama_batch_ext_clear(batch);
    for (int32_t i = 0; i < n; ++i) {
        const int32_t idx = llama_batch_ext_add_token(batch, 0, tokens[i]);
        const llama_pos pos = pos_0 + i;
        llama_batch_ext_set_pos(batch, idx, &pos);
    }
    llama_batch_ext_set_output_logits(batch, n - 1, true);
}

// Answers one request into `out`. Returns 0 on success.
static int answer(struct llama_model *model, const char *request, int max_tokens, FILE *out) {
    const struct llama_vocab *vocab = llama_model_get_vocab(model);
    const char *tmpl = llama_model_chat_template(model, NULL);
    struct llama_chat_message msg = {"user", request};
    int cap = (int)strlen(request) * 2 + 512;
    char *prompt = malloc(cap);
    int len = llama_chat_apply_template(tmpl, &msg, 1, true, prompt, cap);
    if (len > cap) {
        cap = len + 1;
        prompt = realloc(prompt, cap);
        len = llama_chat_apply_template(tmpl, &msg, 1, true, prompt, cap);
    }
    if (len < 0) {
        free(prompt);
        return 1;
    }

    int n_prompt = -llama_tokenize(vocab, prompt, len, NULL, 0, true, true);
    if (n_prompt <= 0 || n_prompt + max_tokens > MAX_CONTEXT) {
        fprintf(stderr, "request too long: %d tokens\n", n_prompt);
        free(prompt);
        return 1;
    }
    llama_token *tokens = malloc(sizeof(llama_token) * n_prompt);
    llama_tokenize(vocab, prompt, len, tokens, n_prompt, true, true);
    free(prompt);

    struct llama_context_params cp = llama_context_default_params();
    cp.n_ctx = n_prompt + max_tokens + 8;
    cp.n_batch = STEP;
    cp.n_ubatch = STEP;
    cp.n_threads = 2;
    cp.n_threads_batch = 2;
    struct llama_context *ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        free(tokens);
        return 1;
    }
    // Low temperature: steady, factual summaries rather than inventive ones
    struct llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.2f));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(1));

    struct llama_batch_ext *batch = llama_batch_ext_init(ctx);
    int failed = 0;
    // The prompt, a step at a time; only its last token's logits are kept
    for (int at = 0; at < n_prompt && !failed; at += STEP) {
        const int n = n_prompt - at < STEP ? n_prompt - at : STEP;
        batch_set_tokens(batch, tokens + at, n, at);
        failed = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch) != 0;
    }
    for (int n_pos = n_prompt, made = 0; !failed && made < max_tokens; made++) {
        llama_token next = llama_sampler_sample(smpl, ctx, -1);
        if (llama_vocab_is_eog(vocab, next)) break;
        char piece[128];
        int n = llama_token_to_piece(vocab, next, piece, sizeof(piece), 0, false);
        if (n > 0) fwrite(piece, 1, n, out);
        batch_set_tokens(batch, &next, 1, n_pos++);
        failed = llama_process(ctx, LLAMA_PROCESS_TYPE_DECODE, batch) != 0;
    }
    llama_batch_ext_free(batch);
    llama_sampler_free(smpl);
    llama_free(ctx);
    free(tokens);
    return failed;
}

static int ends_with(const char *s, const char *suffix) {
    size_t a = strlen(s), b = strlen(suffix);
    return a >= b && strcmp(s + a - b, suffix) == 0;
}

// The next job's name in `dir`, in name order, so noface decides the order. 0 if none.
static int next_job(const char *dir, char *name, size_t cap) {
    DIR *d = opendir(dir);
    if (!d) return 0;
    struct dirent *e;
    int found = 0;
    while ((e = readdir(d))) {
        if (!ends_with(e->d_name, ".job")) continue;
        if (!found || strcmp(e->d_name, name) < 0) {
            snprintf(name, cap, "%s", e->d_name);
            found = 1;
        }
    }
    closedir(d);
    return found;
}

static void quiet(enum ggml_log_level level, const char *text, void *data) {
    (void)data;
    if (level >= GGML_LOG_LEVEL_ERROR) fputs(text, stderr);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <model.gguf> <jobs dir>\n", argv[0]);
        return 2;
    }
    setpriority(PRIO_PROCESS, 0, 19); // The reader always comes first
    llama_log_set(quiet, NULL);
    llama_backend_init();
    char name[256];
    if (!next_job(argv[2], name, sizeof(name))) return 0; // Nothing to do: never load the model

    // Read into memory: from the Kindle's user drive, mapped weights are ~30x slower
    struct llama_model_params mp = llama_model_default_params();
    mp.load_mode = LLAMA_LOAD_MODE_NONE;
    struct llama_model *model = llama_model_load_from_file(argv[1], mp);
    if (!model) {
        fprintf(stderr, "model not loaded: %s\n", argv[1]);
        return 1;
    }
    int done = 0;
    while (next_job(argv[2], name, sizeof(name))) {
        char job[512], tmp[512], out[512];
        snprintf(job, sizeof(job), "%s/%s", argv[2], name);
        size_t base = strlen(name) - 4;
        snprintf(out, sizeof(out), "%s/%.*s.out", argv[2], (int)base, name);
        snprintf(tmp, sizeof(tmp), "%s.tmp", out);

        size_t len = 0;
        char *text = read_file(job, &len);
        int max_tokens = 0;
        char *request = text ? strchr(text, '\n') : NULL;
        if (!text || sscanf(text, "max %d", &max_tokens) != 1 || !request || max_tokens <= 0 || max_tokens > 1024) {
            fprintf(stderr, "bad job: %s\n", name);
            unlink(job);
            free(text);
            continue;
        }
        FILE *f = fopen(tmp, "wb");
        int failed = f ? answer(model, request + 1, max_tokens, f) : 1;
        if (f) fclose(f);
        if (!failed) rename(tmp, out);
        else unlink(tmp);
        unlink(job); // Done or not, it isn't tried again forever
        free(text);
        fprintf(stderr, "%s: %s\n", name, failed ? "failed" : "done");
        done++;
    }
    llama_model_free(model);
    return 0;
}
