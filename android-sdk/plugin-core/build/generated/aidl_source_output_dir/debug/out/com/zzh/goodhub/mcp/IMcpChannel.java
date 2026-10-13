/*
 * This file is auto-generated.  DO NOT MODIFY.
 * Using: /home/zzh/android-sdk/build-tools/36.0.0/aidl -p/home/zzh/android-sdk/platforms/android-35/framework.aidl -o/home/zzh/app/goodhub/android-sdk/plugin-core/build/generated/aidl_source_output_dir/debug/out -I/home/zzh/app/goodhub/android-sdk/plugin-core/src/main/aidl -I/home/zzh/app/goodhub/android-sdk/plugin-core/src/debug/aidl -d/tmp/aidl13495189383033006272.d /home/zzh/app/goodhub/android-sdk/plugin-core/src/main/aidl/com/zzh/goodhub/mcp/IMcpChannel.aidl
 *
 * DO NOT CHECK THIS FILE INTO A CODE TREE (e.g. git, etc..).
 * ALWAYS GENERATE THIS FILE FROM UPDATED AIDL COMPILER
 * AS A BUILD INTERMEDIATE ONLY. THIS IS NOT SOURCE CODE.
 */
package com.zzh.goodhub.mcp;
public interface IMcpChannel extends android.os.IInterface
{
  /** Default implementation for IMcpChannel. */
  public static class Default implements com.zzh.goodhub.mcp.IMcpChannel
  {
    // 同步 JSON-RPC 请求-响应：GoodHub 发裸请求，插件回裸 JSON-RPC 响应字符串。
    // 用于 initialize / tools/list / tools/call / resources/* / prompts/*。
    // 必须在 Binder 事务预算内返回（见 §1.2.3）；长任务改 _async 异步（见下）。
    @Override public java.lang.String call(java.lang.String jsonRpcRequest) throws android.os.RemoteException
    {
      return null;
    }
    // 注册事件回调（进度/反向请求）。首次 bindService 后、首次 call 前调用一次；
    // 传 null 注销。DeathRecipient 触发视为断开。
    @Override public void registerCallback(com.zzh.goodhub.mcp.IMcpCallback callback) throws android.os.RemoteException
    {
    }
    // GoodHub 回答插件经 onEvent 发来的反向请求：把 JSON-RPC 响应字符串回插件。
    // oneway：应答不阻塞 GoodHub。插件按 id 关联原请求。
    @Override public void answerReverse(java.lang.String jsonRpcResponse) throws android.os.RemoteException
    {
    }
    @Override
    public android.os.IBinder asBinder() {
      return null;
    }
  }
  /** Local-side IPC implementation stub class. */
  public static abstract class Stub extends android.os.Binder implements com.zzh.goodhub.mcp.IMcpChannel
  {
    /** Construct the stub and attach it to the interface. */
    @SuppressWarnings("this-escape")
    public Stub()
    {
      this.attachInterface(this, DESCRIPTOR);
    }
    /**
     * Cast an IBinder object into an com.zzh.goodhub.mcp.IMcpChannel interface,
     * generating a proxy if needed.
     */
    public static com.zzh.goodhub.mcp.IMcpChannel asInterface(android.os.IBinder obj)
    {
      if ((obj==null)) {
        return null;
      }
      android.os.IInterface iin = obj.queryLocalInterface(DESCRIPTOR);
      if (((iin!=null)&&(iin instanceof com.zzh.goodhub.mcp.IMcpChannel))) {
        return ((com.zzh.goodhub.mcp.IMcpChannel)iin);
      }
      return new com.zzh.goodhub.mcp.IMcpChannel.Stub.Proxy(obj);
    }
    @Override public android.os.IBinder asBinder()
    {
      return this;
    }
    @Override public boolean onTransact(int code, android.os.Parcel data, android.os.Parcel reply, int flags) throws android.os.RemoteException
    {
      java.lang.String descriptor = DESCRIPTOR;
      if (code >= android.os.IBinder.FIRST_CALL_TRANSACTION && code <= android.os.IBinder.LAST_CALL_TRANSACTION) {
        data.enforceInterface(descriptor);
      }
      if (code == INTERFACE_TRANSACTION) {
        reply.writeString(descriptor);
        return true;
      }
      switch (code)
      {
        case TRANSACTION_call:
        {
          java.lang.String _arg0;
          _arg0 = data.readString();
          java.lang.String _result = this.call(_arg0);
          reply.writeNoException();
          reply.writeString(_result);
          break;
        }
        case TRANSACTION_registerCallback:
        {
          com.zzh.goodhub.mcp.IMcpCallback _arg0;
          _arg0 = com.zzh.goodhub.mcp.IMcpCallback.Stub.asInterface(data.readStrongBinder());
          this.registerCallback(_arg0);
          reply.writeNoException();
          break;
        }
        case TRANSACTION_answerReverse:
        {
          java.lang.String _arg0;
          _arg0 = data.readString();
          this.answerReverse(_arg0);
          break;
        }
        default:
        {
          return super.onTransact(code, data, reply, flags);
        }
      }
      return true;
    }
    private static class Proxy implements com.zzh.goodhub.mcp.IMcpChannel
    {
      private android.os.IBinder mRemote;
      Proxy(android.os.IBinder remote)
      {
        mRemote = remote;
      }
      @Override public android.os.IBinder asBinder()
      {
        return mRemote;
      }
      public java.lang.String getInterfaceDescriptor()
      {
        return DESCRIPTOR;
      }
      // 同步 JSON-RPC 请求-响应：GoodHub 发裸请求，插件回裸 JSON-RPC 响应字符串。
      // 用于 initialize / tools/list / tools/call / resources/* / prompts/*。
      // 必须在 Binder 事务预算内返回（见 §1.2.3）；长任务改 _async 异步（见下）。
      @Override public java.lang.String call(java.lang.String jsonRpcRequest) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        android.os.Parcel _reply = android.os.Parcel.obtain();
        java.lang.String _result;
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeString(jsonRpcRequest);
          boolean _status = mRemote.transact(Stub.TRANSACTION_call, _data, _reply, 0);
          _reply.readException();
          _result = _reply.readString();
        }
        finally {
          _reply.recycle();
          _data.recycle();
        }
        return _result;
      }
      // 注册事件回调（进度/反向请求）。首次 bindService 后、首次 call 前调用一次；
      // 传 null 注销。DeathRecipient 触发视为断开。
      @Override public void registerCallback(com.zzh.goodhub.mcp.IMcpCallback callback) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        android.os.Parcel _reply = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeStrongInterface(callback);
          boolean _status = mRemote.transact(Stub.TRANSACTION_registerCallback, _data, _reply, 0);
          _reply.readException();
        }
        finally {
          _reply.recycle();
          _data.recycle();
        }
      }
      // GoodHub 回答插件经 onEvent 发来的反向请求：把 JSON-RPC 响应字符串回插件。
      // oneway：应答不阻塞 GoodHub。插件按 id 关联原请求。
      @Override public void answerReverse(java.lang.String jsonRpcResponse) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeString(jsonRpcResponse);
          boolean _status = mRemote.transact(Stub.TRANSACTION_answerReverse, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
    }
    static final int TRANSACTION_call = (android.os.IBinder.FIRST_CALL_TRANSACTION + 0);
    static final int TRANSACTION_registerCallback = (android.os.IBinder.FIRST_CALL_TRANSACTION + 1);
    static final int TRANSACTION_answerReverse = (android.os.IBinder.FIRST_CALL_TRANSACTION + 2);
  }
  /** @hide */
  public static final java.lang.String DESCRIPTOR = "com.zzh.goodhub.mcp.IMcpChannel";
  // 同步 JSON-RPC 请求-响应：GoodHub 发裸请求，插件回裸 JSON-RPC 响应字符串。
  // 用于 initialize / tools/list / tools/call / resources/* / prompts/*。
  // 必须在 Binder 事务预算内返回（见 §1.2.3）；长任务改 _async 异步（见下）。
  public java.lang.String call(java.lang.String jsonRpcRequest) throws android.os.RemoteException;
  // 注册事件回调（进度/反向请求）。首次 bindService 后、首次 call 前调用一次；
  // 传 null 注销。DeathRecipient 触发视为断开。
  public void registerCallback(com.zzh.goodhub.mcp.IMcpCallback callback) throws android.os.RemoteException;
  // GoodHub 回答插件经 onEvent 发来的反向请求：把 JSON-RPC 响应字符串回插件。
  // oneway：应答不阻塞 GoodHub。插件按 id 关联原请求。
  public void answerReverse(java.lang.String jsonRpcResponse) throws android.os.RemoteException;
}
