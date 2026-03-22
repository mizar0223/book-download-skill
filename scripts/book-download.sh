#!/usr/bin/env bash
#
# book-download.sh — 小说章节批量下载脚本 v2
#
# 用法:
#   bash book-download.sh <chapter_url> <num_chapters|all> <output_file> [site_type]
#
# 参数:
#   chapter_url    起始章节 URL
#   num_chapters   要下载的章节数，或 "all" 下载到最后一章
#   output_file    输出 txt 文件路径
#   site_type      网站类型: 69shuba | zongheng（自动检测）
#
# 前置条件:
#   - Chrome 已启动并带 --remote-debugging-port=9222
#   - 已手动通过 Cloudflare 验证（如有）
#   - browser-use CLI 已安装并在 PATH 中
#   - 当前浏览器已停留在起始章节页面
#
# 改进记录 (v2, 2026-03-22):
#   - 69shuba 翻页改用 bookinfo.next_page 代替 KeyboardEvent（根因修复）
#   - 新增 Cloudflare 验证检测 + 自动暂停等待
#   - 新增重复章节检测（连续 3 次重复则停止）
#   - 新增非章节页面自动跳过（备用翻页链接）
#   - 用 Python 处理 JSON 避免 bash eval 的中文编码问题
#   - 支持 "all" 模式（下载到最后一章）
#   - 追加写入模式，支持断点续传
#   - 进度日志文件，方便追踪

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CDP_URL="http://localhost:9222"
BROWSER_USE="browser-use"
TMP_DIR="/tmp/book-download-$$"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*" >&2; }
log_prog()  { echo -e "${CYAN}[PROG]${NC} $(date '+%H:%M:%S') $*"; }

usage() {
    cat <<EOF
用法: $0 <chapter_url> <num_chapters|all> <output_file> [site_type]

参数:
  chapter_url    起始章节 URL
  num_chapters   要下载的章节数，或 "all" 下载到最后一章
  output_file    输出 txt 文件路径
  site_type      网站类型: 69shuba | zongheng（自动检测）

示例:
  bash $0 "https://69shuba.com/txt/12345/1" 50 "novel.txt"
  bash $0 "https://69shuba.com/txt/12345/1" all "novel.txt"
EOF
    exit 1
}

detect_site() {
    local url="$1"
    if [[ "$url" == *"69shuba"* ]]; then
        echo "69shuba"
    elif [[ "$url" == *"zongheng"* ]]; then
        echo "zongheng"
    else
        echo "unknown"
    fi
}

check_prerequisites() {
    # 检查 browser-use CLI
    if ! command -v "$BROWSER_USE" &>/dev/null; then
        log_error "browser-use CLI 未找到。请确保已安装并在 PATH 中。"
        exit 1
    fi
    
    # 检查 Chrome 调试端口
    if ! curl -s "$CDP_URL/json/version" &>/dev/null; then
        log_error "无法连接到 Chrome 调试端口 ($CDP_URL)。"
        log_error "请先启动 Chrome："
        log_error '  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \'
        log_error '    --remote-debugging-port=9222 \'
        log_error '    --remote-allow-origins="*" \'
        log_error '    --user-data-dir="/tmp/chrome-debug-profile" \'
        log_error '    --no-first-run --no-default-browser-check \'
        log_error "    \"$1\" &"
        exit 1
    fi
    
    # 检查 Python 3
    if ! command -v python3 &>/dev/null; then
        log_error "python3 未找到。请确保已安装。"
        exit 1
    fi
    
    log_info "前置检查通过"
}

# =====================================================
# 69shuba 抓取函数
# =====================================================

# 获取当前页面信息（标题、正文、翻页状态）
# 输出 JSON 到 stdout，用 Python 解析避免 bash 中文编码问题
get_69shuba_page_info() {
    $BROWSER_USE --cdp-url "$CDP_URL" -- eval "
        (function() {
            // 检测 Cloudflare 验证页面
            var cf = document.querySelector('#challenge-running, .cf-browser-verification, #challenge-form');
            if (cf) return JSON.stringify({action: 'CF'});
            
            // 尝试获取标题
            var titleEl = document.querySelector('.txtnav h1');
            var title = titleEl ? titleEl.innerText.trim() : '';
            
            // 获取翻页信息（bookinfo 是 69shuba 页面的全局变量）
            var nextPage = '';
            try { nextPage = bookinfo.next_page || ''; } catch(e) {}
            
            // 如果没有 bookinfo（非章节页面），尝试从底部导航获取
            if (!nextPage) {
                var links = document.querySelectorAll('.page1 a');
                for (var i = 0; i < links.length; i++) {
                    if (links[i].innerText.includes('下一章')) {
                        nextPage = links[i].href;
                        break;
                    }
                }
            }
            
            // 获取正文
            var txtnav = document.querySelector('.txtnav');
            var html = txtnav ? txtnav.outerHTML : '';
            
            // 无标题且无正文 → 非章节页面
            if (!title && !html) {
                if (nextPage) return JSON.stringify({action: 'SKIP', next_url: nextPage});
                return JSON.stringify({action: 'DONE', reason: 'no_content'});
            }
            
            return JSON.stringify({
                action: 'CHAPTER',
                title: title,
                html: html,
                has_next: nextPage ? true : false,
                next_url: nextPage
            });
        })()
    " 2>/dev/null | tail -1 | sed 's/^result: //'
}

# 提取 69shuba 章节正文并保存
extract_69shuba_chapter() {
    local output_file="$1"
    local page_info_file="$TMP_DIR/page_info.json"
    local tmp_html="$TMP_DIR/chapter.html"
    
    # 获取页面信息
    get_69shuba_page_info > "$page_info_file"
    
    # 用 Python 解析 JSON（避免 bash 中文编码问题）
    local action
    action=$(python3 -c "
import json, sys
try:
    with open('$page_info_file', 'r') as f:
        raw = f.read().strip()
    # 可能有双重 JSON 包裹
    data = json.loads(raw)
    if isinstance(data, str):
        data = json.loads(data)
    print(data.get('action', 'ERROR'))
except Exception as e:
    print('ERROR')
    print(str(e), file=sys.stderr)
" 2>/dev/null) || action="ERROR"
    
    case "$action" in
        CF)
            echo "CF"
            return 0
            ;;
        SKIP)
            # 非章节页面但有下一页链接
            local skip_url
            skip_url=$(python3 -c "
import json
with open('$page_info_file', 'r') as f:
    raw = f.read().strip()
data = json.loads(raw)
if isinstance(data, str): data = json.loads(data)
print(data.get('next_url', ''))
" 2>/dev/null) || skip_url=""
            echo "SKIP|$skip_url"
            return 0
            ;;
        DONE)
            echo "DONE"
            return 0
            ;;
        CHAPTER)
            # 正常章节：提取 HTML 并用 Python 脚本处理
            python3 -c "
import json
with open('$page_info_file', 'r') as f:
    raw = f.read().strip()
data = json.loads(raw)
if isinstance(data, str): data = json.loads(data)
html = data.get('html', '')
# 写入临时文件
with open('$tmp_html', 'w') as f:
    f.write(json.dumps(html))
" 2>/dev/null
            
            python3 "$SCRIPT_DIR/extract_69shuba.py" "$tmp_html" "$output_file"
            
            # 返回章节信息
            local title has_next next_url
            read -r title has_next next_url < <(python3 -c "
import json
with open('$page_info_file', 'r') as f:
    raw = f.read().strip()
data = json.loads(raw)
if isinstance(data, str): data = json.loads(data)
title = data.get('title', '').replace('|', ' ')
has_next = 'true' if data.get('has_next') else 'false'
next_url = data.get('next_url', '')
print(f'{title}|{has_next}|{next_url}')
" 2>/dev/null | tr '|' '\t') || { title=""; has_next="false"; next_url=""; }
            
            echo "CHAPTER|$title|$has_next|$next_url"
            return 0
            ;;
        *)
            echo "ERROR"
            return 0
            ;;
    esac
}

# 69shuba 翻页（直接调用页面的 bookinfo.next_page）
next_chapter_69shuba() {
    local next_url="$1"
    
    if [[ -z "$next_url" ]]; then
        log_error "翻页 URL 为空"
        return 1
    fi
    
    # 直接设置 document.location（不用 open 命令，避免触发 CF）
    # 也不用 KeyboardEvent（keyCode 可能为 0，翻页失败）
    $BROWSER_USE --cdp-url "$CDP_URL" -- eval \
        "document.location = '$next_url'; 'navigated'" \
        2>/dev/null | tail -1
    
    # 等待页面加载
    sleep 2
}

# =====================================================
# zongheng 抓取函数
# =====================================================

extract_zongheng_chapter() {
    local tmp_json="$TMP_DIR/chapter.json"
    
    # 移除水印 + 提取标题和正文
    $BROWSER_USE --cdp-url "$CDP_URL" -- eval "
        document.querySelectorAll('.Jfcounts').forEach(el => el.remove());
        const title = document.querySelector('.title_txtbox')?.innerText || '';
        const ps = Array.from(document.querySelectorAll('.content p')).map(p => p.innerText);
        const nextA = Array.from(document.querySelectorAll('a')).find(a => a.innerText.trim() === '下一章');
        const nextUrl = nextA ? nextA.href : '';
        JSON.stringify({title, paragraphs: ps, nextUrl})
    " 2>/dev/null | tail -1 | sed 's/^result: //' > "$tmp_json"
    
    # 用 Python 脚本提取
    python3 "$SCRIPT_DIR/extract_zongheng.py" "$tmp_json" "$1" 2>&1 | while IFS= read -r line; do
        if [[ "$line" == NEXT_URL:* ]]; then
            echo "${line#NEXT_URL:}" > "$TMP_DIR/next_url"
        else
            echo "$line" >&2
        fi
    done
}

next_chapter_zongheng() {
    local next_url
    if [[ -f "$TMP_DIR/next_url" ]]; then
        next_url=$(cat "$TMP_DIR/next_url")
        rm -f "$TMP_DIR/next_url"
    else
        log_error "无法获取下一章 URL"
        return 1
    fi
    
    if [[ -z "$next_url" ]]; then
        log_error "下一章 URL 为空"
        return 1
    fi
    
    # 使用 open 命令导航（纵横不能用键盘翻页）
    $BROWSER_USE --cdp-url "$CDP_URL" -- open "$next_url" 2>/dev/null
    
    # 等待页面加载
    sleep 3
}

# =====================================================
# 主流程
# =====================================================

main() {
    [[ $# -lt 3 ]] && usage
    
    local chapter_url="$1"
    local num_chapters="$2"
    local output_file="$3"
    local site_type="${4:-$(detect_site "$chapter_url")}"
    
    if [[ "$site_type" == "unknown" ]]; then
        log_error "无法识别网站类型。请指定 site_type: 69shuba 或 zongheng"
        exit 1
    fi
    
    # 处理 "all" 模式
    local download_all=false
    local max_chapters=9999
    if [[ "$num_chapters" == "all" ]]; then
        download_all=true
        log_info "模式: 下载全部章节（直到最后一章）"
    else
        max_chapters="$num_chapters"
        log_info "模式: 下载 $num_chapters 章"
    fi
    
    log_info "网站类型: $site_type"
    log_info "输出文件: $output_file"
    
    check_prerequisites "$chapter_url"
    
    mkdir -p "$TMP_DIR"
    
    # ⚠️ 追加写入（不清空），支持断点续传
    touch "$output_file"
    
    local chapters_downloaded=0
    local consecutive_duplicates=0
    local last_title=""
    local cf_wait_count=0
    local max_cf_wait=60  # 最多等待 CF 验证 60 次（约 10 分钟）
    
    for i in $(seq 1 "$max_chapters"); do
        log_prog "正在处理第 $i 章..."
        
        local result=""
        
        case "$site_type" in
            69shuba)
                result=$(extract_69shuba_chapter "$output_file")
                ;;
            zongheng)
                # zongheng 仍用旧逻辑（目前够用）
                extract_zongheng_chapter "$output_file"
                result="CHAPTER|zongheng|true|"
                ;;
        esac
        
        # 解析结果
        local action
        action=$(echo "$result" | cut -d'|' -f1)
        
        case "$action" in
            CF)
                # Cloudflare 验证：暂停等待
                cf_wait_count=$((cf_wait_count + 1))
                if [[ $cf_wait_count -ge $max_cf_wait ]]; then
                    log_error "等待 Cloudflare 验证超时 (${max_cf_wait} 次)，退出"
                    break
                fi
                log_warn "检测到 Cloudflare 验证页面，请手动完成验证... (等待 $cf_wait_count/$max_cf_wait)"
                sleep 10
                # 不增加 i，重试当前章节
                continue
                ;;
            
            SKIP)
                # 非章节页面（如作者感言），跳过并翻页
                local skip_url
                skip_url=$(echo "$result" | cut -d'|' -f2)
                log_warn "非章节页面，跳过。"
                if [[ -n "$skip_url" ]]; then
                    next_chapter_69shuba "$skip_url"
                else
                    log_error "非章节页面且无翻页链接，停止"
                    break
                fi
                cf_wait_count=0
                continue
                ;;
            
            DONE)
                # 到达最后一章
                log_info "到达最后一章，下载完成"
                break
                ;;
            
            CHAPTER)
                # 正常章节
                local title has_next next_url
                title=$(echo "$result" | cut -d'|' -f2)
                has_next=$(echo "$result" | cut -d'|' -f3)
                next_url=$(echo "$result" | cut -d'|' -f4)
                
                cf_wait_count=0
                chapters_downloaded=$((chapters_downloaded + 1))
                
                # 重复章节检测
                if [[ "$title" == "$last_title" && -n "$title" ]]; then
                    consecutive_duplicates=$((consecutive_duplicates + 1))
                    log_warn "重复章节: $title (连续 $consecutive_duplicates 次)"
                    if [[ $consecutive_duplicates -ge 3 ]]; then
                        log_error "连续 3 次重复章节，翻页可能失效，停止下载"
                        break
                    fi
                else
                    consecutive_duplicates=0
                fi
                last_title="$title"
                
                log_info "[$chapters_downloaded] $title ✓"
                
                # 翻到下一章
                if [[ "$has_next" == "true" && -n "$next_url" ]]; then
                    if [[ "$download_all" == "true" || $i -lt $max_chapters ]]; then
                        next_chapter_69shuba "$next_url"
                    fi
                elif [[ "$download_all" == "true" ]]; then
                    log_info "无下一章链接，全书下载完成"
                    break
                fi
                ;;
            
            ERROR|*)
                log_error "提取失败，跳过"
                # 尝试继续
                ;;
        esac
    done
    
    # 清理临时文件
    rm -rf "$TMP_DIR"
    
    local line_count
    line_count=$(wc -l < "$output_file" | tr -d ' ')
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "下载完成！"
    log_info "  已下载章节: $chapters_downloaded"
    log_info "  总行数: $line_count"
    log_info "  输出文件: $output_file"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

main "$@"
