# 端侧引擎数据面消费 worker（NPU 稿 §6.4，S3-6）：主进程侧 libgdw.so。
# :engine 进程推理闭环仍在 Kotlin/SDK（geniex-android），本库仅做
# 「Ashmem RingBuffer 消费 + Dart 端口投递」，不做任何推理/采样。
cmake_minimum_required(VERSION 3.22.1)
project(gdw LANGUAGES C CXX)

# Dart DL API 符号定义本体（Dart_PostCObject_DL/Dart_InitializeApiDL）：
# 纯 C 件，必须以 C 编译器编译（C++ 下 FindFunctionPointer 返回类型转换
# 非法），故独立 STATIC 目标链接。vendor 自 flutter dart-sdk/include，
# 升级 Flutter 时同步刷新。
add_library(gdw_dl_api STATIC dart_api/dart_api_dl.c)
target_include_directories(gdw_dl_api PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

add_library(gdw SHARED engine_data_worker.cpp)

# G2-2 墓碑·崩溃栈捕获（:engine 进程侧）：与 libgdw 职责分离——libgdw =
# 主进程数据面消费；本库 = :engine 进程 SIGSEGV/SIGABRT/SIGBUS 落盘。
add_library(engine_tombstone SHARED engine_tombstone.cpp)

target_compile_options(gdw PRIVATE -Wall -Wextra)
target_compile_options(engine_tombstone PRIVATE -Wall -Wextra)
target_include_directories(gdw PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
# Dart DL API 头文件闭包（vendor 自 flutter dart-sdk/include，含
# dart_api.h/dart_native_api.h/dart_version.h——升级 Flutter 时同步刷新）。
target_include_directories(gdw PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/dart_api/..)

find_library(log-lib log)
target_link_libraries(gdw PRIVATE gdw_dl_api ${log-lib})
target_link_libraries(engine_tombstone PRIVATE ${log-lib})
