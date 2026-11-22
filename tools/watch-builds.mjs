#!/usr/bin/env node
/**
 * tools/watch-builds.mjs
 *
 * 轮询 GitHub Actions 构建状态，失败时打印到具体 step，并可下载日志。
 *
 * 用法：
 *   GITHUB_TOKEN=xxx node tools/watch-builds.mjs --owner hf805864818 --repo Pet --branch main \
 *     [--timeout 1800] [--logs outdir]
 */

import https from "node:https";
import fs from "node:fs";
import path from "node:path";

const args = process.argv.slice(2);
const arg = (n, d = null) => {
  const i = args.indexOf("--" + n);
  if (i === -1) return d;
  const v = args[i + 1];
  return v === undefined || v.startsWith("--") ? true : v;
};

const TOKEN = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
const OWNER = arg("owner", "hf805864818");
const REPO = arg("repo", "Pet");
const BRANCH = arg("branch", "main");
const TIMEOUT = Number(arg("timeout", "1800"));
const LOGDIR = arg("logs", "");

if (!TOKEN) { console.error("缺少 GITHUB_TOKEN"); process.exit(2); }

function req(method, p, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? Buffer.from(JSON.stringify(body)) : null;
    const r = https.request({
      host: "api.github.com", path: p, method,
      headers: {
        "User-Agent": "petdfy-watch",
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${TOKEN}`,
        "X-GitHub-Api-Version": "2022-11-28",
        ...(payload ? { "Content-Type": "application/json", "Content-Length": payload.length } : {}),
      },
      timeout: 60000,
    }, (res) => {
      const c = [];
      res.on("data", (d) => c.push(d));
      res.on("end", () => {
        const t = Buffer.concat(c).toString("utf8");
        let j = null;
        try { j = t ? JSON.parse(t) : null; } catch {}
        if (res.statusCode >= 200 && res.statusCode < 300) resolve({ status: res.statusCode, json: j, text: t, headers: res.headers });
        else { const e = new Error(`${method} ${p} -> ${res.statusCode}: ${t.slice(0, 400)}`); e.status = res.statusCode; reject(e); }
      });
    });
    r.on("timeout", () => r.destroy(new Error("timeout")));
    r.on("error", reject);
    if (payload) r.write(payload);
    r.end();
  });
}

function reqRaw(urlPath, outFile) {
  return new Promise((resolve, reject) => {
    const r = https.request({
      host: "api.github.com", path: urlPath, method: "GET",
      headers: {
        "User-Agent": "petdfy-watch",
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${TOKEN}`,
        "X-GitHub-Api-Version": "2022-11-28",
      },
      timeout: 120000,
    }, (res) => {
      if (res.statusCode === 302 && res.headers.location) {
        https.get(res.headers.location, (rr) => {
          const ws = fs.createWriteStream(outFile);
          rr.pipe(ws);
          ws.on("finish", () => resolve({ file: outFile }));
          ws.on("error", reject);
        }).on("error", reject);
        return;
      }
      const c = [];
      res.on("data", (d) => c.push(d));
      res.on("end", () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          fs.writeFileSync(outFile, Buffer.concat(c));
          resolve({ file: outFile });
        } else reject(new Error(`logs ${res.statusCode}`));
      });
    });
    r.on("error", reject);
    r.end();
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const started = Date.now();
  let lastKey = "";
  while (true) {
    let run = null;
    try {
      const res = await req("GET", `/repos/${OWNER}/${REPO}/actions/runs?branch=${BRANCH}&per_page=1`);
      run = res.json?.workflow_runs?.[0] || null;
    } catch (e) {
      console.log("查询 runs 失败:", e.message.slice(0, 160));
    }

    if (!run) {
      console.log("暂无 workflow run（可能 workflow 尚未注册或刚推送）");
    } else {
      const key = `${run.id}:${run.status}:${run.conclusion}`;
      if (key !== lastKey) {
        lastKey = key;
        const mins = ((Date.now() - started) / 60000).toFixed(1);
        console.log(`[${mins}m] run=${run.id} status=${run.status} conclusion=${run.conclusion} head=${String(run.head_sha).slice(0, 8)}`);
        console.log(`        ${run.html_url}`);
      }

      if (run.status === "completed") {
        console.log(`\n结论: ${run.conclusion}`);
        let jobs = [];
        try {
          const jr = await req("GET", `/repos/${OWNER}/${REPO}/actions/runs/${run.id}/jobs`);
          jobs = jr.json?.jobs || [];
        } catch (e) { console.log("取 jobs 失败:", e.message.slice(0, 160)); }

        for (const j of jobs) {
          console.log(`\njob: ${j.name} -> ${j.status}/${j.conclusion}`);
          for (const s of j.steps || []) {
            console.log(`   ${s.number}. ${s.conclusion || s.status}: ${s.name}`);
          }
        }

        if (run.conclusion !== "success" && LOGDIR) {
          fs.mkdirSync(LOGDIR, { recursive: true });
          const out = path.join(LOGDIR, `run-${run.id}.zip`);
          try {
            await reqRaw(`/repos/${OWNER}/${REPO}/actions/runs/${run.id}/logs`, out);
            console.log(`\n日志已保存: ${out}`);
          } catch (e) { console.log("下载日志失败:", e.message.slice(0, 160)); }
        }
        process.exit(run.conclusion === "success" ? 0 : 1);
      }
    }

    if ((Date.now() - started) / 1000 > TIMEOUT) {
      console.log(`超时 ${TIMEOUT}s，run 仍在 ${run ? run.status : "unknown"}`);
      process.exit(1);
    }
    await sleep(15000);
  }
})().catch((e) => { console.error("watch 失败:", e.message); process.exit(1); });
