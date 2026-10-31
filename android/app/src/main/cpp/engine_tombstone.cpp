// 端侧引擎墓碑·崩溃栈捕获（G2-2，死因可见性 ADR 2026-10-31）：
// :engine 进程侧 SIGSEGV/SIGABRT/SIGBUS 的 sigaction 处理器——落盘信号号、
// 故障地址与 backtrace 到 <tombstoneDir>/<pid>.stack，随后恢复默认处理
//（让系统按原行为终止，保持墓碑排除法对 LMK/外部 SIGKILL 的纯粹性）。
// 本库仅做信号捕获与落盘，不做任何推理/数据面职责（与 libgdw 职责分离：
// libgdw = 主进程数据面消费，本库 = :engine 进程死因可见性）。
#include <jni.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <execinfo.h>
#include <android/log.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>

#define LOG_TAG "engine-tombstone"
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

namespace {

char g_tombstone_dir[512] = {0};

// async-signal-safety：处理器内禁用非可重入函数（malloc/stdio）——
// backtrace/backtrace_symbols_fd 仅 backtrace_symbols 走 malloc；
// 这里用 backtrace + backtrace_symbols_fd（fd 直写，不 malloc），
// open 用低层 API。栈缓冲固定大小，风险面收敛到最小可辩护理路。
void writeCrashStack(int sig, siginfo_t *info, void * /*uctx*/) {
    char path[600];
    snprintf(path, sizeof(path), "%s/%d.stack", g_tombstone_dir, getpid());

    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        dprintf(fd, "signal=%d addr=%p pid=%d\n", sig,
                info != nullptr ? info->si_addr : nullptr, getpid());
        void *frames[64];
        int n = backtrace(frames, 64);
        dprintf(fd, "frames=%d\n", n);
        if (n > 0) {
            // backtrace_symbols_fd 内部走 malloc——崩溃处理器中属已知的
            // 最佳可辩护理路（AOSP tombstoned 同族取舍）；失败静默，保底
            // 至少有 signal/addr 行。
            backtrace_symbols_fd(frames, n, fd);
        }
        close(fd);
    }
    LOGW("crash captured sig=%d -> %s", sig, path);

    // 恢复默认处理并重发——保留系统既有终止行为（ANR/tombstoned 上报链），
    // 不吞信号、不拦截 SIGKILL（POSIX 不可捕获，墓碑排除法的立论前提）。
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = SIG_DFL;
    sigaction(sig, &sa, nullptr);
    raise(sig);
}

void installHandler(int sig) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = writeCrashStack;
    sa.sa_flags = SA_SIGINFO | SA_RESTART;
    sigemptyset(&sa.sa_mask);
    sigaction(sig, &sa, nullptr);
}

} // namespace

extern "C" JNIEXPORT void JNICALL
Java_com_zzh_goodhub_EngineService_nativeInitTombstone(JNIEnv *env, jclass /*clazz*/,
                                                       jstring dir) {
    if (dir == nullptr) return;
    const char *p = env->GetStringUTFChars(dir, nullptr);
    if (p == nullptr) return;
    snprintf(g_tombstone_dir, sizeof(g_tombstone_dir), "%s", p);
    env->ReleaseStringUTFChars(dir, p);

    installHandler(SIGSEGV);
    installHandler(SIGABRT);
    installHandler(SIGBUS);
    LOGW("tombstone crash handlers installed -> %s", g_tombstone_dir);
}
