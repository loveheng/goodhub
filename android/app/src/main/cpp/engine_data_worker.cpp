// 端侧引擎数据面消费 worker（NPU 稿 §6.4 v3.1，S3-6 UDS 化）：主进程侧 libgdw.so。
// :engine 进程推理闭环仍在 Kotlin/SDK（geniex-android），本库仅做
// 「Unix domain socket 帧读取 + Dart 端口投递」，不做任何推理/采样。
//
// 数据面协议（on-device-npu-deployment.md §6.1 v3.1，S3-7 TLV 化）：
//   [2 字节魔数 0x5A 0xA5][2 字节帧类型][4 字节大端 payload_len][payload]
//   type 0x0001 TOKEN_CHUNK → 微批聚合投 Dart（文本块 UTF-8）
//   type 0x0002 IMAGE_META / 0x0003 PROGRESS → 协议留位（多模态 epic 启用）；
//     当前读到按未知类型 skip + 计数日志（前向兼容：单端先升级不互炸）
//   type 0x000F EOS → 流终结帧（payload_len 恒 0；Dart 流生命周期唯一事实源）
//   read() == 0 (EOF) → 对端关闭（:engine 数据面销毁/进程死亡）→ 投 Dart
//                       null 信号（Dart 侧即刻 failAllActive 收口）后终态退出
//
// 投递形状：kArray [Int32 type, Uint8List payload]（Dart_PostCObject 复制语义，
// 栈上对象仅在 Post 调用期有效即安全）。
//
// 投递策略：**首帧直通 + 微批聚合**——可读沿尽读 socket 缓冲，TOKEN 帧逐帧
// 拼入本地批缓冲（≥4KB 或遇其他类型/EOS/暂无数据即投），高吞吐段把 N 次
// Dart_PostCObject_DL 压成 1 次，防 Dart 事件循环被高频小事件冲垮丢帧；首字
// 延迟不受影响（第一帧随首个可读沿直通投递）。非 TOKEN 帧不聚合（类型语义
// 各异，且 EOS 为代边界必须单投）。
//
// 唤醒/背压/崩溃隔离全部由内核承载：socket 可读事件即唤醒；SO_SNDBUF 满
// 时写端自然阻塞（写侧 3s 有界超时判 IPC_DEADLOCK）；无共享游标，不存在
// 游标错位类失步（旧 RingBuffer 的 P2-10/S2-5 修复面随实现整体退役）。
// SIGPIPE：zygote fork 已 SIG_IGN，本库 initApi 再设一道（防御双保险）。
#include <android/log.h>
#include <cerrno>
#include <csignal>
#include <dart_api/dart_api_dl.h>
#include <fcntl.h>
#include <jni.h>
#include <pthread.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <vector>

#include <atomic>
#include <cstdint>
#include <cstring>

#define LOG_TAG "GdwNative"
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

namespace {

constexpr int kReadChunk = 65536;       // 单次 read() 缓冲
constexpr int kMaxFrameBytes = 1 << 20; // 帧长上限（协议腐化判定；大块数据走落盘+元数据帧引用，不入本协议载荷）
constexpr int kPostBatchBytes = 4096;   // TOKEN 投递微批上限（字节）：防单条 Dart 消息过大
constexpr int kEpollTickMs = 1000;      // 兜底节拍：仅 running 标志复查用

// 帧魔数 + 帧类型（TLV 的 M/T，与 Kotlin SocketTokenWriter/FrameType 同一常量语义）。
constexpr uint8_t kMagic0 = 0x5A;
constexpr uint8_t kMagic1 = 0xA5;
constexpr int kHeaderBytes = 8;  // 魔数 2B + 类型 2B + 长度 4B
constexpr uint16_t kTypeToken = 0x0001;
constexpr uint16_t kTypeEos = 0x000F;

std::atomic<int> g_unknownFrames{0};  // 未知类型帧计数（前向兼容跳过，诊断面）

// start 失败分类码（诊断通道，与返回值的指针值域正交，故可用小正整数）
enum : int {
    kStartErrNone = 0,
    kStartErrNoDartApi = 1,   // initApi 未调 / Dart_PostCObject_DL 为空
    kStartErrEventfd = 2,     // eventfd 创建失败（errno 见 g_lastErrno）
    kStartErrEpoll = 3,       // epoll_create1 / epoll_ctl 失败（errno 见 g_lastErrno）
    kStartErrSock = 4,        // socket fd 设非阻塞失败
    kStartErrPthread = 5,     // pthread_create 重试耗尽（errno 见 g_lastErrno）
};

std::atomic<int> g_readCalls{0};      // 累计可读唤醒次数（诊断：worker 是否在工作）
std::atomic<int> g_postedBytes{0};   // 累计投递字节
std::atomic<int> g_lastError{kStartErrNone};
std::atomic<int> g_lastErrno{0};

struct Worker {
    Dart_Port_DL port = 0;
    int sockFd = -1;                 // 数据面 socket 读端（AIDL detachFd 转移所有权）
    int stopFd = -1;                 // 自建 eventfd
    int epfd = -1;
    std::atomic<bool> running{false};

    // 帧重组缓冲（单线程独占）：粘包/拆包在此归一为完整帧。
    std::vector<uint8_t> acc;
    // 投递微批缓冲（单线程独占）：高吞吐段聚合多帧为一次 Dart 投递。
    std::vector<uint8_t> batch;
};

inline uint32_t loadBE32(const uint8_t* at) {
    return (static_cast<uint32_t>(at[0]) << 24) |
           (static_cast<uint32_t>(at[1]) << 16) |
           (static_cast<uint32_t>(at[2]) << 8) |
           static_cast<uint32_t>(at[3]);
}

// 单条 Dart 消息投递（kArray [Int32 type, Uint8List payload]；Dart_PostCObject
// 复制全部数据，栈上临时对象仅在 Post 调用期有效即安全）。
// len == 0 合法（EOS 流终结帧 → Dart 侧空载荷即本代收口信号）。
void postFrame(Dart_Port_DL port, uint16_t type, const uint8_t* bytes, int len) {
    Dart_CObject obj_type;
    obj_type.type = Dart_CObject_kInt32;
    obj_type.value.as_int32 = static_cast<int32_t>(type);

    Dart_CObject obj_data;
    obj_data.type = Dart_CObject_kTypedData;
    obj_data.value.as_typed_data.type = Dart_TypedData_kUint8;
    obj_data.value.as_typed_data.length = len;
    obj_data.value.as_typed_data.values =
        len > 0 ? const_cast<uint8_t*>(bytes) : nullptr;

    Dart_CObject* values[] = {&obj_type, &obj_data};
    Dart_CObject wrapper;
    wrapper.type = Dart_CObject_kArray;
    wrapper.value.as_array.length = 2;
    wrapper.value.as_array.values = values;
    if (!Dart_PostCObject_DL(port, &wrapper)) {
        LOGW("post failed (port closed)");
    } else {
        g_postedBytes.fetch_add(len, std::memory_order_relaxed);
    }
}

// EOF 信号投递（kNull）：数据面死亡即刻通知 Dart（failAllActive 收口），
// 不经 30s 看门狗兜底。与 EOS（空批）是两个不同信号。
void postNull(Dart_Port_DL port) {
    Dart_CObject cobj;
    cobj.type = Dart_CObject_kNull;
    if (!Dart_PostCObject_DL(port, &cobj)) {
        LOGW("post null failed (port closed)");
    }
}

void flushBatch(Worker* w) {
    if (!w->batch.empty()) {
        postFrame(w->port, kTypeToken, w->batch.data(),
                  static_cast<int>(w->batch.size()));
        w->batch.clear();
    }
}

// 帧重组 + 微批聚合：按 [魔数 2B][类型 2B][4B BE len][payload] 循环切包，
// 粘包/拆包透明。魔数不匹配或帧长超限 = 协议腐化（流偏移/对端错帧）：
// fail-fast，worker 终态退出由 isAlive 判活重建路径自愈——不投垃圾。
// 类型分发：TOKEN → 聚合；EOS → 代边界先投已聚合批再单投（**严禁把 EOS 与
// 任何载荷（含下一代的帧）并入同一条消息**——空载荷即流终，混投即丢 EOS
// 语义）；其余类型（IMAGE_META/PROGRESS/未来新增）→ **skip 整帧 + 计数日志**
// （前向兼容：单端先升级不互炸；生产端启用时在同位替换为本类型的投递分支）。
void parseFrames(Worker* w) {
    for (;;) {
        if (w->acc.size() < static_cast<size_t>(kHeaderBytes)) return;
        if (w->acc[0] != kMagic0 || w->acc[1] != kMagic1) {
            LOGW("frame magic mismatch %02x%02x — protocol corruption, worker exiting",
                 w->acc[0], w->acc[1]);
            w->running.store(false, std::memory_order_relaxed);
            return;
        }
        const uint16_t type = static_cast<uint16_t>((w->acc[2] << 8) | w->acc[3]);
        const uint32_t len = loadBE32(w->acc.data() + 4);
        if (len > kMaxFrameBytes) {
            LOGW("frame type=%u len %u > cap — protocol corruption, worker exiting",
                 type, len);
            w->running.store(false, std::memory_order_relaxed);
            return;
        }
        if (w->acc.size() < kHeaderBytes + static_cast<size_t>(len)) return;
        const uint8_t* payload = w->acc.data() + kHeaderBytes;
        if (type == kTypeEos) {
            flushBatch(w);
            postFrame(w->port, kTypeEos, nullptr, 0);  // EOS：代边界，单投
        } else if (type == kTypeToken) {
            w->batch.insert(w->batch.end(), payload, payload + len);
            if (w->batch.size() >= static_cast<size_t>(kPostBatchBytes)) flushBatch(w);
        } else {
            // 未知/留位类型：skip（载荷不投递，帧边界仍按头推进）。
            const int skips = g_unknownFrames.fetch_add(1) + 1;
            if (skips <= 3 || skips % 100 == 0) {
                LOGW("skip unknown frame type=%u len=%u (#%d)", type, len, skips);
            }
        }
        w->acc.erase(w->acc.begin(), w->acc.begin() + kHeaderBytes + len);
    }
}

// 尽读当前可读字节：>0 追加重组；0 = EOF（对端关闭，数据面死亡）；-1 = 暂无
// 数据（EAGAIN，正常返回）。返回 0/1/-1/-2（-2 = worker 需退出）。
int drainSocket(Worker* w) {
    uint8_t chunk[kReadChunk];
    for (;;) {
        const ssize_t n = read(w->sockFd, chunk, sizeof(chunk));
        if (n > 0) {
            w->acc.insert(w->acc.end(), chunk, chunk + n);
            parseFrames(w);
            if (!w->running.load(std::memory_order_relaxed)) return -2;
            continue;
        }
        if (n == 0) {
            LOGW("socket EOF (writer gone) — data plane dead, worker exiting");
            return 0;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) return 1;
        if (errno == EINTR) continue;
        LOGW("socket read failed: %d — worker exiting", errno);
        return -2;
    }
}

void* workerMain(void* arg) {
    Worker* w = static_cast<Worker*>(arg);
    epoll_event events[2];
    while (w->running.load(std::memory_order_relaxed)) {
        const int n = epoll_wait(w->epfd, events, 2, kEpollTickMs);
        if (n == 0) continue;  // 兜底节拍：仅复查 running 标志
        if (n < 0) {
            if (errno == EINTR) continue;
            LOGW("epoll_wait failed: %d", errno);
            w->running.store(false, std::memory_order_relaxed);
            break;
        }
        for (int i = 0; i < n; ++i) {
            if (events[i].data.fd == w->stopFd) {
                uint64_t one;
                while (read(w->stopFd, &one, sizeof(one)) == (ssize_t)sizeof(one)) {}
                w->running.store(false, std::memory_order_relaxed);
            } else if (events[i].events & (EPOLLIN | EPOLLHUP | EPOLLERR)) {
                // HUP 沿仍先尽读（内核缓冲可能残留尾帧），EOF 由 read()==0 判定。
                const int r = drainSocket(w);
                // 可读沿收口：本轮尽读的聚合批直通投递（首帧直通语义——
                // 首个可读沿的数据立即抵达 Dart，不等下一沿）。
                flushBatch(w);
                if (r <= 0) {
                    // EOF / 致命错误：即刻投 null 信号（Dart failAllActive）后退出。
                    if (r == 0) postNull(w->port);
                    w->running.store(false, std::memory_order_relaxed);
                } else {
                    int calls = g_readCalls.fetch_add(1) + 1;
                    static int lastLoggedPosted = -1;
                    const int posted = g_postedBytes.load();
                    if ((calls <= 3 || calls % 100 == 0) && posted != lastLoggedPosted) {
                        lastLoggedPosted = posted;
                        LOGW("drain #%d posted=%dB", calls, posted);
                    }
                }
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
    // SIGPIPE 防御双保险：zygote fork 的 App 进程已 SIG_IGN（app_process 启动
    // 即屏蔽），此处再显式设一道——对端关闭后的写操作返回 EPIPE 经
    // ErrnoException 正常上抛，杜绝内核默认处置（进程终止）的可能逃逸面。
    ::signal(SIGPIPE, SIG_IGN);
    if (apiPtr != 0) {
        Dart_InitializeApiDL(reinterpret_cast<void*>(apiPtr));
    }
}

// 启动消费 worker。返回 handle：**成功 ≠ 0，失败 = 0**（宿主侧**恒判 != 0，
// 禁判正负**——历史教训见 gdw-handle-sign 钉：成功值是 Worker* 转 jlong，
// Android 64 位 tagged pointer 恒为负；错误分类经 [lastError]/[lastErrno] 取）。
//
// sockFd = 数据面 socket 读端（AIDL getDataSocketFd detachFd 移交所有权，
// 失败/stop 路径均由本文件负责关闭）。
JNIEXPORT jlong JNICALL
Java_com_zzh_goodhub_GdwNative_start(JNIEnv* env, jclass, jlong port,
                                     jint sockFd) {
    // 每次 start 重置诊断通道（分类码仅在本次调用返回 0 后有意义）
    g_lastError.store(kStartErrNone, std::memory_order_relaxed);
    g_lastErrno.store(0, std::memory_order_relaxed);
    if (!Dart_PostCObject_DL) {
        LOGW("Dart_PostCObject_DL not initialized (initApi 未调)");
        close(sockFd);
        g_lastError.store(kStartErrNoDartApi, std::memory_order_relaxed);
        return 0;
    }
    const int stopFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (stopFd < 0) {
        LOGW("eventfd failed: %d", errno);
        close(sockFd);
        g_lastError.store(kStartErrEventfd, std::memory_order_relaxed);
        g_lastErrno.store(errno, std::memory_order_relaxed);
        return 0;
    }
    const int epfd = epoll_create1(EPOLL_CLOEXEC);
    if (epfd < 0) {
        LOGW("epoll_create1 failed: %d", errno);
        close(stopFd);
        close(sockFd);
        g_lastError.store(kStartErrEpoll, std::memory_order_relaxed);
        g_lastErrno.store(errno, std::memory_order_relaxed);
        return 0;
    }
    const int flags = fcntl(sockFd, F_GETFL, 0);
    if (flags < 0 || fcntl(sockFd, F_SETFL, flags | O_NONBLOCK) != 0) {
        LOGW("fcntl O_NONBLOCK sockFd=%d failed: %d", sockFd, errno);
        close(stopFd);
        close(epfd);
        close(sockFd);
        g_lastError.store(kStartErrSock, std::memory_order_relaxed);
        g_lastErrno.store(errno, std::memory_order_relaxed);
        return 0;
    }
    auto* w = new Worker();
    w->port = static_cast<Dart_Port_DL>(port);
    w->sockFd = sockFd;
    w->stopFd = stopFd;
    w->epfd = epfd;
    w->acc.reserve(kReadChunk);
    epoll_event ev{};
    ev.events = EPOLLIN;
    ev.data.fd = sockFd;
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, sockFd, &ev) != 0) {
        LOGW("epoll_ctl ADD sockFd=%d failed: %d", sockFd, errno);
        close(stopFd);
        close(epfd);
        close(sockFd);
        delete w;
        g_lastError.store(kStartErrEpoll, std::memory_order_relaxed);
        g_lastErrno.store(errno, std::memory_order_relaxed);
        return 0;
    }
    ev.data.fd = stopFd;
    if (epoll_ctl(epfd, EPOLL_CTL_ADD, stopFd, &ev) != 0) {
        LOGW("epoll_ctl ADD stopFd=%d failed: %d", stopFd, errno);
        close(stopFd);
        close(epfd);
        close(sockFd);
        delete w;
        g_lastError.store(kStartErrEpoll, std::memory_order_relaxed);
        g_lastErrno.store(errno, std::memory_order_relaxed);
        return 0;
    }
    LOGW("worker started sockFd=%d stopFd=%d epfd=%d", sockFd, stopFd, epfd);
    w->running.store(true, std::memory_order_relaxed);
    // pthread_create 失败（EAGAIN/ENOMEM）在 Android 端侧进程（模型已占
    // ~1.9GB）下常为瞬时抖动或线程数瞬时触顶——有界重试（5ms 退避）。
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
            close(sockFd);
            delete w;
            g_lastError.store(kStartErrPthread, std::memory_order_relaxed);
            g_lastErrno.store(err, std::memory_order_relaxed);
            return 0;
        }
        usleep(5000);
    }
    pthread_detach(tid);
    return reinterpret_cast<jlong>(w);
}

// 停止并释放（幂等：handle=0 no-op）。写 stop eventfd → 线程退出 →
// 清理 fd。调用后 handle 置 0 由 Kotlin 侧维护。
JNIEXPORT void JNICALL
Java_com_zzh_goodhub_GdwNative_stop(JNIEnv*, jclass, jlong handle) {
    if (handle == 0) return;
    auto* w = reinterpret_cast<Worker*>(handle);
    const uint64_t one = 1;
    write(w->stopFd, &one, sizeof(one));  // 唤醒线程走停止沿
    // 有界等待（≤2s）：线程若卡在不可中断路径，stop 不能无限期占住调用线程
    //（AIDL 回调线程被占 → 桥面 stopDataPlane 阻塞 → 事件面停摆）。
    for (int waited = 0;
         waited < 2000 && w->running.load(std::memory_order_relaxed);
         ++waited) {
        usleep(1000);
    }
    if (w->running.load(std::memory_order_relaxed)) {
        LOGW("worker still running after 2000ms — force release (fd 由内核回收)");
    }
    close(w->sockFd);
    close(w->stopFd);
    close(w->epfd);
    delete w;
}

// 消费线程存活判据（宿主侧幂等短路用）：worker 线程退出（socket EOF /
// 协议腐化 / epoll 错误）后句柄仍留在宿主手里——宿主判活后可自愈重建
//（handle=0 → 恒 false）。
JNIEXPORT jboolean JNICALL
Java_com_zzh_goodhub_GdwNative_isAlive(JNIEnv*, jclass, jlong handle) {
    if (handle == 0) return JNI_FALSE;
    auto* w = reinterpret_cast<Worker*>(handle);
    return w->running.load(std::memory_order_relaxed) ? JNI_TRUE : JNI_FALSE;
}

// 取上次 start 失败的分类码（0 = 无失败）。诊断与返回值分离：宿主侧只需判
// 返回句柄 != 0，失败原因经本通道取。
JNIEXPORT jint JNICALL
Java_com_zzh_goodhub_GdwNative_lastError(JNIEnv*, jclass) {
    return g_lastError.load(std::memory_order_relaxed);
}

JNIEXPORT jint JNICALL
Java_com_zzh_goodhub_GdwNative_lastErrno(JNIEnv*, jclass) {
    return g_lastErrno.load(std::memory_order_relaxed);
}

// 消费端可读唤醒计数（诊断对账面，语义沿用旧 drain 计数）：宿主侧在 IPC
// 死锁上报时取此二值——计数不动 = 消费端没在读（线程死 / fd 错）；
JNIEXPORT jint JNICALL
Java_com_zzh_goodhub_GdwNative_lastDrainCount(JNIEnv*, jclass) {
    return g_readCalls.load(std::memory_order_relaxed);
}

// 消费端累计投递字节（诊断）：与 [lastDrainCount] 同面取用——排空过但
// 字节不动 = 投不出去（端口关闭 / Dart 侧未接）。
JNIEXPORT jint JNICALL
Java_com_zzh_goodhub_GdwNative_lastPostedBytes(JNIEnv*, jclass) {
    return g_postedBytes.load(std::memory_order_relaxed);
}

// 归还文件页缓存（posix_fadvise + POSIX_FADV_DONTNEED）：模型分片读入并解析
// 完成后丢弃其 clean page cache，加速整机 MemAvailable 回到健康水位。
//
// 边界（如实记录，禁当削峰手段）：内核按**建议**执行——脏页、或仍被 mmap
// 持有的映射不会立即丢弃；外置存储（FUSE）文件的缓存由 FUSE 自行管理，
// 效果可能有限。故本函数只加速**装载之后**的稳态恢复，**削不平装载瞬态
// 尖峰**（尖峰由权重驻留 + DSP 建立决定，与页缓存无关）。
//
// 返回：0 = 成功；<0 = 失败（errno 取绝对值）。
JNIEXPORT jint JNICALL
Java_com_zzh_goodhub_GdwNative_dropFileCache(JNIEnv* env, jclass, jstring path) {
    const char* utf8 = env->GetStringUTFChars(path, nullptr);
    if (utf8 == nullptr) return -1;
    int fd = ::open(utf8, O_RDONLY | O_CLOEXEC);
    env->ReleaseStringUTFChars(path, utf8);
    if (fd < 0) return -1;
    int rc = ::posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
    ::close(fd);
    return rc;
}

// CMA/DMA-BUF 预分配探针（npu-deployment 稿 §4.9，2026-11-02 加载机制 #7）：
// 装载前以**同量级**尺寸向系统 DMA-BUF 堆真实试分配一次——虚拟内存门禁
// （ActivityManager availMem）探不到物理页碎片化，长开机后一次性大块 ION
// 请求会内核级 ENOMEM/深度 Direct Reclaim 整机卡死。命中即装载前放弃端侧
//（提示重启后重试），不重试、不计熔断（§6.5 口径：环境变更非本端 Bug）。
//
// 语义（返回码三分，禁二值化）：
//   0 = 试分配成功（CMA 可用）——fd 即刻 close（探针即弃，不留句柄）；
//   1 = 堆不可达（SELinux / 无 dma_heap 节点 / ioctl ENOTTY）= **探针不可用**
//       ——不判 CMA 不可用（全机型都会被 SELinux 挡 = 误杀全部端侧）；
//   2 = 堆可达但分配失败（ENOMEM 等）= **CMA 不可用**（真判据）。
//
// 头文件说明：NDK 无 <linux/dma-heap.h>，DMA_HEAP_IOCTL_ALLOC 按 uapi 定义
// 内联（_IOWR('H', 0x0, dma_heap_allocation_data)，v5.6+ uapi 稳定 ABI）。
JNIEXPORT jint JNICALL
Java_com_zzh_goodhub_GdwNative_cmaProbe(JNIEnv*, jclass, jlong bytes) {
    if (bytes <= 0) return 1;
    // /dev/dma_heap/system：v5.6+ 标准 cma 后备堆（untrusted_app 常被
    // SELinux 拒，拒 = 探针不可用而非 CMA 不可用，见返回码 1）。
    int heap = ::open("/dev/dma_heap/system", O_RDWR | O_CLOEXEC);
    if (heap < 0) return 1;
    struct DmaHeapAllocData {
        std::uint64_t len;
        std::uint32_t fd;
        std::uint32_t heap_flags;
    };
    DmaHeapAllocData data{};
    data.len = static_cast<std::uint64_t>(bytes);
    // DMA_HEAP_IOCTL_ALLOC 请求码（uapi 公式 _IOC(RW=3, 'H', 0, sizeof(data)=16)
    // = (3<<30)|(16<<16)|('H'<<8)|0 = 0xC0144800；宏式在 C++ 下对函数局部
    // struct 不可用，按内核 uapi 稳定 ABI 手工推导）。
    constexpr unsigned long kDmaHeapIoctlAlloc = 0xC0144800UL;
    int rc = ::ioctl(heap, kDmaHeapIoctlAlloc, &data);
    int probeErrno = errno;
    if (rc == 0 && data.fd >= 0) {
        ::close(data.fd);  // 探针即弃：验证可分配性，不持有
        ::close(heap);
        return 0;
    }
    ::close(heap);
    // 分配被拒：ENOMEM（碎片化）/ EINTR 重试一次（信号打断非真不可用）。
    if (probeErrno == EINTR) {
        data.fd = 0;
        rc = ::ioctl(heap, kDmaHeapIoctlAlloc, &data);
        if (rc == 0 && data.fd >= 0) {
            ::close(data.fd);
            return 0;
        }
        probeErrno = errno;
    }
    return 2;
}

}  // extern "C"
