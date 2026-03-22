# 支持网站的 DOM 结构参考

## 69shuba.com（69书吧）

### 页面结构

| 元素 | 选择器 | 说明 |
|------|--------|------|
| 正文容器 | `div.txtnav` | 包含标题和正文的主容器 |
| 正文结束 | `div.bottom-ad` | 正文之后的广告区，作为截止标记 |
| 章节标题 | `div.txtnav h1` | 标题标签 |
| 段落分隔 | `<br><br>` | 段落之间用两个 br 分隔 |
| 底部导航 | `div.page1` | 包含上一章/目录/下一章链接 |

### 需要过滤的元素

| 选择器 | 内容 |
|--------|------|
| `div#txtright` | 标题旁广告 |
| `div.contentadv` | 文中插入广告 |
| `div.txtinfo` | 标题区元数据 |
| `script`, `style` | 脚本和样式 |
| `div.page1` | 底部导航（上一章/下一章） |

### 翻页机制（⚠️ 重要）

69shuba 的翻页绑定在 `document.onkeydown` 上，核心函数如下：

```javascript
function jumpPage() {
    var event = document.all ? window.event : arguments[0];
    if (event.keyCode == 37) document.location = bookinfo.preview_page;
    if (event.keyCode == 39) document.location = bookinfo.next_page;
    if (event.keyCode == 13) document.location = bookinfo.index_page;
}
```

#### 关键全局变量

| 变量 | 说明 |
|------|------|
| `bookinfo.next_page` | 下一章 URL |
| `bookinfo.preview_page` | 上一章 URL |
| `bookinfo.index_page` | 目录页 URL |

#### 翻页方式对比

| 方式 | 可靠性 | 说明 |
|------|--------|------|
| ✅ `document.location = bookinfo.next_page` | **最佳** | 直接调用页面变量，100% 可靠 |
| ⚠️ `KeyboardEvent('keydown', {keyCode:39})` | **不可靠** | 现代浏览器中 JS 构造的 keyCode 可能为 0 |
| ❌ `browser-use -- open <url>` | **禁止** | 会触发 Cloudflare 重新验证 |

> **根因**：`jumpPage()` 用 `event.keyCode == 39` 做判断，但 `new KeyboardEvent('keydown', {keyCode:39})` 在 Chrome 等现代浏览器中，`keyCode` 属性已被标记为 deprecated，构造函数设置的值可能不被保留（读取时为 0）。因此最可靠的方式是绕过事件机制，直接读取 `bookinfo.next_page` 并设置 `document.location`。

### 非章节页面处理

69shuba 书籍中可能包含非正文章节页面（如作者感言、上架通知、求月票等），这些页面：
- 可能没有 `bookinfo` 全局变量
- 可能没有 `.txtnav` 容器或内容为空
- **但通常有 `.page1` 底部导航**

处理策略：
```javascript
// 备用翻页链接获取
var links = document.querySelectorAll('.page1 a');
for (var i = 0; i < links.length; i++) {
    if (links[i].innerText.includes('下一章')) {
        nextPage = links[i].href;
        break;
    }
}
```

### Cloudflare 防护

- 有 Cloudflare 防护，需要手动过验证
- `--profile` 模式仍可能触发验证
- `--cdp-url` 连接 + `bookinfo.next_page` 翻页是唯一稳定方案
- 检测 CF 验证页面的选择器：`#challenge-running, .cf-browser-verification, #challenge-form`
- 验证后 cookie 保持有效，可以持续下载

---

## zongheng.com（纵横中文网）

### 页面结构

| 元素 | 选择器 | 说明 |
|------|--------|------|
| 章节容器 | `.reader-box` | 带 `data-chapterid` 属性 |
| 章节标题 | `.reader-box .title_txtbox` | 标题文本 |
| 正文容器 | `.reader-box .content` | 正文区域 |
| 正文段落 | `.reader-box .content > p` | 每个段落一个 p 标签 |
| 下一章链接 | `a`（innerText="下一章"） | 用于获取下一章 URL |

### 需要过滤的元素

| 选择器 | 内容 |
|--------|------|
| `span.Jfcounts.counts` | 数字水印，提取前必须 `remove()` |

### 翻页机制

- **推荐**：用 `open` 命令导航到下一章 URL
- **禁止**：右箭头翻页（会跳转到书籍详情页，不是下一章）
- **不推荐**：JS `click()` 下一章链接（SPA 路由可能导致渲染异常）

### 防护情况

- 无 Cloudflare 防护
- 可直接用 `open` 导航
- 需注意 SPA 页面加载时间，导航后等待 2-3 秒

---

## 通用工程注意事项

### JSON 中文编码

browser-use eval 输出的 JSON 中含有中文字符时，**不要用 bash 的 eval/字符串操作来解析**，会产生编码问题。正确做法：

```bash
# ❌ 错误：用 bash 解析 JSON
eval "$(echo "$json_output" | jq -r '@sh')"

# ✅ 正确：统一用 Python 解析
python3 -c "
import json
with open('/tmp/page_info.json', 'r') as f:
    data = json.loads(f.read().strip())
if isinstance(data, str): data = json.loads(data)  # 处理双重 JSON 包裹
print(data.get('title', ''))
"
```

### browser-use eval 输出格式

- 输出可能带有多行前缀信息
- 真正的结果在最后一行，格式为 `result: <value>`
- 清理方式：`tail -1 | sed 's/^result: //'`
- 字符串结果可能被双重 JSON 包裹（`"\"value\""` → 需要两次 `json.loads`）

### 大批量下载

下载 200+ 章时建议：
1. 用 `nohup ... > download.log 2>&1 &` 后台运行
2. 避免 `head -N` 等管道命令截断输出（会触发 SIGPIPE 杀死脚本）
3. 输出文件用追加模式（`>>`），不用覆盖模式（`>`）

---

## 添加新网站支持

如需支持新的小说网站，需要：

1. **分析 DOM 结构**：
   - 用 `browser-use -- eval "document.querySelector('body').innerHTML"` 获取页面 HTML
   - 找到正文容器、标题、段落的选择器
   - 识别需要过滤的广告/水印元素

2. **测试翻页方式**：
   - 测试右箭头键是否能翻到下一章
   - 如不行，找到下一章链接的选择器
   - 检查是否有全局变量可以直接调用（如 `bookinfo.next_page`）
   - 测试是否有 Cloudflare 或其他防护
   - **⚠️ 必须测试至少 5 次连续翻页**，确认稳定性

3. **编写提取脚本**：
   - 在 `scripts/` 下创建 `extract_<site>.py`
   - 参考现有脚本的模式

4. **更新主脚本**：
   - 在 `book-download.sh` 中添加新的 site_type 分支
   - 添加 `get_<site>_page_info()` 函数返回标准化 JSON
   - 实现 CF 检测、非章节页面处理、备用翻页链接
