import './style.css';

import {
    Search, BookInfo, Download, Library,
    GetSettings, SetSettings,
    OpenFolder, PickDirectory, RemoveLibraryItem,
    RankingCategories, RankingBooks, QimaoRankBooks,
} from '../wailsjs/go/main/App';
import {EventsOn} from '../wailsjs/runtime/runtime';

// ---------------------------------------------------------------------------
// 状态
// ---------------------------------------------------------------------------
let currentBook = null;   // {platform, bookId}
let downloading = false;
const PLATFORM_NAME = {qimao: '七猫', fanqie: '番茄'};

// ---------------------------------------------------------------------------
// DOM 助手
// ---------------------------------------------------------------------------
const $ = (id) => document.getElementById(id);

function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
}

function setStatus(msg, isError) {
    const s = $('search-status');
    s.textContent = msg || '';
    s.className = 'status' + (isError ? ' error' : '');
}

// 全局 toast 提示(右下角浮现)
let toastTimer = null;
function toast(msg, isError) {
    const t = $('toast');
    t.textContent = msg;
    t.className = 'toast' + (isError ? ' error' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { t.className = 'toast hidden'; }, 2400);
}

function fmtTime(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    if (isNaN(d)) return iso;
    const now = new Date();
    const sameDay = d.toDateString() === now.toDateString();
    const hh = String(d.getHours()).padStart(2, '0');
    const mm = String(d.getMinutes()).padStart(2, '0');
    if (sameDay) return `今天 ${hh}:${mm}`;
    return `${d.getMonth() + 1}月${d.getDate()}日 ${hh}:${mm}`;
}

function fmtSize(n) {
    if (n == null) return '';
    if (n > 1024 * 1024) return (n / 1024 / 1024).toFixed(1) + ' MB';
    if (n > 1024) return (n / 1024).toFixed(1) + ' KB';
    return n + ' B';
}

// ---------------------------------------------------------------------------
// 标签页切换
// ---------------------------------------------------------------------------
document.querySelectorAll('.tab').forEach((btn) => {
    btn.addEventListener('click', () => {
        document.querySelectorAll('.tab').forEach((b) => b.classList.remove('active'));
        document.querySelectorAll('.tab-panel').forEach((p) => p.classList.remove('active'));
        btn.classList.add('active');
        $('tab-' + btn.dataset.tab).classList.add('active');
        if (btn.dataset.tab === 'library') loadLibrary();
        if (btn.dataset.tab === 'rank') initRank();
    });
});

// ---------------------------------------------------------------------------
// 排行榜(平台下拉: 番茄/七猫; 番茄另有官网式 男频/女频 + 榜单标签导航)
// ---------------------------------------------------------------------------
let rankCatsLoaded = false;
let rankGroups = [];
let rankPlatform = 'fanqie'; // fanqie | qimao
let rankGender = null;       // null=综合热榜 | '男频' | '女频'(仅番茄)
let rankType = '1';          // 1=阅读榜 2=新书榜
let rankGenreURL = null;     // 当前类型的 URL(阅读/新书)
let rankHotURL = '';

async function initRank() {
    if (rankPlatform === 'fanqie' && !rankCatsLoaded) {
        try {
            rankGroups = await RankingCategories();
            rankCatsLoaded = true;
            for (const g of rankGroups) {
                if (g.gender === '综合') rankHotURL = g.hotUrl;
            }
        } catch (e) {
            $('rank-status').textContent = '加载榜单失败: ' + (e.message || e);
            return;
        }
    }
    switchPlatform(rankPlatform);
}

// 平台下拉切换: 番茄 → 官网式导航; 七猫 → 男生/女生 + 榜单类型
function switchPlatform(p) {
    rankPlatform = p;
    $('rank-platform').value = p;
    if (p === 'qimao') {
        initQimao();
        return;
    }
    // 还原番茄性别按钮标签并显示
    document.querySelectorAll('#tab-rank .rank-gender').forEach((b) => {
        b.classList.remove('hidden');
        b.textContent = b.dataset.gender;
        b.classList.remove('active');
    });
    showHot();
}

// ---------- 七猫榜单 ----------
const QIMAO_TYPES = [
    {t: '1', name: '大热榜'},
    {t: '2', name: '新书榜'},
    {t: '3', name: '完结榜'},
    {t: '4', name: '收藏榜'},
    {t: '6', name: '更新榜'},
];
let qimaoGender = '0'; // 0=男生 1=女生
let qimaoType = '1';

function initQimao() {
    // 性别按钮复用(男频→男生, 女频→女生)
    document.querySelectorAll('#tab-rank .rank-gender').forEach((b) => {
        b.classList.remove('hidden');
        b.textContent = b.dataset.gender === '男频' ? '男生' : '女生';
        b.classList.toggle('active', (b.dataset.gender === '男频') === (qimaoGender === '0'));
    });
    $('rank-type-row').classList.add('hidden');
    $('rank-genres').classList.remove('hidden');
    renderQimaoTypes();
    loadQimao();
}

function renderQimaoTypes() {
    const wrap = $('rank-genres');
    wrap.innerHTML = '';
    QIMAO_TYPES.forEach((d) => {
        const c = el('button', 'chip genre-chip' + (d.t === qimaoType ? ' active' : ''), d.name);
        c.dataset.rtype = d.t;
        c.addEventListener('click', () => {
            qimaoType = d.t;
            wrap.querySelectorAll('.genre-chip').forEach((x) => x.classList.remove('active'));
            c.classList.add('active');
            loadQimao();
        });
        wrap.appendChild(c);
    });
}

async function loadQimao() {
    const ul = $('rank-list');
    ul.innerHTML = '';
    $('rank-status').textContent = '加载榜单…';
    try {
        const books = await QimaoRankBooks(qimaoGender, qimaoType);
        ul.innerHTML = '';
        if (!books.length) {
            ul.appendChild(el('li', 'empty', '暂无数据'));
            $('rank-status').textContent = '';
            return;
        }
        const tname = (QIMAO_TYPES.find((d) => d.t === qimaoType) || {}).name || '';
        $('rank-status').textContent = `TOP ${books.length} · ${qimaoGender === '0' ? '男生' : '女生'}·${tname}`;
        books.forEach((b) => {
            const li = el('li', 'result-item rank-item');
            li.appendChild(el('div', 'rank-no' + (b.position <= 3 ? ' top' : ''), String(b.position)));
            if (b.coverUrl) {
                const cover = el('div', 'card-cover');
                const img = document.createElement('img');
                img.src = b.coverUrl;
                img.onerror = () => { cover.style.display = 'none'; };
                cover.appendChild(img);
                li.appendChild(cover);
            }
            const main = el('div', 'ri-main');
            main.appendChild(el('div', 'ri-title', b.title));
            main.appendChild(el('div', 'ri-meta', b.author || ''));
            const chips = el('div', 'ri-chips');
            if (b.score) chips.appendChild(el('span', 'chip gold', `⭐ ${b.score}`));
            if (b.words) chips.appendChild(el('span', 'chip', `📄 ${b.words}`));
            if (b.hot) chips.appendChild(el('span', 'chip', `👥 ${b.hot}`));
            main.appendChild(chips);
            li.appendChild(main);
            li.appendChild(el('div', 'ri-arrow', '›'));
            li.addEventListener('click', () => showDetail('qimao', b.bookId, b.title));
            ul.appendChild(li);
        });
        $('rank-status').textContent = '';
    } catch (e) {
        $('rank-status').textContent = '加载榜单失败: ' + (e.message || e);
    }
}

// 番茄综合热榜
function showHot() {
    rankGender = null;
    document.querySelectorAll('.rank-gender').forEach((b) => b.classList.remove('active'));
    $('rank-type-row').classList.add('hidden');
    $('rank-genres').classList.add('hidden');
    loadRank(rankHotURL);
}

function renderGenres() {
    const wrap = $('rank-genres');
    wrap.innerHTML = '';
    const group = rankGroups.find((g) => g.gender === rankGender);
    if (!group || !group.genres.length) return;
    group.genres.forEach((gen) => {
        const c = el('button', 'chip genre-chip', gen.name);
        c.dataset.readUrl = gen.readUrl;
        c.dataset.newUrl = gen.newUrl;
        c.addEventListener('click', () => {
            wrap.querySelectorAll('.genre-chip').forEach((x) => x.classList.remove('active'));
            c.classList.add('active');
            rankGenreURL = rankType === '1' ? gen.readUrl : gen.newUrl;
            loadRank(rankGenreURL);
        });
        wrap.appendChild(c);
    });
}

// 男频/女频: 显示阅读/新书切换 + 该性别类型标签
function selectGender(gender) {
    rankGender = gender;
    document.querySelectorAll('.rank-gender').forEach((b) => {
        b.classList.toggle('active', b.dataset.gender === gender);
    });
    $('rank-type-row').classList.remove('hidden');
    $('rank-genres').classList.remove('hidden');
    renderGenres();
    const first = $('rank-genres')?.querySelector('.genre-chip');
    if (first) {
        first.classList.add('active');
        rankGenreURL = rankType === '1' ? first.dataset.readUrl : first.dataset.newUrl;
        loadRank(rankGenreURL);
    }
}

function rankLabel() {
    if (rankPlatform === 'qimao') return '七猫';
    if (!rankGender) return '综合热榜 · 番茄';
    return `${rankGender}·${rankType === '1' ? '阅读' : '新书'}`;
}

async function loadRank(url) {
    if (!url) return;
    const ul = $('rank-list');
    ul.innerHTML = '';
    $('rank-status').textContent = '加载榜单…';
    try {
        const books = await RankingBooks(url);
        ul.innerHTML = '';
        if (!books.length) {
            ul.appendChild(el('li', 'empty', '暂无数据'));
            $('rank-status').textContent = '';
            return;
        }
        $('rank-status').textContent = `TOP ${books.length} · ${rankLabel()}`;
        books.forEach((b) => {
            const li = el('li', 'result-item rank-item');
            li.appendChild(el('div', 'rank-no' + (b.position <= 3 ? ' top' : ''), String(b.position)));
            if (b.coverUrl) {
                const cover = el('div', 'card-cover');
                const img = document.createElement('img');
                img.src = b.coverUrl;
                img.onerror = () => { cover.style.display = 'none'; };
                cover.appendChild(img);
                li.appendChild(cover);
            }
            const main = el('div', 'ri-main');
            main.appendChild(el('div', 'ri-title', b.title));
            main.appendChild(el('div', 'ri-meta', b.author || ''));
            const chips = el('div', 'ri-chips');
            if (b.score) chips.appendChild(el('span', 'chip gold', `⭐ ${b.score}`));
            if (b.words) chips.appendChild(el('span', 'chip', `📄 ${b.words}`));
            if (b.hot) chips.appendChild(el('span', 'chip', `👥 ${b.hot}`));
            main.appendChild(chips);
            li.appendChild(main);
            li.appendChild(el('div', 'ri-arrow', '›'));
            li.addEventListener('click', () => showDetail('fanqie', b.bookId, b.title));
            ul.appendChild(li);
        });
        $('rank-status').textContent = '';
    } catch (e) {
        $('rank-status').textContent = '加载榜单失败: ' + (e.message || e);
    }
}

$('rank-platform').addEventListener('change', (e) => switchPlatform(e.target.value));
document.querySelectorAll('#tab-rank .rank-gender').forEach((btn) => {
    btn.addEventListener('click', () => {
        if (rankPlatform === 'qimao') {
            qimaoGender = btn.dataset.gender === '男频' ? '0' : '1';
            document.querySelectorAll('#tab-rank .rank-gender').forEach((b) => b.classList.toggle('active', b === btn));
            loadQimao();
        } else {
            selectGender(btn.dataset.gender);
        }
    });
});
document.querySelectorAll('.rank-type').forEach((btn) => {
    btn.addEventListener('click', () => {
        rankType = btn.dataset.type;
        document.querySelectorAll('.rank-type').forEach((x) => x.classList.toggle('active', x === btn));
        const active = $('rank-genres')?.querySelector('.genre-chip.active');
        if (active) {
            rankGenreURL = rankType === '1' ? active.dataset.readUrl : active.dataset.newUrl;
            loadRank(rankGenreURL);
        }
    });
});

// ---------------------------------------------------------------------------
// 搜索
// ---------------------------------------------------------------------------
async function doSearch() {
    const kw = $('keyword').value.trim();
    if (!kw) return;
    const platform = $('platform').value;
    const btn = $('btn-search');
    btn.disabled = true;
    setStatus(`🔍 正在搜索「${kw}」…`);
    try {
        const items = await Search(platform, kw);
        const ul = $('results');
        ul.innerHTML = '';
        if (!items.length) {
            setStatus('未找到相关书籍', true);
            return;
        }
        setStatus(`共 ${items.length} 条结果 · 点击查看详情`);
        const enrichTargets = [];
        items.forEach((it) => {
            const li = el('li', 'result-item book-card');
            // 封面缩略图
            if (it.coverUrl) {
                const cover = el('div', 'card-cover');
                const img = document.createElement('img');
                img.src = it.coverUrl;
                img.onerror = () => { cover.style.display = 'none'; };
                cover.appendChild(img);
                li.appendChild(cover);
            }
            const main = el('div', 'ri-main');
            main.appendChild(el('div', 'ri-title', it.title));
            const meta = el('div', 'ri-meta');
            meta.appendChild(el('span', 'chip', PLATFORM_NAME[platform]));
            if (it.isOver) meta.appendChild(el('span', 'chip green', '完结'));
            if (it.author) meta.appendChild(el('span', '', it.author));
            main.appendChild(meta);
            // 信息徽章
            const chips = el('div', 'ri-chips');
            if (it.score) chips.appendChild(el('span', 'chip gold', `⭐ ${it.score}`));
            if (it.words) chips.appendChild(el('span', 'chip', `📄 ${it.words}`));
            if (it.hot) chips.appendChild(el('span', 'chip', `👥 ${it.hot}`));
            main.appendChild(chips);
            if (it.abstract) main.appendChild(el('div', 'ri-abs', it.abstract));
            li.appendChild(main);
            li.appendChild(el('div', 'ri-arrow', '›'));
            li.addEventListener('click', () => showDetail(platform, it.bookId, it.title));
            ul.appendChild(li);
            if (platform === 'qimao') enrichTargets.push({bookId: it.bookId, chips});
        });
        // 七猫后台补全人气/榜单(搜索结果不含,需查详情)
        if (enrichTargets.length) enrichQimao(enrichTargets);
    } catch (e) {
        setStatus('搜索失败: ' + (e.message || e), true);
    } finally {
        btn.disabled = false;
    }
}

// 七猫卡片后台补全: 人气 + 榜单(并发 3)
async function enrichQimao(targets) {
    let idx = 0;
    const worker = async () => {
        while (idx < targets.length) {
            const t = targets[idx++];
            try {
                const info = await BookInfo('qimao', t.bookId);
                if (info.hot) t.chips.appendChild(el('span', 'chip', `👥 ${info.hot}`));
                if (info.rank) t.chips.appendChild(el('span', 'chip', `🏆 ${info.rank}`));
            } catch (e) { /* 单个失败静默 */ }
        }
    };
    await Promise.all([worker(), worker(), worker()]);
}

$('btn-search').addEventListener('click', doSearch);
$('keyword').addEventListener('keydown', (e) => { if (e.key === 'Enter') doSearch(); });

// ---------------------------------------------------------------------------
// 详情弹窗
// ---------------------------------------------------------------------------
function openModal() { $('modal-backdrop').classList.remove('hidden'); }
function closeModal() { $('modal-backdrop').classList.add('hidden'); }

$('modal-close').addEventListener('click', closeModal);
$('modal-backdrop').addEventListener('click', (e) => {
    if (e.target === $('modal-backdrop')) closeModal();
});
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeModal(); });

function resetModal() {
    $('m-download').disabled = downloading;
    $('m-progress-wrap').classList.add('hidden');
    $('m-result').classList.add('hidden');
    $('m-progress-bar').style.width = '0%';
    $('m-progress-text').textContent = '';
    $('m-cover').style.visibility = 'hidden';
    $('m-cover').removeAttribute('src');
}

async function showDetail(platform, bookId, fallbackTitle) {
    currentBook = {platform, bookId};
    resetModal();
    openModal();
    try {
        const info = await BookInfo(platform, bookId);
        $('m-title').textContent = info.title || fallbackTitle;
        $('m-platform').textContent = PLATFORM_NAME[platform];
        $('m-author').textContent = info.author ? '作者: ' + info.author : '';
        $('m-tags').textContent = info.tags || '';
        $('m-desc').textContent = info.description || '暂无简介';
        $('m-chapters').textContent = info.chapterCount ? `共 ${info.chapterCount} 章` : '';
        // 统计行: 评分 / 字数 / 人气在读 / 榜单 / 分类 / 主角
        const stats = $('m-stats');
        stats.innerHTML = '';
        const statItems = [
            info.score ? ['⭐', info.score] : null,
            info.words ? ['📄', info.words] : null,
            info.hot ? ['👥', info.hot] : null,
            info.rank ? ['🏆', info.rank] : null,
            info.category ? ['🗂', info.category] : null,
            info.characters ? ['🧑', '主角: ' + info.characters] : null,
        ].filter(Boolean);
        statItems.forEach(([icon, text]) => {
            const c = el('span', 'chip stat', `${icon} ${text}`);
            stats.appendChild(c);
        });
        if (info.coverUrl) {
            $('m-cover').src = info.coverUrl;
            $('m-cover').style.visibility = 'visible';
        }
    } catch (e) {
        $('m-title').textContent = fallbackTitle || '加载失败';
        $('m-desc').textContent = '详情加载失败: ' + (e.message || e);
        $('m-download').disabled = true;
    }
}

// ---------------------------------------------------------------------------
// 下载 + 进度
// ---------------------------------------------------------------------------
$('m-download').addEventListener('click', () => {
    if (!currentBook || downloading) return;
    downloading = true;
    $('m-download').disabled = true;
    $('m-result').classList.add('hidden');
    $('m-progress-wrap').classList.remove('hidden');
    $('m-progress-bar').style.width = '0%';
    $('m-progress-text').textContent = '准备中…';
    Download(currentBook.platform, currentBook.bookId);
});

EventsOn('download:progress', (p) => {
    const pct = p.total > 0 ? Math.round((p.saved / p.total) * 100) : 0;
    $('m-progress-bar').style.width = pct + '%';
    $('m-progress-text').textContent = p.total > 0
        ? `下载中 ${p.saved}/${p.total} 章 (${pct}%)`
        : `已下载 ${p.saved} 章`;
});

EventsOn('download:done', (r) => {
    downloading = false;
    $('m-download').disabled = false;
    $('m-progress-bar').style.width = '100%';
    $('m-progress-text').textContent = '✅ 下载完成';
    const res = $('m-result');
    res.classList.remove('hidden');
    res.classList.remove('error');
    $('m-result-text').textContent = `${r.title || ''} ${r.author || ''}`.trim();
    $('m-reveal').onclick = () => { if (r.path) OpenFolder(r.path); };
});

EventsOn('download:error', (r) => {
    downloading = false;
    $('m-download').disabled = false;
    $('m-progress-wrap').classList.add('hidden');
    const res = $('m-result');
    res.classList.remove('hidden');
    res.classList.add('error');
    $('m-result-text').textContent = '下载失败: ' + (r.message || '未知错误');
});

// ---------------------------------------------------------------------------
// 已下载
// ---------------------------------------------------------------------------
async function loadLibrary() {
    const ul = $('lib-list');
    ul.innerHTML = '';
    try {
        const items = await Library();
        if (!items.length) {
            ul.appendChild(el('li', 'empty', '暂无已下载的书籍'));
            return;
        }
        items.forEach((it) => {
            const li = el('li', 'result-item no-click');
            const main = el('div', 'ri-main');
            main.appendChild(el('div', 'ri-title', it.name));
            const meta = el('div', 'ri-meta');
            meta.appendChild(el('span', 'chip', PLATFORM_NAME[it.platform] || '下载'));
            meta.appendChild(el('span', '', `${it.ext.toUpperCase()} · ${fmtSize(it.size)}`));
            if (it.time) meta.appendChild(el('span', '', fmtTime(it.time)));
            main.appendChild(meta);
            li.appendChild(main);
            const btns = el('div', 'ri-btns');
            const show = el('button', 'btn small ghost', '显示');
            show.addEventListener('click', () => OpenFolder(it.path));
            const del = el('button', 'btn small danger', '删除');
            del.addEventListener('click', () => askDelete(it));
            btns.appendChild(show);
            btns.appendChild(del);
            li.appendChild(btns);
            ul.appendChild(li);
        });
    } catch (e) {
        ul.appendChild(el('li', 'empty', '加载失败: ' + (e.message || e)));
    }
}

// 删除确认弹窗
let deleteTarget = null;
function askDelete(item) {
    deleteTarget = item;
    $('cf-title').textContent = `删除「${item.name}」?`;
    $('cf-text').textContent =
        '「仅移除记录」：只在列表里移除，文件仍保留在磁盘。\n' +
        '「同时删除文件」：本地文件也会被永久删除。';
    $('confirm-backdrop').classList.remove('hidden');
}
function closeConfirm() {
    $('confirm-backdrop').classList.add('hidden');
    deleteTarget = null;
}
$('cf-cancel').addEventListener('click', closeConfirm);
$('confirm-backdrop').addEventListener('click', (e) => {
    if (e.target === $('confirm-backdrop')) closeConfirm();
});

async function doRemove(deleteFile) {
    if (!deleteTarget) return;
    const target = deleteTarget;
    closeConfirm();
    try {
        await RemoveLibraryItem(target.path, deleteFile);
        toast(deleteFile ? '已删除文件并移除记录' : '已移除记录，文件保留');
        loadLibrary();
    } catch (e) {
        toast('删除失败: ' + (e.message || e), true);
    }
}
$('cf-record').addEventListener('click', () => doRemove(false));
$('cf-file').addEventListener('click', () => doRemove(true));

$('btn-refresh-lib').addEventListener('click', loadLibrary);
$('btn-open-dir').addEventListener('click', async () => {
    const s = await GetSettings();
    OpenFolder(s.downloadDir);
});

// ---------------------------------------------------------------------------
// 设置
// ---------------------------------------------------------------------------
async function loadSettings() {
    const s = await GetSettings();
    $('set-dir').value = s.downloadDir || '';
    $('set-format').value = s.format || 'txt';
}

$('btn-pick-dir').addEventListener('click', async () => {
    const dir = await PickDirectory();
    if (dir) $('set-dir').value = dir;
});

$('btn-save-settings').addEventListener('click', async () => {
    const s = await GetSettings();
    s.downloadDir = $('set-dir').value.trim() || s.downloadDir;
    s.format = $('set-format').value;
    await SetSettings(s);
    toast('✅ 设置已保存');
    loadLibrary();
});

// ---------------------------------------------------------------------------
// 启动
// ---------------------------------------------------------------------------
loadSettings();
loadLibrary();
