// ADR 0051 §9：调用 aster-api 管理端点重编译 policy_versions（resolver 迁移）。
//
// 签名沿用 aster-cloud signByokAllowlistHeaders / aster-api AdminHmacVerifier 的 admin 口径：
//   canonical = method\npath\nts\nnonce\ncontentType\ncontentLength\nbodySha256
// 本请求无 body，contentType / bodySha256 为空、长度 0；query（batchSize）不进签名。
// 密钥 = aster-api 的 aster.plan-gate.hmac-key（secret aster-api-plan-gate-credentials/hmac-key）。
//
// 端点同步执行到全部待迁移行处理完才返回，且幂等（成功行跳过、失败行重试）。
// 因此按轮次调用：processed == 0（全部完成）或 succeeded == 0（剩下的都是设计内失败 /
// 完整性不一致 / 基础设施故障，再跑也不会前进）即停，最多 MAX_ROUNDS 轮。
//
// 只用 node 内置模块（在 aster-resolver-migration 镜像里运行，无额外依赖）。用 node:http 而不是
// fetch：undici 默认 5 分钟 headersTimeout，大批量时同步端点可能超过。
// 退出码：0 = 已拿到报告（含需人工处理的行时只写入报告的 needsAttention，不在这里失败，
// 以免挡住同一 Pod 里的 cloud 迁移；Job 的最终退出码由 summary.mjs 汇总决定）；
// 1 = HTTP/传输错误；2 = 配置缺失。
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import https from 'node:https';

const PATH = '/api/v1/admin/resolver-migration/run';
const INTEGRITY_MISMATCH = 'pre-migration integrity mismatch';

const base = process.env.ASTER_POLICY_API_INTERNAL_URL?.trim();
const key = process.env.ASTER_PLAN_GATE_HMAC_KEY?.trim();
const batchSize = Number(process.env.BATCH_SIZE ?? '50');
const maxRounds = Number(process.env.MAX_ROUNDS ?? '5');
const timeoutMs = Number(process.env.REQUEST_TIMEOUT_MS ?? '3600000');

function fail(code, message) {
  console.error(`[api-migration] ${message}`);
  process.exit(code);
}

if (!base || !key) fail(2, 'refusing to run: ASTER_POLICY_API_INTERNAL_URL / ASTER_PLAN_GATE_HMAC_KEY missing');
if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > 500) fail(2, 'BATCH_SIZE must be 1..500');
const runDir = fs.readFileSync('/work/run-dir', 'utf8').trim();

function signedHeaders() {
  const ts = Math.floor(Date.now() / 1000).toString();
  const nonce = crypto.randomBytes(16).toString('hex');
  const canonical = `POST\n${PATH}\n${ts}\n${nonce}\n\n0\n`;
  const signature = crypto.createHmac('sha256', key).update(canonical, 'utf8').digest('hex');
  return { 'X-Aster-Timestamp': ts, 'X-Aster-Nonce': nonce, 'X-Internal-Signature': signature };
}

function runOnce() {
  const url = new URL(`${PATH}?batchSize=${batchSize}`, base);
  const client = url.protocol === 'https:' ? https : http;
  return new Promise((resolve, reject) => {
    const req = client.request(
      url,
      { method: 'POST', headers: { ...signedHeaders(), 'Content-Length': '0', Accept: 'application/json' }, timeout: timeoutMs },
      (res) => {
        let body = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => { body += chunk; });
        res.on('end', () => {
          if (res.statusCode !== 200) return reject(new Error(`HTTP ${res.statusCode}: ${body.slice(0, 2000)}`));
          try { resolve(JSON.parse(body)); } catch (e) { reject(new Error(`invalid JSON: ${e.message}`)); }
        });
      },
    );
    req.on('timeout', () => req.destroy(new Error(`timeout after ${timeoutMs}ms`)));
    req.on('error', reject);
    req.end();
  });
}

// 端点响应的 failures 只有 { id, error }，没有「是否已归档」的结构化字段，只能按 aster-api
// ResolverMigrationService 写出的错误文本区分。保持待迁移（未归档、带错误）的失败有三类：
//   1. 行级异常（数据库错误等）：`<异常类名>: <消息>`（#migrate 的 catch）；
//   2. 不带源码诊断的编译失败（dbc3761 起不归档）：PolicyCompiler 的 `CNL 编译失败: <消息>`，
//      以及空源码的 `CNL 源代码不能为空`；
//   3. 前置完整性不一致：`pre-migration integrity mismatch`（单独成组）。
// 这些行都需要修复或人工处置，Job 最终以退出码 1 结束；其余失败（带源码诊断）已被归档，属设计内结果。
const INFRA_ERROR = /^(\w+(Exception|Error): |CNL 编译失败: |CNL 源代码不能为空$)/;

function classify(failures) {
  const groups = { integrityMismatch: [], infrastructure: [], e8xx: [], other: [] };
  for (const f of failures) {
    const error = f.error ?? '';
    if (error === INTEGRITY_MISMATCH) groups.integrityMismatch.push(f);
    else if (INFRA_ERROR.test(error)) groups.infrastructure.push(f);
    else if (/\bE8\d\d\b/.test(error)) groups.e8xx.push(f);
    else groups.other.push(f);
  }
  return groups;
}

const rounds = [];
try {
  for (let round = 1; round <= maxRounds; round += 1) {
    const report = await runOnce();
    rounds.push(report);
    console.error(`[api-migration] round ${round}: processed=${report.processed} succeeded=${report.succeeded} failed=${report.failed}`);
    if (report.processed === 0 || report.succeeded === 0) break;
  }
} catch (err) {
  fs.writeFileSync(`${runDir}/api-report.json`, `${JSON.stringify({ rounds, error: String(err) }, null, 2)}\n`);
  fail(1, `FAILED: ${err.message}`);
}

const last = rounds.at(-1);
const summary = {
  rounds,
  totals: {
    succeeded: rounds.reduce((n, r) => n + r.succeeded, 0),
    remainingFailed: last.failed,
  },
  triage: classify(last.failures ?? []),
};
// 未归档、保持待迁移的行 = 基础设施/非源码失败 + 完整性不一致。
summary.needsAttention = summary.triage.infrastructure.length + summary.triage.integrityMismatch.length;
fs.writeFileSync(`${runDir}/api-report.json`, `${JSON.stringify(summary, null, 2)}\n`);
console.log(JSON.stringify(summary, null, 2));
if (summary.needsAttention > 0) {
  console.error(`[api-migration] ${summary.needsAttention} row(s) left pending (not archived): manual triage / fix and re-run; Job will exit 1`);
}
