// 端侧引擎数据面消费 worker（on-device-npu-deployment.md §6.1/§6.4，S3-6）：
// 主进程 native 线程 —— epoll 等待唤醒 fd（pipe 读端）+ 只读映射
// :engine 共享内存 RingBuffer，drain 出 token 字节流经 Dart_PostCObject_DL
// 微批投递 Dart Isolate，全程不占 Binder 线程、不阻塞 UI。
//
// 设计要点（与 Kotlin 侧契约对齐，见 TokenRingBuffer.kt 内存布局）：
//   [0..3] write_idx (u32 LE, 单调自增, 生产者 release 写)
//   [4..7] read_idx  (u32 LE, 单调自增, 消费者 release 写)   ← 本文件唯一写者
//   [8..]  槽区 capacity×4B，载荷 = identity UTF-8 字节值（0..255）
//   容量恒为 2 的幂，idx & (cap-1) 寻址；available = write_idx - read_idx
//   （u32 无符号减法，免显式回绕）。
//
// 载荷投递形态：Uint8Array（kTypedDataUint8Array）微批（Dart_PostCObject
// 复制语义，消费安全）；Dart 侧经 NativeCallable.listener 收 Uint8List
// 喂 StreamingDetokenizer（跨微批流式 UTF-8 重组 §6.4）。
//
// 唤醒通道按「可读 fd」契约承载 pipe 读端（§6.1：eventfd/pipe 对消费端
// 等价）；停止面 = 本文件自建 eventfd（stop() 写 1，线程退出自清理）。

#include <android/log.h>
#include <cerrno>
#include <dart_api/dart_api_dl.h>
#include <jni.h>
#include <pthread.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include <atomic>
#include <cstdint>
#include <cstring>

#define LOG_TAG "GdwWorker"
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

namespace {

constexpr int kMaxDrainPerPass = 4096;      // 单轮 drain 上限（字节）
constexpr int kPostBatchBytes = 4096;       // 单条 Dart 消息批量上限
constexpr int kLogFirstN = 3;               // 前排空打点条数（之后每 100 次一条）

int g_drainCalls = 0;                // 累计 drain 次数（诊断：worker 是否在工作）
std::atomic<int> g_postedBytes{0};   // 累计投递字节

struct Worker {
    Dart_Port_DL port = 0;
    uint8_t* shm = nullptr;          // 读写映射基址（含 header）——消费端要写
                                     // read_idx（header+4），只读映射会 SEGV_ACCERR
    int shmLen = 0;
    int capacity = 0;
    int wakeFd = -1;                 // pipe 读端（Kotlin detachFd 转移所有权）
    int stopFd = -1;                 // 自建 eventfd
    int epfd = -1;
    std::atomic<bool> running{false};
};

// u32 volatile 读（对应 Kotlin setVolatile：ARM ldar/stlr 跨进程可见）。
inline uint32_t loadU32(const uint8_t* at) {
    uint32_t v;
    std::memcpy(&v, at, sizeof(v));
    return __atomic_load_n(&v, __ATOMIC_ACQUIRE);
}

inline void storeU32(uint8_t* at, uint32_t v) {
    __atomic_store_n(at, v, __ATOMIC_RELEASE);
}

// 单条 Dart 消息投递（Uint8Array；Dart_PostCObject 复制数据，消费安全）。
void postBytes(Dart_Port_DL port, const uint8_t* bytes, int len) {
    // 诊断打点（S2-5 字节流腐化排查）：前 2 批 hex 采样，比对写侧 flush hex。
    static int postCount = 0;
    if (++postCount <= 2 && len > 0) {
        char hex[64];
        int off = 0;
        for (int i = 0; i < 16 && i < len && off < 60; ++i) {
            off += snprintf(hex + off, sizeof(hex) - off, "%02x ", bytes[i]);
        }
        LOGW("post #%d len=%d head=[%s]", postCount, len, hex);
    }
    Dart_CObject cobj;
    cobj.type = Dart_CObject_kTypedData;
    cobj.value.as_typed_data.type = Dart_TypedData_kUint8;
    cobj.value.as_typed_data.length = len;
    cobj.value.as_typed_data.values = const_cast<uint8_t*>(bytes);
    if (!Dart_PostCObject_DL(port, &cobj)) {
        LOGW("post failed (port closed)");
    } else {
        g_postedBytes.fetch_add(len, std::memory_order_relaxed);
    }
}

// drain 尽当前可消费字节，按 kPostBatchBytes 分批投 Dart（投递失败 =
// 端口已关闭，静默退出循环由 running 标志收口）。
void drainAndPost(Worker* w) {
    const uint32_t mask = static_cast<uint32_t>(w->capacity - 1);
    uint8_t* header = w->shm;
    uint8_t* slots = w->shm + 8;
    static thread_local uint8_t batch[kPostBatchBytes];
    int filled = 0;
    for (int pass = 0; pass < kMaxDrainPerPass; ++pass) {
        const uint32_t wi = loadU32(header);
        const uint32_t ri = loadU32(header + 4);
        const uint32_t avail = wi - ri;  // u32 回绕语义
        if (avail == 0) break;
        if (avail > static_cast<uint32_t>(w->capacity)) {
            // 失步钳制（S2-5 真机实证）：ri 越过 wi 时 avail 回绕成 ~4.29e9，
            // 不钳制则单次 drain 吞 16MB 未写入槽的垃圾投给 Dart（Format
            // Exception 洪泛/ANR）。失步 = 读写游标协议被破坏（如 clearPending
            // 与在途 drain 竞态）——重同步到写端前沿并放弃本轮，不投垃圾。
            LOGW("ring desync avail=%u ri=%u wi=%u — resync readIdx=wi",
                 avail, ri, wi);
            storeU32(header + 4, wi);
            break;
        }
        const uint32_t n = avail < (kPostBatchBytes - filled)
                               ? avail
                               : (kPostBatchBytes - filled);
        for (uint32_t i = 0; i < n; ++i) {
            const uint32_t idx = ri + i;
            batch[filled + i] = slots[(idx & mask) * 4];  // 低字节 = 字节值
        }
        // 先读槽再 release 推进 read_idx（与 Kotlin 写者 release 发布槽对称）。
        storeU32(header + 4, ri + n);
        filled += static_cast<int>(n);
        if (filled == kPostBatchBytes) {
            postBytes(w->port, batch, filled);
            filled = 0;
        }
    }
    if (filled > 0) postBytes(w->port, batch, filled);
    // 诊断打点（S2-5 ipc deadlock 排查）：worker 是否醒来 + 排空量轨迹。
    int calls = ++g_drainCalls;
    if (calls <= kLogFirstN || calls % 100 == 0) {
        LOGW("drain #%d posted=%dB", calls, g_postedBytes.load());
    }
}

void* workerMain(void* arg) {
    Worker* w = static_cast<Worker*>(arg);
    epoll_event events[2];
    while (w->running.load(std::memory_order_relaxed)) {
        const int n = epoll_wait(w->epfd, events, 2, -1);
        if (n < 0) {
            if (errno == EINTR) continue;
            LOGW("epoll_wait failed: %d", errno);
            break;
        }
        for (int i = 0; i < n; ++i) {
            // 诊断打点（S2-5）：事件分流全出栈——stop 沿/异常沿不再静默。
            LOGW("epoll event fd=%d events=0x%x", events[i].data.fd, events[i].events);
            if (events[i].data.fd == w->stopFd) {
                // 停止沿：耗尽 stop 信号字节后退出主循环。
                uint64_t one;
                while (read(w->stopFd, &one, sizeof(one)) == (ssize_t)sizeof(one)) {}
                w->running.store(false, std::memory_order_relaxed);
            } else if (events[i].events & (EPOLLHUP | EPOLLERR)) {
                // 写端关闭（:engine 死亡/数据面销毁）→ HUP 恒挂，继续 epoll
                // 即百万次热自旋打满 CPU（S2-5 真机实证）——写端 gone 即
                // 数据面死亡，worker 终止，由下次 enable 重建。
                LOGW("wake fd HUP/ERR (writer gone) — worker exiting");
                w->running.store(false, std::memory_order_relaxed);
            } else {
                // 唤醒沿：清 pipe 字节（防累积）+ drain 尽 ring。
                uint8_t scratch[64];
                while (read(w->wakeFd, scratch, sizeof(scratch)) > 0) {}
                LOGW("wake received (drain #%d)", g_drainCalls + 1);
                drainAndPost(w);
            }
        }
    }
    LOGW("worker exiting (running=%d)", w->running.load(std::memory_order_relaxed));
    return nullptr;
}

}  // namespace

extern "C" {

// Dart 侧初始化 DL API 指针（NativeApi.initializeApiDLData，经 MethodChannel
// 以 Long 透传）。幂等：仅首个非空指针生效。
JNIEXPORT void JNICALL
Java_com_zzh_goodhub_GdwNative_initApi(JNIEnv*, jclass, jlong apiPtr) {
    if (apiPtr != 0) {
        Dart_InitializeApiDL(reinterpret_cast<void*>(apiPtr));
    }
}

// 启动消费 worker。返回 handle（>0 成功；0 = 已在运行；<0 = 失败）。
// buffer = Kotlin 侧 shm.mapReadOnly() 直接 ByteBuffer（JNI 取地址，绕开
// SharedMemory.getFd @hide 面）；wakeFd 已由 Kotlin detachFd 转移所有权，
// 失败/stop 路径均由本文件负责关闭。
JNIEXPORT jlong JNICALL
Java_com_zzh_goodhub_GdwNative_start(JNIEnv* env, jclass, jlong port,
                                     jobject buffer, jint wakeFd,
                                     jint capacity) {
    if (!Dart_PostCObject_DL) {
        LOGW("Dart_PostCObject_DL not initialized (initApi 未调)");
        close(wakeFd);
        return -1;
    }
    if (capacity <= 0 || (capacity & (capacity - 1)) != 0) {
        LOGW("capacity must be power of two: %d", capacity);
        close(wakeFd);
        return -2;
    }
    const uint8_t* base =
        static_cast<const uint8_t*>(env->GetDirectBufferAddress(buffer));
    const jlong bufCap = env->GetDirectBufferCapacity(buffer);
    if (base == nullptr || bufCap < 8 + static_cast<jlong>(capacity) * 4) {
        LOGW("buffer not direct or too small: %lld", (long long)bufCap);
        close(wakeFd);
        return -3;
    }
    const int stopFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (stopFd < 0) {
        LOGW("eventfd failed: %d", errno);
        close(wakeFd);
        return -4;
    }
    const int epfd = epoll_create1(EPOLL_CLOEXEC);
    if (epfd < 0) {
        LOGW("epoll_create1 failed: %d", errno);
        close(stopFd);
        close(wakeFd);
        return -5;
    }
    auto* w = new Worker();
    w->port = static_cast<Dart_Port_DL>(port);
    w->shm = const_cast<uint8_t*>(base);
    w->shmLen = static_cast<int>(bufCap);
    w->capacity = capacity;
    w->wakeFd = wakeFd;
    w->stopFd = stopFd;
    w->epfd = epfd;
    // wakeFd 必须非阻塞：唤醒沿的「清 pipe 字节」循环 read 直到耗尽——
    // pipe 默认阻塞模式（dup 共享 O_NONBLOCK 状态标志）下耗尽后 read 会
    // 无限阻塞，worker 永远到不了 drainAndPost（S2-5 真机 ipc deadlock 实证）。
    const int flags = fcntl(wakeFd, F_GETFL, 0);
    if (flags < 0 || fcntl(wakeFd, F_SETFL, flags | O_NONBLOCK) != 0) {
        LOGW("fcntl O_NONBLOCK wakeFd=%d failed: %d", wakeFd, errno);
    }
    epoll_event ev{};
    ev.events = EPOLLIN;
    ev.data.fd = wakeFd;
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, wakeFd, &ev) != 0) {
        LOGW("epoll_ctl ADD wakeFd=%d failed: %d", wakeFd, errno);
    }
    ev.data.fd = stopFd;
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, stopFd, &ev) != 0) {
        LOGW("epoll_ctl ADD stopFd=%d failed: %d", stopFd, errno);
    }
    LOGW("worker started wakeFd=%d stopFd=%d epfd=%d", wakeFd, stopFd, epfd);
    w->running.store(true, std::memory_order_relaxed);
    // 启动即先 drain 一轮：覆盖「写入先于唤醒注册」的窗口。
    drainAndPost(w);
    // pthread_create 失败（EAGAIN/ENOMEM）在 Android 端侧进程（模型已占
    // ~1.9GB）下常为瞬时抖动或线程数瞬时触顶——有界重试若干次（5ms 退避）
    // 即可恢复，避免直接以 -6 失败炸上层。失败路径打印 errno 便于真机确认
    // 根因是瞬时（EAGAIN）还是持久资源不足（ENOMEM/线程数到顶）。
    pthread_t tid;
    int tries = 0;
    constexpr int kMaxTries = 3;
    while (pthread_create(&tid, nullptr, workerMain, w) != 0) {
        const int err = errno;
        if (++tries >= kMaxTries) {
            LOGW("pthread_create failed after %d tries: %d (%s)", tries, err,
                 strerror(err));
            close(stopFd);
            close(epfd);
            close(wakeFd);
            delete w;
            return -6;
        }
        usleep(5000);
    }
    pthread_detach(tid);
    return reinterpret_cast<jlong>(w);
}

// 停止并释放（幂等：handle=0 no-op）。写 stop eventfd → 线程退出 →
// 清理映射与 fd。调用后 handle 置 0 由 Kotlin 侧维护。
JNIEXPORT void JNICALL
Java_com_zzh_goodhub_GdwNative_stop(JNIEnv*, jclass, jlong handle) {
    if (handle == 0) return;
    auto* w = reinterpret_cast<Worker*>(handle);
    const uint64_t one = 1;
    write(w->stopFd, &one, sizeof(one));  // 唤醒线程走停止沿
    // 线程 detach 化，此处不 join；资源随 running=false 后自清理由 stop
    // 触发的主循环收口——fd/映射生命周期归 Worker，延迟销毁安全：
    // running=false 后线程不再触碰 fd/映射，此处阻塞等待其退出。
    while (w->running.load(std::memory_order_relaxed)) {
        usleep(1000);
    }
    close(w->wakeFd);
    close(w->stopFd);
    close(w->epfd);
    delete w;
}

}  // extern "C"
