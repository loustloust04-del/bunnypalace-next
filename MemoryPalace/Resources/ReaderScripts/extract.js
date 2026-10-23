// 联网搜索 Phase 1：胶水脚本。
// 前置：readability.min.js + turndown.min.js 已 evaluate 注入。
// 调用：拼在两个 lib 后面 evaluateJavaScript，最后一个表达式（IIFE return）是 Swift 端拿到的字符串。
// 输入：当前 webView load 的页面 document。
// 输出：JSON 字符串 — { title, byline, markdown, length, excerpt } 或 { error }。
(function () {
  try {
    if (typeof Readability !== 'function' || typeof TurndownService !== 'function') {
      return JSON.stringify({ error: 'lib-missing: Readability=' + typeof Readability + ' Turndown=' + typeof TurndownService });
    }
    var docClone = document.cloneNode(true);
    var article = new Readability(docClone).parse();
    if (!article) {
      return JSON.stringify({ error: 'no-article', title: document.title || '', url: location.href });
    }
    var td = new TurndownService({ headingStyle: 'atx', codeBlockStyle: 'fenced', bulletListMarker: '-' });
    var md = td.turndown(article.content || '');
    return JSON.stringify({
      title: article.title || '',
      byline: article.byline || null,
      markdown: md || '',
      length: (article.textContent || '').length,
      excerpt: article.excerpt || null
    });
  } catch (e) {
    return JSON.stringify({ error: 'extract-failed: ' + String(e && e.message || e) });
  }
})();
