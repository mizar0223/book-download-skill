#!/usr/bin/env python3
"""
从 zongheng.com（纵横中文网）章节页面提取正文。
用法：
  python3 extract_zongheng.py <json_file> [output_file]

  json_file: 包含提取结果的 JSON 文件（由 browser-use eval 生成）
  output_file: 可选，输出纯文本文件路径。不指定则输出到 stdout。
"""

import json
import sys
import re


def clean_text(text: str) -> str:
    """清理提取的文本内容。"""
    # 移除 HTML 标签残留
    text = re.sub(r'<[^>]+>', '', text)
    # 解码 HTML 实体
    text = text.replace('&nbsp;', ' ')
    text = text.replace('&lt;', '<')
    text = text.replace('&gt;', '>')
    text = text.replace('&amp;', '&')
    text = text.replace('&quot;', '"')
    
    # 清理多余空白
    lines = []
    for line in text.split('\n'):
        stripped = line.strip()
        if stripped:
            lines.append(stripped)
    
    return '\n\n'.join(lines)


def main():
    if len(sys.argv) < 2:
        print("用法: python3 extract_zongheng.py <json_file> [output_file]", file=sys.stderr)
        sys.exit(1)
    
    json_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else None
    
    with open(json_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    title = data.get('title', '').strip()
    paragraphs = data.get('paragraphs', [])
    next_url = data.get('nextUrl', '')
    
    content = '\n\n'.join(p.strip() for p in paragraphs if p.strip())
    content = clean_text(content)
    
    result = f"{title}\n\n{content}" if title else content
    
    if output_file:
        with open(output_file, 'a', encoding='utf-8') as f:
            f.write(result + '\n\n')
        print(f"已保存: {title or '(无标题)'}", file=sys.stderr)
    else:
        print(result)
    
    # 输出下一章 URL 到 stderr，方便脚本流程使用
    if next_url:
        print(f"NEXT_URL:{next_url}", file=sys.stderr)


if __name__ == '__main__':
    main()
