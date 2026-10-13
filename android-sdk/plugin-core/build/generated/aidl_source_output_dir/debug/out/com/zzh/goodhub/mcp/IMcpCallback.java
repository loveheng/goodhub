/*
 * This file is auto-generated.  DO NOT MODIFY.
 * Using: /home/zzh/android-sdk/build-tools/36.0.0/aidl -p/home/zzh/android-sdk/platforms/android-35/framework.aidl -o/home/zzh/app/goodhub/android-sdk/plugin-core/build/generated/aidl_source_output_dir/debug/out -I/home/zzh/app/goodhub/android-sdk/plugin-core/src/main/aidl -I/home/zzh/app/goodhub/android-sdk/plugin-core/src/debug/aidl -d/tmp/aidl14289642693496569149.d /home/zzh/app/goodhub/android-sdk/plugin-core/src/main/aidl/com/zzh/goodhub/mcp/IMcpCallback.aidl
 *
 * DO NOT CHECK THIS FILE INTO A CODE TREE (e.g. git, etc..).
 * ALWAYS GENERATE THIS FILE FROM UPDATED AIDL COMPILER
 * AS A BUILD INTERMEDIATE ONLY. THIS IS NOT SOURCE CODE.
 */
package com.zzh.goodhub.mcp;
public interface IMcpCallback extends android.os.IInterface
{
  /** Default implementation for IMcpCallback. */
  public static class Default implements com.zzh.goodhub.mcp.IMcpCallback
  {
    // 插件主动推给 GoodHub 的事件，内容为单条 JSON-RPC 消息字符串：
    //  - 通知帧：notifications/progress
    //  - 反向请求帧：server→client request（带 method + id，如 sampling/createMessage）
    // oneway：投递不阻塞插件；GoodHub 侧经 EventChannel 桥回 Dart。
    @Override public void onEvent(java.lang.String jsonRpcMessage) throws android.os.RemoteException
    {
    }
    @Override
    public android.os.IBinder asBinder() {
      return null;
    }
  }
  /** Local-side IPC implementation stub class. */
  public static abstract class Stub extends android.os.Binder implements com.zzh.goodhub.mcp.IMcpCallback
  {
    /** Construct the stub and attach it to the interface. */
    @SuppressWarnings("this-escape")
    public Stub()
    {
      this.attachInterface(this, DESCRIPTOR);
    }
    /**
     * Cast an IBinder object into an com.zzh.goodhub.mcp.IMcpCallback interface,
     * generating a proxy if needed.
     */
    public static com.zzh.goodhub.mcp.IMcpCallback asInterface(android.os.IBinder obj)
    {
      if ((obj==null)) {
        return null;
      }
      android.os.IInterface iin = obj.queryLocalInterface(DESCRIPTOR);
      if (((iin!=null)&&(iin instanceof com.zzh.goodhub.mcp.IMcpCallback))) {
        return ((com.zzh.goodhub.mcp.IMcpCallback)iin);
      }
      return new com.zzh.goodhub.mcp.IMcpCallback.Stub.Proxy(obj);
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
        case TRANSACTION_onEvent:
        {
          java.lang.String _arg0;
          _arg0 = data.readString();
          this.onEvent(_arg0);
          break;
        }
        default:
        {
          return super.onTransact(code, data, reply, flags);
        }
      }
      return true;
    }
    private static class Proxy implements com.zzh.goodhub.mcp.IMcpCallback
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
      // 插件主动推给 GoodHub 的事件，内容为单条 JSON-RPC 消息字符串：
      //  - 通知帧：notifications/progress
      //  - 反向请求帧：server→client request（带 method + id，如 sampling/createMessage）
      // oneway：投递不阻塞插件；GoodHub 侧经 EventChannel 桥回 Dart。
      @Override public void onEvent(java.lang.String jsonRpcMessage) throws android.os.RemoteException
      {
        android.os.Parcel _data = android.os.Parcel.obtain();
        try {
          _data.writeInterfaceToken(DESCRIPTOR);
          _data.writeString(jsonRpcMessage);
          boolean _status = mRemote.transact(Stub.TRANSACTION_onEvent, _data, null, android.os.IBinder.FLAG_ONEWAY);
        }
        finally {
          _data.recycle();
        }
      }
    }
    static final int TRANSACTION_onEvent = (android.os.IBinder.FIRST_CALL_TRANSACTION + 0);
  }
  /** @hide */
  public static final java.lang.String DESCRIPTOR = "com.zzh.goodhub.mcp.IMcpCallback";
  // 插件主动推给 GoodHub 的事件，内容为单条 JSON-RPC 消息字符串：
  //  - 通知帧：notifications/progress
  //  - 反向请求帧：server→client request（带 method + id，如 sampling/createMessage）
  // oneway：投递不阻塞插件；GoodHub 侧经 EventChannel 桥回 Dart。
  public void onEvent(java.lang.String jsonRpcMessage) throws android.os.RemoteException;
}
