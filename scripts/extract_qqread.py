#!/usr/bin/env python3
"""
QQ阅读 (book.qq.com) 章节提取脚本
通过 Chrome DevTools Protocol (CDP) 提取章节内容
"""
import json
import subprocess
import sys
import time

try:
    import websocket
except ImportError:
    print("正在安装 websocket-client...")
    subprocess.run([sys.executable, '-m', 'pip', 'install', 'websocket-client', '-q'])
    import websocket


def get_qq_read_tab():
    """获取 QQ 阅读页面的 WebSocket URL"""
    result = subprocess.run(
        ['curl', '-s', 'http://localhost:9222/json'],
        capture_output=True, text=True
    )
    tabs = json.loads(result.stdout)
    for tab in tabs:
        url = tab.get('url', '')
        if 'book.qq.com' in url and 'book-read' in url:
            return tab['webSocketDebuggerUrl'], url
    return None, None


def extract_chapter(ws_url):
    """提取当前章节内容"""
    ws = websocket.create_connection(ws_url, timeout=10)
    
    js_code = """
    (function() {
        // 获取章节标题 - 精确选择器：#bookRead > div.page-content > div.read-header > h1
        let title = document.querySelector('#bookRead > div.page-content > div.read-header > h1')?.innerText || '';
        if (!title) {
            // 降级：尝试 h1.chapter-title 或从 pageTitle 提取
            title = document.querySelector('h1.chapter-title')?.innerText || '';
            if (!title) {
                const pageTitle = document.title;
                const match = pageTitle.match(/第\\d+章[^在线]*/);
                title = match ? match[0].trim() : pageTitle.split('_')[1]?.split('在线')[0] || pageTitle;
            }
        }
        
        // 获取正文 - 精确选择器：#article
        const articleDiv = document.querySelector('#article');
        const paragraphs = articleDiv 
            ? Array.from(articleDiv.querySelectorAll('p')).map(p => p.innerText.trim()).filter(t => t && t.length > 0)
            : Array.from(document.querySelectorAll('.chapter-content p, .page-content p')).map(p => p.innerText.trim()).filter(t => t && t.length > 0);
        
        // 获取下一章链接
        let nextUrl = '';
        const links = document.querySelectorAll('a');
        for (const a of links) {
            if (a.innerText.includes('下一章')) {
                nextUrl = a.href;
                break;
            }
        }
        
        return JSON.stringify({
            title: title,
            paragraphs: paragraphs,
            nextUrl: nextUrl,
            currentUrl: location.href
        });
    })()
    """
    
    msg = json.dumps({
        "id": 1,
        "method": "Runtime.evaluate",
        "params": {"expression": js_code, "returnByValue": True}
    })
    
    ws.send(msg)
    response = json.loads(ws.recv())
    ws.close()
    
    if 'result' in response and 'result' in response['result']:
        value = response['result']['result'].get('value')
        if value:
            return json.loads(value)
    return None


def navigate_to_next(ws_url, next_url):
    """导航到下一章"""
    ws = websocket.create_connection(ws_url, timeout=10)
    
    js_code = f"location.href = '{next_url}'; 'navigated'"
    
    msg = json.dumps({
        "id": 1,
        "method": "Runtime.evaluate",
        "params": {"expression": js_code}
    })
    
    ws.send(msg)
    ws.recv()
    ws.close()


def save_chapter(data, output_file, mode='a'):
    """保存章节到文件"""
    with open(output_file, mode, encoding='utf-8') as f:
        # 写入章节标题
        f.write(f"\n{'='*50}\n")
        f.write(f"{data['title']}\n")
        f.write(f"{'='*50}\n\n")
        
        # 写入正文
        for p in data['paragraphs']:
            if p.strip():
                f.write(f"{p}\n\n")


def main():
    if len(sys.argv) < 3:
        print("用法: python extract_qqread.py <章节数|all> <输出文件>")
        print("示例: python extract_qqread.py 3 长夜余火_前3章.txt")
        sys.exit(1)
    
    chapter_count = sys.argv[1]
    output_file = sys.argv[2]
    
    max_chapters = float('inf') if chapter_count == 'all' else int(chapter_count)
    
    # 获取 QQ 阅读页面
    ws_url, current_url = get_qq_read_tab()
    if not ws_url:
        print("错误: 未找到 QQ 阅读页面，请确保 Chrome 已打开章节页面")
        sys.exit(1)
    
    print(f"已连接到: {current_url}")
    print(f"目标章节数: {chapter_count}")
    print(f"输出文件: {output_file}")
    print("-" * 50)
    
    downloaded = 0
    last_title = None
    same_title_count = 0
    
    while downloaded < max_chapters:
        # 需要重新获取 ws_url（页面导航后会变）
        ws_url, _ = get_qq_read_tab()
        if not ws_url:
            print("错误: 连接丢失")
            break
        
        # 提取当前章节
        data = extract_chapter(ws_url)
        if not data:
            print("提取失败，重试...")
            time.sleep(2)
            continue
        
        # 检测重复章节
        if data['title'] == last_title:
            same_title_count += 1
            if same_title_count >= 3:
                print(f"检测到重复章节 '{data['title']}'，停止下载")
                break
        else:
            same_title_count = 0
            last_title = data['title']
        
        # 保存章节
        mode = 'w' if downloaded == 0 else 'a'
        save_chapter(data, output_file, mode)
        downloaded += 1
        
        print(f"[{downloaded}/{chapter_count}] {data['title']} - {len(data['paragraphs'])} 段")
        
        # 检查是否有下一章
        if not data['nextUrl']:
            print("已到达最后一章")
            break
        
        if downloaded < max_chapters:
            # 导航到下一章
            navigate_to_next(ws_url, data['nextUrl'])
            time.sleep(2)  # 等待页面加载
    
    print("-" * 50)
    print(f"完成! 共下载 {downloaded} 章，保存到: {output_file}")


if __name__ == "__main__":
    main()
