---
name: book-download
description: "This skill downloads novel/book chapter content from web fiction sites (69shuba.com, zongheng.com, book.qq.com) and saves them as plain text files. It should be used when the user provides a novel chapter URL and wants to download one or more chapters to a local txt file. Trigger phrases include 下载小说, 抓取章节, 保存小说内容, 下载到txt, or when the user provides a URL from a supported fiction site and asks to extract or save the content."
---

# Book Download — 小说章节下载 v2

从网络小说网站抓取章节正文并保存为 txt 文件。

## 支持的网站

| 网站 | 域名 | 防护 | 翻页方式 | 脚本 |
|------|------|------|----------|------|
| 69书吧 | 69shuba.com | Cloudflare（需手动验证） | `bookinfo.next_page`（页面内变量） | `book-download.sh` |
| 纵横中文网 | zongheng.com | 无 | open 下一章 URL | `book-download.sh` |
| QQ阅读 | book.qq.com | 无 | open 下一章 URL | `extract_qqread.py` ✨新增 |

## 前置条件

- **browser-use CLI** 已安装并在 PATH 中
- **Python 3** 可用
- **Google Chrome** 已安装

## 完整工作流程

### 第一步：启动 Chrome（带远程调试端口）

⚠️ **必须**用 `--user-data-dir` 指定独立 Profile，否则默认 Profile 会导致调试端口不生效。
⚠️ 启动前须确保已退出所有 Chrome 进程。

```bash
# 先检查是否有残留 Chrome 进程占用端口
lsof -i :9222

# 启动 Chrome
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 \
  --remote-allow-origins="*" \
  --user-data-dir="/tmp/chrome-debug-profile" \
  --no-first-run \
  --no-default-browser-check \
  "<起始章节URL>" > /dev/null 2>&1 &
```

### 第二步：手动通过验证（如有 Cloudflare）

对于有 Cloudflare 防护的网站（如 69shuba.com），需要：
1. 在弹出的 Chrome 中**手动完成** Cloudflare 验证
2. 确认已进入目标章节页面
3. 告知 WorkBuddy 验证已完成

对于无防护的网站（如 zongheng.com），等页面加载完成即可。

### 第三步：连接并下载

验证 Chrome 连接：
```bash
browser-use --cdp-url http://localhost:9222 -- state
```

然后执行下载脚本：
```bash
SKILL_DIR="$(find ~/.workbuddy/skills ~/.codebuddy/skills -name 'book-download' -type d 2>/dev/null | head -1)"
bash "$SKILL_DIR/scripts/book-download.sh" "<起始章节URL>" <章节数|all> "<输出文件.txt>"
```

**新功能**：章节数可以传 `all`，脚本会自动下载到最后一章。

## 使用指南（面向 WorkBuddy）

当用户提供一个小说章节链接并要求下载时，按以下流程操作：

### 1. 识别网站类型

根据 URL 判断网站：
- URL 包含 `69shuba` → 69shuba 模式
- URL 包含 `zongheng` → zongheng 模式
- 其他 → 先分析页面结构（参考 `references/site_structures.md` 中"添加新网站支持"部分）

### 2. 询问下载参数

向用户确认：
- 要下载的章节数（默认建议 50 章分批下载，或 `all` 一次下载全部）
- 输出文件名（建议用 `<书名>_前N章.txt` 或 `<书名>_完整版.txt` 格式）

### 3. 启动 Chrome 并等待用户操作

用以下命令启动 Chrome（**替换 URL 为用户提供的链接**）：

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 \
  --remote-allow-origins="*" \
  --user-data-dir="/tmp/chrome-debug-profile" \
  --no-first-run \
  --no-default-browser-check \
  "<用户提供的章节URL>" > /dev/null 2>&1 &
```

如果端口已被占用（有残留 Chrome），先检查并提醒用户关闭，或用已有连接。

**对于有 Cloudflare 防护的网站**：提醒用户在弹出的 Chrome 中完成验证，等待用户确认后再继续。
**对于无防护的网站**：等待几秒让页面加载完成即可。

### 4. 执行下载

使用 `scripts/book-download.sh` 脚本执行批量下载。脚本位置：

```bash
SKILL_DIR="$(find ~/.workbuddy/skills ~/.codebuddy/skills -name 'book-download' -type d 2>/dev/null | head -1)"
```

运行下载：
```bash
bash "$SKILL_DIR/scripts/book-download.sh" "<章节URL>" <章节数|all> "<输出文件.txt>" [site_type]
```

⚠️ **大批量下载建议**：下载 200+ 章时，建议用 `nohup` 后台运行并写日志：

```bash
nohup bash "$SKILL_DIR/scripts/book-download.sh" "<章节URL>" all "<输出文件.txt>" > download.log 2>&1 &
echo "PID: $!"
```

可以用 `tail -f download.log` 查看进度。

**如果脚本执行失败**，可以降级为手动逐章提取模式（见下方"手动逐章提取"部分）。

### 5. 验证结果

下载完成后：
- 读取输出文件的前几行和末几行，确认内容完整
- 报告总行数和章节数
- 如有需要，检查是否有重复章节

## 手动逐章提取（降级方案）

当脚本执行失败时，使用 `browser-use` CLI 手动提取每一章。

### 69shuba.com 手动流程

```bash
# 连接到 Chrome
browser-use --cdp-url http://localhost:9222 -- state

# 提取当前章节 HTML（保存为 JSON）
browser-use --cdp-url http://localhost:9222 -- eval \
  "JSON.stringify(document.querySelector('.txtnav').outerHTML)" \
  2>/dev/null | tail -1 | sed 's/^result: //' > /tmp/chapter.html

# 用 Python 提取正文
python3 "$SKILL_DIR/scripts/extract_69shuba.py" /tmp/chapter.html output.txt

# 翻到下一章 —— ⚠️ 使用 bookinfo.next_page（最可靠的方式）
browser-use --cdp-url http://localhost:9222 -- eval \
  "document.location = bookinfo.next_page; 'navigated'"
sleep 2

# 重复以上步骤
```

### zongheng.com 手动流程

```bash
# 连接到 Chrome
browser-use --cdp-url http://localhost:9222 -- state

# 移除水印 + 提取（保存为 JSON）
browser-use --cdp-url http://localhost:9222 -- eval "
  document.querySelectorAll('.Jfcounts').forEach(el => el.remove());
  const title = document.querySelector('.title_txtbox')?.innerText || '';
  const ps = Array.from(document.querySelectorAll('.content p')).map(p => p.innerText);
  const nextA = Array.from(document.querySelectorAll('a')).find(a => a.innerText.trim() === '下一章');
  const nextUrl = nextA ? nextA.href : '';
  JSON.stringify({title, paragraphs: ps, nextUrl})
" 2>/dev/null | tail -1 | sed 's/^result: //' > /tmp/chapter.json

# 用 Python 提取正文
python3 "$SKILL_DIR/scripts/extract_zongheng.py" /tmp/chapter.json output.txt

# 获取下一章 URL 并导航
NEXT_URL=$(python3 -c "import json; d=json.load(open('/tmp/chapter.json')); print(d.get('nextUrl',''))")
browser-use --cdp-url http://localhost:9222 -- open "$NEXT_URL"
sleep 3

# 重复以上步骤
```

### QQ阅读 (book.qq.com) 使用方法

QQ阅读使用独立的 Python 脚本，通过 CDP 协议直接连接 Chrome 提取内容（不依赖 browser-use CLI）。

```bash
# 1. 启动 Chrome 打开章节页面
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 \
  --remote-allow-origins="*" \
  --user-data-dir="/tmp/chrome-debug-profile" \
  --no-first-run \
  --no-default-browser-check \
  "https://book.qq.com/book-read/<书籍ID>/<章节号>" > /dev/null 2>&1 &

# 2. 等待页面加载后运行提取脚本
SKILL_DIR="$(find ~/.workbuddy/skills ~/.codebuddy/skills -name 'book-download' -type d 2>/dev/null | head -1)"
python3 "$SKILL_DIR/scripts/extract_qqread.py" <章节数|all> "<输出文件.txt>"
```

**特点**：
- 无需 browser-use CLI，只需 Python 3 + `websocket-client` 库（脚本会自动安装）
- 自动提取章节标题（`h1.chapter-title`）和正文（`.chapter-content p`）
- 支持 `all` 参数下载全部章节

## 已知问题和注意事项

### 69shuba 翻页（重要！）

| 方式 | 可靠性 | 说明 |
|------|--------|------|
| ✅ `bookinfo.next_page` | **最佳** | 直接调用页面内翻页变量，不触发 CF |
| ⚠️ `KeyboardEvent` | **不可靠** | JS 构造的 `keyCode` 可能为 0，导致 `jumpPage()` 函数不响应 |
| ❌ `open URL` | **禁止** | 会触发 Cloudflare 重新验证 |

**根因分析**：69shuba 的 `jumpPage()` 函数用 `event.keyCode == 39` 判断右箭头键，但现代浏览器中 JS 构造的 `KeyboardEvent` 对象的 `keyCode` 属性已废弃且可能为 0，因此模拟键盘翻页不可靠。直接读取 `bookinfo.next_page` 并设置 `document.location` 是唯一稳定方案。

### 其他注意事项

- **Cloudflare 验证**：脚本会自动检测 CF 验证页面并暂停等待，用户手动完成验证后脚本自动继续
- **非章节页面**：遇到作者感言、上架通知等非标准章节页面时，脚本会自动从底部导航获取下一章链接并跳过
- **重复章节检测**：如果连续 3 次提取到相同标题的章节，脚本会自动停止（表示翻页可能失效）
- **断点续传**：输出文件采用追加模式，中断后可从当前页面继续下载
- **Chrome 调试端口**：必须用独立 `--user-data-dir`，否则不生效
- **eval 输出处理**：browser-use 的 eval 输出带有前缀，需 `tail -1 | sed 's/^result: //'` 清理
- **JSON 中文编码**：所有 JSON 解析务必用 Python 处理，bash 的 eval/字符串操作对中文不可靠
- **页面加载等待**：翻页后需等待 2-3 秒让页面完成加载
- **大批量下载**：200+ 章建议用 `nohup` 后台运行，避免管道断裂

## 网站结构详情

更详细的 DOM 选择器和过滤规则，参见 `references/site_structures.md`。
