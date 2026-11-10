// CacaoTuneLibrary Windows 版の画面。yt-dlp の起動・ファイル操作は Rust 側（src-tauri/src/lib.rs）に頼む。
// 考え方は Mac 版（../CacaoTuneLibrary/*.swift）と同じ。yt-dlp に渡す引数も同じ。
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { sep } from "@tauri-apps/api/path";
import { open as openDialog, ask, message } from "@tauri-apps/plugin-dialog";
import { openPath } from "@tauri-apps/plugin-opener";
import { readText } from "@tauri-apps/plugin-clipboard-manager";

// ---------------------------------------------------------------- 設定
type CoverMode = "pad" | "crop" | "none";
type Format = "m4a" | "mp3";
interface Settings {
  folder: string;
  format: Format;
  coverMode: CoverMode;
  keepThumbnail: boolean;
  wholePlaylist: boolean;
  idInFilename: boolean;
  channelFolders: boolean;
  ytdlpPath: string;
  ffmpegPath: string;
}
const DEFAULTS: Settings = {
  folder: "", format: "m4a", coverMode: "pad", keepThumbnail: false, wholePlaylist: false,
  idInFilename: false, channelFolders: true, ytdlpPath: "", ffmpegPath: "",
};
let settings: Settings = loadSettings();
function loadSettings(): Settings {
  try { return { ...DEFAULTS, ...JSON.parse(localStorage.getItem("settings") ?? "{}") }; } catch { return { ...DEFAULTS }; }
}
function saveSettings() { localStorage.setItem("settings", JSON.stringify(settings)); }

const SEP = sep();
function dirname(p: string): string { const i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\")); return i < 0 ? "" : p.slice(0, i); }
function basename(p: string): string { const i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\")); return p.slice(i + 1); }
function abbreviate(p: string): string { return p.length > 48 ? "…" + p.slice(-46) : p; }
function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));
}

// ---------------------------------------------------------------- 道具
interface ToolStatus { ytdlp: string | null; ffmpeg: string | null; deno: string | null; version: string | null; tools_dir: string; can_install: boolean }
let tools: ToolStatus = { ytdlp: null, ffmpeg: null, deno: null, version: null, tools_dir: "", can_install: false };
let installing = false;
let installMessage = "";

async function refreshTools() {
  tools = await invoke<ToolStatus>("tool_status", { ytdlpPath: settings.ytdlpPath, ffmpegPath: settings.ffmpegPath });
  renderFooter();
  renderToolDetail();
  pump();
}
const toolsReady = () => !!tools.ytdlp && !!tools.ffmpeg;

async function installTools() {
  if (installing) return;
  installing = true;
  installMessage = "準備を始めます…";
  renderFooter();
  try {
    tools = await invoke<ToolStatus>("install_tools");
    installMessage = "";
    await message("yt-dlp・ffmpeg・deno を用意しました。", { title: "CacaoTuneLibrary" });
  } catch (e) {
    installMessage = "";
    await message(String(e), { title: "用意できませんでした", kind: "error" });
  } finally {
    installing = false;
    renderFooter();
    renderToolDetail();
    pump();
  }
}

// ---------------------------------------------------------------- ジョブ
type JobState =
  | { kind: "waiting" }
  | { kind: "running"; phase: string }
  | { kind: "done" }
  | { kind: "failed"; msg: string }
  | { kind: "cancelled" };

class Job {
  id = crypto.randomUUID();
  title?: string;
  uploader?: string;
  playlistTitle?: string;
  itemIndex?: number;
  itemCount?: number;
  state: JobState = { kind: "waiting" };
  progress = 0;
  files: string[] = [];
  thumb?: string;
  log: string[] = [];
  errorCount = 0;
  lastError?: string;
  constructor(public url: string) {}
  get isActive() { return this.state.kind === "waiting" || this.state.kind === "running"; }
  get displayTitle() { return this.playlistTitle ?? this.title ?? this.url; }
  get itemText() { return this.itemIndex && this.itemCount && this.itemCount > 1 ? `${this.itemIndex}/${this.itemCount} 曲目` : null; }
  get statusText(): string {
    switch (this.state.kind) {
      case "waiting": return "待機中";
      case "running": return this.itemText ? `${this.itemText}　${this.state.phase}` : this.state.phase;
      case "done":
        if (this.errorCount > 0) return `完了（${this.files.length} 曲、${this.errorCount} 曲は保存できず）`;
        return this.files.length > 1 ? `完了（${this.files.length} 曲）` : "完了";
      case "failed": return `失敗: ${this.state.msg}`;
      case "cancelled": return "中止";
    }
  }
}

const jobs: Job[] = [];
let current: Job | null = null;

function extractURLs(text: string): string[] {
  const out: string[] = [];
  for (let raw of text.split(/\s+/)) {
    if (!raw) continue;
    if (!raw.includes("://")) {
      if (/^(youtu\.be\/|(www\.|music\.)?youtube\.com\/)/.test(raw)) raw = "https://" + raw; else continue;
    }
    try { new URL(raw); } catch { continue; }
    if (!out.includes(raw)) out.push(raw);
  }
  return out;
}

function enqueue(url: string) {
  if (jobs.some((j) => j.url === url && j.isActive)) return;
  const job = new Job(url);
  jobs.unshift(job);   // 新しいものを上に
  renderJobs();
  prefetch(job);
  pump();
}
/// 入力欄の Enter。URL なら追加、URL でない文字なら YouTube を検索する
function addFromText() {
  const urls = extractURLs(urlInput.value);
  if (urls.length === 0) {
    const q = urlInput.value.trim();
    if (q) { urlInput.value = ""; updateAddButton(); openSearch(q); }
    return;
  }
  urlInput.value = "";
  updateAddButton();
  urls.forEach(enqueue);
}
async function addFromClipboard() {
  try {
    const t = await readText();
    const urls = extractURLs(t ?? "");
    if (urls.length === 0) { urlInput.focus(); return; }
    urls.forEach(enqueue);
  } catch {
    urlInput.focus();
  }
}

// ---------------------------------------------------------------- yt-dlp の引数（Mac 版 Downloader.arguments と同じ）
const SQUARE_CROP_PPA = `ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -vf crop="'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'"`;
const SQUARE_PAD_PPA = `ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -vf "split[o][b];[b]scale='max(iw,ih)':'max(iw,ih)',gblur=sigma=40,eq=brightness=-0.08[bg];[bg][o]overlay=(W-w)/2:(H-h)/2"`;

function downloadArgs(url: string): string[] {
  const a: string[] = [
    "--no-update", "--no-colors", "--encoding", "utf-8", "--newline", "--progress", "--no-simulate",
    "--print", "before_dl:TITLE\t%(title)s",
    "--print", "before_dl:UPLOADER\t%(uploader,channel)s",
    "--print", "before_dl:ITEM\t%(playlist_index|)s\t%(playlist_count|)s\t%(playlist_title|)s",
    "--print", "after_move:FILE\t%(filepath)s",
    "--no-write-playlist-metafiles",
    "-x", "--audio-format", settings.format,
    "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg",
    "--ffmpeg-location", dirname(tools.ffmpeg!),
    "-o", settings.folder + SEP
      + (settings.channelFolders ? `%(uploader,channel|その他)s${SEP}` : "")
      + (settings.idInFilename ? "%(title)s [%(id)s].%(ext)s" : "%(title)s.%(ext)s"),
  ];
  if (settings.keepThumbnail) a.push("--write-thumbnail");
  if (settings.format === "mp3") a.push("--audio-quality", "0");
  if (settings.coverMode === "pad") a.push("--ppa", SQUARE_PAD_PPA);
  if (settings.coverMode === "crop") a.push("--ppa", SQUARE_CROP_PPA);
  if (tools.deno) a.push("--js-runtimes", `deno:${tools.deno}`);
  a.push(settings.wholePlaylist ? "--yes-playlist" : "--no-playlist", "--", url);
  return a;
}

function humanize(msg: string): string {
  const m = msg.toLowerCase();
  if (m.includes("is not a valid url") || m.includes("unsupported url")) return "URL として読めません";
  if (m.includes("video unavailable") || m.includes("private video")) return "この動画は見られません（非公開・削除など）";
  if (m.includes("sign in")) return "ログインが必要な動画です";
  if (m.includes("ffmpeg") || m.includes("ffprobe")) return "ffmpeg が見つかりません（設定で用意してください）";
  if (m.includes("unable to download") || m.includes("network") || m.includes("resolve")) return "ネットワークにつながりません";
  if (m.includes("requested format is not available")) return "音声の形式が取り出せません（yt-dlp を更新すると直ることが多い）";
  if (m.includes("nsig") || m.includes("signature") || m.includes("player") || m.includes("javascript runtime")) return "YouTube 側が変わりました（yt-dlp を更新するか、deno を用意してください）";
  return msg.length > 120 ? msg.slice(0, 120) + "…" : msg;
}

/// 1 行を解釈してジョブに反映（Mac 版 Downloader.apply と同じ）
function applyLine(job: Job, t: string) {
  job.log.push(t);
  if (job.log.length > 400) job.log.splice(0, job.log.length - 400);
  let m: RegExpMatchArray | null;
  if (t.startsWith("TITLE\t")) {
    job.title = t.slice(6); job.progress = 0; job.state = { kind: "running", phase: "取得中" };
  } else if (t.startsWith("UPLOADER\t")) {
    const u = t.slice(9); job.uploader = u === "NA" || !u ? undefined : u;
  } else if (t.startsWith("ITEM\t")) {
    const p = t.slice(5).split("\t");
    job.itemIndex = parseInt(p[0]) || undefined; job.itemCount = parseInt(p[1]) || undefined;
    if (p[2]) job.playlistTitle = p[2];
  } else if (t.startsWith("FILE\t")) {
    job.files.push(t.slice(5)); job.progress = 1; job.state = { kind: "running", phase: "保存中" };
  } else if ((m = t.match(/^\[download\]\s+([\d.]+)%/))) {
    job.progress = Math.min(1, parseFloat(m[1]) / 100); job.state = { kind: "running", phase: "取得中" };
  } else if (t.startsWith("[download]") && t.includes("already been downloaded")) {
    job.progress = 1; job.state = { kind: "running", phase: "すでに保存済み" };
  } else if (t.startsWith("[ExtractAudio]")) {
    job.state = { kind: "running", phase: settings.format === "mp3" ? "mp3 に変換中" : "音声を取り出し中" };
  } else if (t.startsWith("[ThumbnailsConvertor]")) {
    job.state = { kind: "running", phase: "カバー画像を整え中" };
  } else if (t.startsWith("[EmbedThumbnail]")) {
    job.state = { kind: "running", phase: "カバーを埋め込み中" };
  } else if (t.startsWith("[Metadata]")) {
    job.state = { kind: "running", phase: "曲情報を書き込み中" };
  } else if (t.startsWith("ERROR:")) {
    job.errorCount += 1; job.lastError = humanize(t.slice(6).trim());
  }
}

async function pump() {
  if (current || !toolsReady()) return;
  const job = [...jobs].reverse().find((j) => j.state.kind === "waiting");   // 先に追加したものから
  if (!job) return;
  current = job;
  job.state = { kind: "running", phase: "準備中" };
  renderJobs();
  try {
    await invoke("ensure_dir", { path: settings.folder });
    await invoke("start_download", { jobId: job.id, exe: tools.ytdlp, args: downloadArgs(job.url), cwd: settings.folder });
  } catch (e) {
    job.state = { kind: "failed", msg: String(e) };
    current = null;
    renderJobs();
    pump();
  }
}

function finishJob(job: Job, code: number | null, error: string | null) {
  if (error === "中止" || job.state.kind === "cancelled") {
    job.state = { kind: "cancelled" };
  } else if (job.files.length === 0) {
    job.state = { kind: "failed", msg: job.lastError ?? (code === 0 ? "ファイルができませんでした" : `yt-dlp が終了コード ${code} で終わりました`) };
  } else {
    job.state = { kind: "done" };   // 一部が失敗していても、できた曲ぶんは完了
  }
  current = null;
  renderJobs();
  pump();
}

async function cancel(job: Job) {
  if (job === current) {
    job.state = { kind: "cancelled" };
    await invoke("cancel_download", { jobId: job.id });
  } else if (job.state.kind === "waiting") {
    job.state = { kind: "cancelled" };
    renderJobs();
  }
}
function retry(job: Job) {
  if (job.isActive) return;
  job.state = { kind: "waiting" }; job.progress = 0; job.files = []; job.log = []; job.errorCount = 0; job.lastError = undefined;
  renderJobs(); pump();
}
function remove(job: Job) {
  if (job.isActive) cancel(job);
  const i = jobs.indexOf(job);
  if (i >= 0) jobs.splice(i, 1);
  renderJobs();
}

/// 追加した直後に、題名・チャンネル名・サムネイルだけ先に取ってくる
async function prefetch(job: Job) {
  if (!tools.ytdlp) return;
  const args = [
    "--no-update", "--no-warnings", "--no-colors", "--encoding", "utf-8", "--flat-playlist", "--skip-download", "-I", "1",
    settings.wholePlaylist ? "--yes-playlist" : "--no-playlist",
    "--print", "%(playlist_title|)s\t%(title)s\t%(playlist_channel,playlist_uploader,channel,uploader|)s\t%(thumbnail|)s\t%(id|)s",
  ];
  if (tools.deno) args.push("--js-runtimes", `deno:${tools.deno}`);
  args.push("--", job.url);
  try {
    const r = await invoke<{ code: number | null; output: string }>("run_capture", { exe: tools.ytdlp, args, timeoutSec: 40 });
    if (r.code !== 0) return;
    const line = r.output.split(/\r?\n/).find((l) => l.includes("\t"));
    if (!line) return;
    const f = line.split("\t");
    if (f.length < 5) return;
    if (!jobs.includes(job)) return;
    if (job.playlistTitle == null && f[0]) job.playlistTitle = f[0];
    if (job.title == null) job.title = f[1];
    if (job.uploader == null && f[2] && f[2] !== "NA") job.uploader = f[2];
    if (!job.thumb) job.thumb = f[3] || (f[4] ? `https://i.ytimg.com/vi/${f[4]}/hqdefault.jpg` : undefined);
    renderJobs();
  } catch { /* 先読みは失敗しても困らない */ }
}

// ---------------------------------------------------------------- 画面（主）
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const urlInput = $<HTMLInputElement>("urlInput");
const btnAdd = $<HTMLButtonElement>("btnAdd");
const jobsEl = $("jobs");

function updateAddButton() {
  const t = urlInput.value.trim();
  const isSearch = t !== "" && extractURLs(t).length === 0;
  btnAdd.disabled = t === "" || !toolsReady();
  btnAdd.textContent = isSearch ? "🔍 検索" : "＋ 追加";
  btnAdd.title = isSearch ? "YouTube を検索して、結果から選んで追加" : "URL を一覧に追加";
}

// ---------------------------------------------------------------- YouTube を検索（yt-dlp の ytsearch。Mac 版 Search.swift と同じ）
interface SearchResult { id: string; title: string; channel: string | null; duration: number | null; viewCount: number | null }
let sResults: SearchResult[] = [];
let sQuery = "";
let sCount = 20;
let sGeneration = 0;
let sBusy = false;
const srURL = (r: SearchResult) => `https://www.youtube.com/watch?v=${r.id}`;
function fmtDuration(s: number) {
  const p = (n: number) => String(n).padStart(2, "0");
  return s >= 3600 ? `${Math.floor(s / 3600)}:${p(Math.floor((s % 3600) / 60))}:${p(s % 60)}` : `${Math.floor(s / 60)}:${p(s % 60)}`;
}
function fmtViews(v: number) {
  if (v >= 1e8) return `${(v / 1e8).toFixed(1)}億回`;
  if (v >= 1e4) return `${(v / 1e4).toFixed(1)}万回`;
  return `${v}回`;
}
function openSearch(q: string) {
  $("searchPanel").hidden = false;
  const input = $<HTMLInputElement>("sInput");
  input.value = q;
  input.focus();
  runSearch(q, false);
}
async function runSearch(q: string, more: boolean) {
  if (!tools.ytdlp) return;
  q = q.trim();
  if (!q) return;
  if (more) sCount += 20; else { sCount = 20; sResults = []; }
  sQuery = q;
  sBusy = true;
  const gen = ++sGeneration;
  sRender(null);
  const args = [
    "--no-update", "--no-warnings", "--no-colors", "--encoding", "utf-8", "--flat-playlist", "--skip-download",
    "--print", "%(id)s\t%(title)s\t%(channel,uploader|)s\t%(duration|)s\t%(view_count|)s",
  ];
  if (tools.deno) args.push("--js-runtimes", `deno:${tools.deno}`);
  args.push("--", `ytsearch${sCount}:${q}`);
  let error: string | null = null;
  try {
    const r = await invoke<{ code: number | null; output: string }>("run_capture", { exe: tools.ytdlp, args, timeoutSec: 60 });
    if (gen !== sGeneration) return;
    const found: SearchResult[] = [];
    for (const line of r.output.split(/\r?\n/)) {
      const f = line.split("\t");
      if (f.length < 5 || !f[0]) continue;
      found.push({
        id: f[0], title: f[1] || f[0], channel: f[2] && f[2] !== "NA" ? f[2] : null,
        duration: f[3] ? Number(f[3]) : null, viewCount: f[4] ? Number(f[4]) : null,
      });
    }
    if (found.length) sResults = found;
    else error = r.code === 0 ? "見つかりませんでした" : humanize(r.output.split(/\r?\n/).filter(Boolean).pop() ?? "検索できませんでした");
  } catch (e) {
    if (gen !== sGeneration) return;
    error = String(e);
  }
  sBusy = false;
  sRender(error);
}
function sRender(error: string | null) {
  const list = $("sList");
  $("sStatus").textContent = sBusy ? `「${sQuery}」を YouTube で検索しています…` : (sResults.length ? `${sResults.length} 件` : "");
  if (sBusy && sResults.length === 0) { list.innerHTML = `<div class="empty"><div>検索しています…</div></div>`; return; }
  if (error && sResults.length === 0) { list.innerHTML = `<div class="empty"><div class="big">🔍</div><div>${esc(error)}</div></div>`; return; }
  const rows = sResults.map((r) => {
    const sub = [r.channel, [r.duration != null ? fmtDuration(r.duration) : "", r.viewCount != null ? fmtViews(r.viewCount) : ""].filter(Boolean).join(" ・ ")].filter(Boolean).join(" ・ ");
    const queued = jobs.some((j) => j.url === srURL(r));
    return `<div class="sr" data-id="${esc(r.id)}">
      <img class="thumb wide" src="https://i.ytimg.com/vi/${esc(r.id)}/mqdefault.jpg" alt="" loading="lazy" />
      <div class="body"><div class="title">${esc(r.title)}</div><div class="sub">${esc(sub)}</div></div>
      ${queued ? `<span class="added">✓ 追加済み</span>` : `<button data-act="add" ${toolsReady() ? "" : "disabled"}>＋ 追加</button>`}
    </div>`;
  });
  rows.push(`<div class="more">${sBusy ? `<span class="note">検索しています…</span>` : `<button data-act="more">もっと見る</button>`}</div>`);
  list.innerHTML = rows.join("");
}
function bindSearch() {
  const input = $<HTMLInputElement>("sInput");
  input.addEventListener("keydown", (e) => { if (e.key === "Enter") runSearch(input.value, false); });
  $("sGo").addEventListener("click", () => runSearch(input.value, false));
  $("sClose").addEventListener("click", () => { $("searchPanel").hidden = true; });
  $("sList").addEventListener("click", (ev) => {
    const btn = (ev.target as HTMLElement).closest("button[data-act]") as HTMLButtonElement | null;
    if (!btn) return;
    if (btn.dataset.act === "more") { runSearch(sQuery, true); return; }
    const row = btn.closest(".sr") as HTMLElement | null;
    const r = sResults.find((x) => x.id === row?.dataset.id);
    if (!r) return;
    enqueue(srURL(r));
    const job = jobs.find((j) => j.url === srURL(r));
    if (job) { if (job.title == null) job.title = r.title; if (job.uploader == null && r.channel) job.uploader = r.channel; renderJobs(); }
    sRender(null);
  });
}

let renderQueued = false;
function renderJobs() {
  if (renderQueued) return;
  renderQueued = true;
  requestAnimationFrame(() => { renderQueued = false; renderJobsNow(); });
}
function renderJobsNow() {
  if (jobs.length === 0) {
    jobsEl.innerHTML = `<div class="empty"><div class="big">♫</div><div>ここに保存した曲が並びます</div><div class="note">URL はこの窓にドラッグ＆ドロップしても追加できます</div></div>`;
    $("btnClear").hidden = true;
    return;
  }
  $("btnClear").hidden = !jobs.some((j) => !j.isActive);
  jobsEl.innerHTML = jobs.map((j) => {
    const thumb = j.thumb ? `<img class="thumb" src="${esc(j.thumb)}" alt="" />` : `<div class="thumb">${j.state.kind === "done" ? "♪" : "⤓"}</div>`;
    let sub2 = "";
    if (j.playlistTitle && j.title && j.state.kind === "running") sub2 = `<div class="sub">${esc(j.title)}</div>`;
    else if (j.uploader) sub2 = `<div class="sub">${esc(j.uploader)}</div>`;
    let status = "";
    if (j.state.kind === "running") {
      status = `<div class="prog"><progress max="1" value="${j.progress}"></progress><span class="sub">${esc(j.statusText)}</span></div>`;
    } else if (j.state.kind === "failed") {
      status = `<div class="sub err">${esc(j.statusText)}</div>`;
    } else if (j.state.kind === "done" && j.files.length > 0) {
      const f = j.files[0];
      const line = j.files.length > 1 ? `${j.files.length} 曲 → ${esc(basename(dirname(f)))}${SEP}` : esc(basename(f));
      status = `<div class="sub">${line}</div>` + (j.errorCount > 0 ? `<div class="sub warn">${j.errorCount} 曲は保存できませんでした（${esc(j.lastError ?? "")}）</div>` : "");
    } else {
      status = `<div class="sub">${esc(j.statusText)}</div>`;
    }
    const b: string[] = [];
    if (j.state.kind === "done") {
      b.push(`<button class="icon" data-act="reveal" title="エクスプローラで表示">🔍</button>`);
      b.push(`<button class="icon" data-act="play" title="再生（既定のアプリで開く）">▶</button>`);
    }
    if (j.state.kind === "failed" || j.state.kind === "cancelled" || (j.state.kind === "done" && j.errorCount > 0)) {
      b.push(`<button class="icon" data-act="retry" title="やり直す">↻</button>`);
    }
    b.push(`<button class="icon" data-act="log" title="yt-dlp の出力を見る" ${j.log.length ? "" : "disabled"}>≡</button>`);
    b.push(j.isActive
      ? `<button class="icon" data-act="cancel" title="中止">✕</button>`
      : `<button class="icon" data-act="remove" title="一覧から消す（ファイルは残ります）">🗑</button>`);
    return `<div class="job" data-id="${j.id}">${thumb}<div class="body"><div class="title" title="${esc(j.url)}">${esc(j.displayTitle)}</div>${sub2}${status}</div><div class="btns">${b.join("")}</div></div>`;
  }).join("");
}

jobsEl.addEventListener("click", async (ev) => {
  const btn = (ev.target as HTMLElement).closest<HTMLButtonElement>("button[data-act]");
  if (!btn) return;
  const row = btn.closest<HTMLElement>(".job")!;
  const job = jobs.find((j) => j.id === row.dataset.id);
  if (!job) return;
  switch (btn.dataset.act) {
    case "reveal": if (job.files[0]) await invoke("reveal", { path: job.files[0] }); else await openPath(settings.folder); break;
    case "play": if (job.files[0]) await openPath(job.files[0]); break;
    case "retry": retry(job); break;
    case "log": await message(job.log.slice(-60).join("\n"), { title: job.displayTitle }); break;
    case "cancel": await cancel(job); break;
    case "remove": remove(job); break;
  }
});

function renderFooter() {
  const el = $("toolStatus");
  if (installing) { el.innerHTML = `<span class="warn">⏳</span> ${esc(installMessage)}`; return; }
  if (toolsReady()) {
    const deno = tools.can_install && !tools.deno ? ` <span class="warn">・deno がありません（YouTube の解析に必要。設定から用意）</span>` : "";
    el.innerHTML = `<span class="ok">✔</span> yt-dlp ${esc(tools.version ?? "")} ・ ffmpeg${deno}`;
  } else {
    const names = [tools.ytdlp ? "" : "yt-dlp", tools.ffmpeg ? "" : "ffmpeg"].filter(Boolean).join(" と ");
    el.innerHTML = tools.can_install
      ? `<span class="warn">⚠</span> ${names} がありません <button id="btnInstallFooter">GitHub から用意する（約 200 MB）</button>`
      : `<span class="warn">⚠</span> ${names} が見つかりません。ターミナルで brew install yt-dlp ffmpeg を実行してください`;
    document.getElementById("btnInstallFooter")?.addEventListener("click", installTools);
  }
  updateAddButton();
}

function renderFolder() { const el = $("folderLabel"); el.textContent = abbreviate(settings.folder); el.title = settings.folder; }

async function chooseFolder() {
  const picked = await openDialog({ directory: true, defaultPath: settings.folder, title: "保存先" });
  if (typeof picked === "string") { settings.folder = picked; saveSettings(); renderFolder(); }
}

// ---------------------------------------------------------------- 設定の画面
function renderToolDetail() {
  const el = $("toolDetail");
  const lines = [
    `yt-dlp: ${tools.ytdlp ?? "見つかりません"}${tools.version ? `（${tools.version}）` : ""}`,
    `ffmpeg: ${tools.ffmpeg ?? "見つかりません"}`,
    `deno: ${tools.deno ?? "見つかりません（YouTube の解析に必要）"}`,
  ];
  if (tools.can_install) lines.push(`用意した道具の置き場所: ${tools.tools_dir}`);
  el.innerHTML = lines.map(esc).join("<br>");
  $("btnInstall").hidden = !tools.can_install;
  ($("btnUpdate") as HTMLButtonElement).disabled = !tools.ytdlp;
}
function openSettings() {
  (document.querySelector(`input[name=coverMode][value=${settings.coverMode}]`) as HTMLInputElement).checked = true;
  $<HTMLInputElement>("optKeepThumb").checked = settings.keepThumbnail;
  $<HTMLInputElement>("optChannelFolders").checked = settings.channelFolders;
  $<HTMLInputElement>("optWholePlaylist").checked = settings.wholePlaylist;
  $<HTMLInputElement>("optIdInFilename").checked = settings.idInFilename;
  $<HTMLInputElement>("optYtdlp").value = settings.ytdlpPath;
  $<HTMLInputElement>("optFfmpeg").value = settings.ffmpegPath;
  $("updateOut").hidden = true;
  renderToolDetail();
  $("settingsPanel").hidden = false;
}
function bindSettings() {
  document.querySelectorAll<HTMLInputElement>("input[name=coverMode]").forEach((r) =>
    r.addEventListener("change", () => { if (r.checked) { settings.coverMode = r.value as CoverMode; saveSettings(); } }));
  const bind = (id: string, key: keyof Settings) => $<HTMLInputElement>(id).addEventListener("change", (e) => {
    (settings as any)[key] = (e.target as HTMLInputElement).checked; saveSettings();
  });
  bind("optKeepThumb", "keepThumbnail"); bind("optChannelFolders", "channelFolders");
  bind("optWholePlaylist", "wholePlaylist"); bind("optIdInFilename", "idInFilename");
  $<HTMLInputElement>("optYtdlp").addEventListener("change", (e) => { settings.ytdlpPath = (e.target as HTMLInputElement).value; saveSettings(); refreshTools(); });
  $<HTMLInputElement>("optFfmpeg").addEventListener("change", (e) => { settings.ffmpegPath = (e.target as HTMLInputElement).value; saveSettings(); refreshTools(); });
  $("btnRedetect").addEventListener("click", refreshTools);
  $("btnInstall").addEventListener("click", installTools);
  $("btnUpdate").addEventListener("click", async () => {
    if (!tools.ytdlp) return;
    const out = $("updateOut"); out.hidden = false; out.textContent = "更新中…";
    try {
      const r = await invoke<{ code: number | null; output: string }>("run_capture", { exe: tools.ytdlp, args: ["-U"], timeoutSec: 300 });
      out.textContent = r.output.trim() || (r.code === 0 ? "更新は不要でした（最新です）" : `終了コード ${r.code}`);
    } catch (e) { out.textContent = String(e); }
    refreshTools();
  });
  $("btnSettingsClose").addEventListener("click", () => { $("settingsPanel").hidden = true; });
}

// ---------------------------------------------------------------- ファイル名を整える（Mac 版 RenameModel と同じ）
interface LibFile { path: string; channel: string; name: string; ext: string }
interface RnItem { id: string; path: string; channel: string; originalBase: string; newBase: string; idSuffix: string; ext: string; error?: string }
const ID_SUFFIX = / \[[A-Za-z0-9_-]{11}\]$/;
let rnItems: RnItem[] = [];
let rnScope = "";

function splitID(name: string): [string, string] {
  const m = name.match(ID_SUFFIX);
  return m ? [name.slice(0, m.index), m[0]] : [name, ""];
}
const rnChanged = (i: RnItem) => i.newBase !== i.originalBase;
function rnFullBase(i: RnItem) {
  let b = i.newBase;
  if (i.idSuffix && b.endsWith(i.idSuffix)) b = b.slice(0, -i.idSuffix.length);
  return b + i.idSuffix;
}
function rnNewPath(i: RnItem) { return dirname(i.path) + SEP + rnFullBase(i) + "." + i.ext; }
function rnChannels(): string[] {
  const seen = [...new Set(rnItems.map((i) => i.channel))];
  return seen.sort((a, b) => (a === "") !== (b === "") ? (a === "" ? 1 : -1) : a.localeCompare(b, "ja"));
}
const chLabel = (c: string) => c === "" ? "（保存先の直下）" : c;

async function rnScan() {
  const files = await invoke<LibFile[]>("scan_library", { folder: settings.folder });
  rnItems = files.map((f) => {
    const [base, suffix] = splitID(f.name);
    return { id: crypto.randomUUID(), path: f.path, channel: f.channel, originalBase: base, newBase: base, idSuffix: suffix, ext: f.ext };
  }).sort((a, b) => a.channel.localeCompare(b.channel, "ja") || a.originalBase.localeCompare(b.originalBase, "ja"));
  const sel = $<HTMLSelectElement>("rnScope");
  sel.innerHTML = `<option value="">すべてのチャンネル</option>` + rnChannels().map((c) => `<option value="${esc(c)}">${esc(chLabel(c))}</option>`).join("");
  sel.value = rnChannels().includes(rnScope) ? rnScope : "";
  rnScope = sel.value;
  $("renameFolder").textContent = settings.folder;
  rnValidate();
  rnRender();
}

function rnValidate() {
  rnItems.forEach((i) => (i.error = undefined));
  for (const ch of rnChannels()) {
    const group = rnItems.filter((i) => i.channel === ch);
    const counts = new Map<string, number>();
    for (const i of group) { const k = rnFullBase(i).normalize("NFC"); counts.set(k, (counts.get(k) ?? 0) + 1); }
    for (const i of group) {
      const name = i.newBase.trim();
      if (!name) { i.error = "名前が空です"; continue; }
      if (name.startsWith(".")) { i.error = "先頭に . は使えません"; continue; }
      if (/[\\/:*?"<>|]/.test(name)) { i.error = "\\ / : * ? \" < > | は使えません（全角に）"; continue; }
      if ((counts.get(rnFullBase(i).normalize("NFC")) ?? 0) > 1) { i.error = "同じフォルダに同じ名前があります"; continue; }
    }
  }
}
/// 既にあるファイルとの衝突は Rust に聞く（変わった行だけ）
async function rnCheckExists() {
  for (const i of rnItems) {
    if (!rnChanged(i) || i.error) continue;
    const np = rnNewPath(i);
    if (np.toLowerCase() !== i.path.toLowerCase() && (await invoke<boolean>("path_exists", { path: np }))) i.error = "その名前のファイルが既にあります";
  }
}

function rnApplyReplace() {
  const search = $<HTMLInputElement>("rnSearch").value;
  const repl = $<HTMLInputElement>("rnReplace").value;
  const useRegex = $<HTMLInputElement>("rnRegex").checked;
  const ic = $<HTMLInputElement>("rnIgnoreCase").checked;
  if (!search) return;
  const targets = rnItems.filter((i) => !rnScope || i.channel === rnScope);
  $("rnHelp").textContent = "置換は「新しい名前」に対してかかるので、何度でも重ねられます。例: 正規表現で「【.*?】」→ 空。ファイル名の末尾の動画 ID「 [xxxxxxxxxxx]」は隠してあり、更新のとき自動で付け直します。";
  if (useRegex) {
    let re: RegExp;
    try { re = new RegExp(search, ic ? "gi" : "g"); } catch (e) { $("rnHelp").textContent = `正規表現が読めません: ${e}`; return; }
    targets.forEach((i) => (i.newBase = i.newBase.replace(re, repl)));
  } else {
    const flags = ic ? "gi" : "g";
    const re = new RegExp(search.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), flags);
    targets.forEach((i) => (i.newBase = i.newBase.replace(re, () => repl)));
  }
  rnValidate();
  rnRender();
}

function rnRender() {
  const list = $("rnList");
  if (rnItems.length === 0) {
    list.innerHTML = `<div class="empty"><div class="big">📁</div><div>保存先に m4a / mp3 がありません</div></div>`;
  } else {
    list.innerHTML = rnChannels().filter((ch) => !rnScope || ch === rnScope).map((ch) => {
      const group = rnItems.filter((i) => i.channel === ch);
      const rows = group.map((i) => `
        <div class="rn ${rnChanged(i) ? "changed" : ""}" data-id="${i.id}">
          <div class="body">
            <div class="name"><input type="text" value="${esc(i.newBase)}" data-id="${i.id}" />${i.idSuffix ? `<span class="idtag" title="動画 ID${esc(i.idSuffix)} は隠してあります。更新のとき自動で付きます">[ID]</span>` : ""}<span class="ext">.${esc(i.ext)}</span></div>
            ${rnChanged(i) ? `<div class="sub">元: ${esc(i.originalBase)}</div>` : ""}
            ${i.error ? `<div class="sub err">${esc(i.error)}</div>` : ""}
          </div>
          ${rnChanged(i) ? `<button class="icon" data-act="reset" title="この行を元に戻す">↶</button>` : ""}
          <button class="icon" data-act="reveal" title="エクスプローラで表示">🔍</button>
        </div>`).join("");
      return `<div class="ch">${ch === "" ? "📁" : "👤"} ${esc(chLabel(ch))} <span class="n">${group.length} 曲</span></div>${rows}`;
    }).join("");
  }
  const changed = rnItems.filter(rnChanged).length;
  const errors = rnItems.filter((i) => i.error).length;
  $("rnStatus").textContent = (errors ? `⚠ ${errors} 件に問題　` : "") + (changed ? `${changed} 件を変更` : "変更なし");
  $<HTMLButtonElement>("rnCommit").disabled = changed === 0 || errors > 0;
  $<HTMLButtonElement>("rnResetAll").disabled = changed === 0;
  $("rnSort").hidden = !rnItems.some((i) => i.channel === "");
}

function bindRename() {
  const list = $("rnList");
  // 名前の編集: 行を作り直すとフォーカスが飛ぶので、入力中は文字だけ反映し、確定（change）で描き直す
  list.addEventListener("input", (ev) => {
    const inp = ev.target as HTMLInputElement;
    if (inp.tagName !== "INPUT") return;
    const item = rnItems.find((i) => i.id === inp.dataset.id);
    if (item) { item.newBase = inp.value; rnValidate(); const row = inp.closest(".rn")!; row.classList.toggle("changed", rnChanged(item)); }
  });
  list.addEventListener("change", (ev) => { if ((ev.target as HTMLElement).tagName === "INPUT") rnRender(); });
  list.addEventListener("click", async (ev) => {
    const btn = (ev.target as HTMLElement).closest<HTMLButtonElement>("button[data-act]");
    if (!btn) return;
    const item = rnItems.find((i) => i.id === btn.closest<HTMLElement>(".rn")!.dataset.id);
    if (!item) return;
    if (btn.dataset.act === "reset") { item.newBase = item.originalBase; rnValidate(); rnRender(); }
    if (btn.dataset.act === "reveal") await invoke("reveal", { path: item.path });
  });
  $("rnApply").addEventListener("click", rnApplyReplace);
  $("rnSearch").addEventListener("keydown", (e) => { if (e.key === "Enter") rnApplyReplace(); });
  $("rnReplace").addEventListener("keydown", (e) => { if (e.key === "Enter") rnApplyReplace(); });
  $<HTMLSelectElement>("rnScope").addEventListener("change", (e) => { rnScope = (e.target as HTMLSelectElement).value; rnRender(); });
  $("rnResetAll").addEventListener("click", () => { rnItems.forEach((i) => (i.newBase = i.originalBase)); rnValidate(); rnRender(); });
  $("rnRescan").addEventListener("click", rnScan);
  $("rnClose").addEventListener("click", () => { $("renamePanel").hidden = true; });
  $("rnSort").addEventListener("click", async () => { await sortIntoChannels(); await rnScan(); });
  $("rnCommit").addEventListener("click", async () => {
    rnValidate();
    await rnCheckExists();
    rnRender();
    const changed = rnItems.filter(rnChanged);
    if (changed.length === 0 || rnItems.some((i) => i.error)) return;
    const ok = await ask(`${changed.length} 件のファイル名を書き換えます。\n曲の中のタイトル（タグ）はそのままです。`, { title: "更新", okLabel: "更新", cancelLabel: "キャンセル" });
    if (!ok) return;
    const results = await invoke<{ from: string; ok: boolean; error: string | null }[]>("move_files", {
      pairs: changed.map((i) => ({ from: i.path, to: rnNewPath(i) })),
    });
    let okCount = 0; const failed: string[] = [];
    for (const r of results) {
      const i = changed.find((x) => x.path === r.from)!;
      if (r.ok) { i.path = rnNewPath(i); i.originalBase = i.newBase; okCount++; } else { i.error = r.error ?? "失敗"; failed.push(`${i.originalBase}: ${r.error}`); }
    }
    rnRender();
    await message(failed.length ? `${okCount} 件を変え、${failed.length} 件は失敗しました\n${failed.join("\n")}` : `${okCount} 件の名前を変えました`, { title: "更新" });
  });
}
async function openRename() { $("renamePanel").hidden = false; await rnScan(); $<HTMLInputElement>("rnSearch").focus(); }

// ---------------------------------------------------------------- 直下の曲をチャンネルに振り分ける（埋め込んだアーティスト名で）
function ytdlpFolderName(artist: string): string {
  const table: Record<string, string> = { "/": "⧸", "\\": "⧵", ":": "：", "|": "｜", "?": "？", "*": "＊", '"': "＂", "<": "＜", ">": "＞" };
  let s = [...artist].map((c) => table[c] ?? c).join("").trim();
  while (s.endsWith(".")) s = s.slice(0, -1);
  return s || "その他";
}
async function readArtist(path: string): Promise<string | null> {
  const ffprobe = dirname(tools.ffmpeg!) + SEP + basename(tools.ffmpeg!).replace(/^ffmpeg/, "ffprobe");
  try {
    const r = await invoke<{ code: number | null; output: string }>("run_capture", {
      exe: ffprobe, args: ["-v", "quiet", "-print_format", "json", "-show_entries", "format_tags=artist", path], timeoutSec: 30,
    });
    const tags = JSON.parse(r.output).format?.tags ?? {};
    for (const k of Object.keys(tags)) if (k.toLowerCase() === "artist" && String(tags[k]).trim()) return String(tags[k]);
  } catch { /* 読めなければ無し */ }
  return null;
}
async function sortIntoChannels() {
  if (!tools.ffmpeg) { await message("ffmpeg（ffprobe）が必要です。", { kind: "warning" }); return; }
  const files = (await invoke<LibFile[]>("scan_library", { folder: settings.folder })).filter((f) => f.channel === "");
  if (files.length === 0) { await message("保存先の直下に曲はありません。すでにチャンネルごとのフォルダに入っています。"); return; }
  const ok = await ask(`直下の ${files.length} 曲をチャンネルのフォルダに振り分けます。\n曲に埋め込んであるチャンネル名（アーティスト）のフォルダへ移します。入っていない曲はそのまま残します。`, { title: "振り分け", okLabel: "振り分ける", cancelLabel: "キャンセル" });
  if (!ok) return;
  const pairs: { from: string; to: string }[] = [];
  const noArtist: string[] = [];
  for (const f of files) {
    const a = await readArtist(f.path);
    if (!a) { noArtist.push(basename(f.path)); continue; }
    pairs.push({ from: f.path, to: settings.folder + SEP + ytdlpFolderName(a) + SEP + basename(f.path) });
  }
  const results = pairs.length ? await invoke<{ from: string; ok: boolean; error: string | null }[]>("move_files", { pairs }) : [];
  const moved = results.filter((r) => r.ok).length;
  const channels = new Set(pairs.filter((p) => results.find((r) => r.from === p.from)?.ok).map((p) => basename(dirname(p.to))));
  const exists = results.filter((r) => !r.ok && r.error?.includes("同じ名前")).length;
  const failed = results.filter((r) => !r.ok && !r.error?.includes("同じ名前")).length;
  const lines = [moved ? `${moved} 曲を ${channels.size} 個のチャンネルフォルダに振り分けました` : "振り分けた曲はありません"];
  if (noArtist.length) lines.push(`チャンネル名が入っていないので残した: ${noArtist.length} 曲`);
  if (exists) lines.push(`同じ名前のファイルが先にあるので残した: ${exists} 曲`);
  if (failed) lines.push(`移せなかった: ${failed} 曲`);
  await message(lines.join("\n"), { title: "振り分け" });
}

// ---------------------------------------------------------------- 起動
async function main() {
  if (!settings.folder) { settings.folder = await invoke<string>("default_folder"); saveSettings(); }
  const override = await invoke<string | null>("folder_override");   // 動作確認用（保存はしない）
  if (override) settings.folder = override;
  renderFolder();
  document.querySelectorAll<HTMLButtonElement>("#formatSeg button").forEach((b) => {
    b.classList.toggle("on", b.dataset.format === settings.format);
    b.addEventListener("click", () => {
      settings.format = b.dataset.format as Format; saveSettings();
      document.querySelectorAll("#formatSeg button").forEach((x) => x.classList.toggle("on", x === b));
    });
  });
  urlInput.addEventListener("input", updateAddButton);
  urlInput.addEventListener("keydown", (e) => { if (e.key === "Enter") addFromText(); });
  btnAdd.addEventListener("click", addFromText);
  $("btnClip").addEventListener("click", addFromClipboard);
  $("btnFolder").addEventListener("click", chooseFolder);
  $("btnOpenFolder").addEventListener("click", async () => { await invoke("ensure_dir", { path: settings.folder }); await openPath(settings.folder); });
  $("btnSettings").addEventListener("click", openSettings);
  $("btnRename").addEventListener("click", openRename);
  $("btnClear").addEventListener("click", () => { for (let i = jobs.length - 1; i >= 0; i--) if (!jobs[i].isActive) jobs.splice(i, 1); renderJobs(); });
  document.addEventListener("keydown", (e) => {
    const mod = e.ctrlKey || e.metaKey;   // Windows は Ctrl、Mac で動かすときは ⌘
    if (mod && e.shiftKey && e.key.toLowerCase() === "v") { e.preventDefault(); addFromClipboard(); }
    if (mod && e.shiftKey && e.key.toLowerCase() === "o") { e.preventDefault(); openPath(settings.folder); }
    if (mod && !e.shiftKey && e.key.toLowerCase() === "r") { e.preventDefault(); openRename(); }
    if (e.key === "Escape") { $("settingsPanel").hidden = true; $("renamePanel").hidden = true; $("searchPanel").hidden = true; }
  });
  // URL のドラッグ＆ドロップ
  document.addEventListener("dragover", (e) => e.preventDefault());
  document.addEventListener("drop", (e) => { e.preventDefault(); const t = e.dataTransfer?.getData("text") ?? ""; extractURLs(t).forEach(enqueue); });
  bindSettings();
  bindRename();
  bindSearch();

  await listen<{ job_id: string; line: string }>("dl-line", (ev) => {
    const job = jobs.find((j) => j.id === ev.payload.job_id);
    if (job) { applyLine(job, ev.payload.line); renderJobs(); }
  });
  await listen<{ job_id: string; code: number | null; error: string | null }>("dl-done", (ev) => {
    const job = jobs.find((j) => j.id === ev.payload.job_id);
    if (job) finishJob(job, ev.payload.code, ev.payload.error);
    else { current = null; pump(); }
  });
  await listen<{ message: string }>("tools-progress", (ev) => { installMessage = ev.payload.message; renderFooter(); });

  renderJobs();
  await refreshTools();
  urlInput.focus();
  const q = await invoke<string | null>("search_override");   // 動作確認用
  if (q) openSearch(q);
}
main();
