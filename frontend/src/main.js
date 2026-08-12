import './style.css';

import {
    Search, BookInfo, Download, Library,
    GetSettings, SetSettings,
    OpenFolder, PickDirectory, RemoveLibraryItem,
    RankingCategories, RankingBooks, QimaoRankBooks, QimaoAdaptConfig, QimaoAdaptBooks,
    ShortdramaSearch, SetShortdramaIgnored, ShortdramaSessionStatus,
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
function toast(msg, isError, icon) {
    const t = $('toast');
    t.innerHTML = '';
    if (icon) {
        const s = symSpan(icon);
        s.style.width = '14px';
        s.style.height = '14px';
        t.appendChild(s);
        t.appendChild(document.createTextNode(' ' + msg));
    } else {
        t.textContent = msg;
    }
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
// 下载 / 设置弹窗
// ---------------------------------------------------------------------------
$('btn-open-library').addEventListener('click', () => {
    $('lib-backdrop').classList.remove('hidden');
    loadLibrary();
});
$('lib-close').addEventListener('click', () => $('lib-backdrop').classList.add('hidden'));
$('lib-backdrop').addEventListener('click', (e) => { if (e.target === $('lib-backdrop')) $('lib-backdrop').classList.add('hidden'); });

$('btn-open-settings').addEventListener('click', (e) => {
    e.stopPropagation();
    const pop = $('settings-pop');
    pop.classList.toggle('hidden');
    if (!pop.classList.contains('hidden')) loadSettings();
});
// 点击悬浮菜单外部关闭
document.addEventListener('click', (e) => {
    const pop = $('settings-pop');
    if (!pop.classList.contains('hidden') && !e.target.closest('#settings-pop') && !e.target.closest('#btn-open-settings')) {
        pop.classList.add('hidden');
    }
});

// ---------------------------------------------------------------------------
// 排行榜(整合进搜索页:平台共用顶部下拉,频道按钮 + 榜单名称 + 题材 一行)
// ---------------------------------------------------------------------------
let rankCatsLoaded = false;
let rankGroups = [];
let rankChannel = 'hot';     // 'hot' 综合热榜 | '男频' | '女频'
let rankType = '1';          // 番茄 榜单名称: 1=阅读榜 2=新书榜
let rankGenreURL = null;     // 番茄 当前题材 URL
let rankHotURL = '';
let qimaoGender = '0';       // 七猫: 0=男生 1=女生
let qimaoType = '1';         // 七猫 榜单名称: 1大热 2新书 3完结 4收藏 6更新

const QIMAO_TYPES = [
    {t: '1', name: '大热榜'},
    {t: '2', name: '新书榜'},
    {t: '3', name: '完结榜'},
    {t: '4', name: '收藏榜'},
    {t: '6', name: '更新榜'},
];

function curPlatform() { return $('platform').value; }

async function initRank() {
    if (curPlatform() === 'fanqie' && !rankCatsLoaded) {
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
    await switchPlatform();
}

// 平台下拉变化 → 重建榜单导航(频道标签/榜单名称选项)并回到综合热榜
async function switchPlatform() {
    const isQimao = curPlatform() === 'qimao';
    // 短剧IP功能关闭时,七猫改编书单不显示
    let sdEnabled = true;
    try { sdEnabled = !(await GetSettings()).shortdramaIgnored; } catch (e) {}
    const canAdapt = isQimao && sdEnabled;
    document.querySelectorAll('#rank-default .rank-channel').forEach((b) => {
        if (b.dataset.channel === 'adapt') {
            b.classList.toggle('hidden', !canAdapt);
            b.innerHTML = '<span class=\'sym sym-film btn-inline-sym\'></span>改编书单';
        } else if (b.dataset.channel === 'hot') {
            b.textContent = '综合热榜';
        } else {
            b.textContent = isQimao ? (b.dataset.channel === '男频' ? '男生' : '女生') : b.dataset.channel;
        }
    });
    // 平台切到番茄或短剧功能关闭时,若当前在改编书单频道则回综合热榜
    if (rankChannel === 'adapt' && !canAdapt) rankChannel = 'hot';
    const rt = $('rank-type');
    const defs = isQimao
        ? QIMAO_TYPES
        : [{t: '1', name: '阅读榜'}, {t: '2', name: '新书榜'}];
    rt.innerHTML = '';
    defs.forEach((d) => {
        const op = document.createElement('option');
        op.value = d.t;
        op.textContent = d.name;
        rt.appendChild(op);
    });
    selectChannel(rankChannel === 'adapt' && canAdapt ? 'adapt' : 'hot');
}

// 频道切换: 综合热榜 / 男频(男生) / 女频(女生) / 改编书单(仅七猫)
function selectChannel(ch) {
    rankChannel = ch;
    document.querySelectorAll('#rank-default .rank-channel').forEach((b) => {
        b.classList.toggle('active', b.dataset.channel === ch);
    });
    // 改编书单:显示筛选+列表,隐藏常规榜单
    if (ch === 'adapt') {
        $('rank-type').classList.add('hidden');
        $('rank-genre').classList.add('hidden');
        $('rank-body').classList.add('hidden');
        $('adapt-body').classList.remove('hidden');
        initAdapt();
        return;
    }
    $('adapt-body').classList.add('hidden');
    $('rank-body').classList.remove('hidden');
    const isQimao = curPlatform() === 'qimao';
    if (isQimao) {
        if (ch === 'hot') { qimaoGender = '0'; qimaoType = '1'; $('rank-type').value = '1'; }
        else qimaoGender = ch === '女频' ? '1' : '0';
        $('rank-genre').classList.add('hidden');
        $('rank-type').classList.remove('hidden');
        loadQimao();
        return;
    }
    if (ch === 'hot') {
        $('rank-type').classList.add('hidden');
        $('rank-genre').classList.add('hidden');
        loadRank(rankHotURL);
    } else {
        $('rank-type').classList.remove('hidden');
        setupFanqieGenres(ch);
    }
}

// 番茄:填充题材下拉并加载第一个题材
function setupFanqieGenres(ch) {
    const sel = $('rank-genre');
    sel.innerHTML = '';
    sel.classList.remove('hidden');
    const group = rankGroups.find((g) => g.gender === ch);
    if (!group || !group.genres.length) {
        loadRank('');
        return;
    }
    group.genres.forEach((gen) => {
        const op = document.createElement('option');
        op.value = gen.readUrl;
        op.dataset.readUrl = gen.readUrl;
        op.dataset.newUrl = gen.newUrl;
        op.textContent = gen.name;
        sel.appendChild(op);
    });
    const first = group.genres[0];
    rankGenreURL = rankType === '1' ? first.readUrl : first.newUrl;
    loadRank(rankGenreURL);
}

// 榜单名称下拉变化
function onRankTypeChange() {
    if (curPlatform() === 'qimao') {
        qimaoType = $('rank-type').value;
        loadQimao();
        return;
    }
    rankType = $('rank-type').value;
    const gen = $('rank-genre').selectedOptions[0];
    if (gen) {
        rankGenreURL = rankType === '1' ? gen.dataset.readUrl : gen.dataset.newUrl;
        loadRank(rankGenreURL);
    }
}

// 题材下拉变化(番茄)
function onRankGenreChange() {
    const gen = $('rank-genre').selectedOptions[0];
    if (!gen) return;
    rankGenreURL = rankType === '1' ? gen.dataset.readUrl : gen.dataset.newUrl;
    loadRank(rankGenreURL);
}

// 七猫:加载榜单
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
            if (b.score) chips.appendChild(chipSym('gold', 'star', b.score));
            if (b.words) chips.appendChild(chipSym('', 'doc', b.words));
            if (b.hot) chips.appendChild(chipSym('', 'person2', b.hot));
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

// 番茄:加载榜单
function rankLabel() {
    if (rankChannel === 'hot') return '综合热榜 · 番茄';
    return `${rankChannel}·${rankType === '1' ? '阅读' : '新书'}`;
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
            if (b.score) chips.appendChild(chipSym('gold', 'star', b.score));
            if (b.words) chips.appendChild(chipSym('', 'doc', b.words));
            if (b.hot) chips.appendChild(chipSym('', 'person2', b.hot));
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

// 平台下拉共用:变化时同步刷新榜单(搜索时会临时切走榜单视图,不受影响)
$('platform').addEventListener('change', () => {
    if (!$('rank-default').classList.contains('hidden')) initRank();
});
document.querySelectorAll('#rank-default .rank-channel').forEach((btn) => {
    btn.addEventListener('click', () => selectChannel(btn.dataset.channel));
});
$('rank-type').addEventListener('change', onRankTypeChange);
$('rank-genre').addEventListener('change', onRankGenreChange);

// ---------------------------------------------------------------------------
// 搜索
// ---------------------------------------------------------------------------
async function doSearch() {
    const kw = $('keyword').value.trim();
    if (!kw) return;
    // 切换到搜索结果视图(隐藏默认的排行榜)
    $('rank-default').classList.add('hidden');
    $('search-results').classList.remove('hidden');
    const platform = $('platform').value;
    const btn = $('btn-search');
    btn.disabled = true;
    setStatusSym('search', `正在搜索「${kw}」…`);
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
            if (it.score) chips.appendChild(chipSym('gold', 'star', it.score));
            if (it.words) chips.appendChild(chipSym('', 'doc', it.words));
            if (it.hot) chips.appendChild(chipSym('', 'person2', it.hot));
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
                if (info.hot) t.chips.appendChild(chipSym('', 'person2', info.hot));
                if (info.rank) t.chips.appendChild(chipSym('', 'trophy', info.rank));
            } catch (e) { /* 单个失败静默 */ }
        }
    };
    await Promise.all([worker(), worker(), worker()]);
}

$('btn-search').addEventListener('click', doSearch);
$('keyword').addEventListener('keydown', (e) => { if (e.key === 'Enter') doSearch(); });
$('btn-back-rank').addEventListener('click', () => {
    $('search-results').classList.add('hidden');
    $('rank-default').classList.remove('hidden');
    $('keyword').value = '';
    setStatus('');
    initRank();
});

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
    $('m-sd-strip').classList.add('hidden');
    $('m-sd-hint').classList.add('hidden');
    $('m-progress-bar').style.width = '0%';
    $('m-progress-text').textContent = '';
    $('m-cover').style.visibility = 'hidden';
    $('m-cover').removeAttribute('src');
}

// SF Symbol 图标 span(mask + currentColor)
function symSpan(name) {
    const s = el('span', 'sym sym-' + name);
    s.style.width = '12px';
    s.style.height = '12px';
    return s;
}


// 带图标的 chip
function chipSym(cls, sym, text) {
    const c = el('span', 'chip' + (cls ? ' ' + cls : ''));
    const s = symSpan(sym);
    s.style.width = '11px';
    s.style.height = '11px';
    c.appendChild(s);
    c.appendChild(document.createTextNode(' ' + text));
    return c;
}
// 带图标的 status
function setStatusSym(sym, msg, isError) {
    const s = $('search-status');
    s.innerHTML = '';
    const icon = symSpan(sym);
    icon.style.width = '13px';
    icon.style.height = '13px';
    s.appendChild(icon);
    s.appendChild(document.createTextNode(' ' + msg));
    s.className = 'status' + (isError ? ' error' : '');
}

// 封面按弹窗内容高度取 3:4 比例(实测七猫/番茄封面均为 3:4),直接写死尺寸,防拉伸裁切。
function sizeCover() {
    const cover = $('m-cover').parentElement;
    const body = cover.parentElement; // .modal-body
    let h = body.clientHeight;
    h = Math.max(280, Math.min(h, 560));
    cover.style.height = h + 'px';
    cover.style.width = Math.round(h * 0.75) + 'px';
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
            [info.score ? 'star' : null, info.score],
            [info.words ? 'doc' : null, info.words],
            [info.hot ? 'person2' : null, info.hot],
            [info.rank ? 'trophy' : null, info.rank],
            [info.category ? 'folder' : null, info.category],
            [info.characters ? 'person' : null, '主角: ' + info.characters],
        ].filter(([k]) => k);
        statItems.forEach(([s, text]) => {
            const c = el('span', 'chip stat');
            c.appendChild(symSpan(s));
            c.appendChild(document.createTextNode(' ' + text));
            stats.appendChild(c);
        });
        if (info.coverUrl) {
            $('m-cover').src = info.coverUrl;
            $('m-cover').style.visibility = 'visible';
        }
        sizeCover();
        // 番茄小说:自动查短剧后台,在简介与下载按钮之间显示 IP 数据
        if (platform === 'fanqie' && info.title) {
            loadShortdramaStrip(info.title);
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
    $('m-progress-text').innerHTML = '<span class=\'sym sym-check btn-inline-sym\'></span>下载完成';
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
// 改编书单(官方筛选菜单 + 分页)
// ---------------------------------------------------------------------------
const ADAPT_PAGE_SIZE = 20;
let adaptCfgLoaded = false;
let adaptPage = 1;
let adaptPages = 1;

async function initAdapt() {
    if (!adaptCfgLoaded) {
        try {
            const groups = await QimaoAdaptConfig();
            const group = (key) => (groups.find((g) => g.key === key) || {options: []}).options;
            fillSelect($('af-direction'), group('direction'));
            fillSelect($('af-channel'), group('channel'));
            fillSelect($('af-category'), group('category'));
            fillSelect($('af-words'), group('words'));
            fillSelect($('af-over'), group('is_over'));
            fillSelect($('af-ranking'), group('ranking_type'));
            adaptCfgLoaded = true;
        } catch (e) {
            $('af-status').textContent = '加载筛选菜单失败: ' + (e.message || e);
            return;
        }
    }
    adaptPage = 1;
    loadAdapt();
}

function fillSelect(sel, options) {
    sel.innerHTML = '';
    options.forEach((o) => {
        const op = document.createElement('option');
        op.value = o.value;
        op.textContent = o.label;
        sel.appendChild(op);
    });
}

async function loadAdapt() {
    const ul = $('af-list');
    ul.innerHTML = '';
    $('af-status').textContent = '加载中…';
    try {
        const r = await QimaoAdaptBooks(
            $('af-direction').value, $('af-channel').value,
            $('af-category').value, $('af-words').value,
            $('af-over').value, $('af-ranking').value,
            adaptPage
        );
        ul.innerHTML = '';
        adaptPages = Math.max(1, r.pages);
        if (!r.books.length) {
            ul.appendChild(el('li', 'empty', '暂无符合条件的书籍'));
            $('af-status').textContent = '';
        } else {
            $('af-status').textContent = `共 ${r.total} 本 · 第 ${adaptPage}/${adaptPages} 页`;
            r.books.forEach((b) => {
                const li = el('li', 'result-item');
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
                chips.appendChild(chipSym('gold', 'film', '改编'));
                if (b.words) chips.appendChild(chipSym('', 'doc', b.words));
                main.appendChild(chips);
                li.appendChild(main);
                li.appendChild(el('div', 'ri-arrow', '›'));
                li.addEventListener('click', () => showDetail('qimao', b.bookId, b.title));
                ul.appendChild(li);
            });
        }
        $('af-prev').disabled = adaptPage <= 1;
        $('af-next').disabled = adaptPage >= adaptPages;
        $('af-pageinfo').textContent = `${adaptPage} / ${adaptPages}`;
    } catch (e) {
        $('af-status').textContent = '加载失败: ' + (e.message || e);
    }
}

['af-direction', 'af-channel', 'af-category', 'af-words', 'af-over', 'af-ranking'].forEach((id) => {
    $(id).addEventListener('change', () => {
        adaptPage = 1;
        loadAdapt();
    });
});
$('af-prev').addEventListener('click', () => { if (adaptPage > 1) { adaptPage--; loadAdapt(); } });
$('af-next').addEventListener('click', () => { if (adaptPage < adaptPages) { adaptPage++; loadAdapt(); } });

// ---------------------------------------------------------------------------
// 设置
// ---------------------------------------------------------------------------
async function loadSettings() {
    const s = await GetSettings();
    $('set-dir').textContent = s.downloadDir || '~/Downloads';
    $('set-format').value = s.format || 'txt';
    $('set-sd-enabled').checked = !s.shortdramaIgnored;   // 短剧IP开关 = 启用状态
}

// 点击文件夹名 → 弹出选择框 → 立即保存
$('set-dir').addEventListener('click', async () => {
    const dir = await PickDirectory();
    if (!dir) return;
    $('set-dir').textContent = dir;
    const s = await GetSettings();
    s.downloadDir = dir;
    await SetSettings(s);
    toast('已保存下载目录', false, 'check');
});

// 保存格式 → 立即保存
$('set-format').addEventListener('change', async () => {
    const s = await GetSettings();
    s.format = $('set-format').value;
    await SetSettings(s);
    toast('已保存格式', false, 'check');
});

// 短剧模式开关 → 立即保存
$('set-sd-enabled').addEventListener('change', async () => {
    const on = $('set-sd-enabled').checked;
    await SetShortdramaIgnored(!on);
    toast(on ? '已开启短剧模式' : '已关闭短剧模式', false, on ? 'check' : '');
    // 刷新榜单导航(关闭时隐藏七猫改编书单)
    if (!$('rank-default').classList.contains('hidden')) switchPlatform();
});

// ---------------------------------------------------------------------------
// 短剧后台:番茄详情弹窗里自动查询,在简介与下载按钮之间显示 上架/申请/改编中
// ---------------------------------------------------------------------------
async function loadShortdramaStrip(title) {
    const strip = $('m-sd-strip');
    const hint = $('m-sd-hint');
    // 用户已忽略短剧数据功能,不再尝试
    try {
        if ((await GetSettings()).shortdramaIgnored) return;
    } catch (e) { return; }
    try {
        const items = await ShortdramaSearch(title);
        const best = items[0];
        if (!best) return;
        $('sd-online').textContent = best.onlineMonth || '—';
        $('sd-apply').textContent = best.selectedCnt || '0';
        $('sd-adapting').textContent = best.adaptingCnt || '0';
        // 申请/改编中 > 0 时红色高亮
        $('sd-apply').closest('.sd-item').classList.toggle('sd-alert', parseInt(best.selectedCnt || '0', 10) > 0);
        $('sd-adapting').closest('.sd-item').classList.toggle('sd-alert', parseInt(best.adaptingCnt || '0', 10) > 0);
        strip.classList.remove('hidden');
    } catch (e) {
        // 无浏览器登录态时提醒用户(其他错误静默)
        if (e && e.message && e.message.includes('登录态')) {
            hint.classList.remove('hidden');
        }
    }
}

// 忽略短剧后台数据功能(持久化,之后不再显示)
$('btn-sd-ignore').addEventListener('click', async () => {
    try {
        await SetShortdramaIgnored(true);
        $('m-sd-hint').classList.add('hidden');
        toast('已忽略短剧IP数据');
    } catch (e) {
        toast('操作失败: ' + (e.message || e), true);
    }
});

// ---------------------------------------------------------------------------
// 首次进入:询问是否启用短剧模式
// ---------------------------------------------------------------------------
async function maybeShowShortdramaPrompt() {
    try {
        const s = await GetSettings();
        if (s.shortdramaPrompted) return;   // 已询问过
        $('sd-first-backdrop').classList.remove('hidden');
    } catch (e) { /* 静默 */ }
}

$('btn-sd-enable').addEventListener('click', async () => {
    try {
        await SetShortdramaIgnored(false);
        $('sd-first-backdrop').classList.add('hidden');
        // 检查本地浏览器登录态,给用户反馈
        const ok = await ShortdramaSessionStatus();
        toast(ok ? '已启用,检测到浏览器登录态' : '已启用;未检测到浏览器登录态,打开番茄详情时会提示登录', !ok, 'check');
    } catch (e) {
        toast('操作失败: ' + (e.message || e), true);
    }
});

$('btn-sd-skip').addEventListener('click', async () => {
    try {
        await SetShortdramaIgnored(true);
        $('sd-first-backdrop').classList.add('hidden');
        toast('已忽略短剧模式');
    } catch (e) {
        toast('操作失败: ' + (e.message || e), true);
    }
});

// ---------------------------------------------------------------------------
// 启动
// ---------------------------------------------------------------------------
loadSettings();
loadLibrary();
initRank();
maybeShowShortdramaPrompt();
