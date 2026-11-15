//
//  OBJDiagLog.c
//  objekat
//
//  Le cœur du journal de diagnostic — @see OBJDiagLog.h pour le contrat.
//
//  Deux chemins d'écriture, volontairement séparés :
//    • le chemin NORMAL (`objdiag_log`) prend un verrou, formate, écrit, tourne si besoin ;
//    • le chemin CRASH (gestionnaire de signal) n'a droit à rien de cela : pas de verrou (le
//      thread qui plante peut le tenir), pas de malloc, pas de snprintf, pas de stdio. Il formate
//      à la main dans un tampon de pile et fait un write() — seul appel système sûr ici.
//

#include "OBJDiagLog.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define OBJDIAG_MAX_LINE   4000          // octets de message, ellipse comprise
#define OBJDIAG_DEFAULT_MB 20u
#define OBJDIAG_PATH_MAX   1024
#define OBJDIAG_META_MAX   4096

int objdiag_enabled_flag = 0;

// ─── État ────────────────────────────────────────────────────────────────────

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int    g_fd = -1;
static char            g_log_path[OBJDIAG_PATH_MAX];
static char            g_meta_path[OBJDIAG_PATH_MAX];
static char            g_meta_clean[OBJDIAG_META_MAX];
static char            g_header[1024];
static uint64_t        g_max_bytes = 0;
static uint64_t        g_bytes = 0;
static int             g_rotations = 0;
static struct timespec g_t0_mono;
static long            g_tz_offset = 0;       // secondes à ajouter à l'UTC pour l'heure locale
static time_t          g_tz_checked = 0;
static int             g_atexit_installed = 0;
static int             g_handlers_installed = 0;
static intptr_t        g_main_slide = 0;

// ─── Utilitaires async-signal-safe ───────────────────────────────────────────

static size_t as_len(const char* s) { size_t n = 0; while (s[n]) n++; return n; }

static char* as_puts(char* p, const char* end, const char* s) {
    while (*s && p < end) *p++ = *s++;
    return p;
}

static char* as_putu(char* p, const char* end, uint64_t v, int min_width, char pad) {
    char tmp[24]; int n = 0;
    do { tmp[n++] = (char)('0' + (v % 10)); v /= 10; } while (v);
    while (n < min_width && n < 23) tmp[n++] = pad;
    while (n && p < end) *p++ = tmp[--n];
    return p;
}

static char* as_puthex(char* p, const char* end, uint64_t v) {
    static const char digits[] = "0123456789abcdef";
    char tmp[20]; int n = 0;
    do { tmp[n++] = digits[v & 15]; v >>= 4; } while (v);
    p = as_puts(p, end, "0x");
    while (n && p < end) *p++ = tmp[--n];
    return p;
}

static void as_write_all(int fd, const char* buf, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, buf, n);
        if (w < 0) { if (errno == EINTR) continue; return; }
        buf += w; n -= (size_t)w;
    }
}

/// `HH:MM:SS.mmm +secondes ` — async-signal-safe (clock_gettime, offset mis en cache).
static char* put_prefix(char* p, const char* end) {
    struct timespec now, mono;
    clock_gettime(CLOCK_REALTIME, &now);
    clock_gettime(CLOCK_MONOTONIC, &mono);

    long local = (long)now.tv_sec + g_tz_offset;
    long day = ((local % 86400) + 86400) % 86400;
    p = as_putu(p, end, (uint64_t)(day / 3600), 2, '0');       p = as_puts(p, end, ":");
    p = as_putu(p, end, (uint64_t)((day / 60) % 60), 2, '0');  p = as_puts(p, end, ":");
    p = as_putu(p, end, (uint64_t)(day % 60), 2, '0');         p = as_puts(p, end, ".");
    p = as_putu(p, end, (uint64_t)(now.tv_nsec / 1000000), 3, '0');

    long ds = (long)(mono.tv_sec - g_t0_mono.tv_sec);
    long dn = mono.tv_nsec - g_t0_mono.tv_nsec;
    if (dn < 0) { ds -= 1; dn += 1000000000L; }
    if (ds < 0) { ds = 0; dn = 0; }
    p = as_puts(p, end, " +");
    p = as_putu(p, end, (uint64_t)ds, 1, '0');  p = as_puts(p, end, ".");
    p = as_putu(p, end, (uint64_t)(dn / 1000000), 3, '0');
    return as_puts(p, end, " ");
}

static char* put_category(char* p, const char* end, const char* cat) {
    size_t n = 0;
    while (cat && cat[n] && n < 5 && p < end) { *p++ = cat[n]; n++; }
    while (n < 6 && p < end) { *p++ = ' '; n++; }     // « API    » — colonne de 6
    return p;
}

static void refresh_tz(void) {
    time_t now = time(NULL);
    struct tm lt;
    if (localtime_r(&now, &lt)) g_tz_offset = (long)lt.tm_gmtoff;
    g_tz_checked = now;
}

// ─── Thread temps réel ───────────────────────────────────────────────────────

static __thread int tls_realtime = -1;     // -1 inconnu, 0 non, 1 oui

int objdiag_is_realtime_thread(void) {
    if (tls_realtime < 0) {
        char name[64] = {0};
        if (pthread_getname_np(pthread_self(), name, sizeof name) == 0)
            tls_realtime = (strncmp(name, "com.apple.audio.", 16) == 0) ? 1 : 0;
        else
            tls_realtime = 0;
    }
    return tls_realtime;
}

// ─── Méta ────────────────────────────────────────────────────────────────────

static void write_file_replace(const char* path, const char* content) {
    // temp + rename : un lecteur (diag_latest.py) ne voit jamais un méta à moitié écrit.
    char tmp[OBJDIAG_PATH_MAX + 8];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    as_write_all(fd, content, strlen(content));
    close(fd);
    rename(tmp, path);
}

/// Version signal-safe : tronque et réécrit en place (pas de rename — il est sûr, mais le
/// fichier est tout petit et un lecteur concurrent est improbable à ce moment).
static void write_clean_meta_in_place(void) {
    if (!g_meta_path[0] || !g_meta_clean[0]) return;
    int fd = open(g_meta_path, O_WRONLY | O_TRUNC);
    if (fd < 0) return;
    as_write_all(fd, g_meta_clean, as_len(g_meta_clean));
    close(fd);
}

// ─── Rotation ────────────────────────────────────────────────────────────────

static void write_header_locked(int continued) {
    char line[1200];
    char* p = line; const char* end = line + sizeof line - 2;
    if (continued) p = as_puts(p, end, "# (suite apres rotation) ");
    p = as_puts(p, end, g_header);
    *p++ = '\n';
    as_write_all(g_fd, line, (size_t)(p - line));
    g_bytes += (uint64_t)(p - line);
}

static void rotate_locked(void) {
    close(g_fd);
    g_fd = -1;
    char old[OBJDIAG_PATH_MAX + 4];
    snprintf(old, sizeof old, "%s.1", g_log_path);
    rename(g_log_path, old);
    g_fd = open(g_log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    g_bytes = 0;
    g_rotations++;
    if (g_fd >= 0) write_header_locked(1);
}

// ─── Écriture normale ────────────────────────────────────────────────────────

static void emit(const char* cat, const char* msg, size_t msg_len) {
    char line[OBJDIAG_MAX_LINE + 96];
    const char* end = line + sizeof line - 2;

    if (g_tz_checked == 0 || time(NULL) - g_tz_checked > 300) refresh_tz();

    char* p = put_prefix(line, end);
    p = put_category(p, end, cat);

    size_t take = msg_len;
    int truncated = 0;
    if (take > OBJDIAG_MAX_LINE) {
        take = OBJDIAG_MAX_LINE - 3;
        // ne pas couper un caractère UTF-8 en deux
        while (take > 0 && ((unsigned char)msg[take] & 0xC0) == 0x80) take--;
        truncated = 1;
    }
    for (size_t i = 0; i < take && p < end; i++) {
        unsigned char c = (unsigned char)msg[i];
        if (c == '\n') { if (p + 3 < end) { *p++ = ' '; *p++ = '|'; *p++ = ' '; } }
        else if (c == '\r') { /* ignoré */ }
        else if (c == 0) { /* ignoré */ }
        else *p++ = (char)c;
    }
    if (truncated && p + 3 < end) { *p++ = (char)0xE2; *p++ = (char)0x80; *p++ = (char)0xA6; }
    *p++ = '\n';
    size_t n = (size_t)(p - line);

    pthread_mutex_lock(&g_lock);
    if (g_fd >= 0) {
        uint64_t cap = g_max_bytes ? g_max_bytes : (uint64_t)OBJDIAG_DEFAULT_MB * 1024u * 1024u;
        if (g_bytes + n > cap) rotate_locked();
        if (g_fd >= 0) {
            as_write_all(g_fd, line, n);
            g_bytes += n;
        }
    }
    pthread_mutex_unlock(&g_lock);
}

void objdiag_log(const char* cat, const char* msg) {
    if (!objdiag_enabled() || !msg) return;
    if (objdiag_is_realtime_thread()) {
#ifndef NDEBUG
        // Une ligne de journal sur le thread audio est un bug : un verrou et un write().
        assert(0 && "objdiag_log appelé depuis un thread audio temps réel");
#endif
        return;
    }
    emit(cat, msg, strlen(msg));
}

void objdiag_logf(const char* cat, const char* fmt, ...) {
    if (!objdiag_enabled() || !fmt) return;
    char buf[OBJDIAG_MAX_LINE + 8];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n >= sizeof buf) n = (int)sizeof buf - 1;
    if (objdiag_is_realtime_thread()) {
#ifndef NDEBUG
        assert(0 && "objdiag_logf appelé depuis un thread audio temps réel");
#endif
        return;
    }
    emit(cat, buf, (size_t)n);
}

size_t objdiag_copy_path(char* buf, size_t capacity) {
    if (!buf || capacity == 0) return 0;
    pthread_mutex_lock(&g_lock);
    size_t n = (g_fd >= 0) ? strlen(g_log_path) : 0;
    if (n >= capacity) n = capacity - 1;
    memcpy(buf, g_log_path, n);
    buf[n] = 0;
    pthread_mutex_unlock(&g_lock);
    return n;
}

uint64_t objdiag_bytes_written(void) { return g_bytes; }
int objdiag_rotation_count(void) { return g_rotations; }

// ─── Gestionnaires de signaux ────────────────────────────────────────────────

static const int kCrashSignals[] = { SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE };
static const int kExitSignals[]  = { SIGTERM, SIGINT };
static struct sigaction g_prev_action[NSIG];
static char g_altstack[128 * 1024];

static const char* signal_name(int sig) {
    switch (sig) {
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGTRAP: return "SIGTRAP";
        case SIGABRT: return "SIGABRT";
        case SIGFPE:  return "SIGFPE";
        case SIGTERM: return "SIGTERM";
        case SIGINT:  return "SIGINT";
        default:      return "SIG?";
    }
}

/// Remonte la chaîne de frame pointers à partir du contexte du signal. Chaque pointeur est
/// validé (aligné, croissant, borné) : un fp corrompu ne doit pas faire planter le gestionnaire.
static int walk_frames(void* uctx, uintptr_t* out, int max) {
    int n = 0;
    if (!uctx || max <= 0) return 0;
    ucontext_t* uc = (ucontext_t*)uctx;
    if (!uc->uc_mcontext) return 0;
    uintptr_t pc = 0, fp = 0, lr = 0;
#if defined(__arm64__) || defined(__aarch64__)
    pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
    fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
    lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
#elif defined(__x86_64__)
    pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
    fp = (uintptr_t)uc->uc_mcontext->__ss.__rbp;
    lr = 0;
#endif
    if (pc) out[n++] = pc;
    if (lr && n < max) out[n++] = lr;
    uintptr_t prev = 0;
    while (n < max && fp && (fp & 7) == 0 && fp > prev
           && (prev == 0 || fp - prev < ((uintptr_t)64 << 20))) {
        uintptr_t* frame = (uintptr_t*)fp;
        uintptr_t next = frame[0];
        uintptr_t ret  = frame[1];
        if (!ret) break;
        out[n++] = ret;
        if (next <= fp) break;
        prev = fp;
        fp = next;
    }
    return n;
}

static void write_crash_lines(int sig, siginfo_t* info, void* uctx) {
    char buf[1600];
    const char* end = buf + sizeof buf - 2;
    char* p = put_prefix(buf, end);
    p = put_category(p, end, "CRASH");
    p = as_puts(p, end, "signal ");
    p = as_puts(p, end, signal_name(sig));
    p = as_puts(p, end, " (");
    p = as_putu(p, end, (uint64_t)sig, 1, '0');
    p = as_puts(p, end, ") code=");
    p = as_putu(p, end, info ? (uint64_t)(unsigned)info->si_code : 0, 1, '0');
    p = as_puts(p, end, " addr=");
    p = as_puthex(p, end, info ? (uint64_t)(uintptr_t)info->si_addr : 0);
    p = as_puts(p, end, " thread=");
    {
        char name[64] = {0};
        pthread_getname_np(pthread_self(), name, sizeof name);
        p = as_puts(p, end, name[0] ? name : "?");
    }
    p = as_puts(p, end, " pid=");
    p = as_putu(p, end, (uint64_t)getpid(), 1, '0');
    *p++ = '\n';

    // Deuxième ligne : les adresses brutes (la symbolisation vient du .ips, lu par diag_latest.py).
    p = put_prefix(p, end);
    p = put_category(p, end, "CRASH");
    p = as_puts(p, end, "stack slide=");
    p = as_puthex(p, end, (uint64_t)g_main_slide);
    uintptr_t frames[48];
    int n = walk_frames(uctx, frames, 48);
    for (int i = 0; i < n && p + 24 < end; i++) {
        p = as_puts(p, end, " ");
        p = as_puthex(p, end, (uint64_t)frames[i]);
    }
    *p++ = '\n';
    as_write_all(g_fd, buf, (size_t)(p - buf));
}

static void restore_previous(int sig) {
    sigaction(sig, &g_prev_action[sig], NULL);
}

static void crash_handler(int sig, siginfo_t* info, void* uctx) {
    static volatile sig_atomic_t entered = 0;
    if (!entered) {
        entered = 1;
        if (g_fd >= 0) write_crash_lines(sig, info, uctx);
    }
    restore_previous(sig);
    // Une faute matérielle (code > 0, hors SI_USER = 0x10001) se rejoue d'elle-même en sortant :
    // le gestionnaire précédent — ou le défaut — voit la vraie faute, d'où un .ips complet.
    // Tout le reste (abort(), kill -SEGV) ne se rejoue pas : on relance le signal.
    int hardware_fault = info && info->si_code > 0 && info->si_code < 0x10000 && sig != SIGABRT;
    if (!hardware_fault) {
        sigset_t set; sigemptyset(&set); sigaddset(&set, sig);
        pthread_sigmask(SIG_UNBLOCK, &set, NULL);
        pthread_kill(pthread_self(), sig);
    }
}

static void exit_signal_handler(int sig, siginfo_t* info, void* uctx) {
    (void)info; (void)uctx;
    if (g_fd >= 0) {
        char buf[200];
        const char* end = buf + sizeof buf - 2;
        char* p = put_prefix(buf, end);
        p = put_category(p, end, "EXIT");
        p = as_puts(p, end, "external signal ");
        p = as_puts(p, end, signal_name(sig));
        *p++ = '\n';
        as_write_all(g_fd, buf, (size_t)(p - buf));
        write_clean_meta_in_place();
    }
    restore_previous(sig);
    sigset_t set; sigemptyset(&set); sigaddset(&set, sig);
    pthread_sigmask(SIG_UNBLOCK, &set, NULL);
    kill(getpid(), sig);
}

static void install_handlers(void) {
    if (g_handlers_installed) return;
    g_handlers_installed = 1;

    g_main_slide = (intptr_t)_dyld_get_image_vmaddr_slide(0);

    // Pile alternative du thread qui installe (le principal) : un débordement de pile ne
    // laisserait sinon aucune place au gestionnaire.
    stack_t ss;
    ss.ss_sp = g_altstack;
    ss.ss_size = sizeof g_altstack;
    ss.ss_flags = 0;
    sigaltstack(&ss, NULL);

    for (size_t i = 0; i < sizeof kCrashSignals / sizeof kCrashSignals[0]; i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = crash_handler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
        sigaction(kCrashSignals[i], &sa, &g_prev_action[kCrashSignals[i]]);
    }
    for (size_t i = 0; i < sizeof kExitSignals / sizeof kExitSignals[0]; i++) {
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = exit_signal_handler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_SIGINFO;
        sigaction(kExitSignals[i], &sa, &g_prev_action[kExitSignals[i]]);
    }
}

// ─── Ouverture / fermeture ───────────────────────────────────────────────────

static void atexit_close(void) { objdiag_close("exit normal"); }

int objdiag_open(const char* log_path, const char* meta_path,
                 const char* meta_unclean_json, const char* meta_clean_json,
                 const char* header, uint64_t max_bytes) {
    if (!log_path || !meta_path) return -EINVAL;
    pthread_mutex_lock(&g_lock);
    if (g_fd >= 0) { pthread_mutex_unlock(&g_lock); return 0; }

    int fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) { int e = errno; pthread_mutex_unlock(&g_lock); return -e; }

    snprintf(g_log_path, sizeof g_log_path, "%s", log_path);
    snprintf(g_meta_path, sizeof g_meta_path, "%s", meta_path);
    snprintf(g_meta_clean, sizeof g_meta_clean, "%s", meta_clean_json ? meta_clean_json : "");
    snprintf(g_header, sizeof g_header, "%s", header ? header : "# OBJEKAT");
    g_max_bytes = max_bytes;
    g_bytes = 0;
    g_rotations = 0;
    clock_gettime(CLOCK_MONOTONIC, &g_t0_mono);
    refresh_tz();
    g_fd = fd;

    if (meta_unclean_json) write_file_replace(g_meta_path, meta_unclean_json);
    write_header_locked(0);

    install_handlers();
    if (!g_atexit_installed) { g_atexit_installed = 1; atexit(atexit_close); }

    __atomic_store_n(&objdiag_enabled_flag, 1, __ATOMIC_RELAXED);
    pthread_mutex_unlock(&g_lock);
    return 0;
}

void objdiag_update_meta(const char* meta_unclean_json, const char* meta_clean_json) {
    pthread_mutex_lock(&g_lock);
    if (g_fd >= 0) {
        if (meta_clean_json) snprintf(g_meta_clean, sizeof g_meta_clean, "%s", meta_clean_json);
        if (meta_unclean_json) write_file_replace(g_meta_path, meta_unclean_json);
    }
    pthread_mutex_unlock(&g_lock);
}

void objdiag_close(const char* reason) {
    if (!objdiag_enabled()) return;
    emit("EXIT", reason ? reason : "close", reason ? strlen(reason) : 5);
    pthread_mutex_lock(&g_lock);
    __atomic_store_n(&objdiag_enabled_flag, 0, __ATOMIC_RELAXED);
    if (g_fd >= 0) {
        write_file_replace(g_meta_path, g_meta_clean);
        int fd = g_fd;
        g_fd = -1;
        close(fd);
    }
    pthread_mutex_unlock(&g_lock);
}

// ─── Crashs de test ──────────────────────────────────────────────────────────

#ifndef NDEBUG
static int overflow(int depth);
// Par un pointeur volatil : le compilateur ne peut ni transformer la récursion en boucle ni la supprimer.
static int (*volatile g_overflow)(int) = overflow;
static int overflow(int depth) {
    volatile char pad[4096];
    pad[0] = (char)depth;
    pad[4095] = (char)depth;
    return g_overflow(depth + 1) + pad[0] + pad[4095];
}

void objdiag_debug_crash(int kind) {
    switch (kind) {
        case 0: *(volatile int*)8 = 1; break;
        case 1: abort(); break;
        case 2: (void)overflow(0); break;
        default: break;
    }
}
#endif
