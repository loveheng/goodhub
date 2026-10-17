#!/usr/bin/env node
// upload-r2.mjs — 零依赖 上传/删除 R2 对象（AWS SigV4，region=auto）
// 用法:
//   上传: node scripts/upload-r2.mjs put <localFile> <remoteKey> [contentType]
//         （兼容旧式: node scripts/upload-r2.mjs <localFile> <remoteKey> [contentType]）
//   删除: node scripts/upload-r2.mjs delete <remoteKey>
// 凭证/桶从环境变量读取: R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
// 同款移植自 goodshare scripts/upload-r2.mjs（self-update epic，2026-10-14）
import { readFileSync } from 'node:fs';
import { createHash, createHmac } from 'node:crypto';
import { setDefaultResultOrder } from 'node:dns';
// 沙箱 egress 对 Cloudflare R2 双栈/双 IPv4 偶发连接超时；强制 IPv4 优先避免 IPv6 死路。
setDefaultResultOrder('ipv4first');

const argv = process.argv.slice(2);
let mode;
let localPath, remoteKey, contentType;
if (argv[0] === 'delete') {
  mode = 'delete';
  remoteKey = argv[1];
  if (!remoteKey) {
    console.error('用法: node scripts/upload-r2.mjs delete <remoteKey>');
    process.exit(2);
  }
} else {
  mode = 'put';
  localPath = argv[0];
  remoteKey = argv[1];
  contentType = argv[2] || 'application/octet-stream';
  if (!localPath || !remoteKey) {
    console.error('用法: node scripts/upload-r2.mjs <localFile> <remoteKey> [contentType]');
    process.exit(2);
  }
}

const accountId = process.env.R2_ACCOUNT_ID;
const ak = process.env.R2_ACCESS_KEY_ID;
const sk = process.env.R2_SECRET_ACCESS_KEY;
const bucket = process.env.R2_BUCKET;
if (!accountId || !ak || !sk || !bucket) {
  console.error('FAIL: 缺少 R2 环境变量（R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_BUCKET）');
  process.exit(1);
}

const host = `${accountId}.r2.cloudflarestorage.com`;
const url = `https://${host}/${bucket}/${remoteKey}`;
const region = 'auto';
const service = 's3';
const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
const dateStamp = amzDate.slice(0, 8);
// 大文件用 UNSIGNED-PAYLOAD，避免整段计算哈希（R2 支持）
const payloadHash = 'UNSIGNED-PAYLOAD';
const httpMethod = mode === 'delete' ? 'DELETE' : 'PUT';

function hmac(key, data) {
  return createHmac('sha256', key).update(data).digest();
}
function sha256hex(s) {
  return createHash('sha256').update(s).digest('hex');
}

const canonicalHeaders = `host:${host}\nx-amz-content-sha256:${payloadHash}\nx-amz-date:${amzDate}\n`;
const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';
const canonicalRequest =
  `${httpMethod}\n/${bucket}/${remoteKey}\n\n${canonicalHeaders}\n${signedHeaders}\n${payloadHash}`;
const algorithm = 'AWS4-HMAC-SHA256';
const credentialScope = `${dateStamp}/${region}/${service}/aws4_request`;
const stringToSign = `${algorithm}\n${amzDate}\n${credentialScope}\n${sha256hex(canonicalRequest)}`;
const signingKey = hmac(hmac(hmac(hmac(`AWS4${sk}`, dateStamp), region), service), 'aws4_request');
const signature = createHmac('sha256', signingKey).update(stringToSign).digest('hex');
const authorization =
  `${algorithm} Credential=${ak}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

// 沙箱 egress 到 R2 偶发 ETIMEDOUT（curl 验证双 IPv4 实际可达，属瞬时抖动）；
// 加重试 + 每次 30s 超时兜底，避免单次连接超时即失败。
async function requestWithRetry(targetUrl, init, attempts = 6) {
  let lastErr;
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 30000);
    try {
      const r = await fetch(targetUrl, { ...init, signal: ctrl.signal });
      clearTimeout(timer);
      return r;
    } catch (e) {
      clearTimeout(timer);
      lastErr = e;
      console.error(`  (重试 ${attempt}/${attempts}) 连接失败: ${e.cause?.code || e.message}`);
      if (attempt < attempts) await new Promise((res) => setTimeout(res, 1500));
    }
  }
  throw lastErr;
}

if (mode === 'delete') {
  const res = await requestWithRetry(url, {
    method: 'DELETE',
    headers: {
      Authorization: authorization,
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
    },
  });
  // 204 删除成功；404 已不存在（幂等，视为成功）
  if (res.status === 204 || res.status === 404) {
    console.log(`OK: 删除 s3://${bucket}/${remoteKey}${res.status === 404 ? '（已不存在）' : ''}`);
  } else {
    const txt = await res.text();
    console.error(`FAIL: 删除失败 HTTP ${res.status}: ${txt}`);
    process.exit(1);
  }
} else {
  const body = readFileSync(localPath);
  const res = await requestWithRetry(url, {
    method: 'PUT',
    headers: {
      Authorization: authorization,
      'x-amz-date': amzDate,
      'x-amz-content-sha256': payloadHash,
      'Content-Type': contentType,
    },
    body,
  });
  if (!res.ok) {
    const txt = await res.text();
    console.error(`FAIL: 上传失败 HTTP ${res.status}: ${txt}`);
    process.exit(1);
  }
  console.log(`OK: 上传 ${localPath} → s3://${bucket}/${remoteKey}`);
}
