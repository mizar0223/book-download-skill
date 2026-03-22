#!/usr/bin/env python3
"""
从 69shuba.com 章节页面 HTML 中提取正文。
用法：
  python3 extract_69shuba.py <html_file> [output_file]
  
  html_file: 包含页面 HTML 的文件（通过 browser-use eval 获取）
  output_file: 可选，输出纯文本文件路径。不指定则输出到 stdout。
"""

import re
import sys
import json
import os


def extract_chapter(html: str) -> tuple[str, str]:
    """
    从 69shuba.com 章节 HTML 提取标题和正文。
    返回 (title, content)。
    """
    # 提取 txtnav 到 bottom-ad 之间的内容
    match = re.search(r'class="txtnav"[^>]*>(.*?)(?:<div\s+class="bottom-ad")', html, re.DOTALL)
    if not match:
        # 尝试备用匹配
        match = re.search(r'class="txtnav"[^>]*>(.*?)$', html, re.DOTALL)
    if not match:
        return "", "[提取失败：未找到 txtnav 容器]"
    
    content = match.group(1)
    
    # 移除广告和无关元素
    content = re.sub(r'<div\s+id="txtright"[^>]*>.*?</div>', '', content, flags=re.DOTALL)
    content = re.sub(r'<div\s+class="contentadv"[^>]*>.*?</div>', '', content, flags=re.DOTALL)
    content = re.sub(r'<div\s+class="txtinfo"[^>]*>.*?</div>', '', content, flags=re.DOTALL)
    content = re.sub(r'<script[^>]*>.*?</script>', '', content, flags=re.DOTALL)
    content = re.sub(r'<style[^>]*>.*?</style>', '', content, flags=re.DOTALL)
    
    # 移除底部导航
    content = re.sub(r'<div\s+class="page1"[^>]*>.*?</div>', '', content, flags=re.DOTALL)
    
    # 提取标题（h1 标签）
    title_match = re.search(r'<h1[^>]*>(.*?)</h1>', content, re.DOTALL)
    title = ""
    if title_match:
        title = re.sub(r'<[^>]+>', '', title_match.group(1)).strip()
        content = content[title_match.end():]
    
    # 将 <br> 转换为换行
    content = re.sub(r'<br\s*/?>', '\n', content, flags=re.IGNORECASE)
    
    # 移除所有剩余 HTML 标签
    content = re.sub(r'<[^>]+>', '', content)
    
    # 清理文本：解码 HTML 实体
    content = content.replace('&nbsp;', ' ')
    content = content.replace('&lt;', '<')
    content = content.replace('&gt;', '>')
    content = content.replace('&amp;', '&')
    content = content.replace('&quot;', '"')
    
    # 清理多余空白，保留段落分隔
    lines = []
    for line in content.split('\n'):
        stripped = line.strip()
        if stripped:
            lines.append(stripped)
    
    content = '\n\n'.join(lines)
    
    return title, content


def main():
    if len(sys.argv) < 2:
        print("用法: python3 extract_69shuba.py <html_file> [output_file]", file=sys.stderr)
        sys.exit(1)
    
    html_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else None
    
    with open(html_file, 'r', encoding='utf-8') as f:
        data = f.read()
    
    # 尝试 JSON 解析（browser-use eval 输出可能是 JSON 包裹的字符串）
    try:
        data = json.loads(data)
        if isinstance(data, str):
            html = data
        else:
            html = str(data)
    except (json.JSONDecodeError, TypeError):
        html = data
    
    title, content = extract_chapter(html)
    
    result = f"{title}\n\n{content}" if title else content
    
    if output_file:
        with open(output_file, 'a', encoding='utf-8') as f:
            f.write(result + '\n\n')
        print(f"已保存: {title or '(无标题)'}", file=sys.stderr)
    else:
        print(result)


if __name__ == '__main__':
    main()
