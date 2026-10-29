// ADR 0051 §9：汇总两库迁移报告（api-report.json + cloud-report.json），打印到日志并写 SUMMARY.txt。
// 只读运行目录里的报告，不连库、不发请求。用法：node summary.mjs <runDir> <cloudExitCode>
import fs from 'node:fs';

const [runDir, cloudExit = '?'] = process.argv.slice(2);
const read = (name) => {
  try { return JSON.parse(fs.readFileSync(`${runDir}/${name}`, 'utf8')); } catch { return null; }
};
const api = read('api-report.json');
const cloud = read('cloud-report.json');
const len = (v) => (Array.isArray(v) ? v.length : v && typeof v === 'object' ? Object.values(v).flat().length : 0);

const lines = [`ADR 0051 resolver migration summary — ${runDir}`];
if (api) {
  const t = api.triage ?? {};
  const last = api.rounds?.at(-1) ?? {};
  lines.push(
    `aster-api policy_versions: rounds=${api.rounds?.length ?? 0} succeeded=${api.totals?.succeeded ?? '?'} ` +
      `remainingFailed=${last.failed ?? '?'} (E8xx=${len(t.e8xx)} integrityMismatch=${len(t.integrityMismatch)} infrastructure=${len(t.infrastructure)} other=${len(t.other)})`,
  );
} else lines.push('aster-api: no report');
if (cloud) {
  const t = cloud.triage ?? {};
  lines.push(
    `aster-cloud "PolicyVersion": processed=${cloud.processed} succeeded=${cloud.succeeded} failed=${cloud.failed} exit=${cloudExit}`,
    `  triage: e8xx=${len(t.e8xx)} invalidConstructForm=${len(t.invalidConstructForm)} untypedFieldAccess=${len(t.untypedFieldAccess)} ` +
      `vocabularyScopeByUser=${len(t.vocabularyScopeByUser)} integrityMismatch=${len(t.integrityMismatch)} ` +
      `otherCompile=${len(t.otherCompile)} infrastructure=${len(t.infrastructure)}`,
  );
} else lines.push(`aster-cloud: no report (exit=${cloudExit})`);
lines.push('Full reports: api-report.json, cloud-report.json (runbook: aster-api docs/runbooks/adr0051-rollout.md)');

const text = `${lines.join('\n')}\n`;
fs.writeFileSync(`${runDir}/SUMMARY.txt`, text);
process.stdout.write(text);
