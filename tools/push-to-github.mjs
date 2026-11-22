#!/usr/bin/env node
/**
 * tools/push-to-github.mjs
 *
 * 不依赖 git 二进制：用 GitHub Git Data API 直接建 commit 并更新分支。
 * 适用于本机没有安装 git 的环境。
 *
 * 用法：
 *   GITHUB_TOKEN=ghp_xxx node tools/push-to-github.mjs \
 *     --dir . --owner hf805864818 --repo Pet --branch main \
 *     [--message "commit message"] [--create-private false]
 *
 * 说明：
 *   - token 需要 repo 权限（classic: repo；fine-grained: Contents=Read/Write, Workflows=Read/Write）
 *   - 首次运行若仓库不存在，会创建；分支不存在则创建初始提交
 *   - 每次推送都是「整树替换」：本地删掉的文件也会从远端删除
 */

import fs from "node:fs";
import path from "node:path";
import https from "node:https";

const args = process.argv.slice(2);
function arg(name, def = null) {
  const i = args.indexOf("--" + name);
  if (i === -1) return def;
  const v = args[i + 1];
  return v === undefined || v.startsWith("--") ? true : v;
}

const TOKEN = process.env.GITHUB_TOKEN || process.env.GH_TOKEN || arg("token");
if (!TOKEN) {
  console.error("缺少 GITHUB_TOKEN 环境变量（或 --token）");
  process.exit(2);
}

const OWNER = arg("owner", "hf805864818");
const REPO = arg("repo", "Pet");
const BRANCH = arg("branch", "main");
const DIR = path.resolve(arg("dir", "."));
const MESSAGE = arg("message", "PetDFY: 素材导入修复 + CI 自动打包");
const CREATE_PRIVATE = String(arg("create-private", "false")) === "true";

const API = "api.github.com";

function req(method, urlPath, body, { raw = false } = {}) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const r = https.request(
      {
        host: API,
        path: urlPath,
        method,
        headers: {
          "User-Agent": "petdfy-push",
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${TOKEN}`,
          "X-GitHub-Api-Version": "2022-11-28",
          ...(payload ? { "Content-Type": "application/json", "Content-Length": payload.length } : {}),
        },
        timeout: 60000,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let json = null;
          try { json = text ? JSON.parse(text) : null; } catch { /* non-json */ }
          if (res.statusCode >= 200 && res.statusCode < 300) resolve({ status: res.statusCode, json, text });
          else {
            const err = new Error(`${method} ${urlPath} -> ${res.statusCode}: ${text.slice(0, 500)}`);
            err.status = res.statusCode;
            err.body = json;
            reject(err);
          }
        });
      }
    );
    r.on("timeout", () => r.destroy(new Error("request timeout")));
    r.on("error", reject);
    if (payload) r.write(payload);
    r.end();
  });
}

async function withRetry(fn, label, tries = 4) {
  let lastErr;
  for (let i = 1; i <= tries; i++) {
    try { return await fn(); } catch (e) {
      lastErr = e;
      const transient = !e.status || e.status >= 500 || e.status === 429;
      if (!transient || i === tries) break;
      const wait = 800 * i;
      console.error(`  retry ${i}/${tries - 1} ${label}: ${e.message.slice(0, 120)} (wait ${wait}ms)`);
      await new Promise((r) => setTimeout(r, wait));
    }
  }
  throw lastErr;
}

const SKIP_DIRS = new Set([".git", ".theos", "packages", "build", "layout", "node_modules", "__pycache__"]);
const SKIP_FILES = new Set([".DS_Store", "build.log"]);

function walk(root) {
  const out = [];
  (function rec(dir) {
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      if (ent.isDirectory()) {
        if (SKIP_DIRS.has(ent.name)) continue;
        rec(path.join(dir, ent.name));
      } else {
        if (SKIP_FILES.has(ent.name)) continue;
        const abs = path.join(dir, ent.name);
        out.push(path.relative(root, abs).split(path.sep).join("/"));
      }
    }
  })(root);
  return out.sort();
}

(async () => {
  console.log(`owner=${OWNER} repo=${REPO} branch=${BRANCH} dir=${DIR}`);

  // 1) 仓库存在性
  let repoExists = true;
  try {
    await withRetry(() => req("GET", `/repos/${OWNER}/${REPO}`), "get repo");
    console.log("仓库已存在");
  } catch (e) {
    if (e.status === 404) {
      repoExists = false;
    } else if (e.status === 401) {
      console.error("token 无效或已过期（401）");
      process.exit(3);
    } else {
      throw e;
    }
  }
  if (!repoExists) {
    const me = await withRetry(() => req("GET", `/user`), "get user");
    const login = me.json.login;
    if (login.toLowerCase() !== OWNER.toLowerCase()) {
      console.error(`token 属于 ${login}，但目标 owner 是 ${OWNER}；请用该账号的 token 或改 --owner`);
      process.exit(4);
    }
    console.log("仓库不存在，创建中…");
    await withRetry(
      () => req("POST", `/user/repos`, {
        name: REPO,
        private: CREATE_PRIVATE,
        auto_init: false,
        description: "PetDFY 大肥鱼〇V〇 桌面宠物（素材导入修复版）",
      }),
      "create repo"
    );
    console.log("仓库已创建");
  }

  // 2) 当前分支 head（可能不存在）
  let headSha = null;
  let baseTree = null;
  try {
    const ref = await withRetry(() => req("GET", `/repos/${OWNER}/${REPO}/git/ref/heads/${BRANCH}`), "get ref");
    headSha = ref.json.object.sha;
    const commit = await withRetry(() => req("GET", `/repos/${OWNER}/${REPO}/git/commits/${headSha}`), "get commit");
    baseTree = commit.json.tree.sha;
    console.log(`分支 ${BRANCH} 现有 head=${headSha.slice(0, 12)}`);
  } catch (e) {
    if (e.status !== 404 && e.status !== 409) throw e;
    console.log(`分支 ${BRANCH} 不存在，将创建`);
  }

  // 3) 上传 blob
  const files = walk(DIR);
  console.log(`准备上传 ${files.length} 个文件…`);
  const treeEntries = [];
  let done = 0;
  const CONCURRENCY = 6;

  async function uploadOne(rel) {
    const abs = path.join(DIR, rel);
    const buf = fs.readFileSync(abs);
    const res = await withRetry(
      () => req("POST", `/repos/${OWNER}/${REPO}/git/blobs`, {
        content: buf.toString("base64"),
        encoding: "base64",
      }),
      `blob ${rel}`
    );
    treeEntries.push({
      path: rel,
      mode: "100755",
      type: "blob",
      sha: res.json.sha,
    });
    done++;
    if (done % 25 === 0 || done === files.length) console.log(`  blob ${done}/${files.length}`);
  }

  const queue = [...files];
  await Promise.all(
    Array.from({ length: CONCURRENCY }, async () => {
      while (queue.length) {
        const rel = queue.shift();
        await uploadOne(rel);
      }
    })
  );

  // 4) 建 tree（不用 base_tree：整树替换，删除本地已删文件）
  const tree = await withRetry(
    () => req("POST", `/repos/${OWNER}/${REPO}/git/trees`, { tree: treeEntries }),
    "create tree"
  );
  console.log(`tree=${tree.json.sha}`);

  // 5) 建 commit
  const parent = headSha ? [headSha] : [];
  const commit = await withRetry(
    () => req("POST", `/repos/${OWNER}/${REPO}/git/commits`, {
      message: MESSAGE,
      tree: tree.json.sha,
      parents: parent,
    }),
    "create commit"
  );
  console.log(`commit=${commit.json.sha}`);

  // 6) 更新 / 创建分支
  if (headSha) {
    await withRetry(
      () => req("PATCH", `/repos/${OWNER}/${REPO}/git/refs/heads/${BRANCH}`, {
        sha: commit.json.sha,
        force: true,
      }),
      "update ref"
    );
  } else {
    await withRetry(
      () => req("POST", `/repos/${OWNER}/${REPO}/git/refs`, {
        ref: `refs/heads/${BRANCH}`,
        sha: commit.json.sha,
      }),
      "create ref"
    );
  }

  const url = `https://github.com/${OWNER}/${REPO}/commit/${commit.json.sha}`;
  console.log("\n推送完成");
  console.log("commit:", commit.json.sha);
  console.log("url   :", url);
  console.log("compare:", `https://github.com/${OWNER}/${REPO}/tree/${BRANCH}`);
})().catch((e) => {
  console.error("\n推送失败:", e.message);
  process.exit(1);
});
