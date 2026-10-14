#!/usr/bin/env node
// upload-r2.mjs — 零依赖上传单个文件到 Cloudflare R2（AWS SigV4，region=auto）
// 用法: node scripts/upload-r2.mjs <localFile> <remoteKey> [contentType]
// 凭证/桶从环境变量读取: R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
// 同款移植自 goodshare scripts/upload-r2.mjs（self-update epic，2026-10-14）
import { readFileSync } from 'node:fs';
import { createHash, createHmac } from 'node:crypto';

const [, , localPath, remoteKey, contentType = 'application/octet-stream'] = process.argv;
if (!localPath || !remoteKey) {
  console.error('用法: node scripts/upload-r2.mjs <localFile> <remoteKey> [contentType]');
  process.exit(2);
}
const accountId = process.env.R2_ACCOUNT_ID;
const ak = process.env.R2_ACCESS_KEY_ID;
const sk = process.env.R2_SECRET_ACCESS_KEY;
const bucket = process.env.R2_BUCKET;
if (!accountId || !ak || !sk || !bucket) {
  console.error('FAIL: 缺少 R2 环境变量（R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_BUCKET）');
  process.exit(1);
}

const body = readFileSync(localPath);
const host = `${accountId}.r2.cloudflarestorage.com`;
const url = `https://${host}/${bucket}/${remoteKey}`;
const region = 'auto';
const service = 's3';
const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
const dateStamp = amzDate.slice(0, 8);
// 大文件用 UNSIGNED-PAYLOAD，避免整段计算哈希（R2 支持）
const payloadHash = 'UNSIGNED-PAYLOAD';

function hmac(key, data) {
  return createHmac('sha256', key).update(data).digest();
}
function sha256hex(s) {
  return createHash('sha256').update(s).digest('hex');
}

const canonicalHeaders = `host:${host}\nx-amz-content-sha256:${payloadHash}\nx-amz-date:${amzDate}\n`;
const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';
const canonicalRequest =
  `PUT\n/${bucket}/${remoteKey}\n\n${canonicalHeaders}\n${signedHeaders}\n${payloadHash}`;
const algorithm = 'AWS4-HMAC-SHA256';
const credentialScope = `${dateStamp}/${region}/${service}/aws4_request`;
const stringToSign = `${algorithm}\n${amzDate}\n${credentialScope}\n${sha256hex(canonicalRequest)}`;
const signingKey = hmac(hmac(hmac(hmac(`AWS4${sk}`, dateStamp), region), service), 'aws4_request');
const signature = createHmac('sha256', signingKey).update(stringToSign).digest('hex');
const authorization =
  `${algorithm} Credential=${ak}/${credentialScope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;

const res = await fetch(url, {
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
